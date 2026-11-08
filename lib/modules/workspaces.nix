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

  # The workspace-only option of `workspaces.<ws>.targets.<triple>`; the
  # rest is ./target-spec.nix, merged with `targets.<triple>` per workspace
  # by lib/repository.nix. Keyed, so the module system imports it once.
  workspaceTarget = {
    key = "breakbulk/modules/workspaces.nix#workspaceTarget";
    _file = ./workspaces.nix;
    options.packages = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        The packages to plan for this target, each traced with
        `-p`. `null` traces `--workspace`.
      '';
    };
  };

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
            What the variant compiles. `build`: products and test binaries
            (`cargo build`, `cargo test --no-run`). `check`: `cargo check`
            and `cargo check --all-targets`, metadata only, no products or
            test runs; `target.<triple>.variants.<v>.check` builds every
            unit and is in `repo.checks`. `clippy`: as `check`, with
            clippy-driver as `RUSTC_WORKSPACE_WRAPPER` (workspace members
            only, so dependencies are shared with `check`). `coverage`:
            `build` with `-C instrument-coverage` on target units.
            Use the same profile as the build variant to share host units;
            Cargo's own `clippy` uses the dev profile.
          '';
        };
        allTargets = mkOption {
          type = types.bool;
          default = true;
          description = ''
            For `check` and `clippy` variants: also check every target,
            as `cargo check --all-targets` does (tests, examples, benches
            in test mode, through the test plan). `false`: plain `cargo
            check` (libraries and bins, the build plan only), for gates
            that do not check test code. Only check and clippy variants
            take `false`.
          '';
        };
        clippyArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "-D"
            "warnings"
          ];
          description = ''
            Clippy's own arguments, as in `cargo clippy -- ARGS`
            (`CLIPPY_ARGS`), for a `clippy` variant. They reach only the
            units clippy-driver compiles (workspace members).
          '';
        };
        benches = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Also trace `cargo bench --no-run` with this variant's settings
            (use `profile = "bench"`): bench binaries, and lib and bin
            harnesses in bench mode, at
            `target.<triple>.variants.<v>.benches.<pkg>.<bench>`.
            `target.<triple>.benches` is the default variant's when it has
            benches, else the one variant with `benches = true`. The test
            plan builds no benches (`cargo test --no-run` does not).
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
              clippy = mkOption {
                type = types.package;
                default = pkgs.clippy;
                defaultText = lib.literalExpression "pkgs.clippy";
                description = ''
                  clippy (with `bin/clippy-driver`), for `clippy` variants.
                  It must be built for the same rustc.
                '';
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
          type = types.attrsOf (types.deferredModuleWith { staticModules = [ workspaceTarget ]; });
          default = {
            ${nativeTriple} = { };
          };
          defaultText = lib.literalExpression "{ \${pkgs.stdenv.hostPlatform.rust.rustcTarget} = { }; }";
          example = lib.literalExpression ''
            {
              wasm32-unknown-unknown = {
                packages = [ "ui" ];
                # Any `targets.<triple>` option, for this workspace only.
                rustflags = [ "--cfg" "getrandom_backend=\"wasm_js\"" ];
              };
            }
          '';
          description = ''
            The triples this workspace is built for. Each is planned on its
            own (`--target <triple>`). Besides `packages`, an entry takes
            every option of `targets.<triple>`: they are merged with the
            repository-wide `targets.<triple>` for this workspace only, as
            two definitions of the same options merge (lists concatenate,
            attribute sets merge, and a single value such as `preset` or
            `linker` set in both places needs `lib.mkForce` on the one that
            should win). The spec is evaluated with this workspace's
            toolchain, so presets pick tools for its rustc. The default is
            the native triple only.
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

        test = {
          runner = mkOption {
            type = types.nullOr (
              types.enum [
                "libtest"
                "nextest"
              ]
            );
            default = null;
            example = "nextest";
            description = ''
              The default `packages.<name>.test.runner` for this
              workspace's packages: `libtest` or `nextest`. A package's own
              setting wins. `null` means `libtest`.
            '';
          };
          nextest = {
            profile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "ci";
              description = "The default nextest profile for this workspace's test runs; a package's `test.nextest.profile` wins (`null`: `default`).";
            };
            configFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = ''
                The default nextest configuration file for this workspace's
                test runs; a package's `test.nextest.configFile` wins.
                `null`: the workspace's `.config/nextest.toml` when it
                exists.
              '';
            };
            package = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = "The default cargo-nextest for this workspace's test runs; a package's `test.nextest.package` wins.";
            };
          };
        };

        benchSmoke = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Run each bench binary of `target.<triple>.benches` once in test
            mode (`--test`) as a check (`<ws>/<triple>/<pkg>/bench-<name>`
            in `repo.checks`). Timed runs never happen inside Nix.
          '';
        };

        docs.noDeps = bt.notImplemented "M6" (mkOption {
          type = types.bool;
          default = true;
          description = "Document only workspace members (`cargo doc --no-deps`).";
        });

        warnings = bt.warningsOption;
      };

      config.warnings = bt.unimplementedWarnings "workspaces.${name}" options {
        "M2, later" = [ [ "roots" ] ];
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
