# Toolchain presets ("Toolchain presets" in
# docs/src/explanation/internals/toolchains.md;
# docs/src/explanation/targets.md).
#
# A preset is a function from `{ pkgs, triple, …options }` to a module value
# for `targets.<triple>`, so every field can be overridden with ordinary
# module priorities: scalar fields (linker, cc, runner, …) are set with
# `mkDefault`, so a plain definition replaces them; lists (rustflags,
# cflags) concatenate, and `mkForce` replaces them; env values are
# `mkDefault` per variable.
#
#   targets.x86_64-unknown-linux-musl =
#     breakbulk.presets.linuxStatic { inherit pkgs; triple = "x86_64-unknown-linux-musl"; };
#   # or, letting the target fill in pkgs and the triple:
#   targets.x86_64-unknown-linux-musl.preset = breakbulk.presets.linuxStatic;
#   targets.x86_64-pc-windows-msvc.preset = breakbulk.presets.windows { inherit sdk; };
#
# A preset called without `pkgs` returns the same preset with those options
# bound, so `presets.windows { sdk = …; }` is itself a preset.
#
# Through `preset`, a target's preset is applied once per workspace and
# given that workspace's toolchain (`toolchain`, see mkPreset), so presets
# that need rustc's LLVM or wasi-sdk version follow each workspace's rustc.
# Calling a preset directly (`presets.windows { inherit pkgs triple sdk;
# … }`) has no workspace: pass `rustc` there.
#
# Every preset sets the host spec (`host.linker`, `host.env`) from
# `pkgs.buildPackages`, so host units (build scripts, proc macros and their
# dependencies) always get the build machine's tools, and target settings
# never reach them: target env is added only to target units at
# instantiation, never through Cargo's `[env]`.
#
# Presets that use LLVM tools (windows for msvc, wasm, linux with crossLanguageLto)
# need the LLVM matching rustc: the workspace's `rustc` by default, or one
# passed as `rustc` (its version is looked up in breakbulk.llvmVersions,
# read from `rustc -vV` (IFD) when the table does not cover it, or nixpkgs'
# rustc.llvmPackages is used), `llvmMajor`, or `llvmPackages`.
{
  lib,
  targetTraits,
  llvmVersions,
  runners,
  wasmBindgen,
  wasiSdk,
  stageHelpers,
}:
let
  inherit (lib) mkDefault;

  # Bind options until `pkgs` is given.
  #
  # `traits` are the target's traits (lib/target-traits.nix), which a
  # target passes with the user's `targets.<triple>.traits` merged in; a
  # preset called without them uses the built-in traits of its triple.
  #
  # `toolchain` is the workspace's toolchain (`workspaces.<ws>.toolchain`),
  # which a target passes when it applies the preset for one workspace
  # (lib/modules/target-spec.nix): its `rustc` becomes the preset's `rustc`
  # unless one was given, so LLVM tools and the wasi-sdk follow each
  # workspace's compiler. Every stage advertises `toolchain`
  # in its function arguments; a preset that does not (a plain user
  # function) is called without it.
  mkPreset =
    f:
    let
      go =
        bound:
        lib.setFunctionArgs (
          args:
          let
            a = bound // args;
            tc = a.toolchain or null;
            withRustc =
              removeAttrs a [ "toolchain" ]
              // lib.optionalAttrs (!(a ? rustc) && tc != null && tc.rustc or null != null) {
                inherit (tc) rustc;
              };
          in
          if a ? pkgs then f withRustc // { presetDirect = true; } else go a
        ) {
          toolchain = true;
          traits = true;
        };
    in
    go { };

  inherit (targetTraits) nativeTriple;

  # nixpkgs' cross package set for a Rust target, where it differs from
  # importing nixpkgs with `crossSystem.config = <triple>`: a pkgsCross
  # attribute (the ones Hydra builds, and caches), or a crossSystem.
  crossSets = {
    "aarch64-unknown-linux-gnu" = "aarch64-multiplatform";
    "aarch64-unknown-linux-musl" = "aarch64-multiplatform-musl";
    "x86_64-unknown-linux-gnu" = "gnu64";
    "x86_64-unknown-linux-musl" = "musl64";
    "riscv64gc-unknown-linux-gnu" = "riscv64";
    "armv7-unknown-linux-gnueabihf" = "armv7l-hf-multiplatform";
    "wasm32-wasip1" = "wasi32";
    # mingw-w64 with gcc and msvcrt (Rust's own windows-gnu CRT).
    "x86_64-pc-windows-gnu" = "mingwW64";
    "i686-pc-windows-gnu" = "mingw32";
    # LLVM mingw-w64 with ucrt.
    "aarch64-pc-windows-gnullvm" = "ucrtAarch64";
    "x86_64-pc-windows-gnullvm" = lib.systems.examples.mingw-ucrt-x86_64-llvm;
  };

  # The package set whose libraries `triple` links, one table for every
  # preset: pkgs itself for the native triple, else a cross set.
  targetPkgsFor =
    pkgs: triple:
    let
      cross = crossSets.${triple} or { config = triple; };
    in
    if triple == nativeTriple pkgs then
      pkgs
    else if builtins.isString cross then
      pkgs.pkgsCross.${cross}
    else
      import pkgs.path {
        localSystem = pkgs.stdenv.buildPlatform;
        crossSystem = cross;
        inherit (pkgs) overlays config;
      };

  # The linker choice (./linker.nix): one function for every preset.
  linkers = import ./linker.nix { inherit lib targetTraits; };
  inherit (linkers) chooseLinker;

  # The test runner choice (./runner.nix): one function for every preset.
  runnerChoice = import ./runner.nix { inherit lib runners wasmBindgen; };
  inherit (runnerChoice) chooseRunner;

  # The host spec every preset sets: the build machine's linker. On a
  # native build host and target linkers are the same derivation, so host
  # units are identical whatever the target.
  hostSpec = pkgs: {
    linker = mkDefault (chooseLinker {
      pkgs = pkgs.buildPackages;
      triple = nativeTriple pkgs.buildPackages;
    });
    env = { };
  };

  defaultEnv = lib.mapAttrs (_: mkDefault);

  # Shared by the wasm presets.
  wasmCommon =
    {
      pkgs,
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      rustc ? null,
      llvmMajor ? null,
      llvmPackages ? null,
      ...
    }:
    let
      bp = pkgs.buildPackages;
      llvm = llvmVersions.packagesFor {
        pkgs = bp;
        inherit rustc llvmMajor llvmPackages;
      };
      clang = llvm.clang-unwrapped;
    in
    {
      packageSet = mkDefault null;
      linker = mkDefault (chooseLinker {
        inherit
          pkgs
          triple
          traits
          llvm
          ;
      });
      # Unwrapped: a wrapped compiler can silently emit host objects.
      cc = mkDefault "${clang}/bin/clang";
      cxx = mkDefault "${clang}/bin/clang++";
      ar = mkDefault "${llvm.llvm}/bin/llvm-ar";
      testSystem = mkDefault null;
      host = hostSpec pkgs;
    };

  linuxGnuWith =
    extra:
    {
      pkgs,
      triple ? throw "breakbulk.presets: give the target `triple`",
      traits ? targetTraits.resolve { inherit triple; },
      packageSet ? targetPkgsFor pkgs triple,
      crossLanguageLto ? false,
      nativeBuilder ? false,
      rustc ? null,
      llvmMajor ? null,
      llvmPackages ? null,
      ...
    }:
    let
      tp = packageSet;
      cc = tp.stdenv.cc;
      prefix = cc.targetPrefix;
      llvm =
        if crossLanguageLto then
          llvmVersions.packagesFor {
            pkgs = tp.buildPackages;
            inherit rustc llvmMajor llvmPackages;
          }
        else
          null;
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
      packageSet = mkDefault tp;
      linker = mkDefault (chooseLinker {
        inherit
          pkgs
          triple
          traits
          llvm
          ;
        lto = crossLanguageLto;
        packageSet = tp;
      });
      # With crossLanguageLto, C code is LLVM bitcode for the linker to
      # optimize with rustc's: the LLVM's clang compiles it, and its llvm-ar
      # archives it (GNU ar cannot index bitcode members).
      cc = mkDefault (
        if crossLanguageLto then "${llvm.clang}/bin/${llvm.clang.targetPrefix}clang" else "${cc}/bin/${prefix}cc"
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
      rustflags =
        lib.optionals crossLanguageLto [
          "-C"
          "linker-plugin-lto"
        ]
        ++ st.rustflags;
      env = defaultEnv st.env;
      runner = mkDefault r.runner;
      testSystem = mkDefault r.testSystem;
      host = hostSpec pkgs;
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
    # Linux, dynamically linked, native or cross (nixpkgs cross toolchains). Linker: mold
    # through the wrapped cc; with crossLanguageLto, clang + lld from the LLVM
    # matching rustc and `-C linker-plugin-lto`. Tests: native when the build
    # machine can run them; else on a native builder when nativeBuilder
    # (testSystem), else under qemu-user.
    linux = mkPreset (linuxGnuWith { });

    # Linux musl: as linux with nixpkgs' musl cross toolchain, and static
    # linking (`staticLinking`: `+crt-static`, pkg-config libraries static).
    # rustc's default for musl targets stays: crt objects,
    # libc.a and libunwind.a from the Rust target's self-contained directory
    # (`-C link-self-contained=no` fails: nixpkgs' musl toolchain has no
    # libunwind.a). C code compiles against nixpkgs' musl headers.
    linuxMusl = mkPreset (linuxGnuWith {
      crtStatic = true;
    });

    # A fully static glibc binary (static-pie by default; see relocationModel)
    # on the host triple. Host and target share
    # the triple, so passing it as `--target` keeps the target rustflags off
    # host units, and the static-only env (PKG_CONFIG_ALL_STATIC) is target
    # env: build scripts and proc macros stay dynamic. `staticLibDirs` are
    # extra directories of static archives (`-L native=`), e.g.
    # [ "${openssl.override { static = true; }}/lib" ].
    staticGlibc = mkPreset (
      {
        pkgs,
        triple ? nativeTriple pkgs,
        traits ? targetTraits.resolve { inherit triple; },
        staticLibDirs ? [ ],
        # null: rustc's default (pic), which with +crt-static gives a
        # static-pie executable. Not "static" (non-PIE) by default: mold
        # 3.0.0 links Rust non-PIE static glibc executables that crash at
        # startup in `_dl_get_origin` (bfd and lld do not; C programs are
        # unaffected).
        relocationModel ? null,
        ...
      }:
      let
        cc = pkgs.stdenv.cc;
      in
      assert lib.assertMsg (
        triple == nativeTriple pkgs
      ) "breakbulk.presets.linuxStatic: ${triple} is not the host triple ${nativeTriple pkgs}";
      let
        st = staticLinking { inherit traits; };
      in
      {
        packageSet = mkDefault pkgs;
        linker = mkDefault (chooseLinker { inherit pkgs triple traits; });
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
        host = hostSpec pkgs;
      }
    );

    # Windows msvc through xwin: lld-link (wrapped so
    # the PDB, and so the .exe, are reproducible), clang-cl and llvm-lib from
    # the LLVM matching rustc, include directories as -imsvc for cc and
    # -isystem for bindgen, RC/RCFLAGS/LIB/INCLUDE on target units only,
    # optional +crt-static, wine as the runner (x86_64 and i686).
    # `extraSdks`: further SDKs, each { includeDirs = [ … ]; libDirs = [ … ]; }
    # (libDirs for this target's arch), e.g. a driver kit.
    msvc = mkPreset (
      {
        pkgs,
        triple,
        traits ? targetTraits.resolve { inherit triple; },
        # The SDK's library directories are per arch (`sdk.libDirs.<arch>`).
        arch ? traits.arch,
        sdk ? throw "breakbulk.presets.windows: the msvc target ${triple} needs `sdk` (breakbulk.xwinSdk { … })",
        crtStatic ? false,
        extraSdks ? [ ],
        rustc ? null,
        llvmMajor ? null,
        llvmPackages ? null,
        wine ? pkgs.wineWow64Packages.minimal,
        ...
      }:
      let
        bp = pkgs.buildPackages;
        llvm = llvmVersions.packagesFor {
          pkgs = bp;
          inherit rustc llvmMajor llvmPackages;
        };
        clang = llvm.clang-unwrapped;
        tools = "${llvm.llvm}/bin";
        incdirs = sdk.includeDirs ++ lib.concatMap (s: s.includeDirs or [ ]) extraSdks;
        libdirs = sdk.libDirs.${arch} ++ lib.concatMap (s: s.libDirs or [ ]) extraSdks;
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
            llvm
            ;
        });
        cc = mkDefault "${clang}/bin/clang-cl";
        cxx = mkDefault "${clang}/bin/clang-cl";
        ar = mkDefault "${tools}/llvm-lib";
        inherit cflags;
        bindgen.extraClangArgs = [
          "--target=${triple}"
        ]
        ++ lib.concatMap (d: [
          "-isystem"
          d
        ]) incdirs;
        rustflags =
          map (d: "-Lnative=${d}") libdirs ++ (staticLinking { inherit traits crtStatic; }).rustflags;
        env = defaultEnv {
          LIBCLANG_PATH = "${lib.getLib llvm.libclang}/lib";
          RC = "${tools}/llvm-rc";
          RCFLAGS = lib.concatMapStringsSep " " (d: "/I ${d}") incdirs;
          LIB = lib.concatStringsSep ";" libdirs;
          INCLUDE = lib.concatStringsSep ";" incdirs;
          # llvm-rc runs `clang` from PATH to preprocess (llvm-rc.cpp,
          # findClang); PATH is appended to the capture's.
          PATH = "${clang}/bin:${tools}:${llvm.lld}/bin";
        };
        runner = mkDefault (chooseRunner {
          inherit pkgs traits wine;
          canExecute = false;
        }).runner;
        testSystem = mkDefault null;
        host = hostSpec pkgs;
      }
    );

    # wasm32-unknown-unknown for the browser: rustc's own wasm linker flavor,
    # with the version-matched `wasm-ld` instead of rustup's rust-lld; C code
    # with unwrapped clang targeting wasm32; tests under
    # wasm-bindgen-test-runner in Node.js (browser = "chromium" or
    # "firefox" for that headless browser). The runner is a function of the
    # workspace's lockfile, since the runner must be the exact wasm-bindgen
    # version.
    wasmWeb = mkPreset (
      {
        pkgs,
        triple ? "wasm32-unknown-unknown",
        browser ? "node",
        rustc ? null,
        llvmMajor ? null,
        llvmPackages ? null,
        ...
      }@args:
      wasmCommon (args // { inherit triple; })
      // {
        stagePreset = mkDefault "wasmWeb";
        runner = mkDefault (chooseRunner {
          inherit pkgs browser;
          traits = args.traits or (targetTraits.resolve { inherit triple; });
          canExecute = false;
          flavor = "wasm-bindgen";
        }).runner;
      }
    );

    # Further targets, one file each.
    wasip2 = mkPreset (
      import ./wasip2.nix {
        inherit lib wasmCommon chooseRunner;
        wasiSdkLib = wasiSdk;
      }
    );
    linuxPortable = mkPreset (
      import ./linux-portable.nix {
        inherit
          lib
          targetTraits
          stageHelpers
          chooseLinker
          chooseRunner
          hostSpec
          nativeTriple
          ;
      }
    );
    windowsGnu = mkPreset (
      import ./windows-gnu.nix {
        inherit
          lib
          targetTraits
          targetPkgsFor
          chooseLinker
          chooseRunner
          hostSpec
          staticLinking
          ;
      }
    );

    # wasm32-unknown-unknown core modules, componentized by the product's
    # stages. withC = true: C code compiles against nixpkgs' wasilibc
    # (headers and libc.a), with `-C link-self-contained=no` and the library
    # directory on the link path. Runner: wasmtime.
    wasmCore = mkPreset (
      {
        pkgs,
        triple ? "wasm32-unknown-unknown",
        withC ? false,
        wasilibc ? pkgs.pkgsCross.wasi32.wasilibc,
        # The multiarch directory wasilibc installs headers and libraries under.
        wasiTriple ? "wasm32-wasip1",
        ...
      }@args:
      let
        c = wasmCommon (args // { inherit triple; });
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
        bindgen.extraClangArgs = [
          "--target=${triple}"
          inc
        ];
      }
      // {
        stagePreset = mkDefault "wasmComponent";
        runner = mkDefault (chooseRunner {
          inherit pkgs;
          traits = args.traits or (targetTraits.resolve { inherit triple; });
          canExecute = false;
          flavor = "wasmtime";
        }).runner;
      }
    );
  };
in
{
  inherit
    targetPkgsFor
    chooseLinker
    chooseRunner
    hostSpec
    mkPreset
    staticLinking
    ;
  inherit (linkers)
    linkerKind
    moldLinker
    lldLinker
    ;
  inherit (runnerChoice) runnerKind;

  # Presets are named for what they are for; the mechanism follows from
  # the target triple's traits. Options that do not apply
  # to the triple's mechanism are ignored, so one bound preset can serve
  # several targets (`windows { inherit sdk; }` for an msvc and a gnu
  # triple).

  # Linux, dynamically linked, native or cross (nixpkgs cross toolchains,
  # glibc or musl from the triple). Linker: mold through the wrapped cc;
  # with crossLanguageLto, clang + lld from the LLVM matching rustc and
  # `-C linker-plugin-lto`. Tests: native when the build machine can run
  # them; else on a native builder when nativeBuilder (testSystem), else
  # under qemu-user.
  inherit (impl) linux;

  # Linux, statically linked (`staticLinking`: `+crt-static`, pkg-config
  # libraries static): with musl for a `-musl` triple (nixpkgs' musl cross
  # toolchain; options as `linux`), as a static-pie glibc executable for a
  # `-gnu` triple, which must be the host triple (`staticLibDirs`,
  # `relocationModel`). Default triple: the host's.
  linuxStatic = mkPreset (
    args:
    let
      triple = args.triple or (nativeTriple args.pkgs);
      traits = args.traits or (targetTraits.resolve { inherit triple; });
      a = args // {
        inherit triple traits;
      };
    in
    if traits.isLinux && traits.env == "musl" then
      impl.linuxMusl a
    else if traits.isLinux && traits.env == "gnu" then
      impl.staticGlibc a
    else
      throw "breakbulk.presets.linuxStatic: `${triple}` is not a Linux -musl or -gnu triple"
  );

  # Linux programs that run on other distributions:
  # `linuxPortable { glibc = "2.17"; systemLibraries = [ ]; backend =
  # "zig"; rebuildInputs = [ ]; }` (./linux-portable.nix).
  inherit (impl) linuxPortable;

  # Windows: msvc through xwin for a `-msvc` triple (`sdk`, `extraSdks`,
  # `crtStatic` default false), MinGW for a `-gnu` or `-gnullvm` triple
  # (./windows-gnu.nix; `crtStatic` default true, `lld`).
  windows = mkPreset (
    args:
    let
      triple = args.triple or (throw "breakbulk.presets.windows: give the target `triple`");
      traits = args.traits or (targetTraits.resolve { inherit triple; });
      a = args // {
        inherit traits;
      };
    in
    if traits.isMsvc then
      impl.msvc a
    else if traits.isMingw then
      impl.windowsGnu a
    else
      throw "breakbulk.presets.windows: `${triple}` is not a Windows -msvc, -gnu or -gnullvm triple"
  );

  # wasm for the web: core modules through wasm-bindgen.
  inherit (impl) wasmWeb;

  # wasm components: `wasm32-wasip2` links them directly with rustc's
  # wasm-component-ld (./wasip2.nix; `withC`, `wasiSdkVersion`,
  # `wasiSdk`); `wasm32-unknown-unknown` core modules are componentized by
  # the products' stages (`withC`, `wasilibc`, `wasiTriple`). Default
  # triple: wasm32-unknown-unknown.
  wasmComponent = mkPreset (
    args:
    let
      triple = args.triple or "wasm32-unknown-unknown";
      traits = args.traits or (targetTraits.resolve { inherit triple; });
      a = args // {
        inherit triple traits;
      };
    in
    if traits.isWasm && traits.isWasi && traits.env == "p2" then
      impl.wasip2 a
    else if traits.isWasm && !traits.isWasi then
      impl.wasmCore a
    else
      throw "breakbulk.presets.wasmComponent: `${triple}` is not wasm32-wasip2 or a wasm target without WASI"
  );
}
