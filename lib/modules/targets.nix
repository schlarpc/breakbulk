# targets.<triple>: the toolchain spec of one target platform (M3).
#
# A spec is data: the linker, C toolchain, rustflags, env and runner for a
# target's units, plus the host spec (`host.*`) for the host units (build
# scripts, proc macros and their dependencies) of plans for this target.
# Presets (lib/presets) fill it in; any field can be overridden.
#
# How the fields reach units (lib/repository.nix, breakbulk-plan's spec.rs):
#  - `rustflags`, `linker`, `host.linker` go to Cargo with `--config`
#    (rustflags under the key the project uses; decision 33). On a
#    same-triple target the planner rewrites host units' linker to
#    `host.linker`.
#  - `cc`, `cxx`, `ar`, `cflags`, `bindgen.extraClangArgs` become
#    `CC_<triple>`, `CXX_<triple>`, `AR_<triple>`, `CFLAGS_<triple>` and
#    `CXXFLAGS_<triple>`, `BINDGEN_EXTRA_CLANG_ARGS_<triple>` in `env`.
#  - `env` is added to target units only; `host.env` to host units only.
#    Neither goes through Cargo's `[env]`.
#  - `packageSet` gives the target's env capture and the package set that
#    `packages.<name>.inputs` functions are called with.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) types mkOption;
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

  target =
    {
      name,
      options,
      config,
      ...
    }:
    let
      applied =
        if config.preset == null then
          { }
        else
          config.preset {
            inherit pkgs;
            triple = name;
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
          type = types.nullOr (types.functionTo types.raw);
          default = null;
          example = lib.literalExpression "breakbulk.presets.linuxMusl";
          description = ''
            A toolchain preset (`breakbulk.presets.*`, or a preset with its
            options bound, such as `breakbulk.presets.msvc { inherit sdk; }`).
            It is called with this target's `pkgs` and triple, and sets the
            fields below at default priority, so fields set here override
            the preset's (lists concatenate; use `lib.mkForce` to replace
            one). Equivalent to defining the target as
            `breakbulk.presets.<name> { inherit pkgs; triple = …; }`.
          '';
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
        host = {
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

        warnings = bt.warningsOption;
      };

      config =
        lib.foldl' lib.recursiveUpdate { } (map (p: lib.setAttrByPath p (fromPreset p)) presetFields)
        // {
          warnings = [ ];
        };
    };
in
{
  options.targets = mkOption {
    type = types.attrsOf (types.submodule target);
    default = { };
    description = ''
      Toolchain specs per target triple. A workspace builds for the triples
      in `workspaces.<ws>.targets`; their specs come from here. A triple
      with no entry uses an empty spec (the native toolchain as Cargo
      finds it).
    '';
  };

  config.warnings = lib.concatMap (t: t.warnings) (lib.attrValues config.targets);
}
