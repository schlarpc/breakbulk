# linuxPortable (decision 122; was `zig`): Linux gnu programs that run on
# other distributions, linked against an old glibc (default 2.17, the
# oldest Rust's std supports on x86_64). The one backend, "zig", uses
# `zig cc -target <arch>-linux-gnu.<glibc>` as the target units' linker and
# C compiler.
#
#   targets.x86_64-unknown-linux-gnu.preset = breakbulk.presets.linuxPortable { glibc = "2.17"; };
#
# A same-triple preset: the target is usually the host triple, which the
# planner passes as `--target`, so the zig linker and rustflags reach target
# units only and host units (build scripts, proc macros) keep the host
# linker through the planner's linker rewrite.
#
# Portable means (decision 122): everything Nix provides is linked
# statically, and only glibc's own libraries (and the `systemLibraries`
# the user names, such as libGL.so.1, which the target system has) are
# loaded at run time. `rebuildInputs` are rebuilt as static libraries
# only, pkg-config runs in static mode for target units
# (PKG_CONFIG_ALL_STATIC), and every product gets the check
# `portableLibraries` (stageHelpers.neededLibraries), which reads each ELF
# file's NEEDED entries, as auditwheel does for Python wheels, and fails on
# any other library. There is no bundling or rpath option: a product needs
# nothing next to it.
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
  targetTraits,
  stageHelpers,
  hostSpec,
  chooseLinker,
  chooseRunner,
  nativeTriple,
}:
{
  pkgs,
  triple ? nativeTriple pkgs,
  traits ? targetTraits.resolve { inherit triple; },
  glibc ? "2.17",
  # How the old-glibc link is done; "zig" is the only one.
  backend ? "zig",
  # Sonames a product may load besides glibc's own libraries, because
  # every target system has them (e.g. [ "libGL.so.1" ]). Anything else
  # must be linked statically (`portableLibraries` check).
  systemLibraries ? [ ],
  zig ? pkgs.buildPackages.zig,
  # Extra `zig cc` invocations' flags to warm the cache with, e.g.
  # [ "-lc++" ] for C++ code.
  warmFlags ? [ ],
  # Names of nixpkgs packages to rebuild with `zig cc` against `glibc`
  # (decision 102), e.g. [ "openssl" "zlib" ]: `packages.<name>.inputs`
  # functions get these from the target's package set instead of nixpkgs'
  # builds, which need nixpkgs' newer glibc. Each is
  # `pkgs.<name>.override { stdenv = makeStaticLibraries zigStdenv; … }`
  # (static libraries only, as pkgsStatic builds them; `static = true` and
  # `shared = false` where the package takes them), with the other rebuilt
  # packages passed for the arguments it takes, and its test phases off
  # (test programs ask for the FHS loader, which the sandbox lacks); a
  # rebuild that still installs a shared library fails. Opt-in: the
  # rebuilds are not in any binary cache (openssl takes about 5 minutes on
  # 4 cores), and only C libraries whose own library dependencies are
  # listed too, or have none, are correct. Every other library input still
  # comes from nixpkgs and gets an evaluation warning.
  rebuildInputs ? [ ],
  ...
}:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  rustArch =
    if backend != "zig" then
      throw "breakbulk.presets.linuxPortable: unknown backend `${backend}`; the one backend is \"zig\""
    else if !(traits.isLinux && traits.env == "gnu") then
      throw "breakbulk.presets.linuxPortable: `${triple}` is not a Linux -gnu triple"
    else
      traits.arch;
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

  # The arguments nixpkgs packages take for a static-only build.
  staticArgs = {
    static = true;
    shared = false;
    enableStatic = true;
    enableShared = false;
  };

  rebuilt = lib.fix (
    self:
    lib.genAttrs rebuildInputs (
      n:
      let
        p = pkgs.${n} or (throw "breakbulk.presets.linuxPortable: rebuildInputs: nixpkgs has no package `${n}`");
        deps = lib.intersectAttrs (lib.functionArgs p.override) (removeAttrs self [ n ]);
      in
      (p.override (
        {
          stdenv = pkgs.stdenvAdapters.makeStaticLibraries zigStdenv;
        }
        // lib.intersectAttrs (lib.functionArgs p.override) staticArgs
        // deps
      )).overrideAttrs
        (old: {
          doCheck = false;
          doInstallCheck = false;
          # Static libraries only: a shared one would be linked in place of
          # the archive and loaded from the store at run time.
          postFixup = (old.postFixup or "") + ''
            for o in $outputs; do
              found=$(find "''${!o}" \( -name '*.so' -o -name '*.so.*' \) -print -quit)
              if [ -n "$found" ]; then
                echo "breakbulk.presets.linuxPortable: rebuildInputs builds static libraries only, but ${n} installed $found" >&2
                exit 1
              fi
            done
          '';
        })
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
    if rebuildInputs != [ ] && triple != nativeTriple pkgs then
      throw "breakbulk.presets.linuxPortable: rebuildInputs needs the native triple (${nativeTriple pkgs}), not ${triple}"
    else
      builtins.mapAttrs (
        n: v:
        rebuilt.${n} or (
          if lib.elem n quiet || !(isDrv v) then
            v
          else
            lib.warn "breakbulk.presets.linuxPortable: a package input uses nixpkgs' `${n}`, which needs nixpkgs' glibc, not ${glibc}; rebuild it with `presets.linuxPortable { rebuildInputs = [ \"${n}\" ]; }` or use the crate's vendored C code" v
        )
      ) pkgs
      // {
        inherit zigStdenv;
        breakbulkZigRebuilt = rebuilt;
      };
in
{
  packageSet = mkDefault packageSet;
  # ./linker.nix, kind zig: zig cc, minus the `-fuse-ld=lld -B…/gcc-ld`
  # rustc adds on x86_64; zig links with its own lld.
  linker = mkDefault (chooseLinker {
    inherit pkgs triple;
    flavor = "zig";
    zig = {
      cc = zigCc;
      target = zigTarget;
    };
  });
  cc = mkDefault zigCc;
  cxx = mkDefault zigCxx;
  ar = mkDefault zigAr;
  # pkg-config-rs links every pkg-config library statically (when its
  # archive exists), as for linuxStatic; target units only.
  env.PKG_CONFIG_ALL_STATIC = mkDefault "1";
  # The auditwheel-like check: NEEDED names only glibc's libraries and
  # `systemLibraries`.
  checks.portableLibraries = {
    run = stageHelpers.neededLibraries {
      allowed = stageHelpers.glibcLibraries ++ systemLibraries;
      why = "linuxPortable links everything Nix provides statically (rebuildInputs builds static libraries); add a library every target system has to `presets.linuxPortable { systemLibraries = [ \"<soname>\" ]; }`";
    };
  };
  # zig links the FHS loader path (/lib64/ld-linux-x86-64.so.2), as a
  # program for other distributions should; the Nix sandbox has none, so
  # tests run through the build machine's glibc loader, which also finds
  # its own libc.so.6 (newer than `glibc`, as on a real target system):
  # ./runner.nix, kind ld-so, when the build machine runs the target.
  runner = mkDefault (chooseRunner {
    inherit pkgs;
    traits = null;
    flavor = "zig";
    canExecute =
      pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform
      && triple == nativeTriple pkgs;
  }).runner;
  testSystem = mkDefault null;
  host = hostSpec pkgs;
}
