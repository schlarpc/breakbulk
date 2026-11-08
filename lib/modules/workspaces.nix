# workspaces.<ws>: the Cargo workspaces of the repository.
{
  lib,
  config,
  pkgs,
  root,
  ...
}:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  nativeTriple = (import ../target-traits.nix { inherit lib; }).nativeTriple pkgs;

  # `workspaces.<ws>.toolchain.capabilities.<name>` (lib/toolchain-facts.nix).
  capabilityDocs = {
    remapPathScope = ''
      rustc takes `--remap-path-scope` (default: rustc 1.95 or later).
      Without it, every unit remaps every path scope, so debug info names
      no real source paths even where it is split off.
    '';
    trimPaths = ''
      Cargo has the `trim-paths` profile setting (default: Cargo 1.101 or
      later, nightly 1.101 included). The planner then turns it on when the
      project has not.
    '';
    nightly = ''
      Cargo allows unstable features (default: a `-nightly` or `-dev`
      Cargo release).
    '';
  };

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
        The packages to plan for this target, each traced with `-p`, in
        the build and the test plan. `null` traces `--workspace`.
      '';
    };
    options.tests = mkOption {
      type = types.either types.bool (types.listOf types.str);
      default = true;
      example = [ "my-lib" ];
      description = ''
        Test binaries, test runs, test apps and doctests on this target.
        `false`: none (a target that is only built, such as a wasm
        component whose tests run natively); the test plan is then not
        traced, except for a check or clippy variant with `allTargets`. A
        list of packages: the test plan is `cargo test --no-run -p <pkg> …`
        for those packages only, and only their tests are run. `true`: the
        variant's or target's package selection.
      '';
    };
  };

  # `ws`: the workspace's config, for defaults a variant inherits.
  variant =
    ws:
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
        targets = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = [ "x86_64-unknown-linux-gnu" ];
          description = ''
            The workspace's targets (`workspaces.<ws>.targets`) this
            variant is planned for. `null`: every target. A target left
            out has no `target.<triple>.variants.<v>`, and nothing of the
            variant in `repo.checks`; when the default variant is left
            out, the target's `packages`, `tests` and test runs are empty.
            Use it for gates that apply to one target only (clippy
            natively, a `cargo check` gate for wasm).
          '';
        };
        packages = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = [ "my-lib" ];
          description = ''
            The packages this variant plans, each traced with `-p`, in
            place of the target's `packages` (`workspaces.<ws>.targets.<triple>.packages`).
            `null`: the target's selection. Features then name the
            selected package's own features, as with `cargo build -p
            <pkg> --features <f>`; `breakbulk.variants.packageFeaturePowerset`
            makes such variants.
          '';
        };
        checks = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Put this variant's enabled test runs and doctests in
            `repo.checks`: the default variant's as
            `<ws>/<triple>/<pkg>/test-<name>` and `…/<pkg>/doctest`, any
            other build or coverage variant's as
            `<ws>/<triple>/variant-<v>/<pkg>/test-<name>` and
            `…/variant-<v>/<pkg>/doctest`. Check and clippy variants have
            no test runs; their `check` is in `repo.checks` regardless.
            Variants made by `breakbulk.variants.featurePowerset` and
            `packageFeaturePowerset` set this to `false` unless their
            arguments set it (decision 133).
          '';
        };
        cargoTrimPaths = mkOption {
          type = types.nullOr types.bool;
          default = ws.cargoTrimPaths;
          defaultText = lib.literalExpression "workspaces.<ws>.cargoTrimPaths";
          description = "This variant's `workspaces.<ws>.cargoTrimPaths`.";
        };
        sourcePaths = mkOption {
          type = types.enum [
            "hide"
            "keep"
          ];
          default = ws.sourcePaths;
          defaultText = lib.literalExpression "workspaces.<ws>.sourcePaths";
          description = "This variant's `workspaces.<ws>.sourcePaths`.";
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
    {
      name,
      options,
      config,
      ...
    }:
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
          type = types.submodule (tc: {
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
                # Derivations compare by output path. A toolchain other
                # than nixpkgs' (rust-overlay, fenix's combined ones)
                # carries its own clippy-driver; nixpkgs' clippy is built
                # for nixpkgs' rustc only.
                default = if tc.config.rustc == pkgs.rustc then pkgs.clippy else tc.config.rustc;
                defaultText = lib.literalExpression "if rustc == pkgs.rustc then pkgs.clippy else rustc";
                description = ''
                  clippy (with `bin/clippy-driver`), for `clippy` variants.
                  It must be built for the same rustc: planning compares
                  `clippy-driver --rustc --print sysroot` with rustc's and
                  fails naming this option when they differ. The default is
                  nixpkgs' clippy with nixpkgs' rustc, and `rustc` itself
                  otherwise, as a rustup-style toolchain with the clippy
                  component (rust-overlay's default profile, fenix's
                  `toolchain`) has `bin/clippy-driver`.
                '';
              };
              capabilities = mkOption {
                type = types.submodule {
                  options =
                    lib.genAttrs
                      [
                        "remapPathScope"
                        "trimPaths"
                        "nightly"
                      ]
                      (
                        n:
                        mkOption {
                          type = types.nullOr types.bool;
                          default = null;
                          description = capabilityDocs.${n};
                        }
                      );
                };
                default = { };
                example = lib.literalExpression "{ remapPathScope = false; }";
                description = ''
                  What this toolchain can do, where breakbulk would otherwise
                  decide it from the rustc and cargo versions (or, for a
                  toolchain whose `version` attribute is missing or not a
                  Rust release, such as fenix's, by asking them
                  through import-from-derivation). Set one only for a
                  forked or patched toolchain whose version says otherwise;
                  `null` keeps breakbulk's own answer. The planner and the
                  instantiator read nothing else
                  (`breakbulk.toolchainFacts.of`, "Toolchain capabilities"
                  in docs/implementation.md).
                '';
              };
            };
          });
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
          type = types.attrsOf (types.submodule (variant config));
          defaultText = lib.literalExpression "{ default = { }; }";
          description = ''
            Plan parameters. Each variant is a separate pair of plans (build
            and test) per target; units that come out identical are shared.
            While `defaultVariant` is `"default"`, a `default` variant
            (`{ }`) is always defined, merged with yours: adding
            `variants.clippy` keeps it, and `variants.default.profile`
            changes it.
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

        cargoTrimPaths = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Who hides source paths in Rust code when Cargo has
            `trim-paths` (1.101 and later: the toolchain's `trimPaths`
            capability; decision 121). `null`: breakbulk turns it on
            (`--config profile.<p>.trim-paths="all"`) unless the project
            declares `trim-paths` in any profile of the workspace root's
            `Cargo.toml` or of its `.cargo/config.toml` files (any profile,
            package override or value counts; the files are read, not
            merged as Cargo would), and leaves it to the project then.
            `true`: always on, replacing the project's own setting (an
            error without the capability). `false`: never turned on by
            breakbulk, which then hides paths with its own remaps; a
            project that sets it itself still gets Cargo's. Under Cargo's
            trim-paths, breakbulk's own C prefix maps use Cargo's names, as
            cc-rs does. A variant's own setting wins.
          '';
        };

        sourcePaths = mkOption {
          type = types.enum [
            "hide"
            "keep"
          ];
          default = "hide";
          description = ''
            Whether source paths are hidden in what this workspace builds
            (decision 121). `hide`: as `cargoTrimPaths` says, through
            Cargo's trim-paths or breakbulk's own remaps, and every product
            gets the `noSourceReferences` check. `keep`: breakbulk neither
            turns Cargo's trim-paths on nor adds remaps of its own (Rust or
            C), and products get no default `noSourceReferences` check;
            binaries then reference their sources' store paths. A project
            that sets `trim-paths` itself still gets Cargo's remaps. A
            variant's own setting wins.
          '';
        };

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
          stripForRun = mkOption {
            type = types.bool;
            default = false;
            description = ''
              The default `packages.<name>.test.stripForRun` for this
              workspace's packages: test runs consume a debug-stripped copy
              of each test binary. A package's own setting wins.
            '';
          };
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

      # A definition, not the option's default, so that a user's variants
      # merge with it instead of replacing it.
      config.variants = lib.mkIf (config.defaultVariant == "default") { default = { }; };

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
    # Zero configuration: a repository whose root is a Cargo workspace (or
    # package) is one workspace, `default`. Any definition replaces the
    # whole default, as for every option default.
    default = lib.optionalAttrs (builtins.pathExists (root + "/Cargo.toml")) {
      default.path = ".";
    };
    defaultText = lib.literalMD ''
      `{ default.path = "."; }` when the repository root has a `Cargo.toml`,
      else `{ }`
    '';
    description = ''
      The Cargo workspaces of the repository, by a name of your choice.
      Without any definition, a repository whose root has a `Cargo.toml`
      gets one workspace, `default`, at the root, so `mkRepository` needs
      no modules; declaring any workspace turns that default off.
    '';
  };

  config.warnings = lib.concatMap (w: w.warnings) (lib.attrValues config.workspaces);
}
