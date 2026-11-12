# workspaces.<ws>: the Cargo workspaces of the repository.
{
  lib,
  config,
  pkgs,
  root,
  projectBuildTarget,
  ...
}:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  settings = (import ./package-settings.nix { inherit lib; }).settings;
  nativeTriple = (import ../target-traits.nix { inherit lib; }).nativeTriple pkgs;
  util = import ../util.nix { inherit lib; };
  manifest = import ../manifest.nix { inherit lib util; };

  # The exclude form, in each selection option's description.
  excludeFormDoc = ''
    `{ exclude = [ … ]; }`: every member
    ([`members`](#workspacesnamemembers)) but those, as `--workspace
    --exclude <entry>…` selects; each is traced with `-p`. An entry is a
    package name, or a glob pattern as Cargo takes it (`*`, `?`, `[…]`,
    `[!…]`). An entry that matches no member is an error (Cargo only
    warns).
  '';

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
      type = types.nullOr bt.packageList;
      default = null;
      example = lib.literalExpression ''{ exclude = [ "xtask" ]; }'';
      description = ''
        The packages to plan for this target, each traced with `-p`, in
        the build and the test plan. `null` traces `--workspace`.
        ${excludeFormDoc}
      '';
    };
    options.tests = mkOption {
      type = types.oneOf [
        types.bool
        bt.packageList
      ];
      default = true;
      example = lib.literalExpression ''{ exclude = [ "*-bench" ]; }'';
      description = ''
        Test binaries, test runs, test apps and doctests on this target.
        `false`: none (a target that is only built, such as a wasm
        component whose tests run natively); the test plan is then not
        traced, except for a check or clippy variant with `allTargets`. A
        list of packages: the test plan is `cargo test -p <pkg> …`
        for those packages only, and only their tests are run. `true`: the
        variant's or target's package selection.
        ${excludeFormDoc}
      '';
    };
    options.products = mkOption {
      type = types.oneOf [
        types.bool
        bt.packageList
      ];
      default = true;
      example = false;
      description = ''
        Products on this target, the counterpart of `tests`. `false`: none
        (a target that is only tested, such as the native target of
        crates that ship as wasm and run their unit tests natively): the
        build plan is not traced, and the target has no `packages.<pkg>`
        and no product checks; test binaries, test runs, test apps,
        doctests and benches are unchanged. A list of packages: products
        for those packages only. `true`: every package the variant plans.
        ${excludeFormDoc}
      '';
    };
    options.variantDefaults = mkOption {
      type = types.deferredModule;
      default = { };
      example = lib.literalExpression ''
        {
          noDefaultFeatures = true;
          features = [ "web" ];
        }
      '';
      description = ''
        Settings for every variant planned on this target: any option of
        `variants.<v>`, for facts about the target ("msvc needs the
        `windows` feature", "wasm has no default features"). For each
        variant on this target they apply over the variant's own settings,
        and its `variants.<v>.target.<triple>` over them: lists
        concatenate, and a single value set in two of these places takes
        the later one's, without `lib.mkForce`. Priorities still count
        across them: `lib.mkForce` in the variant wins over a plain value
        here, `lib.mkDefault` here loses to a plain value in the variant
        ([layers and priorities](../../how-to/targets.md#layers-and-priorities)).

        Variants made by `breakbulk.variants.packageFeaturePowerset` keep
        their own `features`, `noDefaultFeatures` and `allFeatures` over
        these: Cargo rejects a feature that no selected package has.
      '';
    };
  };

  # `ws`: the workspace's config, for defaults a variant inherits;
  # `wsName`, its name, for messages.
  variant =
    wsName: ws:
    {
      name,
      options,
      config,
      extendModules,
      ...
    }:
    let
      at = "workspaces.${wsName}.variants.${name}";
      checkMode = config.mode == "check" || config.mode == "clippy";
      unknownTargets = lib.filter (t: !(ws.targets ? ${t})) (if config.targets == null then [ ] else config.targets);
      planned = if config.targets == null then lib.attrNames ws.targets else config.targets;
      unplannedLayers = lib.filter (t: !(lib.elem t planned)) (lib.attrNames config.target);
    in
    {
      # Through extendModules, so the variant's own definitions keep their
      # priorities: a value merged first could not be replaced by a plain
      # definition in a later layer.
      config.onTarget =
        defaults: triple:
        let
          layer = rank: bt.layer rank (n: options ? ${n} && bt.singleValued options.${n}.type);
        in
        (extendModules {
          modules = [
            (layer 1 defaults)
          ]
          ++ lib.optional (config.target ? ${triple}) (layer 2 config.target.${triple});
        }).config;

      config.assertions = [
        {
          assertion = !(config.benches && checkMode);
          message = "breakbulk: ${at}${bt.setIn options.benches}: `benches` needs a build variant, not `${config.mode}`";
        }
        {
          assertion = config.allTargets || checkMode;
          message = "breakbulk: ${at}${bt.setIn options.allTargets}: `allTargets = false` needs a check or clippy variant, not `${config.mode}`";
        }
        {
          assertion = unknownTargets == [ ];
          message = "breakbulk: ${at}.targets${bt.setIn options.targets}: ${lib.concatStringsSep ", " unknownTargets} not among the workspace's targets (${lib.concatStringsSep ", " (lib.attrNames ws.targets)})";
        }
        {
          assertion = unplannedLayers == [ ];
          message = "breakbulk: ${at}.target${bt.setIn options.target}: ${lib.concatStringsSep ", " unplannedLayers} not among the targets this variant is planned for (${lib.concatStringsSep ", " planned})";
        }
      ]
      ++ lib.optionals (builtins.isAttrs config.packages) (
        map (m: {
          assertion = false;
          message = "breakbulk: ${at}.packages.exclude${bt.setIn options.packages}: ${m}";
        }) (manifest.excludeMembers (lib.attrNames ws.members) config.packages.exclude).errors
      );

      options = {
        assertions = bt.assertionsOption;
        profile = mkOption {
          type = types.str;
          default = "release";
          description = ''
            The Cargo profile (`--profile`) of the build plan, and of the
            bench plan. A check or clippy variant's test plan uses it too.
            Units are shared between variants whose profiles have the same
            settings, whatever their names.
          '';
        };
        testProfile = mkOption {
          type = types.str;
          default = "test";
          example = "release";
          description = ''
            The Cargo profile of a build or coverage variant's test plan
            (test binaries, test runs, doctests). The default, `test`, is
            what plain `cargo test` uses: Cargo's `test` profile inherits
            `dev` (debug assertions on, no optimization), with the
            project's `[profile.test]` over it. Set it to the variant's
            `profile` (`"release"`) to build tests as the products are
            built: the test plan then shares its dependency units with the
            build plan, while with two profiles of different settings it
            shares none. Check and clippy variants ignore it: they trace
            one Cargo command with `profile`, as `cargo check` and `cargo
            clippy` do.
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
            (`cargo build`, `cargo test`). `check`: `cargo check`
            and `cargo check --all-targets`, metadata only, no products or
            test runs; `target.<triple>.variants.<v>.check` builds every
            unit and is in `repo.checks`. `clippy`: as `check`, with
            clippy-driver as `RUSTC_WORKSPACE_WRAPPER` (workspace members
            only, so dependencies are shared with `check`), and the
            `clippy.toml` files of each member's directory and its parents
            up to the repository root (`CLIPPY_CONF_DIR`). `coverage`:
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
        target = mkOption {
          type = types.attrsOf types.deferredModule;
          default = { };
          example = lib.literalExpression ''
            {
              x86_64-pc-windows-msvc.features = [ "windows" ];
              wasm32-unknown-unknown = {
                noDefaultFeatures = lib.mkForce true;
                allTargets = false;
              };
            }
          '';
          description = ''
            This variant's settings on one of its targets: any option of
            the variant (`features`, `noDefaultFeatures`, `profile`,
            `testProfile`, `allTargets`, `clippyArgs`, `packages`, `benches`, `checks`, …)
            except `targets`. They apply over the variant's own settings
            and the target's `variantDefaults`
            (`workspaces.<ws>.targets.<triple>.variantDefaults`): lists
            concatenate, and a single value set here wins over theirs
            without `lib.mkForce`, unless one of theirs has a higher
            priority (`lib.mkForce`)
            ([layers and priorities](../../how-to/targets.md#layers-and-priorities)).
            Only targets the variant is planned for are allowed.
          '';
        };
        onTarget = mkOption {
          type = types.raw;
          internal = true;
          readOnly = true;
          description = ''
            The variant's settings on one target, as a function of the
            target's `variantDefaults` module and the triple.
          '';
        };
        packages = mkOption {
          type = types.nullOr bt.packageList;
          default = null;
          example = [ "my-lib" ];
          description = ''
            The packages this variant plans, each traced with `-p`, in
            place of the target's `packages` (`workspaces.<ws>.targets.<triple>.packages`).
            `null`: the target's selection. Features then name the
            selected package's own features, as with `cargo build -p
            <pkg> --features <f>`; `breakbulk.variants.packageFeaturePowerset`
            makes such variants.
            ${excludeFormDoc}
          '';
        };
        checks = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Put this build or coverage variant's outputs in `repo.checks`:
            its products (`<pkg>/build`), their checks (`<pkg>/<check>`),
            its enabled test runs (`<pkg>/test-<name>`) and doctests
            (`<pkg>/doctest`). The default variant's are under
            `<ws>/<triple>/`, any other variant's under
            `<ws>/<triple>/variant-<v>/`. A product whose roots Cargo all
            skipped (required features) is left out. Check and clippy
            variants have no products or test runs; their `check` is in
            `repo.checks` regardless.
            Variants made by `breakbulk.variants.featurePowerset` and
            `packageFeaturePowerset` set this to `false` unless their
            arguments set it.
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

        members = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  description = "The package's name.";
                };
                path = mkOption {
                  type = types.str;
                  description = ''
                    The package's directory, relative to the repository
                    root as `workspaces.<ws>.path` is (`.` for the root).
                  '';
                };
              };
            }
          );
          readOnly = true;
          default = manifest.memberPackages {
            inherit root;
            wsDir = util.normalizeRel config.path;
          };
          defaultText = lib.literalMD "the workspace's members, by name";
          example = lib.literalExpression ''
            {
              app = { name = "app"; path = "."; };
              core = { name = "core"; path = "crates/core"; };
            }
          '';
          description = ''
            The workspace's member packages, by name: read it, do not set
            it. They are found as Cargo finds them: the root package, the
            directories `[workspace] members` names (globs included) but
            not those under `[workspace] exclude`, and the path
            dependencies of members inside the workspace directory. It is
            read from the manifests alone, so a module can compute a
            selection from `config.workspaces.<ws>.members`:

            ```nix
            { config, lib, ... }:
            {
              workspaces.default.targets.x86_64-unknown-linux-gnu.tests =
                lib.filter (lib.hasPrefix "core-")
                  (lib.attrNames config.workspaces.default.members);
            }
            ```

            The selection options also take `{ exclude = [ … ]; }`: every
            member but those.
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
              rustfmt = mkOption {
                type = types.package;
                default = if tc.config.rustc == pkgs.rustc then pkgs.rustfmt else tc.config.rustc;
                defaultText = lib.literalExpression "if rustc == pkgs.rustc then pkgs.rustfmt else rustc";
                description = ''
                  rustfmt (with `bin/rustfmt` and `bin/cargo-fmt`), for the
                  `fmt` check. Formatting differs between rustfmt releases,
                  and `rustfmt.toml` options can need a nightly one, so it
                  defaults to the workspace's own toolchain as `clippy` does:
                  nixpkgs' rustfmt with nixpkgs' rustc, and `rustc` itself
                  otherwise (a rustup-style toolchain with the rustfmt
                  component has both programs).
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
                  (`breakbulk.toolchainFacts.of`).
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
          type = types.attrsOf (types.submodule (variant name config));
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

        roots = bt.notImplemented 46 (mkOption {
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
            capability). `null`: breakbulk turns it on
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
            Whether source paths are hidden in what this workspace builds.
            `hide`: as `cargoTrimPaths` says, through
            Cargo's trim-paths or breakbulk's own remaps, and every product
            gets the `noSourceReferences` check. `keep`: breakbulk neither
            turns Cargo's trim-paths on nor adds remaps of its own (Rust or
            C), and products get no default `noSourceReferences` check;
            binaries then reference their sources' store paths. A project
            that sets `trim-paths` itself still gets Cargo's remaps. A
            variant's own setting wins.
          '';
        };

        fmt.enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Add a check, `repo.checks."<ws>/fmt"`, that runs `cargo fmt
            --check` with `toolchain.rustfmt` on every member of the
            workspace (`-p`, so path dependencies outside it are left to
            their own workspace). It reads the workspace directory and any
            `rustfmt.toml` or `.rustfmt.toml` above it up to the repository
            root, and needs no plan.

            A project that formats with treefmt (treefmt-nix) can use its
            check instead. Its rustfmt runs per file with one `--edition`
            (treefmt-nix's default is 2024), while `cargo fmt` takes each
            crate's edition from its `Cargo.toml`, and the edition sets
            rustfmt's style edition; so pin `style_edition` in
            `rustfmt.toml`, or set `programs.rustfmt.edition` to the crates'
            edition. Point `programs.rustfmt.package` at
            `repo.workspaces.<ws>.toolchain.rustfmt` to use the same rustfmt.
          '';
        };

        devShell.setTarget = mkOption {
          type = types.raw;
          visible = false;
          description = "Removed: use `devShell.target`.";
        };

        defaultTarget = mkOption {
          type = types.nullOr types.str;
          default =
            let
              ts = lib.attrNames config.targets;
              # Read only when needed: an import-from-derivation unless the
              # workspace has no Cargo config file.
              buildTarget = projectBuildTarget config.path;
            in
            if lib.elem nativeTriple ts then
              nativeTriple
            else if lib.length ts == 1 then
              lib.head ts
            else if buildTarget != null && lib.length buildTarget == 1 && lib.elem (lib.head buildTarget) ts then
              lib.head buildTarget
            else
              null;
          defaultText = lib.literalMD ''
            the native triple when it is one of `targets`, else the only
            target, else the project's `build.target` when it is one of
            `targets`, else `null`
          '';
          example = "x86_64-unknown-uefi";
          description = ''
            The target whose products and tests the workspace's shortcuts
            are (`packages`, `tests`, `testRuns`, and the flake-parts
            module's `packages`), and the default of `devShell.target`.
            Every target in `targets` is built either way; this only picks
            which one the shortcuts name. `null`: the shortcuts are empty;
            use `target.<triple>.packages`.

            The default's `build.target` is read from the project's own
            `.cargo/config.toml` files (from the workspace directory up to
            the repository root, with Cargo's merging), as the planner reads
            Cargo config: not `$CARGO_HOME`'s, not the environment. Only a
            single triple counts: a list, `host-tuple` or a `.json` path
            gives `null`. Reading it is an import-from-derivation, made only
            when the earlier rules do not decide and the workspace has a
            Cargo config file; setting this option skips it.

            Not Cargo's own `package.default-target` (nightly, per package),
            which breakbulk does not read.
          '';
        };

        devShell.target = mkOption {
          type = types.nullOr types.str;
          default = config.defaultTarget;
          defaultText = lib.literalExpression "defaultTarget";
          example = "x86_64-unknown-uefi";
          description = ''
            The target the dev shell is set up for, one of `targets`. The
            shell exports `CARGO_BUILD_TARGET=<target>`, so local Cargo
            behaves as the planner's (which always passes `--target`):
            rustflags stay off build scripts, and `-C metadata` matches.
            Binaries then go to `target/<triple>/…`. It also gets that
            target's linker and rustflags as the planner passes them, and
            its `env`. `null`: none of these, so the project's own
            `build.target` (or Cargo's host default) applies.

            The shell also merges every package's `env`, `forHost.env` and
            `forTarget.env`, as the default variant's plans on this target
            see them. Set `devShell.env` to change or remove any of these
            variables.
          '';
        };

        devShell.env = mkOption {
          type = types.attrsOf (types.nullOr bt.envValue);
          default = { };
          example = lib.literalExpression ''
            {
              MY_ASSETS_DIR = null;  # unset: build.rs falls back to its dev path
              RUST_LOG = "debug";
            }
          '';
          description = ''
            Variables for the dev shell, applied last, over everything the
            shell sets. The shell sets, in this order:

            1. each package's `env`, `forHost.env` and `forTarget.env`
               (its layers for `devShell.target` and the default
               variant), for every package in `Cargo.lock` order;
            2. the `env` of `devShell.target`;
            3. the Cargo env config for `devShell.target`: its linker,
               its rustflags, and trim-paths when the planner turns it on;
            4. `CARGO_BUILD_TARGET`.

            A value sets or replaces the variable. A variable set here is
            not reported as a conflict between packages. `null` removes
            the variable: the shell does not set it, and does not depend on
            the derivation its value named, so that derivation is not built
            when the shell opens. A variable from your own environment
            stays set.

            Changing or removing a variable from 3 or 4 makes local Cargo
            differ from the plan: it compiles with other flags than Nix
            builds do, and `-C metadata` can differ.
          '';
        };

        memberDefaults = mkOption {
          type = types.submodule settings;
          default = { };
          # The options of `packages.<name>`, documented there.
          visible = "shallow";
          example = lib.literalExpression ''
            {
              test.env.RUST_LOG = "debug";
              test.runner = "nextest";
              extraSources = [ "testdata" ];
            }
          '';
          description = ''
            Settings for every member of this workspace (the path packages
            of its `Cargo.lock`), with the options of
            [`packages.<name>`](packages.md). They are a layer under the
            package's own `packages.<name>` settings: lists concatenate,
            `env` attributes merge, and the package's own value wins for
            single values (`test.runner`) unless this one has a higher
            priority (`lib.mkForce`)
            ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)).
            Dependencies from a registry or git do not get them.
          '';
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

        docs.noDeps = bt.notImplemented 6 (mkOption {
          type = types.bool;
          default = true;
          description = "Document only workspace members (`cargo doc --no-deps`).";
        });

        warnings = bt.warningsOption;
        assertions = bt.assertionsOption;
      };

      config.assertions =
        let
          targets = lib.concatStringsSep ", " (lib.attrNames config.targets);
          # A target option (`defaultTarget`, `devShell.target`): one of
          # the workspace's targets, or null.
          targetOption =
            path:
            let
              t = lib.getAttrFromPath path config;
            in
            {
              assertion = t == null || config.targets ? ${t};
              message = "breakbulk: workspaces.${name}.${lib.concatStringsSep "." path} `${t}`${bt.setIn (lib.getAttrFromPath path options)} is not one of its targets (${targets})";
            };
        in
        [
          # Removed (#32).
          {
            assertion = !options.devShell.setTarget.isDefined;
            message = "breakbulk: workspaces.${name}.devShell.setTarget${bt.setIn options.devShell.setTarget} was removed; use devShell.target: a triple, or null for none";
          }
          {
            assertion = config.variants ? ${config.defaultVariant};
            message = "breakbulk: workspaces.${name}.defaultVariant `${config.defaultVariant}`${bt.setIn options.defaultVariant} is not one of its variants (${
              if config.variants == { } then "it has none" else lib.concatStringsSep ", " (lib.attrNames config.variants)
            })";
          }
          (targetOption [ "defaultTarget" ])
        ]
        # `devShell.target` defaults to `defaultTarget`: one message for an
        # invalid `defaultTarget`, naming it.
        ++ lib.optional (config.devShell.target != config.defaultTarget) (targetOption [
          "devShell"
          "target"
        ])
        ++ lib.concatMap (v: v.assertions) (lib.attrValues config.variants);

      # A definition, not the option's default, so that a user's variants
      # merge with it instead of replacing it.
      config.variants = lib.mkIf (config.defaultVariant == "default") { default = { }; };

      config.warnings =
        bt.unimplementedWarnings "workspaces.${name}" options {
          "46" = [ [ "roots" ] ];
          "6" = [
            [
              "docs"
              "noDeps"
            ]
          ];
        }
        ++ map (
          v:
          "breakbulk: `workspaces.${name}.memberDefaults.variant.${lib.strings.escapeNixIdentifier v}` names no variant of workspaces.${name} (${lib.concatStringsSep ", " (lib.attrNames config.variants)}); it has no effect."
        ) (lib.filter (v: !(config.variants ? ${v})) (lib.attrNames config.memberDefaults.variant));
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
  config.assertions = lib.concatMap (w: w.assertions) (lib.attrValues config.workspaces);
}
