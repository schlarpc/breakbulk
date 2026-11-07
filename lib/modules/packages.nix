# packages.<name>: per-package overrides. They reach only that package's
# units, so a build stamp or a large SDK never changes another unit.
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };

  targetOverride =
    { ... }:
    {
      options = {
        env = bt.mkEnv "Environment for this package's units on this target (target units only).";
        nativeInputs = bt.mkInputs "Build-machine tools for this package's units on this target (target units only).";
        inputs = bt.mkInputs "Libraries for this package's units on this target (target units only).";
        stages = mkOption {
          type = bt.stages;
          default = { };
          description = "Post-link stages for this package's products on this target.";
        };
        checks = mkOption {
          type = bt.stages;
          default = { };
          description = "Checks on this package's products on this target.";
        };
      };
    };

  testBinary = {
    options = {
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "libtest arguments for this test binary.";
      };
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this binary's test run is part of `repo.checks` (it is built either way).";
      };
    };
  };

  package =
    {
      name,
      options,
      config,
      ...
    }:
    {
      options = {
        version = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = ">=0.42, <0.50";
          description = ''
            A version requirement in Cargo's syntax (`1.2`, `^1.2`, `~1.2`,
            `=1.2.3`, `>=1, <2`, `*`). The override applies to the
            package's locked versions that match. `null` matches every
            version. The attribute name may also carry the requirement:
            `packages."aws-lc-sys@>=0.42"`.
          '';
        };

        env = bt.mkEnv ''
          Environment for every unit of this package (compiles and build
          script runs, host and target). Values may be derivations,
          including another workspace's products; they are passed by
          reference.
        '';
        nativeInputs = bt.mkInputs ''
          Tools that run on the build machine (`pkg-config`, `cmake`,
          `protoc`). A function of the build platform's package set, or a
          list.
        '';
        inputs = bt.mkInputs ''
          Libraries for the platform being built (`openssl`). A function of
          a package set (`p: [ p.openssl ]`), called with the build
          machine's set for host units and with the target's set for
          target units; or a list used as given.
        '';
        extraSources = mkOption {
          type = types.listOf (types.either types.path types.str);
          default = [ ];
          example = [
            "wit"
            "../shared/assets"
          ];
          description = ''
            Files and directories outside the package directory that its
            units read (`include_str!("../../wit/x.wit")`, a sibling assets
            directory, patches), at their original relative paths. Strings
            are relative to the repository root.
          '';
        };

        host = {
          env = bt.mkEnv "Environment for this package's host units only (build scripts, proc macros, build dependencies).";
          nativeInputs = bt.mkInputs "Tools for this package's host units only.";
          inputs = bt.mkInputs "Libraries for this package's host units only.";
        };

        target = mkOption {
          type = types.attrsOf (types.submodule targetOverride);
          default = { };
          description = "Settings for this package's target units on one target triple.";
        };

        stages = mkOption {
          type = bt.stages;
          default = { };
          description = "Post-link stages for this package's products, on every target.";
        };
        checks = mkOption {
          type = bt.stages;
          default = { };
          description = "Checks on this package's products, on every target.";
        };

        test = {
          env = bt.mkEnv "Environment for this package's test runs.";
          path = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "Packages added to `PATH` in this package's test runs.";
          };
          sourceScope = mkOption {
            type = types.listOf (types.either types.path types.str);
            default = [ ];
            example = [ "testdata" ];
            description = ''
              Extra repository paths (paths, or strings relative to the
              repository root) in the source view of this package's test
              units: its test harnesses (`--test` compiles), doctests and
              test runs, whose working directory is the package directory
              of that view. Other units keep the package's normal view, so
              editing these paths re-runs only this package's tests.
            '';
          };
          args = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [
              "--skip"
              "net::"
            ];
            description = "libtest arguments for every test binary of this package.";
          };
          includeIgnored = mkOption {
            type = types.bool;
            default = false;
            description = "Also run `#[ignore]` tests.";
          };
          binaries = mkOption {
            type = types.attrsOf (types.submodule testBinary);
            default = { };
            description = "Per test binary settings.";
          };
        };

        strictSources = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Override the repository's `strictSources` for this package's build scripts.";
        };

        pipelining = bt.notImplemented "M6" (mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Opt this package in or out of the pipelined split.";
        });

        warnings = bt.warningsOption;
      };

      config.warnings =
        bt.unimplementedWarnings "packages.${lib.strings.escapeNixIdentifier name}" options {
          M6 = [ [ "pipelining" ] ];
        };
    };
in
{
  options.packages = mkOption {
    type = types.attrsOf (types.submodule package);
    default = { };
    example = lib.literalExpression ''
      {
        openssl-sys = { nativeInputs = p: [ p.pkg-config ]; inputs = p: [ p.openssl ]; };
        app.env.GIT_REV = self.rev or "dirty";
        "aws-lc-sys@>=0.42".env.AWS_LC_SYS_USE_SYSTEM = "1";
      }
    '';
    description = ''
      Per-package overrides, by package name (or `name@<version
      requirement>`). They apply in every workspace whose lockfile has a
      matching package, and only to that package's units. An override that
      matches nothing in any lockfile is an evaluation warning.
    '';
  };

  config.warnings = lib.concatMap (p: p.warnings) (lib.attrValues config.packages);
}
