# Target traits (lib/target-traits.nix; "Target traits" in
# docs/src/explanation/internals/toolchains.md).
#
#   target-traits        evaluation assertions: built-in traits of the
#                        targets breakbulk has presets for, a user's
#                        traits merged over them (and for a target with no
#                        built-in ones) reaching the linker choice, the
#                        debug handling and the resolved repository target,
#                        and an unknown target failing only when a trait
#                        is read
#   target-traits-rustc  `parse` against `rustc --print cfg --target <t>`
#                        for every built-in target of nixpkgs' rustc (IFD):
#                        each name it knows has rustc's vendor, os, env
#                        and families (and abi, where the name spells one);
#                        its file-name traits are `--print file-names`',
#                        and objectFormat, isApple, isWasm, isMsvc/isUefi
#                        (an MSVC-style linker) and debugArtifacts are
#                        what `--print all-target-specs-json` says
#   linker-kind-rustc    the default Linux linker kind against the linker
#                        flavor of rustc's own target specs, for several
#                        rust-lang releases and nixpkgs' rustc
{
  pkgs,
  bb,
  runTests,
}:
let
  inherit (pkgs) lib;
  tt = bb.targetTraits;
  r = triple: tt.resolve { inherit triple; };
  pick = fields: t: lib.getAttrs fields t;
  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;

  # A target breakbulk knows nothing about, declared by the user, as
  # mkRepository resolves it.
  repo = bb.mkRepository {
    inherit pkgs;
    root = ../fixtures/walking-skeleton;
    modules = [
      {
        workspaces.main.targets."my-board" = { };
        targets."my-board".traits = {
          arch = "x86_64";
          os = "linux";
          env = "musl";
          executableSuffix = ".elf";
        };
        # A known triple with one trait corrected.
        workspaces.main.targets."x86_64-unknown-linux-gnu".traits.dylibPathVar = "MY_LIBS";
      }
    ];
  };
  board = repo.workspaces.main.target."my-board".traits;
  native = repo.workspaces.main.target."x86_64-unknown-linux-gnu".traits;

  rustcCfgs = pkgs.runCommand "rustc-target-cfgs" { nativeBuildInputs = [ pkgs.rustc ]; } ''
    for t in $(rustc --print target-list); do
      # Targets whose LLVM backend nixpkgs' LLVM lacks fail; skip them.
      rustc --print cfg --target "$t" > cfg 2>/dev/null || continue
      printf '%s' "$t"
      for k in vendor os env abi; do
        printf '\t%s' "$(sed -n "s/^target_$k=\"\(.*\)\"$/\1/p" cfg)"
      done
      printf '\t%s\n' "$(sed -n 's/^target_family="\(.*\)"$/\1/p' cfg | paste -sd, -)"
    done > $out
  '';
  rows = map (
    l:
    let
      f = lib.splitString "\t" l;
    in
    {
      triple = lib.elemAt f 0;
      vendor = lib.elemAt f 1;
      os = lib.elemAt f 2;
      env = lib.elemAt f 3;
      abi = lib.elemAt f 4;
      families = lib.elemAt f 5;
    }
  ) (lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile rustcCfgs)));
  check =
    row:
    let
      p = tt.parse row.triple;
    in
    if p == null then
      null
    else if
      p.vendor == row.vendor
      && p.os == row.os
      && p.env == row.env
      && lib.concatStringsSep "," p.families == row.families
      # rustc infers some abis the name does not spell (powerpc64's elfv1
      # and elfv2); a spelled one must match.
      && (p.abi == "" || p.abi == row.abi)
    then
      true
    else
      "${row.triple}: parsed ${
        builtins.toJSON (
          removeAttrs p [
            "arch"
            "triple"
          ]
        )
      }, rustc says ${builtins.toJSON row}";
  results = map check rows;
  mismatches = lib.filter builtins.isString results;
  known = lib.count (x: x == true) results;

  # The file-name traits against `rustc --print file-names` per crate type
  # (empty where rustc drops the crate type for the target: no dylibs on
  # wasm, none of either on bare metal).
  rustcFileNames = pkgs.runCommand "rustc-target-file-names" { nativeBuildInputs = [ pkgs.rustc ]; } ''
    for t in $(rustc --print target-list); do
      rustc --print cfg --target "$t" >/dev/null 2>&1 || continue
      printf '%s' "$t"
      for c in bin dylib cdylib staticlib; do
        printf '\t%s' "$(rustc --print file-names --crate-type $c --crate-name foo --target "$t" - </dev/null 2>/dev/null)"
      done
      printf '\n'
    done > $out
  '';
  fileNameRows = map (
    l:
    let
      f = lib.splitString "\t" l;
    in
    {
      triple = lib.elemAt f 0;
      bin = lib.elemAt f 1;
      dylib = lib.elemAt f 2;
      cdylib = lib.elemAt f 3;
      staticlib = lib.elemAt f 4;
    }
  ) (lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile rustcFileNames)));
  checkFileNames =
    row:
    let
      t = r row.triple;
      expect = {
        bin = "foo${t.executableSuffix}";
        dylib = "${t.sharedLibraryPrefix}foo${t.sharedLibrarySuffix}";
        cdylib = "${t.sharedLibraryPrefix}foo${t.sharedLibrarySuffix}";
        staticlib = "${t.staticLibraryPrefix}foo${t.staticLibrarySuffix}";
      };
      wrong = lib.filter (c: row.${c} != "" && row.${c} != expect.${c}) (lib.attrNames expect);
    in
    if tt.parse row.triple == null then
      null
    else if wrong == [ ] then
      true
    else
      "${row.triple}: ${lib.concatMapStringsSep ", " (c: "${c} is ${row.${c}}, traits say ${expect.${c}}") wrong}";
  fileNameResults = map checkFileNames fileNameRows;
  fileNameMismatches = lib.filter builtins.isString fileNameResults;
  fileNamesKnown = lib.count (x: x == true) fileNameResults;

  # The fields rustc's target specs state, against
  # `--print all-target-specs-json` (every built-in target, whether
  # nixpkgs' LLVM has its backend or not). A key a spec leaves out has
  # rustc's default (rustc_target spec/json.rs writes only the others).
  rustcSpecs = builtins.fromJSON (
    builtins.readFile (
      pkgs.runCommand "rustc-target-specs" { nativeBuildInputs = [ pkgs.rustc ]; } ''
        RUSTC_BOOTSTRAP=1 rustc -Z unstable-options --print all-target-specs-json > $out
      ''
    )
  );
  checkSpec =
    triple: spec:
    let
      t = r triple;
      s = k: d: spec.${k} or d;
      supported = s "supported-split-debuginfo" [ "off" ];
      # rustc_codegen_ssa back/link.rs: the side files of an MSVC-style
      # link, dsymutil, thorin and split DWARF (as breakbulk-plan's
      # target_spec.rs reads them).
      msvcLinker = lib.elem (s "linker-flavor" "gcc") [
        "msvc"
        "msvc-lld"
      ];
      artifacts =
        lib.optional msvcLinker {
          suffix = ".pdb";
          when = "always";
        }
        ++ lib.optional (lib.elem "packed" supported && s "is-like-darwin" false) {
          suffix = ".dSYM";
          when = "split-packed";
          directory = true;
        }
        ++ lib.optional (
          lib.elem "packed" supported && !(s "is-like-darwin" false) && !(s "is-like-windows" false)
        ) {
          suffix = ".dwp";
          when = "split-packed";
        }
        ++ lib.optional (lib.elem "unpacked" supported && s "debuginfo-kind" "dwarf" == "dwarf") {
          suffix = ".dwo";
          when = "split-unpacked";
          perObject = true;
        };
      expect = {
        # rustc writes wasm for every `is-like-wasm` target, whatever
        # `binary-format` says (WALI's is elf).
        objectFormat =
          if s "is-like-wasm" false then
            "wasm"
          else
            {
              elf = "elf";
              coff = "pe";
              mach-o = "macho";
              xcoff = "xcoff";
            }
            .${s "binary-format" "elf"};
        isApple = s "is-like-darwin" false;
        isWasm = s "is-like-wasm" false;
        isMsvcOrUefi = msvcLinker;
        debugArtifacts = artifacts;
      };
      ours = {
        inherit (t) objectFormat isApple isWasm;
        isMsvcOrUefi = t.isMsvc || t.isUefi;
        inherit (t) debugArtifacts;
      };
      wrong = lib.filter (f: ours.${f} != expect.${f}) (lib.attrNames expect);
    in
    if tt.parse triple == null then
      null
    else if wrong == [ ] then
      true
    else
      "${triple}: ${
        lib.concatMapStringsSep ", " (
          f: "${f} is ${builtins.toJSON ours.${f}}, rustc's spec says ${builtins.toJSON expect.${f}}"
        ) wrong
      }";
  specResults = lib.mapAttrsToList checkSpec rustcSpecs;
  specMismatches = lib.filter builtins.isString specResults;
  specsKnown = lib.count (x: x == true) specResults;
in
{
  target-traits = runTests "target-traits" {
    testLinuxGnu = {
      expr = pick [
        "arch"
        "vendor"
        "os"
        "env"
        "isLinux"
        "objectFormat"
        "executableSuffix"
        "dylibPathVar"
        "debugInfo"
        "kernel"
        "debugArtifacts"
      ] (r "x86_64-unknown-linux-gnu");
      expected = {
        arch = "x86_64";
        vendor = "unknown";
        os = "linux";
        env = "gnu";
        isLinux = true;
        objectFormat = "elf";
        executableSuffix = "";
        dylibPathVar = "LD_LIBRARY_PATH";
        debugInfo = "split";
        kernel = "linux";
        debugArtifacts = [
          {
            suffix = ".dwp";
            when = "split-packed";
          }
          {
            suffix = ".dwo";
            when = "split-unpacked";
            perObject = true;
          }
        ];
      };
    };
    testMsvc = {
      expr = pick [
        "isWindows"
        "isMsvc"
        "isMingw"
        "objectFormat"
        "executableSuffix"
        "sharedLibraryPrefix"
        "sharedLibrarySuffix"
        "staticLibraryPrefix"
        "staticLibrarySuffix"
        "debugArtifacts"
        "kernel"
        "dylibPathVar"
        "dylibPathSep"
        "debugInfo"
      ] (r "aarch64-pc-windows-msvc");
      expected = {
        isWindows = true;
        isMsvc = true;
        isMingw = false;
        objectFormat = "pe";
        executableSuffix = ".exe";
        sharedLibraryPrefix = "";
        sharedLibrarySuffix = ".dll";
        staticLibraryPrefix = "";
        staticLibrarySuffix = ".lib";
        debugArtifacts = [
          {
            suffix = ".pdb";
            when = "always";
          }
        ];
        kernel = "windows";
        dylibPathVar = "PATH";
        dylibPathSep = ";";
        debugInfo = "keep";
      };
    };
    testMingw = {
      expr = map (t: pick [ "isMingw" "abi" "staticLibrarySuffix" "debugInfo" ] (r t)) [
        "x86_64-pc-windows-gnu"
        "x86_64-pc-windows-gnullvm"
      ];
      expected = [
        {
          isMingw = true;
          abi = "";
          staticLibrarySuffix = ".a";
          debugInfo = "keep";
        }
        {
          isMingw = true;
          abi = "llvm";
          staticLibrarySuffix = ".a";
          debugInfo = "keep";
        }
      ];
    };
    # Linked by rust-lld as lld-link, so a PDB on every link, as on msvc.
    testUefi = {
      expr = pick [
        "isUefi"
        "isMsvc"
        "objectFormat"
        "executableSuffix"
        "debugArtifacts"
        "kernel"
        "dylibPathVar"
        "debugInfo"
      ] (r "x86_64-unknown-uefi");
      expected = {
        isUefi = true;
        isMsvc = false;
        objectFormat = "pe";
        executableSuffix = ".efi";
        debugArtifacts = [
          {
            suffix = ".pdb";
            when = "always";
          }
        ];
        kernel = null;
        dylibPathVar = null;
        debugInfo = "keep";
      };
    };
    testWasm = {
      expr =
        map
          (
            t:
            pick [
              "os"
              "env"
              "isWasm"
              "isWasi"
              "executableSuffix"
              "dylibPathVar"
              "objectFormat"
            ] (r t)
          )
          [
            "wasm32-unknown-unknown"
            "wasm32-wasip2"
          ];
      expected = [
        {
          os = "unknown";
          env = "";
          isWasm = true;
          isWasi = false;
          executableSuffix = ".wasm";
          dylibPathVar = null;
          objectFormat = "wasm";
        }
        {
          os = "wasi";
          env = "p2";
          isWasm = true;
          isWasi = true;
          executableSuffix = ".wasm";
          dylibPathVar = null;
          objectFormat = "wasm";
        }
      ];
    };
    testOthers = {
      expr = map (t: pick [ "os" "env" "abi" "objectFormat" "isLinux" "kernel" "debugInfo" ] (r t)) [
        "aarch64-unknown-linux-musl"
        "riscv64gc-unknown-linux-gnu"
        "x86_64-unknown-none"
        "thumbv7em-none-eabihf"
        "aarch64-linux-android"
        "aarch64-apple-darwin"
      ];
      expected = [
        {
          os = "linux";
          env = "musl";
          abi = "";
          objectFormat = "elf";
          isLinux = true;
          kernel = "linux";
          debugInfo = "split";
        }
        {
          os = "linux";
          env = "gnu";
          abi = "";
          objectFormat = "elf";
          isLinux = true;
          kernel = "linux";
          debugInfo = "split";
        }
        {
          os = "none";
          env = "";
          abi = "";
          objectFormat = "elf";
          isLinux = false;
          kernel = null;
          debugInfo = "keep";
        }
        {
          os = "none";
          env = "";
          abi = "eabihf";
          objectFormat = "elf";
          isLinux = false;
          kernel = null;
          debugInfo = "keep";
        }
        {
          os = "android";
          env = "";
          abi = "";
          objectFormat = "elf";
          isLinux = false;
          kernel = "linux";
          debugInfo = "keep";
        }
        {
          os = "macos";
          env = "";
          abi = "";
          objectFormat = "macho";
          isLinux = false;
          kernel = "darwin";
          debugInfo = "keep";
        }
      ];
    };
    # The linker kinds of the targets presets cover, from traits and a
    # rust-lang rustc 1.99 on x86_64 Linux.
    testLinkerKinds = {
      expr =
        let
          rustc = {
            version = "1.99.0";
            bundledLld = true;
            host = "x86_64-unknown-linux-gnu";
          };
        in
        map (t: bb.presets.linkerKind { triple = t; inherit rustc; }) [
          "x86_64-unknown-linux-gnu"
          "aarch64-unknown-linux-musl"
          "x86_64-pc-windows-msvc"
          "wasm32-wasip2"
          "wasm32-unknown-unknown"
          "x86_64-pc-windows-gnullvm"
        ];
      expected = [
        "lld"
        "cc"
        "lld-link"
        "wasm-component-ld"
        "wasm-ld"
        "mingw-lld"
      ];
    };
    # The test runner kinds (lib/presets/runner.nix), from traits alone.
    testRunnerKinds = {
      expr = map (c: bb.presets.runnerKind ({ traits = r c.t; } // removeAttrs c [ "t" ])) [
        {
          t = "x86_64-unknown-linux-gnu";
          canExecute = true;
        }
        {
          t = "aarch64-unknown-linux-gnu";
          canExecute = false;
        }
        {
          t = "aarch64-unknown-linux-gnu";
          canExecute = false;
          nativeBuilder = true;
        }
        {
          t = "x86_64-pc-windows-msvc";
          canExecute = false;
        }
        {
          t = "aarch64-pc-windows-msvc";
          canExecute = false;
        }
        {
          t = "i686-pc-windows-gnu";
          canExecute = false;
        }
        {
          t = "wasm32-wasip2";
          canExecute = false;
        }
        {
          t = "wasm32-unknown-unknown";
          canExecute = false;
        }
        {
          t = "wasm32-unknown-unknown";
          canExecute = false;
          flavor = "wasm-bindgen";
        }
        {
          t = "x86_64-unknown-linux-gnu";
          canExecute = true;
          flavor = "zig";
        }
        {
          t = "x86_64-unknown-none";
          canExecute = false;
        }
      ];
      expected = [
        "native"
        "qemu-user"
        "native-builder"
        "wine"
        "none"
        "wine"
        "wasmtime"
        "none"
        "wasm-bindgen"
        "ld-so"
        "none"
      ];
    };
    # One table of cross package sets (presets.targetPkgsFor), for the
    # Linux and the MinGW presets alike.
    testPackageSets = {
      expr = map (t: (bb.presets.targetPkgsFor pkgs t).stdenv.hostPlatform.config) [
        "x86_64-unknown-linux-gnu"
        "aarch64-unknown-linux-musl"
        "x86_64-pc-windows-gnu"
        "x86_64-pc-windows-gnullvm"
      ];
      expected = [
        pkgs.stdenv.hostPlatform.config
        pkgs.pkgsCross.aarch64-multiplatform-musl.stdenv.hostPlatform.config
        pkgs.pkgsCross.mingwW64.stdenv.hostPlatform.config
        lib.systems.examples.mingw-ucrt-x86_64-llvm.config
      ];
    };
    # Toolchain facts (lib/toolchain-facts.nix): from attributes and tables,
    # and from `rustc -vV` (IFD) for a rustc without a version or with one
    # that is not a release (fenix's manifest dates).
    testToolchainFacts = {
      expr =
        let
          rust = pkgs.rust-bin.stable."1.97.0".minimal;
          f =
            r:
            removeAttrs (bb.toolchainFacts.of {
              inherit pkgs;
              rustc = r;
            }) [ "capabilities" ];
        in
        [
          (f rust)
          (f (removeAttrs rust [ "version" ]))
          (f (rust // { version = "2026-10-15"; }))
          (f pkgs.rustc).llvmMajor
          (f pkgs.rustc).bundledLld
        ];
      expected = [
        {
          version = "1.97.0";
          majorMinor = "1.97";
          llvmMajor = 22;
          wasiSdkVersion = "33";
          bundledLld = true;
        }
        {
          version = "1.97.0";
          majorMinor = "1.97";
          llvmMajor = 22;
          wasiSdkVersion = "33";
          bundledLld = true;
        }
        {
          version = "1.97.0";
          majorMinor = "1.97";
          llvmMajor = 22;
          wasiSdkVersion = "33";
          bundledLld = true;
        }
        (lib.toInt (lib.versions.major pkgs.rustc.llvmPackages.llvm.version))
        false
      ];
    };
    # Toolchain capabilities (lib/toolchain-facts.nix): from the rustc and
    # cargo versions across the supported window; from the toolchain itself
    # (IFD: `rustc --remap-path-scope`, `cargo -V`) without a version or
    # with a date for one (fenix's components), which
    # agrees with the table on both sides of 1.95; overrides win, null ones
    # are ignored; an unknown name fails.
    testToolchainCapabilities = {
      expr =
        let
          caps =
            tc: overrides:
            (bb.toolchainFacts.of {
              inherit pkgs;
              rustc = tc;
              cargo = tc;
              capabilities = overrides;
            }).capabilities;
          noVersion = tc: removeAttrs tc [ "version" ];
          # fenix's component packages: `version` is the channel
          # manifest's date, not a release.
          dateVersion = tc: tc // { version = "2026-10-15"; };
          r = v: pkgs.rust-bin.stable.${v}.minimal;
          nightly = pkgs.rust-bin.nightly.latest.minimal;
        in
        [
          (caps (r "1.94.0") { })
          (caps (r "1.95.0") { })
          (caps (r "1.97.0") { })
          (caps (r "1.99.0") { })
          (caps nightly { })
          (caps pkgs.rustc { })
          (caps (noVersion (r "1.94.0")) { })
          (caps (noVersion (r "1.95.0")) { })
          (caps (noVersion nightly) { })
          (caps (dateVersion (r "1.94.0")) { })
          (caps (dateVersion (r "1.99.0")) { })
          (caps (dateVersion nightly) { })
          (caps (r "1.99.0") {
            remapPathScope = false;
            trimPaths = true;
            nightly = null;
          })
          (builtins.tryEval (caps (r "1.99.0") { remapPathscope = false; })).success
        ];
      expected =
        let
          c = remapPathScope: trimPaths: nightly: { inherit remapPathScope trimPaths nightly; };
        in
        [
          (c false false false)
          (c true false false)
          (c true false false)
          (c true false false)
          (c true true true)
          (c true false false)
          (c false false false)
          (c true false false)
          (c true true true)
          (c false false false)
          (c true false false)
          (c true true true)
          (c false true false)
          false
        ];
    };
    # Unknown names: no built-in traits, and every field fails only when
    # read.
    testUnknownParse = {
      expr = map tt.parse [
        "thumbv7em-none-eabihf.json"
        "x86_64-unknown-hermit"
        "my-board"
      ];
      expected = [
        null
        null
        null
      ];
    };
    testUnknownFailsLazily = {
      expr =
        let
          u = r "my-board";
        in
        [
          (builtins.isAttrs u)
          (fails u.isLinux)
          (fails (bb.presets.linkerKind { triple = "my-board"; }))
        ];
      expected = [
        true
        true
        true
      ];
    };
    # A misspelt or renamed trait is an error, not silently ignored.
    testMisnamedTrait = {
      expr = fails (tt.resolve {
        triple = "x86_64-unknown-linux-gnu";
        traits.exeSuffix = ".elf";
      }).os;
      expected = true;
    };
    # Android: the Linux kernel, not a Linux userland. No
    # linker rule (issue #27), and qemu-user cannot run bionic programs.
    testAndroid = {
      expr =
        let
          a = r "aarch64-linux-android";
        in
        [
          (fails (bb.presets.linkerKind { triple = "aarch64-linux-android"; }))
          (bb.presets.runnerKind {
            traits = a;
            canExecute = false;
          })
        ];
      expected = [
        true
        "none"
      ];
    };
    # A user's base fields recompute the derived ones; a derived field set
    # directly wins.
    testUserTraits = {
      expr =
        pick
          [
            "triple"
            "os"
            "env"
            "vendor"
            "isLinux"
            "objectFormat"
            "executableSuffix"
            "dylibPathVar"
            "debugInfo"
          ]
          (
            tt.resolve {
              triple = "my-board";
              traits = {
                os = "linux";
                env = "musl";
                executableSuffix = ".elf";
              };
            }
          );
      expected = {
        triple = "my-board";
        os = "linux";
        env = "musl";
        vendor = "unknown";
        isLinux = true;
        objectFormat = "elf";
        executableSuffix = ".elf";
        dylibPathVar = "LD_LIBRARY_PATH";
        debugInfo = "split";
      };
    };
    # Through mkRepository: `targets.<t>.traits` reaches the resolved
    # target, and decisions made from it.
    testRepositoryTraits = {
      expr = {
        board = pick [ "os" "env" "executableSuffix" "isLinux" "debugInfo" ] board;
        linker = bb.presets.linkerKind {
          triple = "my-board";
          traits = board;
          rustc = {
            version = "1.99.0";
            bundledLld = true;
            host = "x86_64-unknown-linux-gnu";
          };
        };
        scope = bb.products.shippedRemapScope {
          triple = "my-board";
          traits = board;
        };
        nativeVar = native.dylibPathVar;
        nativeOs = native.os;
      };
      expected = {
        board = {
          os = "linux";
          env = "musl";
          executableSuffix = ".elf";
          isLinux = true;
          debugInfo = "split";
        };
        linker = "cc";
        scope = "macro,diagnostics";
        nativeVar = "MY_LIBS";
        nativeOs = "linux";
      };
    };
  };

  target-traits-rustc =
    assert lib.assertMsg (
      mismatches == [ ]
    ) "target-traits-rustc: parse disagrees with rustc:\n${lib.concatStringsSep "\n" mismatches}";
    # Every target breakbulk has a preset or a test for is known.
    assert lib.assertMsg (known >= 200) "target-traits-rustc: only ${toString known} targets known";
    assert lib.assertMsg (fileNameMismatches == [ ])
      "target-traits-rustc: file-name traits disagree with rustc --print file-names:\n${lib.concatStringsSep "\n" fileNameMismatches}";
    assert lib.assertMsg (fileNamesKnown == known) "target-traits-rustc: file names checked for ${toString fileNamesKnown} targets, cfg for ${toString known}";
    assert lib.assertMsg (specMismatches == [ ])
      "target-traits-rustc: traits disagree with rustc --print all-target-specs-json:\n${lib.concatStringsSep "\n" specMismatches}";
    # Every target `--print cfg` was checked for has a spec checked too.
    assert lib.assertMsg (specsKnown >= known) "target-traits-rustc: specs checked for ${toString specsKnown} targets, cfg for ${toString known}";
    pkgs.runCommand "target-traits-rustc" { } ''
      echo "${toString known} of ${toString (lib.length rows)} rustc targets parsed, all agreeing with rustc --print cfg and --print file-names; ${toString specsKnown} target specs agreeing with --print all-target-specs-json" > $out
    '';

  # The default Linux linker kind (lib/presets/linker.nix, `rustcPicksLld`)
  # against the linker flavor of rustc's own target spec (`--print
  # target-spec-json`; `gnu-lld-cc` is its bundled lld through the C
  # driver), for rust-lang's builds on both sides of 1.90 and 1.92, the
  # current nightly, and nixpkgs' rustc.
  linker-kind-rustc =
    let
      toolchains = {
        "1.89" = pkgs.rust-bin.stable."1.89.0".minimal;
        "1.90" = pkgs.rust-bin.stable."1.90.0".minimal;
        "1.91" = pkgs.rust-bin.stable."1.91.0".minimal;
        "1.92" = pkgs.rust-bin.stable."1.92.0".minimal;
        "1.99" = pkgs.rust-bin.stable."1.99.0".minimal;
        nightly = pkgs.rust-bin.nightly.latest.minimal;
        nixpkgs = pkgs.rustc;
      };
      targets = [
        "x86_64-unknown-linux-gnu"
        "aarch64-unknown-linux-gnu"
        "riscv64gc-unknown-linux-gnu"
        "i686-unknown-linux-gnu"
        "armv7-unknown-linux-gnueabihf"
        "x86_64-unknown-linux-musl"
        "aarch64-unknown-linux-musl"
      ];
      kind =
        rustc: triple:
        bb.presets.linkerKind {
          inherit triple;
          rustc = bb.presets.rustcFacts { inherit pkgs rustc; };
        };
      rows = lib.concatLists (
        lib.mapAttrsToList (name: rustc: map (t: "${name} ${rustc} ${t} ${kind rustc t}") targets) toolchains
      );
    in
    pkgs.runCommand "linker-kind-rustc" { rows = lib.concatStringsSep "\n" rows; } ''
      while read -r name rustc triple kind; do
        flavor=$(RUSTC_BOOTSTRAP=1 $rustc/bin/rustc -Z unstable-options --print target-spec-json --target "$triple" |
          sed -n 's/^ *"linker-flavor": *"\([^"]*\)".*/\1/p')
        if [ "$flavor" = gnu-lld-cc ]; then want=lld; else want=cc; fi
        echo "$name $triple: rustc $flavor, linkerKind $kind" | tee -a $out
        [ "$kind" = "$want" ] || {
          echo "linker-kind-rustc: $name $triple: rustc's spec says $flavor, linkerKind $kind" >&2
          exit 1
        }
      done <<< "$rows"
    '';
}
