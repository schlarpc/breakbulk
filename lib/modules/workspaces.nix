# workspaces.<ws>: the Cargo workspaces of the repository.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  nativeTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  variant =
    { name, ... }:
    {
      options = {
        profile = mkOption {
          type = types.str;
          default = "release";
          description = ''
            The Cargo profile (`--profile`). Units are shared between
            variants whose profiles have the same settings, whatever their
            names.
          '';
        };
        features = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Features to enable (`--features`), as Cargo spells them (`pkg/feat` is allowed).";
        };
        noDefaultFeatures = mkOption {
          type = types.bool;
          default = false;
          description = "Pass `--no-default-features`.";
        };
        allFeatures = mkOption {
          type = types.bool;
          default = false;
          description = "Pass `--all-features`.";
        };
        mode = mkOption {
          type = types.enum [
            "build"
            "check"
            "clippy"
            "coverage"
          ];
          default = "build";
          description = ''
            What the variant compiles. Only `build` is implemented; `check`,
            `clippy` and `coverage` come with M4, and using such a variant's
            outputs is an error until then.
          '';
        };
      };
    };

  workspace =
    { name, options, ... }:
    {
      options = {
        path = mkOption {
          type = types.str;
          default = ".";
          description = ''
            The workspace root, relative to the repository root. Its
            `Cargo.lock` is used.
          '';
        };

        toolchain = mkOption {
          type = types.submodule {
            options = {
              rustc = mkOption {
                type = types.package;
                default = pkgs.rustc;
                defaultText = lib.literalExpression "pkgs.rustc";
                description = "rustc (with `bin/rustc` and `bin/rustdoc`).";
              };
              cargo = mkOption {
                type = types.package;
                default = pkgs.cargo;
                defaultText = lib.literalExpression "pkgs.cargo";
                description = "cargo (with `bin/cargo`).";
              };
            };
          };
          default = { };
          example = lib.literalExpression ''
            let tc = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
            in { rustc = tc; cargo = tc; }
          '';
          description = ''
            The toolchain this workspace is planned and built with. Any
            rustc/cargo pair works: nixpkgs, rust-overlay, fenix. A single
            package that provides both may be given for both.
          '';
        };

        targets = mkOption {
          type = types.attrsOf (
            types.submodule {
              options.packages = mkOption {
                type = types.nullOr (types.listOf types.str);
                default = null;
                description = ''
                  The packages to plan for this target, each traced with
                  `-p`. `null` traces `--workspace`.
                '';
              };
            }
          );
          default = {
            ${nativeTriple} = { };
          };
          defaultText = lib.literalExpression "{ \${pkgs.stdenv.hostPlatform.rust.rustcTarget} = { }; }";
          description = ''
            The triples this workspace is built for. Each is planned on its
            own (`--target <triple>`), with its spec from
            `targets.<triple>`. The default is the native triple only.
          '';
        };

        variants = mkOption {
          type = types.attrsOf (types.submodule variant);
          default = {
            default = { };
          };
          description = ''
            Plan parameters. Each variant is a separate pair of plans (build
            and test) per target; units that come out identical are shared.
          '';
        };

        defaultVariant = mkOption {
          type = types.str;
          default = "default";
          description = ''
            The variant whose products are `packages.<pkg>` and
            `target.<triple>.packages.<pkg>`. Every variant's products are
            also under `target.<triple>.variants.<variant>`.
          '';
        };

        roots = bt.notImplemented "M2, later" (mkOption {
          type = types.nullOr types.raw;
          default = null;
          description = ''
            Replace the predicted root names. The escape hatch for a bug in
            breakbulk's target auto-discovery.
          '';
        });

        devShell.setTarget = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Export `CARGO_BUILD_TARGET=<native triple>` in the dev shell, so
            local Cargo behaves as the planner's (which always passes
            `--target`): rustflags stay off build scripts, and `-C metadata`
            matches. Binaries then go to `target/<triple>/…`.
          '';
        };

        benchSmoke = bt.notImplemented "M4" (mkOption {
          type = types.bool;
          default = false;
          description = "Run each bench binary once in test mode (`--test`), as a check.";
        });

        docs.noDeps = bt.notImplemented "M6" (mkOption {
          type = types.bool;
          default = true;
          description = "Document only workspace members (`cargo doc --no-deps`).";
        });

        warnings = bt.warningsOption;
      };

      config.warnings = bt.unimplementedWarnings "workspaces.${name}" options {
        "M2, later" = [ [ "roots" ] ];
        M4 = [ [ "benchSmoke" ] ];
        M6 = [
          [
            "docs"
            "noDeps"
          ]
        ];
      };
    };
in
{
  options.workspaces = mkOption {
    type = types.attrsOf (types.submodule workspace);
    default = { };
    description = "The Cargo workspaces of the repository, by a name of your choice.";
  };

  config.warnings = lib.concatMap (w: w.warnings) (lib.attrValues config.workspaces);
}
