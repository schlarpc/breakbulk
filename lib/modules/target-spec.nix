# The toolchain spec of one target platform, for one workspace (M3;
# decision 70). Repository-wide definitions (`targets.<triple>`) and a
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

  # Decision 105: on a Linux (glibc) build machine the native target gets
  # `presets.linuxGnu` unless another preset is set, so the native linker is
  # nixpkgs' wrapped cc with mold, as on every other target, instead of
  # rustc's bundled rust-lld. A target defined directly from a preset
  # (`targets.<t> = breakbulk.presets.zig { … }`) counts as having one.
  targetTraits = import ../target-traits.nix { inherit lib; };
  nativeTriple = targetTraits.nativeTriple pkgs;
  nativeDefault = pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isGnu;
  bt = import ./types.nix { inherit lib; };
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
  # takes `traits` (every `breakbulk.presets.*` does) gets the target's.
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
        if name == nativeTriple && nativeDefault && !config.presetDirect then
          breakbulkPresets.linuxGnu
        else
          null;
      defaultText = lib.literalMD ''
        `breakbulk.presets.linuxGnu` for the native triple when the build
        machine is Linux with glibc, unless the target is defined directly
        from a preset; `null` otherwise
      '';
      example = lib.literalExpression "breakbulk.presets.linuxMusl";
      description = ''
        A toolchain preset (`breakbulk.presets.*`, or a preset with its
        options bound, such as `breakbulk.presets.msvc { inherit sdk; }`).
        It is called once per workspace that builds this triple, with
        `pkgs`, the triple and the workspace's `toolchain`, whose rustc
        it uses unless it was given `rustc` itself: msvc and wasm presets
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
        (`breakbulk.targetTraits.resolve`, "Target traits" in
        docs/implementation.md). Every platform-dependent decision reads
        the resulting traits: the linker kind, the default stage chain,
        the install layout and file names, debuginfo side files, the
        dynamic-library path of test processes, static linking. Base
        fields (`arch`, `vendor`, `os`, `env`, `abi`, `families`, as
        rustc's `target_*` cfg values) recompute the derived ones
        (`isLinux`, `objectFormat`, `exeSuffix`, `dylibPathVar`, …);
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
      description = "The linker for this target's units (`target.<triple>.linker` in Cargo config). A store path.";
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
        unit environment contract), never through Cargo's `[env]`, so
        build scripts and proc macros (host units) do not see it.
        List-like variables (`PATH`, `NIX_CFLAGS_COMPILE`, …) are
        appended to the env capture's value.
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
        description = "Environment added to host units of this target's plans only.";
      };
    };
    stages = mkOption {
      type = bt.stages;
      default = { };
      example = lib.literalExpression ''
        {
          strip = { after = "splitDebug"; run = breakbulk.stageHelpers.strip; };
          splitDebug = lib.mkForce null;   # remove a default stage
        }
      '';
      description = ''
        Post-link stages for this target's products, merged over the
        stage preset's defaults (`stagePreset`). A stage is
        `{ after ? null; before ? null; run = { input, product, target,
        pkgs }: <derivation>; }`; `null` removes one. Package settings
        (`packages.<name>.stages`) merge over these.
      '';
    };
    checks = mkOption {
      type = bt.stages;
      default = { };
      description = ''
        Checks on this target's products: `{ on ? <the product>; run =
        { input, product, pkgs }: <derivation>; }`, where `on` names a
        stage (`linked` for the raw link output). Every product also
        gets `noSourceReferences`; `null` removes a check. Checks appear
        in `repo.checks` as `<ws>/<triple>/<pkg>/<name>`.
      '';
    };
    stagePreset = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wasmBrowser";
      description = ''
        Which default stage chain this target's products get
        (`breakbulk.stages.defaultStageNames`: `linuxGnu`,
        `linuxMusl`, `staticGlibc` split debug info; `msvc` none;
        `wasmBrowser` bindgen and wasmOpt; `wasmComponent` wasmOpt and
        componentize). Presets set it; `null` picks by triple: Linux
        targets split debug info, others get none. Whether the chain
        contains `splitDebug` also decides how source paths are
        remapped (debug info keeps real paths only when it is split
        off).
      '';
    };
  };

  config = lib.foldl' lib.recursiveUpdate { } (
    map (p: lib.setAttrByPath p (fromPreset p)) presetFields
  );
}
