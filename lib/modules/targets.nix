# targets.<triple>: the toolchain spec of one target platform.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  M3 = bt.notImplemented "M3";
  M4 = bt.notImplemented "M4";
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
        stages = M4 (mkOption {
          type = bt.stages;
          default = { };
          description = "Default post-link stages for this target's products.";
        });

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
        M4 = [ [ "stages" ] ];
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
