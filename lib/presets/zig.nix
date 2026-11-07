# zig (M7): Linux gnu programs linked against an old glibc (default 2.17,
# the oldest Rust's std supports on x86_64) with `zig cc -target
# <arch>-linux-gnu.<glibc>` as the target units' linker and C compiler.
#
#   targets.x86_64-unknown-linux-gnu.preset = breakbulk.presets.zig { glibc = "2.17"; };
#
# A same-triple preset: the target is usually the host triple, which the
# planner passes as `--target`, so the zig linker and rustflags reach target
# units only and host units (build scripts, proc macros) keep the host
# linker through the planner's linker rewrite.
#
# zig builds glibc's stubs, crt objects, libunwind and compiler-rt into its
# global cache on first use (about 10 s). In a sandbox that cache starts
# empty in every unit, so `cache` is a derivation that warms it once, and
# the wrapper copies it into the unit's $TMPDIR on first use (about 60 MB,
# well under 0.1 s). zig cannot use the store copy in place: it opens cache
# manifests for writing even on a hit ("manifest_create AccessDenied" with
# a read-only cache, zig 0.17.0); a copy at another path is a full hit.
# breakbulk-unit has no zig special case: the wrapper does it all.
{
  lib,
  hostSpec,
  driverWrapper,
}:
{
  pkgs,
  triple ? pkgs.stdenv.hostPlatform.rust.rustcTarget,
  glibc ? "2.17",
  zig ? pkgs.buildPackages.zig,
  # Extra `zig cc` invocations' flags to warm the cache with, e.g.
  # [ "-lc++" ] for C++ code.
  warmFlags ? [ ],
  # Names of nixpkgs packages to rebuild with `zig cc` against `glibc`
  # (decision 102), e.g. [ "openssl" "zlib" ]: `packages.<name>.inputs`
  # functions get these from the target's package set instead of nixpkgs'
  # builds, which need nixpkgs' newer glibc. Each is
  # `pkgs.<name>.override { stdenv = zigStdenv; … }`, with the other
  # rebuilt packages passed for the arguments it takes, and its test
  # phases off (test programs ask for the FHS loader, which the sandbox
  # lacks). Opt-in: the rebuilds are not in any binary cache (openssl takes
  # about 5 minutes on 4 cores), and only C libraries whose own library
  # dependencies are listed too, or have none, are correct. Every other
  # library input still comes from nixpkgs and gets an evaluation warning.
  rebuildInputs ? [ ],
  ...
}:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  m = builtins.match "([a-z0-9_]+)-unknown-linux-gnu" triple;
  rustArch =
    if m == null then
      throw "breakbulk.presets.zig: `${triple}` is not a *-unknown-linux-gnu triple"
    else
      lib.head m;
  zigArch = { riscv64gc = "riscv64"; }.${rustArch} or rustArch;
  zigTarget = "${zigArch}-linux-gnu.${glibc}";

  # The warmed global cache: an executable and a shared library linked with
  # the libraries rustc's linux-gnu spec passes.
  cache =
    bp.runCommand "zig-cache-${zigTarget}"
      {
        nativeBuildInputs = [ zig ];
      }
      ''
        export ZIG_GLOBAL_CACHE_DIR=$out ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
        printf 'int main(void) { return 0; }\n' > main.c
        libs="-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc"
        zig cc -target ${zigTarget} main.c -o main $libs
        zig cc -target ${zigTarget} -shared -fPIC main.c -o libmain.so $libs
        zig cc -target ${zigTarget} -O2 -c main.c -o main.o
        ${lib.concatMapStringsSep "\n" (
          f: "zig cc -target ${zigTarget} main.c -o extra ${f} $libs"
        ) warmFlags}
        rm -rf $out/tmp
      '';

  # `zig <mode>` with the warmed cache copied into $TMPDIR once per unit
  # (copied aside, then renamed, so parallel cc jobs do not race).
  zigTool =
    name: mode:
    "${bp.writeShellScriptBin name ''
      dir="''${TMPDIR:-/tmp}/breakbulk-zig"
      if [[ ! -d $dir/global ]]; then
        mkdir -p "$dir"
        tmp=$(mktemp -d "$dir/copy.XXXXXX")
        cp -r ${cache} "$tmp/global"
        chmod -R u+w "$tmp/global"
        mv -T "$tmp/global" "$dir/global" 2>/dev/null || rm -rf "$tmp/global"
        rmdir "$tmp"
      fi
      export ZIG_GLOBAL_CACHE_DIR="$dir/global" ZIG_LOCAL_CACHE_DIR="$dir/local"
      # The cc crate passes `--target=<Rust triple>` (zig cannot parse
      # it, and it would override -target); the target is fixed here.
      args=()
      for a in "$@"; do
        [[ $a == --target=* ]] || args+=("$a")
      done
      exec ${zig}/bin/zig ${mode} "''${args[@]}"
    ''}/bin/${name}";

  zigCc = zigTool "zig-cc-${zigTarget}" "cc -target ${zigTarget}";
  zigCxx = zigTool "zig-cxx-${zigTarget}" "c++ -target ${zigTarget}";
  zigAr = zigTool "zig-ar" "ar";

  # A nixpkgs stdenv whose C compiler is `zig cc` for `zigTarget`, behind
  # nixpkgs' cc-wrapper with no libc (zig brings its own glibc stubs and
  # headers), so setup hooks, NIX_CFLAGS_COMPILE and NIX_LDFLAGS work as
  # usual. The wrapped compiler claims not to be clang: for clang the
  # wrapper adds nixpkgs gcc's libstdc++ (`--gcc-toolchain`, `-cxx-isystem`)
  # and passes arguments in a response file with backslash-escaped commas,
  # which zig's parser keeps, so `-Wl,-soname,…` and `-Wl,-rpath,…` were
  # dropped (zig 0.17.0, nixpkgs cc-wrapper `use_response_file_by_default`).
  zigStdenv =
    let
      unwrapped =
        bp.runCommand "zig-cc-${zigTarget}"
          {
            passthru = {
              isClang = false;
              langC = true;
              langCC = true;
            };
          }
          ''
            mkdir -p $out/bin $out/lib
            ln -s ${zigCc} $out/bin/cc
            ln -s ${zigCxx} $out/bin/c++
            ln -s ${zigCc} $out/bin/gcc
            ln -s ${zigCxx} $out/bin/g++
          '';
      llvmBin = "${bp.llvmPackages.bintools-unwrapped}/bin";
      bintools = bp.wrapBintoolsWith {
        bintools = bp.runCommand "zig-bintools-${zigTarget}" { } ''
          mkdir -p $out/bin
          ln -s ${zigAr} $out/bin/ar
          for t in nm objcopy objdump ranlib readelf strip size strings; do
            ln -s ${llvmBin}/llvm-$t $out/bin/$t
          done
          ln -s ${llvmBin}/ld.lld $out/bin/ld
        '';
        libc = null;
      };
    in
    pkgs.overrideCC pkgs.stdenv (
      bp.wrapCCWith {
        cc = unwrapped;
        libc = null;
        inherit bintools;
      }
    );

  rebuilt = lib.fix (
    self:
    lib.genAttrs rebuildInputs (
      n:
      let
        p = pkgs.${n} or (throw "breakbulk.presets.zig: rebuildInputs: nixpkgs has no package `${n}`");
        deps = lib.intersectAttrs (lib.functionArgs p.override) (removeAttrs self [ n ]);
      in
      (p.override ({ stdenv = zigStdenv; } // deps)).overrideAttrs {
        doCheck = false;
        doInstallCheck = false;
      }
    )
  );

  # The target's package set: nixpkgs, with the rebuilt packages in place
  # and a warning on any other package a package's `inputs` takes, since
  # it was built against nixpkgs' glibc. Tools (`nativeInputs`) come from
  # `buildPackages`, which is nixpkgs' own and never warns.
  isDrv = v: builtins.isAttrs v && (v.type or null) == "derivation";
  quiet = [
    "stdenv"
    "stdenvNoCC"
  ];
  packageSet =
    if rebuildInputs != [ ] && triple != pkgs.stdenv.hostPlatform.rust.rustcTarget then
      throw "breakbulk.presets.zig: rebuildInputs needs the native triple (${pkgs.stdenv.hostPlatform.rust.rustcTarget}), not ${triple}"
    else
      builtins.mapAttrs (
        n: v:
        rebuilt.${n} or (
          if lib.elem n quiet || !(isDrv v) then
            v
          else
            lib.warn "breakbulk.presets.zig: a package input uses nixpkgs' `${n}`, which needs nixpkgs' glibc, not ${glibc}; rebuild it with `presets.zig { rebuildInputs = [ \"${n}\" ]; }` or use the crate's vendored C code" v
        )
      ) pkgs
      // {
        inherit zigStdenv;
        breakbulkZigRebuilt = rebuilt;
      };
in
{
  packageSet = mkDefault packageSet;
  # driverWrapper drops the `-fuse-ld=lld -B…/gcc-ld` rustc adds on
  # x86_64 (rustc's self-contained rust-lld); zig links with its own lld.
  linker = mkDefault (driverWrapper pkgs "zig-cc-link-${zigTarget}" zigCc "");
  cc = mkDefault zigCc;
  cxx = mkDefault zigCxx;
  ar = mkDefault zigAr;
  env = { };
  # zig links the FHS loader path (/lib64/ld-linux-x86-64.so.2), as a
  # program for other distributions should; the Nix sandbox has none, so
  # tests run through the build machine's glibc loader, which also finds
  # its own libc.so.6 (newer than `glibc`, as on a real target system).
  runner = mkDefault (
    if
      pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform
      && triple == pkgs.stdenv.hostPlatform.rust.rustcTarget
    then
      bp.writeShellScript "breakbulk-runner-ld-so" ''
        exec ${pkgs.stdenv.cc.bintools.dynamicLinker} "$@"
      ''
    else
      null
  );
  testSystem = mkDefault null;
  host = hostSpec pkgs;
  stagePreset = mkDefault "linuxGnu";
}
