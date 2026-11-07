# targets.<triple>: the toolchain spec of one target platform.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  M3 = bt.notImplemented "M3";
  tool = types.nullOr (
    types.oneOf [
      types.str
      types.path
      types.package
    ]
  );

  target =
    { name, options, ... }:
    {
      options = {
        preset = M3 (mkOption {
          type = types.nullOr types.raw;
          default = null;
          example = lib.literalExpression "breakbulk.presets.linuxGnu";
          description = ''
            The toolchain preset for this target: a module that sets the
            fields below for the target and the host spec from
            `pkgs.buildPackages`. Fields set here override the preset's.
          '';
        });
        linker = M3 (mkOption {
          type = tool;
          default = null;
          description = "The linker for this target's units (`target.<triple>.linker` in Cargo config). A store path.";
        });
        cc = M3 (mkOption {
          type = tool;
          default = null;
          description = "The C compiler build scripts use for this target (`CC_<triple>`).";
        });
        cxx = M3 (mkOption {
          type = tool;
          default = null;
          description = "The C++ compiler build scripts use for this target (`CXX_<triple>`).";
        });
        ar = M3 (mkOption {
          type = tool;
          default = null;
          description = "The archiver build scripts use for this target (`AR_<triple>`).";
        });
        cflags = M3 (mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "C flags for this target's C code (`CFLAGS_<triple>`).";
        });
        bindgen.extraClangArgs = M3 (mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra libclang arguments for bindgen (`BINDGEN_EXTRA_CLANG_ARGS_<triple>`).";
        });
        rustflags = M3 (mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Extra rustflags for this target's units, passed to Cargo with
            `--config` under the key the project itself uses
            (`build.rustflags` or `target.<triple>.rustflags`), so both sets
            arrive.
          '';
        });
        env = mkOption {
          type = bt.envAttrs;
          default = { };
          description = ''
            Environment added to this target's units only (layer 4 of the
            unit environment contract), never through Cargo's `[env]`, so
            build scripts and proc macros (host units) do not see it.
          '';
        };
        runner = M3 (mkOption {
          type = tool;
          default = null;
          description = "The program that runs this target's test binaries (wine, wasmtime, qemu-user, …).";
        });
        testSystem = M3 (mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "aarch64-linux";
          description = "The Nix system that runs this target's test runs, so Nix sends them to native builders.";
        });
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
            componentize). `null` picks by triple: Linux targets split debug
            info, msvc and others get none. Toolchain presets set it.
            Whether the chain contains `splitDebug` also decides how source
            paths are remapped (debug info keeps real paths only when it is
            split off).
          '';
        };

        warnings = bt.warningsOption;
      };

      config.warnings = bt.unimplementedWarnings "targets.${name}" options {
        M3 = [
          [ "preset" ]
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
          [ "runner" ]
          [ "testSystem" ]
        ];
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
