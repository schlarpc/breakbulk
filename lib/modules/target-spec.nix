# The toolchain spec of one target platform, for one workspace (decision
# 70). Repository-wide definitions (`targets.<triple>`) and a
# workspace's own (`workspaces.<ws>.targets.<triple>`) are both modules of
# this kind; lib/repository.nix evaluates them together once per
# (workspace, target), with `name` the triple and `breakbulkToolchain` the
# workspace's toolchain, so a preset gets that workspace's rustc (see
# lib/modules/targets.nix for how the fields reach units).
{
  lib,
  name,
  options,
  config,
  pkgs,
  breakbulkPresets,
  breakbulkToolchain,
  ...
}:
let
  inherit (lib) types mkOption;

  # On Linux the native target gets `presets.linux`
  # (glibc `pkgs`) or `presets.linuxStatic` (musl `pkgs`) unless another
  # preset is set, so the native linker is nixpkgs' wrapped cc, as on every
  # other target, instead of rustc's bundled rust-lld. A target
  # defined directly from a preset (`targets.<t> =
  # breakbulk.presets.linuxPortable { … }`) counts as having one.
  targetTraits = import ../target-traits.nix { inherit lib; };
  nativeTriple = targetTraits.nativeTriple pkgs;
  nativePreset = targetTraits.nativeDefaultPreset pkgs;
  bt = import ./types.nix { inherit lib; };
  linkerKinds = import ../presets/linker-kinds.nix { inherit lib; };
  tool = types.nullOr (
    types.oneOf [
      types.str
      types.path
      types.package
    ]
  );

  # The fields a preset may set, as attribute paths.
  presetFields = [
    [ "packageSet" ]
    [ "linker" ]
    [ "cc" ]
    [ "cxx" ]
    [ "ar" ]
    [ "cflags" ]
    [
      "bindgen"
      "extraClangArgs"
    ]
    [ "rustflags" ]
    [ "env" ]
    [ "runner" ]
    [ "testSystem" ]
    [
      "host"
      "linker"
    ]
    [
      "host"
      "env"
    ]
    [ "stagePreset" ]
    [ "debugInfo" ]
    [ "checks" ]
  ];

  # This target's traits: the built-in ones of the triple with `traits`
  # merged over them (lib/target-traits.nix).
  traits = targetTraits.resolve {
    triple = name;
    inherit (config) traits;
  };

  # A preset that takes `toolchain` (every `breakbulk.presets.*` does)
  # gets this workspace's, so it picks LLVM tools and the wasi-sdk for the
  # workspace's rustc unless the preset was given `rustc` itself; one that
  # takes `traits` or `linkerKind` (every `breakbulk.presets.*` does) gets
  # the target's.
  takesLinkerKind = config.preset != null && lib.functionArgs config.preset ? linkerKind;
  applied =
    if config.preset == null then
      { }
    else
      config.preset (
        {
          inherit pkgs;
          triple = name;
        }
        // lib.optionalAttrs (breakbulkToolchain != null && lib.functionArgs config.preset ? toolchain) {
          toolchain = breakbulkToolchain;
        }
        // lib.optionalAttrs (lib.functionArgs config.preset ? traits) { inherit traits; }
        // lib.optionalAttrs (takesLinkerKind && config.linkerKind != null) { inherit (config) linkerKind; }
      );

  # One definition: a function, or a preset with options bound (a functor,
  # whose function arguments say whether it takes `toolchain`).
  presetType = lib.mkOptionType {
    name = "breakbulkPreset";
    description = "breakbulk preset (function)";
    descriptionClass = "noun";
    check = lib.isFunction;
    merge = lib.mergeOneOption;
  };
  fromPreset =
    path:
    lib.mkIf (config.preset != null && lib.hasAttrByPath path applied) (
      lib.getAttrFromPath path applied
    );
in
{
  options = {
    preset = mkOption {
      type = types.nullOr presetType;
      default =
        if name == nativeTriple && nativePreset != null && !config.presetDirect then
          breakbulkPresets.${nativePreset}
        else
          null;
      defaultText = lib.literalMD ''
        for the native triple, unless the target is defined directly from
        a preset: `breakbulk.presets.linux` when the `pkgs` given to
        mkRepository is Linux with glibc, `breakbulk.presets.linuxStatic`
        when it is Linux with musl (`pkgs.pkgsMusl`); `null` otherwise
      '';
      example = lib.literalExpression "breakbulk.presets.linuxStatic";
      description = ''
        A toolchain preset (`breakbulk.presets.*`, or a preset with its
        options bound, such as `breakbulk.presets.windows { inherit sdk; }`).
        It is called once per workspace that builds this triple, with
        `pkgs`, the triple and the workspace's `toolchain`, whose rustc
        it uses unless it was given `rustc` itself: the windows (msvc) and wasm presets
        pick the LLVM tools and the wasi-sdk matching each workspace's
        compiler. It sets the fields below at default priority, so
        fields set here override the preset's (lists concatenate; use
        `lib.mkForce` to replace one). Defining the target as
        `breakbulk.presets.<name> { inherit pkgs; triple = …; }` gives
        the same fields, except that the preset then sees no workspace
        toolchain (pass `rustc` there). Set `null` to use no preset on
        the native target (rustc's own linker choice and the C toolchain
        Cargo finds).
      '';
    };
    traits = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = lib.literalExpression ''
        # A board breakbulk has no built-in traits for (a custom target
        # spec): an ELF bare-metal target.
        { os = "none"; env = ""; abi = "eabihf"; }
      '';
      description = ''
        Facts about this target platform that override or extend the
        built-in ones breakbulk reads from the triple
        (`breakbulk.targetTraits.resolve`). Every platform-dependent
        decision reads the resulting traits: the linker kind, the default
        debug handling, the install layout and file names, debuginfo side
        files, the dynamic-library path of test processes, static linking.
        Base
        fields (`arch`, `vendor`, `os`, `env`, `abi`, `families`, as
        rustc's `target_*` cfg values) recompute the derived ones
        (`isLinux`, `objectFormat`, `executableSuffix`, `dylibPathVar`, …);
        derived fields set here win over the computed ones. A triple with
        no built-in traits (a custom target, a `.json` target spec, an
        uncommon OS) needs at least the base fields here; reading any
        trait of it otherwise fails with a message naming this option.
      '';
    };
    presetDirect = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      visible = false;
      description = "Set by every preset's value, so a target defined directly from a preset gets no default preset.";
    };
    packageSet = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        The nixpkgs package set for this platform: the target units'
        env capture uses its stdenv, and `packages.<name>.inputs`
        functions are called with it for target units. `null`: `pkgs`
        itself for the native triple; for any other triple there is no
        package set (msvc, wasm32-unknown-unknown), the env capture
        comes from the build platform, and package inputs are an
        error.
      '';
    };
    linker = mkOption {
      type = tool;
      default = null;
      description = ''
        The linker for this target's units (`target.<triple>.linker` in
        Cargo config). A store path. The preset sets it from
        `linkerKind`; a value here wins over both.
      '';
    };
    linkerKind = mkOption {
      type = types.nullOr (types.enum linkerKinds.names);
      default = null;
      example = "mold";
      description = ''
        Which kind of linker the preset builds for this target's units,
        and for host units (build scripts, proc macros) when this is the
        build machine's own triple. `null`: the linker rustc itself picks
        for the triple and Rust release, always through nixpkgs' wrapped
        C compiler: `lld` on Linux where rustc links with its bundled
        lld, `cc` (the C compiler's default, GNU ld) on other Linux
        targets; `lld-link`, `wasm-ld`, `wasm-component-ld` or
        `mingw-lld` on Windows and wasm. A kind that cannot link for this
        target, or with the preset's other settings (`mold` with
        `crossLanguageLto`), is an evaluation error. It needs a `preset`
        here; a target defined directly from a preset takes `linkerKind`
        as the preset's argument.
      '';
    };
    cc = mkOption {
      type = tool;
      default = null;
      description = "The C compiler build scripts use for this target (`CC_<triple>`).";
    };
    cxx = mkOption {
      type = tool;
      default = null;
      description = "The C++ compiler build scripts use for this target (`CXX_<triple>`).";
    };
    ar = mkOption {
      type = tool;
      default = null;
      description = "The archiver build scripts use for this target (`AR_<triple>`).";
    };
    cflags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "C and C++ flags for this target's C code (`CFLAGS_<triple>`, `CXXFLAGS_<triple>`).";
    };
    bindgen.extraClangArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra libclang arguments for bindgen (`BINDGEN_EXTRA_CLANG_ARGS_<triple>`).";
    };
    rustflags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra rustflags for this target's units, passed to Cargo with
        `--config` under the key the project itself uses
        (`build.rustflags` or `target.<triple>.rustflags`), so both sets
        arrive. Host units never get them.
      '';
    };
    env = mkOption {
      type = bt.envAttrs;
      default = { };
      description = ''
        Environment added to this target's units only (layer 4 of the
        unit environment contract; which units are on which
        [side](../../explanation/configuration.md#host-and-target-sides)),
        never through Cargo's `[env]`, so build-script compiles and proc
        macros (host units) do not see it.
        List-like variables (`PATH`, `NIX_CFLAGS_COMPILE`, …) are
        appended to the env capture's value.

        ${bt.envNote}
      '';
    };
    runner = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        The program that runs this target's test binaries (wine,
        wasmtime, qemu-user, …), invoked as `<runner> <binary> <args…>`
        like Cargo's `target.<triple>.runner`: a program, or a list of
        the program and its first arguments. `null`: run directly.
        May be a function `{ lockfile, workspace }: <runner>` for runners
        that depend on the workspace (wasm-bindgen-test-runner must
        match the locked wasm-bindgen).
      '';
    };
    testSystem = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "aarch64-linux";
      description = "The Nix system that runs this target's test runs, so Nix sends them to native builders. `null`: the build machine's.";
    };
    stdenv = mkOption {
      type = types.nullOr types.raw;
      default = null;
      example = lib.literalExpression "pkgs.clangStdenv";
      description = ''
        The stdenv whose setup hooks the target units' environment
        capture records (its C compiler, wrapper flags, hardening), for
        the base capture and every package's own. `null`: the package
        set's stdenv (`packageSet.stdenv`, or the build machine's for a
        target without a package set). It must build for this target.
      '';
    };
    host = {
      stdenv = mkOption {
        type = types.nullOr types.raw;
        default = null;
        example = lib.literalExpression "pkgs.clangStdenv";
        description = ''
          The stdenv of the host units' environment capture (build
          scripts, proc macros and their dependencies) of this target's
          plans. `null`: the build machine's (`buildPackages.stdenv` of
          the target's package set). It must build for the build machine.
        '';
      };
      linker = mkOption {
        type = tool;
        default = null;
        description = ''
          The linker for host units of this target's plans: given to
          Cargo as `target.<host triple>.linker` when the triples
          differ; when they are the same, host units' `-C linker` and
          `RUSTC_LINKER` are rewritten to it.
        '';
      };
      env = mkOption {
        type = bt.envAttrs;
        default = { };
        description = ''
          Environment added to host units of this target's plans only ([sides](../../explanation/configuration.md#host-and-target-sides)).

          ${bt.envNote}
        '';
      };
    };
    stages = mkOption {
      type = bt.stages;
      default = { };
      example = lib.literalExpression ''
        {
          # Strip the symbol tables too, after debug info is split off.
          stripAll = { after = "splitDebug"; run = breakbulk.stageHelpers.strip { all = true; }; };
        }
      '';
      description = ''
        Post-link stages for this target's products, merged over the
        stage `debugInfo` inserts and the stage preset's defaults
        (`stagePreset`). A stage is `{ after ? null; before ? null; run
        = { input, product, target, pkgs }: <derivation>; }`; `null`
        removes one. A stage runs before `install` and sees the flat link
        output, unless it is ordered after `install` (`after =
        "install"`, or after such a stage); then it sees the installed
        layout (`bin/`, `lib/`, `pkg/`), the place for wrappers and
        packaging. Package settings (`packages.<name>.stages`) merge
        over these. Neither may remove the stage `debugInfo` inserts or
        add `splitDebug` where it inserts none; set `debugInfo` instead.
      '';
    };
    checks = mkOption {
      type = bt.stages;
      default = { };
      description = ''
        Checks on this target's products: `{ on ? <the product>; run =
        { input, product, pkgs }: <derivation>; }`, where `on` names a
        stage (`linked` for the raw link output). Every product also
        gets `noSourceReferences`, `buildScriptFiles` and
        `buildScriptPaths`. `buildScriptFiles` fails when a build script
        placed files next to the binaries (Cargo's `target/<profile>`,
        where `cargo run` finds them; libraries sdl2-sys `bundled` copies,
        Tauri's resources) and the product does not include them, which
        the `stageHelpers.buildScriptFiles` stage does (#23).
        `buildScriptPaths` fails when a build script below the product
        declared a `rerun-if-changed` path that was not in its view.
        `null` removes a check. Checks appear
        in `repo.checks` as `<ws>/<triple>/<pkg>/<name>`.
      '';
    };
    debugInfo = mkOption {
      type = types.nullOr (
        types.enum [
          "split"
          "keep"
          "strip"
        ]
      );
      default = null;
      example = "keep";
      description = ''
        What this target's products do with debug info,
        for every package of the target, because the units are shared:

        - `"split"`: the `splitDebug` stage, first after `linked`, moves
          it to a `debug` output (`$debug/lib/debug/.build-id/…`); the
          target's links get a GNU build ID, and shipped units remap
          source paths only in panic messages, `file!()` and diagnostics,
          so the debug info names the real sources. ELF only.
        - `"keep"`: no stage; every source path is remapped, so the debug
          info stays in the file without naming store paths. msvc's
          `.pdb` is a separate file already and goes to the `debug`
          output.
        - `"strip"`: the `strip` stage (`strip --strip-debug`), first
          after `linked`; every source path is remapped. ELF only.

        `null`: the target's traits' `debugInfo`: `"split"` on Linux
        ELF targets, `"keep"` elsewhere.
      '';
    };
    stagePreset = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wasmWeb";
      description = ''
        Which default stage chain this target's products get
        (`breakbulk.stages.defaultStageNames`: `wasmWeb` bindgen and
        wasmOpt; `wasmComponent` wasmOpt and componentize). Presets set
        it; `null`: none. Debug info is handled by `debugInfo`, not by
        the chain.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.foldl' lib.recursiveUpdate { } (map (p: lib.setAttrByPath p (fromPreset p)) presetFields))
    # Between the preset's defaults and a user's `linker`, which still wins.
    {
      linker = lib.mkIf (config.linkerKind != null && !takesLinkerKind) (
        lib.mkOverride 999 (
          throw "breakbulk: `targets.${name}.linkerKind` needs a `preset` on the target that takes `linkerKind` (every `breakbulk.presets.*` does); a target defined directly from a preset takes it as the preset's argument"
        )
      );
    }
  ];
}
