# breakbulk module for datboi2 (field trial; docs/field-trials.md).
#
# Written as the repository would carry it in nix/rust.nix, replacing the
# crane wiring in its flake.nix:
#   - `host`: the root workspace (crates/*), native, release; its CI also
#     runs clippy (--workspace --all-targets -D warnings) and the tests.
#   - eight wasm component workspaces (crates/datboi-{xf,ex}-*), each its
#     own lockfile, built for wasm32-unknown-unknown, componentized and
#     stamped; their unit tests run natively as in the flake.
#   - `emu-ds`: a nightly-only standalone workspace with git dependencies,
#     a wasm-bindgen browser core.
#   - the host embeds the components (DATBOI_COMPONENTS_DIR), the web dist
#     (DATBOI_WEB_DIST), the emu core (DATBOI_EMU_DS) and file(1)'s magic
#     database (DATBOI_MAGIC_DB) through build-script env.
{
  lib,
  pkgs,
  root,
  repo,
  breakbulk,
  ...
}:
let
  wasm = "wasm32-unknown-unknown";
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  # rust-toolchain.toml: 1.96.1, default profile, wasm32 target.
  rust = pkgs.rust-bin.fromRustupToolchainFile (root + "/rust-toolchain.toml");
  toolchain = {
    rustc = rust;
    cargo = rust;
    clippy = rust;
  };
  # The emu lane's pinned nightly (flake.nix emuToolchainFor).
  emuRust = pkgs.rust-bin.nightly."2025-12-20".minimal.override { targets = [ wasm ]; };

  components = [
    "datboi-xf-cso"
    "datboi-xf-ecm"
    "datboi-xf-preflate"
    "datboi-xf-reference"
    "datboi-xf-reference-stream"
    "datboi-xf-xgd1-prng"
    "datboi-ex-unrar"
    "datboi-ex-7z"
  ];
  isExtractor = lib.hasPrefix "datboi-ex-";
  guestOf = c: if isExtractor c then "datboi-guest-extractor" else "datboi-guest-transform";
  moduleName = c: lib.replaceStrings [ "-" ] [ "_" ] c;

  # ---- non-Rust inputs (the same recipes as flake.nix) ----------------------

  # flake.nix spells the wasi32 toolchain's names for its nixpkgs pin
  # (wasm32-unknown-wasi-*, lib/wasm32-wasi, lib/wasi); newer nixpkgs calls
  # the platform wasm32-unknown-wasip1, so read the names from the set.
  wasi = pkgs.pkgsCross.wasi32;
  cc = wasi.stdenv.cc;
  wasiEnv = {
    DATBOI_WASI_CXX = "${cc}/bin/${cc.targetPrefix}clang++";
    DATBOI_WASI_CC = "${cc}/bin/${cc.targetPrefix}clang";
    DATBOI_WASI_WASMLD = "${cc.bintools.bintools}/bin/${cc.targetPrefix}wasm-ld";
    DATBOI_WASI_LIBCXX_DIR = "${wasi.llvmPackages.libcxx}/lib";
    DATBOI_WASI_LIBC_DIR = "${wasi.wasilibc}/lib/wasm32-wasip1";
    DATBOI_WASI_BUILTINS_DIR = "${wasi.llvmPackages.compiler-rt}/lib/wasip1";
  };
  unrarSrc = pkgs.callPackage (root + "/crates/datboi-ex-unrar/nix/unrar-src.nix") { };
  lzmaSdk = pkgs.callPackage (root + "/crates/datboi-ex-7z/nix/lzma-sdk.nix") { };

  webSrc = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (lib.fileset.difference (root + "/web") (
        lib.fileset.unions [
          (lib.fileset.maybeMissing (root + "/web/node_modules"))
          (lib.fileset.maybeMissing (root + "/web/dist"))
          (lib.fileset.maybeMissing (root + "/web/.vite"))
        ]
      ))
      (root + "/crates/datboi-api/openapi.json")
    ];
  };
  webNodeModules = pkgs.importNpmLock.buildNodeModules {
    npmRoot = "${webSrc}/web";
    inherit (pkgs) nodejs;
  };
  web = pkgs.stdenv.mkDerivation {
    pname = "datboi-web";
    version = "0.1.0";
    src = webSrc;
    sourceRoot = "source/web";
    nativeBuildInputs = [ pkgs.nodejs ];
    buildPhase = ''
      ln -s ${webNodeModules}/node_modules node_modules
      npm run generate
      npm run build
    '';
    installPhase = "cp -r dist $out";
  };
  magicDb = pkgs.runCommand "datboi-magic-mgc" { } ''
    cp ${pkgs.file}/share/misc/magic.mgc $out
  '';

  # ---- component stamping (flake.nix transformPackageFor) ---------------------

  # After componentize: the D54 identity stamp, with the git tree hashes of
  # the crate and its lane's guest crate as the revision; installed as
  # lib/<module>.wasm, the layout DATBOI_COMPONENTS_DIR expects.
  stamp =
    c:
    { input, pkgs, ... }:
    let
      manifest = builtins.fromTOML (builtins.readFile (root + "/crates/${c}/Cargo.toml"));
    in
    pkgs.runCommand "${c}-stamped"
      {
        nativeBuildInputs = [
          pkgs.wasm-tools
          pkgs.gitMinimal
        ];
      }
      ''
        export GIT_DIR="$TMPDIR/rev-git"
        git init -q "$GIT_DIR"
        export GIT_INDEX_FILE="$TMPDIR/rev-index"
        git --work-tree=${root + "/crates/${c}"} add -A
        tree=$(git write-tree)
        export GIT_INDEX_FILE="$TMPDIR/rev-index-guest"
        git --work-tree=${root + "/crates/${guestOf c}"} add -A
        guest=$(git write-tree)
        mkdir -p $out/lib
        wasm-tools metadata add ${input}/${moduleName c}.wasm \
          --name "datboi:${lib.removePrefix "datboi-" c}" \
          --description ${lib.escapeShellArg manifest.package.description} \
          --authors ${lib.escapeShellArg (builtins.head manifest.package.authors)} \
          --licenses ${lib.escapeShellArg manifest.package.license} \
          --source "https://github.com/schlarpc/datboi/tree/main/crates/${c}" \
          --revision "tree:$tree;guest:$guest" \
          -o "$out/lib/${moduleName c}.wasm"
      '';

  transforms = pkgs.symlinkJoin {
    name = "datboi-transforms";
    paths = map (c: repo.workspaces.${c}.target.${wasm}.packages.${c}) components;
  };

  # The emu core: wasm-bindgen --target web --no-typescript into pkg/, plus
  # the crate's asset/ and test-page/ at the root (flake.nix emuDsFor).
  emuInstall =
    { input, pkgs, ... }:
    pkgs.runCommand "datboi-emu-ds" { } ''
      mkdir -p $out/pkg
      cp -r ${input}/. $out/pkg/
      cp -r ${root + "/crates/datboi-emu-ds/asset"}/. $out/
      cp -r ${root + "/crates/datboi-emu-ds/test-page"}/. $out/
    '';
in
{
  mode = "ifd";

  workspaces = {
    host = {
      path = ".";
      inherit toolchain;
      variants.default = { };
      variants.clippy = {
        mode = "clippy";
        clippyArgs = [
          "--deny"
          "warnings"
        ];
      };
    };
    emu-ds = {
      path = "crates/datboi-emu-ds";
      toolchain = {
        rustc = emuRust;
        cargo = emuRust;
      };
      targets.${wasm} = { };
    };
  }
  // lib.genAttrs components (c: {
    path = "crates/${c}";
    inherit toolchain;
    # The component for wasm; its unit tests natively (flake.nix
    # `<crate>-test`).
    targets = {
      ${wasm} = { };
      ${native} = { };
    };
  });

  targets.${wasm}.preset = breakbulk.presets.wasmComponent { rustc = rust; };
  # Without a preset the native target links with rustc's own rust-lld,
  # which bypasses nixpkgs' linker wrapper (no rpath for libmagic.so).
  targets.${native}.preset = breakbulk.presets.linuxGnu;

  packages = lib.mkMerge [
    {
      # The wit-bindgen macro reads ../../wit/<lane>/v1 (and the deps/
      # symlinks inside it) at compile time.
      datboi-guest-transform.extraSources = [ "wit" ];
      datboi-guest-extractor.extraSources = [ "wit" ];
      # The host side of the same worlds (wasmtime's bindgen!).
      datboi-runtime.extraSources = [ "wit" ];
      # Tests that include_bytes! fixtures of sibling crates.
      # These pin the blake3 of the crane-built components, whose bytes
      # carry crane's build paths in panic locations (/build/nest/…, the
      # vendor directory) and the wit-component version of the flake's
      # wasm-tools. breakbulk's components differ, deterministically; a
      # migration re-pins them.
      datboi-runtime.test.args = [
        "--skip"
        "component_bytes_are_pinned"
      ];
      datboi-runtime.test.sourceScope = [
        "crates/datboi-ingest/tests/fixtures"
        "crates/datboi-xf-xgd1-prng/data"
      ];
      datboi-exec.test.sourceScope = [ "crates/datboi-runtime/tests/fixtures" ];

      # The `magic` crate links libmagic. magic-sys's build script prints
      # only `rustc-link-lib=dylib=magic` unless MAGIC_DIR is set, and the
      # final link happens in the binaries' units, which do not get
      # magic-sys's inputs; MAGIC_DIR makes it print the search path too.
      magic-sys.env.MAGIC_DIR = "${lib.getLib pkgs.file}/lib";

      # The curated default sets LIBSQLITE3_SYS_USE_PKG_CONFIG=1, which
      # replaces rusqlite's `bundled` SQLite (what the crane build ships)
      # with nixpkgs' sqlite.
      libsqlite3-sys = {
        env = lib.mkForce { };
        nativeInputs = lib.mkForce [ ];
        inputs = lib.mkForce [ ];
      };

      # Embeds (build-script env, re-exported with rustc-env).
      datboi-runtime.env.DATBOI_COMPONENTS_DIR = "${transforms}/lib";
      datboi-ingest.env.DATBOI_COMPONENTS_DIR = "${transforms}/lib";
      datboi-server.env = {
        DATBOI_WEB_DIST = "${web}";
        DATBOI_MAGIC_DB = "${magicDb}";
        DATBOI_EMU_DS = "${repo.workspaces.emu-ds.target.${wasm}.packages.datboi-emu-ds}";
      };

      # datboi-gen-openapi is a dev tool that writes
      # $CARGO_MANIFEST_DIR/openapi.json, so it names its source on
      # purpose (the default check caught it; crane's build embeds
      # /build/source there).
      datboi-api.checks.noSourceReferences = null;

      # The D62 fsck-in-CI gate.
      datboi.test = {
        path = [ pkgs.dosfstools ];
        env.DATBOI_REQUIRE_FSCK = "1";
      };
      datboi-exec.test = {
        path = [ pkgs.dosfstools ];
        env.DATBOI_REQUIRE_FSCK = "1";
      };

      datboi-ex-unrar.env = wasiEnv // {
        DATBOI_UNRAR_SRC = "${unrarSrc}";
      };
      datboi-ex-7z.env = wasiEnv // {
        DATBOI_LZMA_SRC = "${lzmaSdk}";
      };

      datboi-emu-ds.target.${wasm}.stages = {
        wasmOpt = lib.mkForce null;
        componentize = lib.mkForce null;
        bindgen = {
          after = "linked";
          run = breakbulk.stageHelpers.bindgen {
            extraArgs = [ "--no-typescript" ];
          };
        };
        emu = {
          after = "bindgen";
          run = emuInstall;
        };
        install = lib.mkForce null;
      };
    }
    (lib.genAttrs components (c: {
      target.${wasm}.stages = {
        # No wasm-opt: the flake componentizes the core module as built.
        wasmOpt = lib.mkForce null;
        stamp = {
          after = "componentize";
          run = stamp c;
        };
        install = lib.mkForce null;
      };
    }))
  ];
}
