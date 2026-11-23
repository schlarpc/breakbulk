# linuxPortable: Linux gnu programs that run on
# other distributions, linked against an old glibc (default 2.17, the
# oldest Rust's std supports on x86_64). `zig cc -target
# <arch>-linux-<abi>.<glibc>` is the target units' linker and C compiler.
#
#   targets.x86_64-unknown-linux-gnu.preset = breakbulk.presets.linuxPortable { glibc = "2.17"; };
#
# A same-triple preset: the target is usually the host triple, which the
# planner passes as `--target`, so the zig linker and rustflags reach target
# units only and host units (build scripts, proc macros) keep the host
# linker through the planner's linker rewrite.
#
# Portable means: everything Nix provides is linked
# statically, and only glibc's own libraries (and GCC's runtime
# libraries, libgcc_s.so.1 and libstdc++.so.6, as manylinux allows, and
# the `systemLibraries` the user names, such as libGL.so.1, which the
# target system has) are loaded at run time. The package set builds
# library inputs as static libraries only (`packageSet` below),
# pkg-config runs in static mode for target units
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
  chooseLinker,
  runners,
  nativeTriple,
}:
{
  pkgs,
  triple ? nativeTriple pkgs,
  traits ? targetTraits.resolve { inherit triple; },
  glibc ? "2.17",
  # Sonames a product may load besides glibc's own libraries and GCC's
  # runtime (libgcc_s.so.1, libstdc++.so.6), because every target system
  # has them (e.g. [ "libGL.so.1" ]). Anything else must be linked
  # statically (`portableLibraries` check).
  systemLibraries ? [ ],
  # Store paths a product may name in its files anyway (the
  # `portableNoStorePaths` check, stageHelpers.noStorePaths): shell globs
  # against each whole path found, or store paths.
  allowStorePaths ? [ ],
  zig ? pkgs.buildPackages.zig,
  # nixpkgs overlays for the target's package set's own packages (its
  # `crossOverlays`, after breakbulk's, which sets OpenSSL's directories),
  # e.g. to change how a library is configured.
  overlays ? [ ],
  linkerKind ? null,
  kinds,
  facts,
  ...
}@args:
let
  inherit (lib) mkDefault;
  # The preset takes `...` (every preset gets the same arguments), so an
  # argument it no longer has would otherwise be ignored without a word.
  removedArgs = lib.filter (n: args ? ${n}) [
    "rebuildInputs"
    "rebuildOverrides"
  ];
  bp = pkgs.buildPackages;
  zigArch =
    if !(traits.isLinux && traits.env == "gnu") then
      throw "breakbulk.presets.linuxPortable: `${triple}` is not a Linux -gnu triple"
    else
      traits.zigArch;
  # The ABI from the traits (gnueabihf for armv7's hard float), and the
  # CPU too: zig's own baseline is not rustc's on Arm.
  zigTarget = "${zigArch}-linux-${traits.zigAbi}.${glibc}";
  zigTargetArgs = "-target ${zigTarget}${
    lib.optionalString (traits.zigMcpu != null) " -mcpu=${traits.zigMcpu}"
  }";
  # The package set's platform, the target's GNU triple with the vendor
  # `none` (as in ARM's aarch64-none-linux-gnu toolchains). Not the Rust
  # triple itself: for the build machine's own triple, the cross tools'
  # prefix (`x86_64-unknown-linux-gnu-gcc`) is also the name of the build
  # machine's unwrapped gcc, which a package's `depsBuildBuild` compiler
  # puts first on PATH, and configure scripts given the same `--build` and
  # `--host` do not treat the build as a cross build.
  nixpkgsConfig = "${(targetTraits.nixpkgsPlatform traits).parsed.cpu.name}-none-linux-${lib.last (lib.splitString "-" triple)}";
  # Whether the build machine runs the target's programs (through its own
  # loader: zig links the FHS one).
  canExecute =
    pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform && triple == nativeTriple pkgs;

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
        zig cc ${zigTargetArgs} main.c -o main $libs
        zig cc ${zigTargetArgs} -shared -fPIC main.c -o libmain.so $libs
        zig cc ${zigTargetArgs} -O2 -c main.c -o main.o
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

  zigCc = zigTool "zig-cc-${zigTarget}" "cc ${zigTargetArgs}";
  zigCxx = zigTool "zig-cxx-${zigTarget}" "c++ ${zigTargetArgs}";
  zigAr = zigTool "zig-ar" "ar";

  # The target's package set: nixpkgs for a static variant of the target
  # platform (`isStatic`, as pkgsStatic), cross-built from the build
  # machine, with the stdenv replaced by one around `zig cc` for `glibc`.
  # A library input's own library dependencies come from the same set
  # through nixpkgs' splicing, and tools (`nativeBuildInputs`, a package's
  # `nativeInputs`) from `buildPackages`, nixpkgs' own builds.
  packageSet = import pkgs.path {
    localSystem = pkgs.stdenv.buildPlatform;
    crossSystem = {
      config = nixpkgsConfig;
      isStatic = true;
    };
    inherit (pkgs) overlays;
    crossOverlays = [ defaultOverlay ] ++ overlays;
    config = pkgs.config // {
      replaceCrossStdenv = zigCrossStdenv;
    };
  };

  # nixpkgs' cross stdenv for this platform with `zig cc` as its compiler,
  # behind nixpkgs' cc-wrapper with no libc (zig brings its own glibc stubs
  # and headers), so setup hooks, NIX_CFLAGS_COMPILE and pkg-config work as
  # usual. Not nixpkgs' `baseStdenv`: for a static glibc platform that is
  # makeStatic's, which links programs with `-static` against nixpkgs'
  # `glibc.static`. Only makeStaticLibraries (`--disable-shared`,
  # BUILD_SHARED_LIBS=OFF, meson's default_library=static) and
  # propagateBuildInputs are kept, as pkgsStatic has them.
  #
  # When the build machine runs the target, nixpkgs says so to meson and
  # CMake (no exe wrapper; `env` as the emulator), which run the programs
  # they link; those ask for the FHS loader, which
  # the sandbox lacks, so the stdenv's compiler links executables with the
  # build machine's loader (`cc-ldflags`, read only when linking). Archives
  # have no loader, and products are linked by the target units' own
  # `zig cc`, never this one. Test phases stay off: they would run
  # against the build machine's glibc, not `glibc`, and nothing links a
  # package's tests into a product.
  #
  # The wrapped compiler claims not to be clang: for clang the wrapper adds
  # nixpkgs gcc's libstdc++ (`--gcc-toolchain`, `-cxx-isystem`) and passes
  # arguments in a response file with backslash-escaped commas, which zig's
  # parser keeps, so `-Wl,-soname,…` and `-Wl,-rpath,…` were dropped (zig
  # 0.17.0, nixpkgs cc-wrapper `use_response_file_by_default`).
  zigCrossStdenv =
    { buildPackages, baseStdenv }:
    let
      # cc-wrapper's and bintools-wrapper's `targetPrefix`.
      prefix = baseStdenv.hostPlatform.config + "-";
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
            # The wrapper adds `-L` and `-B` for this cross compiler's
            # library directory; zig warns when it is missing.
            mkdir -p $out/bin $out/${baseStdenv.hostPlatform.config}/lib
            ln -s ${zigCc} $out/bin/${prefix}cc
            ln -s ${zigCxx} $out/bin/${prefix}c++
            ln -s ${zigCc} $out/bin/${prefix}gcc
            ln -s ${zigCxx} $out/bin/${prefix}g++
          '';
      llvmBin = "${bp.llvmPackages.bintools-unwrapped}/bin";
      bintools = buildPackages.wrapBintoolsWith {
        bintools = bp.runCommand "zig-bintools-${zigTarget}" { } ''
          mkdir -p $out/bin
          ln -s ${zigAr} $out/bin/${prefix}ar
          for t in nm objcopy objdump ranlib readelf strip size strings; do
            ln -s ${llvmBin}/llvm-$t $out/bin/${prefix}$t
          done
          ln -s ${llvmBin}/ld.lld $out/bin/${prefix}ld
        '';
        libc = null;
      };
      adapters = buildPackages.stdenvAdapters;
      plain = buildPackages.stdenv.override (old: {
        inherit (baseStdenv) buildPlatform hostPlatform targetPlatform;
        overrides = _: _: { };
        extraBuildInputs = [ ];
        allowedRequisites = null;
        cc = buildPackages.wrapCCWith {
          cc = unwrapped;
          libc = null;
          inherit bintools;
          extraBuildCommands = lib.optionalString canExecute ''
            echo "--dynamic-linker=${bp.stdenv.cc.bintools.dynamicLinker}" >> $out/nix-support/cc-ldflags
          '';
        };
        hasCC = true;
      });
    in
    lib.pipe plain [
      adapters.makeStaticLibraries
      adapters.propagateBuildInputs
      # Test phases off (above), and their hooks too: a hook may name a
      # check input, which would then be built anyway (nghttp2's preCheck
      # names tzdata).
      (adapters.overrideMkDerivationArgs (_: {
        doCheck = false;
        doInstallCheck = false;
        preCheck = "";
        postCheck = "";
        preInstallCheck = "";
        postInstallCheck = "";
      }))
    ];

  # Packages that nixpkgs builds for a static platform in ways this one
  # cannot take. The `portableLibraries` and `portableNoStorePaths` checks
  # find what slips through on another package.
  defaultOverlay =
    final: prev:
    let
      pslSystemFile = "/usr/share/publicsuffix/public_suffix_list.dat";
      # bash builds its helper programs with the build machine's gcc, whose
      # default C standard (C23, gcc 15 and later) its configure script
      # assumes the target's compiler has too; nixpkgs passes `-std=c23`
      # only when the compiler is clang, which this one does not claim to
      # be (above).
      c23 =
        p:
        p.overrideAttrs (old: {
          env = old.env // {
            NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -std=c23";
          };
        });
    in
    {
      bash = c23 prev.bash;
      bashNonInteractive = c23 prev.bashNonInteractive;
      # nixpkgs' libiconv on a glibc platform is glibc's iconv.h, copied
      # from a glibc built for this platform, which zig cc cannot build and
      # which would be a newer glibc anyway; zig's own glibc headers and
      # stubs have iconv, so the package is empty.
      libiconv = final.runCommand "zig-glibc-iconv" { } "mkdir -p $out";
      # `static` (default: isStatic) links its programs with `-static`,
      # which glibc cannot do; its library is static either way.
      libev = prev.libev.override { static = false; };
      # libpsl compiles in the path `psl_latest()` reads (meson's
      # `psl_distfile`, `-DPSL_DISTFILE`), a store path in nixpkgs that the
      # `portableNoStorePaths` check finds; on the target system it is
      # where Debian and Fedora install the list. (The list the built-in
      # one was made from is written as its basename only, libpsl 0.23.3
      # src/psl-make-dafsa.)
      libpsl = prev.libpsl.overrideAttrs (old: {
        mesonFlags = map (
          f: if lib.hasPrefix "-Dpsl_distfile=" f then "-Dpsl_distfile=${pslSystemFile}" else f
        ) old.mesonFlags;
      });
      # nixpkgs' static OpenSSL configures OPENSSLDIR as its `etc` output
      # (ENGINESDIR below it) and MODULESDIR as `$out/lib/ossl-modules`,
      # store paths the `portableNoStorePaths` check finds; all three are
      # compiled into libcrypto from make variables
      # (`-DOPENSSLDIR="\"$(OPENSSLDIR)\""`, OpenSSL 3.5.9
      # Configurations/unix-Makefile.tmpl). They are set for the build only
      # (`buildFlags`), so `make install` still installs into the store; on
      # the target system OpenSSL reads /etc/ssl/openssl.cnf, as on Arch,
      # Alpine or openSUSE, with engines in /etc/ssl/engines-3.
      openssl = prev.openssl.overrideAttrs (old: {
        buildFlags = (old.buildFlags or [ ]) ++ [
          "OPENSSLDIR=/etc/ssl"
          "MODULESDIR=/usr/lib/ossl-modules"
        ];
      });
    };
in
if removedArgs != [ ] then
  throw "breakbulk.presets.linuxPortable: ${
    lib.concatMapStringsSep " and " (n: "`${n}`") removedArgs
  } no longer exist${
    lib.optionalString (lib.length removedArgs == 1) "s"
  }: library inputs come from the preset's package set, a static nixpkgs built against `glibc`; name them in `packages.<name>.inputs` (`p: [ p.openssl ]`), and change how one is built with the preset's `overlays` argument"
else
  {
    packageSet = mkDefault packageSet;
    # ./linker.nix, kind zig: zig cc, minus the `-fuse-ld=lld -B…/gcc-ld`
    # rustc adds on x86_64; zig links with its own lld. Another kind
    # would link against the build machine's glibc, not `glibc`.
    linker = mkDefault (chooseLinker {
      inherit pkgs triple kinds;
      kind =
        if linkerKind == null || linkerKind == "zig" then
          "zig"
        else
          throw "breakbulk.presets.linuxPortable: `linkerKind = \"${linkerKind}\"` cannot link for `${triple}`: linuxPortable links with `zig cc` against its old glibc";
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
    # The auditwheel-like check: NEEDED names only glibc's libraries, GCC's
    # runtime libraries and `systemLibraries`.
    checks.portableLibraries = {
      run = mkDefault (
        stageHelpers.neededLibraries {
          allowed = stageHelpers.glibcLibraries ++ stageHelpers.gccRuntimeLibraries ++ systemLibraries;
          why = "linuxPortable links everything Nix provides statically (its package set builds static libraries); add a library every target system has to `presets.linuxPortable { systemLibraries = [ \"<soname>\" ]; }`";
        }
      );
    };
    # No Nix store path anywhere in a product's files: on
    # another system nothing is there.
    checks.portableNoStorePaths = {
      run = mkDefault (
        stageHelpers.noStorePaths {
          allow = allowStorePaths;
          why = "a linuxPortable product runs where there is no Nix store; allow a path with `presets.linuxPortable { allowStorePaths = [ \"<glob>\" ]; }`";
        }
      );
    };
    # zig links the FHS loader path (/lib64/ld-linux-x86-64.so.2), as a
    # program for other distributions should; the Nix sandbox has none, so
    # tests run through the build machine's glibc loader, which also finds
    # its own libc.so.6 (newer than `glibc`, as on a real target system),
    # when the build machine runs the target. Not qemu-user for another
    # CPU: its loader is not at the FHS path either.
    runner = mkDefault (if canExecute then runners.ldSo { pkgs = bp; } else false);
    testSystem = mkDefault null;
  }
