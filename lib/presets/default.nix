# Toolchain presets ("Toolchain presets" in
# docs/src/explanation/internals/toolchains.md;
# docs/src/explanation/targets.md; docs/src/how-to/write-a-preset.md).
#
# A preset is a module of the target spec (lib/modules/target-spec.nix),
# which `targets.<triple>.preset` imports. It gets the module arguments
# `pkgs`, `name` (the triple) and `toolchain` (the workspace's), reads
# the target's options (`config.traits`, `config.linkerKind`) and sets
# any of them: scalar fields (linker, cc, runner, …) with `mkDefault`, so
# a plain definition replaces them; lists (rustflags, cflags, cxxflags)
# concatenate, and `mkForce` replaces them; env values are `mkDefault`
# per variable; stages are `mkDefault` per field.
#
#   targets.x86_64-unknown-linux-musl.preset = breakbulk.presets.linuxStatic;
#   targets.x86_64-pc-windows-msvc.preset = breakbulk.presets.windows { inherit sdk; };
#
# A preset applied to an attribute set of its options is the same module
# with those options bound, so `presets.windows { sdk = …; }` is itself a
# preset.
#
# A preset is evaluated once per workspace, with that workspace's
# toolchain, so presets that need rustc's LLVM or wasi-sdk version follow
# each workspace's rustc.
#
# A preset sets up the target's units only. Host units (build scripts,
# proc macros and their dependencies) take their linker, env and stdenv
# from the workspace's host spec (`workspaces.<ws>.host`), the same in
# every plan; target env is added only to target units at instantiation,
# never through Cargo's `[env]`.
#
# Presets that use LLVM tools (windows, uefi, wasm, the Linux presets
# with crossLanguageLto or the lld linker kind) take the LLVM matching
# rustc from the workspace's toolchain facts (`toolchain.facts`,
# lib/toolchain-facts.nix): nixpkgs' rustc.llvmPackages, else the major
# from breakbulk.llvmVersions' table or `rustc -vV` (IFD), unless
# `workspaces.<ws>.toolchain.facts` says otherwise.
{
  lib,
  util,
  targetTraits,
  toolchainFacts,
  llvmVersions,
  runners,
  wasmBindgen,
  wasiSdk,
  appleSdk,
  stageHelpers,
}:
let
  inherit (lib) mkDefault;

  # A preset made from `body`, a function of the preset's options and the
  # target's facts (`{ pkgs; config; triple; traits; linkerKind;
  # toolchain; facts; }`, `facts` the toolchain's) to the module's
  # definitions. The module system calls a module with its
  # arguments, which have `config` and `options`; any other attribute set
  # binds options. The definitions' names must not depend on the
  # target's options (`config.traits`, read lazily here): the module system
  # reads every module's names before any option's value, so a check on
  # the traits goes into the values (`guard`) and a choice between
  # mechanisms into `lib.mkIf` (`dispatch`).
  presetModule =
    body:
    let
      bind = opts: {
        __functor =
          _: args:
          if args ? config && args ? options then
            body (
              opts
              // {
                inherit (args) pkgs config toolchain;
                inherit (args.toolchain) facts;
                kinds = args.config.linkerKinds;
                triple = args.name;
                inherit (args.config) traits linkerKind;
              }
            )
          else
            let
              moved = lib.attrNames (builtins.intersectAttrs targetArgs args);
            in
            if moved != [ ] then
              throw "breakbulk.presets: ${
                lib.concatMapStringsSep ", " (n: "`${n}`") moved
              } is not a preset option: ${lib.concatMapStringsSep "; " (n: targetArgs.${n}) moved}"
            else
              bind (opts // args);
      };
    in
    bind { };

  # What a preset reads from the target and the workspace, never from
  # its options, and where each is set.
  targetArgs = {
    pkgs = "the preset gets mkRepository's `pkgs`";
    triple = "the preset gets the target's name";
    traits = "set `targets.<triple>.traits`";
    linkerKind = "set `targets.<triple>.linkerKind`";
    rustc = "set `workspaces.<ws>.toolchain.rustc`";
    llvmMajor = "set `workspaces.<ws>.toolchain.facts.llvmMajor`";
    llvmPackages = "set `workspaces.<ws>.toolchain.facts.llvmPackages`";
    wasiSdkVersion = "set `workspaces.<ws>.toolchain.facts.wasiSdkVersion`";
    packageSet = "set `targets.<triple>.packageSet`";
  };

  # Definitions `attrs` with every value failing with `msg` unless
  # `cond`. Plain attribute sets keep their names, down to the values:
  # under an option group (`host`, `bindgen`) the module system reads the
  # names before deciding a `lib.mkIf`.
  guard =
    cond: msg:
    let
      g =
        v:
        if builtins.isAttrs v && !(v ? _type) && !lib.isDerivation v then
          lib.mapAttrs (_: g) v
        else if cond then
          v
        else
          throw msg;
    in
    g;

  # One of several mechanisms, chosen by the target's traits: `cases` is
  # a list of `{ when; definitions; }`; none matching fails with `msg`
  # when the linker is read.
  dispatch =
    cases: msg:
    lib.mkMerge (
      map (c: lib.mkIf c.when c.definitions) cases
      ++ [ (lib.mkIf (!lib.any (c: c.when) cases) { linker = throw msg; }) ]
    );

  # A chain of stage helpers (`breakbulk.stageHelpers`), each after the
  # previous, the first after `linked`, every field `mkDefault`.
  stageChain =
    names:
    lib.listToAttrs (
      lib.imap0 (
        i: n:
        lib.nameValuePair n {
          after = mkDefault (if i == 0 then "linked" else lib.elemAt names (i - 1));
          run = mkDefault stageHelpers.${n};
        }
      ) names
    );
  inherit (targetTraits) nativeTriple;

  # The package set whose libraries a target links, one rule for every
  # preset: pkgs itself for the native triple, else nixpkgs for the
  # target's `nixpkgsSystem` trait.
  #
  #   targetPkgsFor pkgs traits -> a package set
  targetPkgsFor =
    pkgs: traits:
    let
      s = traits.nixpkgsSystem;
    in
    if traits.triple == nativeTriple pkgs then
      pkgs
    else
      builtins.seq (targetTraits.nixpkgsPlatform traits).system (
        if builtins.isString s then
          pkgs.pkgsCross.${s}
        else
          import pkgs.path {
            localSystem = pkgs.stdenv.buildPlatform;
            crossSystem = s;
            inherit (pkgs) overlays config;
          }
      );

  # The linker choice (./linker.nix): one function for every preset.
  linkers = import ./linker.nix {
    inherit
      lib
      util
      targetTraits
      toolchainFacts
      ;
  };
  inherit (linkers) chooseLinker;

  # The test runner choice (./runner.nix): one function for every preset.
  runnerChoice = import ./runner.nix { inherit lib runners wasmBindgen; };
  inherit (runnerChoice) chooseRunner;

  defaultEnv = lib.mapAttrs (_: mkDefault);

  # Shared by the wasm presets.
  wasmCommon =
    {
      pkgs,
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      linkerKind ? null,
      kinds,
      facts,
      ...
    }:
    let
      bp = pkgs.buildPackages;
      llvm = facts.llvmPackages;
      clang = llvm.clang-unwrapped;
    in
    {
      packageSet = mkDefault null;
      linker = mkDefault (chooseLinker {
        inherit
          pkgs
          triple
          traits
          facts
          llvm
          ;
        kind = linkerKind;
        inherit kinds;
      });
      # Unwrapped: a wrapped compiler can silently emit host objects.
      cc = mkDefault "${clang}/bin/clang";
      cxx = mkDefault "${clang}/bin/clang++";
      ar = mkDefault "${llvm.llvm}/bin/llvm-ar";
      testSystem = mkDefault null;
    };

  linuxGnuWith =
    extra:
    {
      pkgs,
      config,
      triple,
      traits,
      linkerKind ? null,
      kinds,
      crossLanguageLto ? false,
      nativeBuilder ? false,
      facts,
      ...
    }:
    let
      # The target's package set: the preset's default below, or the
      # user's `packageSet`.
      tp = config.packageSet;
      cc = tp.stdenv.cc;
      prefix = cc.targetPrefix;
      # The LLVM matching rustc: for crossLanguageLto's C toolchain, and the
      # linker kinds with lld.
      llvm = facts.llvmPackages;
      # Natively when the build machine runs the target's programs; else
      # on a native builder when nativeBuilder (testSystem), else under
      # qemu-user.
      r = chooseRunner {
        inherit pkgs traits nativeBuilder;
        hostPlatform = tp.stdenv.hostPlatform;
        canExecute = pkgs.stdenv.buildPlatform.canExecute tp.stdenv.hostPlatform;
      };
      st = staticLinking {
        inherit traits;
        crtStatic = extra.crtStatic or false;
      };
    in
    {
      packageSet = mkDefault (targetPkgsFor pkgs traits);
      linker = mkDefault (chooseLinker {
        inherit
          pkgs
          triple
          traits
          facts
          llvm
          ;
        kind = linkerKind;
        inherit kinds;
        lto = crossLanguageLto;
        packageSet = tp;
      });
      # With crossLanguageLto, C code is LLVM bitcode for the linker to
      # optimize with rustc's: the LLVM's clang compiles it, and its llvm-ar
      # archives it (GNU ar cannot index bitcode members).
      cc = mkDefault (
        if crossLanguageLto then
          "${llvm.clang}/bin/${llvm.clang.targetPrefix}clang"
        else
          "${cc}/bin/${prefix}cc"
      );
      cxx = mkDefault (
        if crossLanguageLto then
          "${llvm.clang}/bin/${llvm.clang.targetPrefix}clang++"
        else
          "${cc}/bin/${prefix}c++"
      );
      ar = mkDefault (
        if crossLanguageLto then "${llvm.llvm}/bin/llvm-ar" else "${cc.bintools}/bin/${prefix}ar"
      );
      cflags = lib.optionals crossLanguageLto [ "-flto=thin" ];
      cxxflags = lib.optionals crossLanguageLto [ "-flto=thin" ];
      rustflags =
        lib.optionals crossLanguageLto [
          "-C"
          "linker-plugin-lto"
        ]
        ++ st.rustflags;
      env = defaultEnv st.env;
      runner = mkDefault r.runner;
      testSystem = mkDefault r.testSystem;
    };

  # Static linking, one rule for every preset: `+crt-static` in the target
  # units' rustflags, and, where that makes the C library static too (an
  # ELF target: musl, static glibc; a static executable has no dynamic
  # loader, so it cannot load a shared library), PKG_CONFIG_ALL_STATIC in
  # the target units' env, so that pkg-config-rs links every library it
  # finds statically (`rustc-link-lib=static=…`, when the `.a` exists;
  # pkg-config 0.3.34, `infer_static`, which has no rule of its own for
  # musl). Target env, never host env: on host units it makes build
  # scripts link `libc.a` and crash. Windows' `+crt-static` links the C
  # runtime statically, but an .exe still loads DLLs, so pkg-config is
  # left alone there.
  #
  #   staticLinking { traits; crtStatic ? true; } -> { rustflags; env; }
  staticLinking =
    {
      traits,
      crtStatic ? true,
    }:
    if !crtStatic then
      {
        rustflags = [ ];
        env = { };
      }
    else
      {
        rustflags = [
          "-C"
          "target-feature=+crt-static"
        ];
        env = lib.optionalAttrs (traits.objectFormat == "elf") {
          # pkg-config-rs: link every pkg-config library statically.
          PKG_CONFIG_ALL_STATIC = "1";
        };
      };

  # The presets' implementations, one per mechanism; the public presets
  # below pick one from the target's traits.
  impl = {
    # Linux, dynamically linked, native or cross (nixpkgs cross toolchains).
    # Linker: the one rustc picks (./linker.nix), through the wrapped cc;
    # with crossLanguageLto, clang + lld from the LLVM matching rustc and
    # `-C linker-plugin-lto`. Tests: native when the build
    # machine can run them; else on a native builder when nativeBuilder
    # (testSystem), else under qemu-user.
    linux = linuxGnuWith { };

    # Linux musl: as linux with nixpkgs' musl cross toolchain, and static
    # linking (`staticLinking`: `+crt-static`, pkg-config libraries static).
    # rustc's default for musl targets stays: crt objects,
    # libc.a and libunwind.a from the Rust target's self-contained directory
    # (`-C link-self-contained=no` fails: nixpkgs' musl toolchain has no
    # libunwind.a). C code compiles against nixpkgs' musl headers.
    linuxMusl = linuxGnuWith {
      crtStatic = true;
    };

    # A fully static glibc binary (static-pie by default; see relocationModel)
    # on the host triple. Host and target share
    # the triple, so passing it as `--target` keeps the target rustflags off
    # host units, and the static-only env (PKG_CONFIG_ALL_STATIC) is target
    # env: build scripts and proc macros stay dynamic. `staticLibDirs` are
    # extra directories of static archives (`-L native=`), e.g.
    # [ "${openssl.override { static = true; }}/lib" ].
    staticGlibc =
      {
        pkgs,
        triple,
        traits,
        staticLibDirs ? [ ],
        # null: rustc's default (pic), which with +crt-static gives a
        # static-pie executable, as `cargo build` does. "static" (non-PIE)
        # works with the cc and lld linker kinds; mold 3.0.0 links Rust
        # non-PIE static glibc executables that crash at startup in
        # `_dl_get_origin` (C programs are unaffected), so chooseLinker
        # rejects that pair.
        relocationModel ? null,
        linkerKind ? null,
        kinds,
        facts,
        ...
      }:
      let
        cc = pkgs.stdenv.cc;
        st = staticLinking { inherit traits; };
      in
      guard (triple == nativeTriple pkgs)
        "breakbulk.presets.linuxStatic: ${triple} is not the host triple ${nativeTriple pkgs}"
        {
          packageSet = mkDefault pkgs;
          linker = mkDefault (chooseLinker {
            inherit
              pkgs
              triple
              traits
              facts
              ;
            kind = linkerKind;
            inherit kinds;
            staticNonPie = relocationModel == "static";
            llvm = facts.llvmPackages;
          });
          cc = mkDefault "${cc}/bin/cc";
          cxx = mkDefault "${cc}/bin/c++";
          ar = mkDefault "${cc.bintools}/bin/ar";
          rustflags =
            st.rustflags
            ++ lib.optionals (relocationModel != null) [
              "-C"
              "relocation-model=${relocationModel}"
            ]
            ++ lib.concatMap (d: [
              "-L"
              "native=${d}"
            ]) ([ "${pkgs.glibc.static}/lib" ] ++ staticLibDirs);
          env = defaultEnv st.env;
          runner = mkDefault null;
          testSystem = mkDefault null;
        };

    # Windows msvc through xwin: lld-link (wrapped so
    # the PDB, and so the .exe, are reproducible), clang-cl and llvm-lib from
    # the LLVM matching rustc, include directories as -imsvc for cc and
    # -isystem for bindgen, RC/RCFLAGS/LIB/INCLUDE on target units only,
    # optional +crt-static, wine as the runner (x86_64 and i686).
    # `extraSdks`: further SDKs, each { includeDirs = [ … ]; libDirs = [ … ]; }
    # (libDirs for this target's arch), e.g. a driver kit.
    msvc =
      {
        pkgs,
        triple,
        traits,
        sdk ? throw "breakbulk.presets.windows: the msvc target ${triple} needs `sdk` (breakbulk.xwinSdk { … })",
        crtStatic ? false,
        extraSdks ? [ ],
        linkerKind ? null,
        kinds,
        facts,
        wine ? pkgs.wineWow64Packages.minimal,
        ...
      }:
      let
        bp = pkgs.buildPackages;
        llvm = facts.llvmPackages;
        clang = llvm.clang-unwrapped;
        tools = "${llvm.llvm}/bin";
        incdirs = sdk.includeDirs ++ lib.concatMap (s: s.includeDirs or [ ]) extraSdks;
        # The SDK's library directories are per arch, in xwin's names.
        arch = traits.xwinArch;
        sdkLibDirs =
          sdk.libDirs.${arch}
            or (throw "breakbulk.presets.windows: the SDK for ${triple} has no libraries for xwin's arch `${arch}`; build it with `breakbulk.xwinSdk { arches = [ \"${arch}\" ]; … }`, or set `targets.\"${triple}\".traits.xwinArch`");
        libdirs = sdkLibDirs ++ lib.concatMap (s: s.libDirs or [ ]) extraSdks;
        cflags = [
          "--target=${triple}"
        ]
        ++ lib.concatMap (d: [
          "-imsvc"
          d
        ]) incdirs;
      in
      {
        packageSet = mkDefault null;
        linker = mkDefault (chooseLinker {
          inherit
            pkgs
            triple
            traits
            facts
            llvm
            ;
          kind = linkerKind;
          inherit kinds;
        });
        cc = mkDefault "${clang}/bin/clang-cl";
        cxx = mkDefault "${clang}/bin/clang-cl";
        ar = mkDefault "${tools}/llvm-lib";
        inherit cflags;
        cxxflags = cflags;
        bindgen.extraClangArgs = [
          "--target=${triple}"
        ]
        ++ lib.concatMap (d: [
          "-isystem"
          d
        ]) incdirs;
        rustflags =
          map (d: "-Lnative=${d}") libdirs ++ (staticLinking { inherit traits crtStatic; }).rustflags;
        env =
          defaultEnv {
            LIBCLANG_PATH = "${lib.getLib llvm.libclang}/lib";
            RC = "${tools}/llvm-rc";
            RCFLAGS = lib.concatMapStringsSep " " (d: "/I ${d}") incdirs;
            LIB = lib.concatStringsSep ";" libdirs;
            INCLUDE = lib.concatStringsSep ";" incdirs;
          }
          # llvm-rc runs `clang` from PATH to preprocess (llvm-rc.cpp,
          # findClang): a list, appended to the capture's PATH, and not at
          # `mkDefault`, which a user's own list would drop.
          // {
            PATH = [
              "${clang}/bin"
              tools
              "${llvm.lld}/bin"
            ];
          };
        runner =
          mkDefault
            (chooseRunner {
              inherit pkgs traits wine;
              canExecute = false;
            }).runner;
        testSystem = mkDefault null;
      };

    # UEFI applications: lld-link from the LLVM matching rustc, wrapped
    # as for msvc so the PDB, and so the .efi, are reproducible; rustc's
    # target spec otherwise links with its own rust-lld as lld-link, and
    # its temporary directory's random name lands in the PDB. No C
    # toolchain and no runner: nothing to set them from.
    uefi =
      {
        pkgs,
        triple,
        traits,
        linkerKind ? null,
        kinds,
        facts,
        ...
      }:
      guard traits.isUefi "breakbulk.presets.uefi: `${triple}` is not a UEFI triple" {
        packageSet = mkDefault null;
        linker = mkDefault (chooseLinker {
          inherit
            pkgs
            triple
            traits
            facts
            ;
          kind = linkerKind;
          inherit kinds;
          llvm = facts.llvmPackages;
        });
        runner = mkDefault null;
        testSystem = mkDefault null;
      };

    # Bare-metal targets (os none) whose rustc spec links with lld: the
    # toolchain's own rust-lld, as the spec does, when it ships one
    # (`facts.bundledLld`), else nixpkgs' ld.lld of rustc's LLVM major
    # (./linker.nix). No C toolchain and no runner: nothing to set them
    # from (a C compiler for the board is `targets.<t>.cc`).
    bareMetal =
      {
        pkgs,
        triple,
        traits,
        linkerKind ? null,
        kinds,
        facts,
        ...
      }:
      guard traits.isBareMetal
        "breakbulk.presets.bareMetal: `${triple}` is not a bare-metal triple (os none)"
        {
          packageSet = mkDefault null;
          linker = mkDefault (chooseLinker {
            inherit
              pkgs
              triple
              traits
              facts
              kinds
              ;
            kind = linkerKind;
          });
          runner =
            mkDefault
              (chooseRunner {
                inherit pkgs traits;
                canExecute = false;
              }).runner;
          testSystem = mkDefault null;
        };

    # wasm32-unknown-unknown for the browser: rustc's own wasm linker flavor,
    # with the version-matched `wasm-ld` instead of rustup's rust-lld; C code
    # with unwrapped clang targeting wasm32; tests under
    # wasm-bindgen-test-runner in Node.js (browser = "chromium" or
    # "firefox" for that headless browser). The runner is a function of the
    # workspace's lockfile, since the runner must be the exact wasm-bindgen
    # version.
    wasmWeb =
      {
        pkgs,
        traits,
        browser ? "node",
        ...
      }@args:
      wasmCommon args
      // {
        stages = stageChain [
          "wasmBindgen"
          "wasmOpt"
        ];
        runner =
          mkDefault
            (chooseRunner {
              inherit pkgs browser traits;
              canExecute = false;
              flavor = "wasm-bindgen";
            }).runner;
      };

    # Further targets, one file each.
    wasip2 = import ./wasip2.nix {
      inherit
        lib
        wasmCommon
        chooseRunner
        guard
        ;
      wasiSdkLib = wasiSdk;
    };
    linuxPortable = import ./linux-portable.nix {
      inherit
        lib
        targetTraits
        stageHelpers
        chooseLinker
        chooseRunner
        nativeTriple
        ;
    };
    darwin = import ./darwin.nix {
      inherit
        lib
        targetTraits
        appleSdk
        linkers
        chooseRunner
        guard
        stageHelpers
        ;
    };
    windowsGnu = import ./windows-gnu.nix {
      inherit
        lib
        targetPkgsFor
        chooseLinker
        chooseRunner
        staticLinking
        ;
    };

    # wasm32-unknown-unknown core modules, componentized by the product's
    # stages. withC = true: C code compiles against nixpkgs' wasilibc
    # (headers and libc.a), with `-C link-self-contained=no` and the library
    # directory on the link path. Runner: wasmtime.
    wasmCore =
      {
        pkgs,
        triple,
        traits,
        withC ? false,
        wasilibc ? pkgs.pkgsCross.wasi32.wasilibc,
        ...
      }@args:
      let
        c = wasmCommon args;
        # The multiarch directory wasilibc installs headers and libraries under.
        wasiTriple = "wasm32-wasip1";
        inc = "-isystem ${lib.getDev wasilibc}/include/${wasiTriple}";
      in
      c
      // lib.optionalAttrs withC {
        rustflags = [
          "-C"
          "link-self-contained=no"
          "-L"
          "native=${wasilibc}/lib/${wasiTriple}"
        ];
        cflags = [ inc ];
        cxxflags = [ inc ];
        bindgen.extraClangArgs = [
          "--target=${triple}"
          inc
        ];
      }
      // {
        stages = stageChain [
          "wasmOpt"
          "wasmComponentize"
          "wasmMetadata"
        ];
        runner =
          mkDefault
            (chooseRunner {
              inherit pkgs traits;
              canExecute = false;
              flavor = "wasmtime";
            }).runner;
      };
  };
in
{
  # The functions presets are built from (`breakbulk.presetHelpers`), apart
  # from the presets because a target's default preset is looked up in
  # `presets` by name.
  helpers = {
    inherit
      targetPkgsFor
      chooseLinker
      chooseRunner
      staticLinking
      ;
    inherit (linkers)
      linkerKind
      linkerFeatures
      rustcFacts
      lldLinker
      ccDriverLinker
      # The linker kinds `targets.<triple>.linkerKinds` starts from.
      builtinKinds
      ;
    inherit (runnerChoice) runnerKind;
  };

  presets = {
    # Presets are named for what they are for; the mechanism follows from
    # the target triple's traits. Options that do not apply
    # to the triple's mechanism are ignored, so one bound preset can serve
    # several targets (`windows { inherit sdk; }` for an msvc and a gnu
    # triple).

    # Linux, dynamically linked, native or cross (nixpkgs cross toolchains,
    # glibc or musl from the triple). Linker: the one rustc picks, through
    # the wrapped cc (`linkerKind` for another);
    # with crossLanguageLto, clang + lld from the LLVM matching rustc and
    # `-C linker-plugin-lto`. Tests: native when the build machine can run
    # them; else on a native builder when nativeBuilder (testSystem), else
    # under qemu-user.
    linux = presetModule impl.linux;

    # Linux, statically linked (`staticLinking`: `+crt-static`, pkg-config
    # libraries static): with musl for a `-musl` triple (nixpkgs' musl cross
    # toolchain; options as `linux`), as a static-pie glibc executable for a
    # `-gnu` triple, which must be the host triple (`staticLibDirs`,
    # `relocationModel`).
    linuxStatic = presetModule (
      a:
      dispatch [
        {
          when = a.traits.isLinux && a.traits.env == "musl";
          definitions = impl.linuxMusl a;
        }
        {
          when = a.traits.isLinux && a.traits.env == "gnu";
          definitions = impl.staticGlibc a;
        }
      ] "breakbulk.presets.linuxStatic: `${a.triple}` is not a Linux -musl or -gnu triple"
    );

    # Linux programs that run on other distributions:
    # `linuxPortable { glibc = "2.17"; systemLibraries = [ ]; overlays = [ ]; }`
    # (./linux-portable.nix).
    linuxPortable = presetModule impl.linuxPortable;

    # Windows: msvc through xwin for a `-msvc` triple (`sdk`, `extraSdks`,
    # `crtStatic` default false), MinGW for a `-gnu` or `-gnullvm` triple
    # (./windows-gnu.nix; `crtStatic` default true; `lld`).
    windows = presetModule (
      a:
      dispatch [
        {
          when = a.traits.isMsvc;
          definitions = impl.msvc a;
        }
        {
          when = a.traits.isMingw;
          definitions = impl.windowsGnu a;
        }
      ] "breakbulk.presets.windows: `${a.triple}` is not a Windows -msvc, -gnu or -gnullvm triple"
    );

    # macOS: {aarch64,x86_64}-apple-darwin (./darwin.nix). On a Linux build
    # machine rustc links with an ld64.lld against the macOS SDK, which is
    # required (`sdk`, a package or a version for breakbulk.appleSdk);
    # `deploymentTarget`, `nativeBuilder`.
    darwin = presetModule impl.darwin;

    # wasm for the web: core modules through wasm-bindgen.
    wasmWeb = presetModule impl.wasmWeb;

    # UEFI applications (`*-unknown-uefi`): the default preset of every UEFI
    # triple, which only sets the linker.
    uefi = presetModule impl.uefi;

    # Bare-metal programs (`x86_64-unknown-none`, `thumbv*-none-eabi*`,
    # `riscv*-unknown-none-elf`, …): the default preset of the bare-metal
    # triples whose rustc spec links with lld, which only sets the linker.
    bareMetal = presetModule impl.bareMetal;

    # Not a preset: a C compiler driver as a linker, for the `build` of a
    # linker kind a user adds (`targets.<triple>.linkerKinds`), as the
    # cc, lld and mold kinds are built (./linker.nix).
    inherit (linkers) ccDriverLinker;

    # wasm components: `wasm32-wasip2` links them directly with rustc's
    # wasm-component-ld (./wasip2.nix; `withC`, `wasiSdk`);
    # `wasm32-unknown-unknown` core modules are componentized by the
    # products' stages (`withC`, `wasilibc`).
    wasmComponent = presetModule (
      a:
      dispatch
        [
          {
            when = a.traits.linksComponents;
            definitions = impl.wasip2 a;
          }
          {
            when = a.traits.isWasm && !a.traits.isWasi;
            definitions = impl.wasmCore a;
          }
        ]
        "breakbulk.presets.wasmComponent: `${a.triple}` is not wasm32-wasip2 or a wasm target without WASI"
    );
  };
}
