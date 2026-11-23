# workspaces.<ws>: the Cargo workspaces of the repository.
{
  lib,
  config,
  pkgs,
  root,
  projectBuildTarget,
  targetsDefaultTarget,
  ...
}:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  inherit (import ./package-settings.nix { inherit lib; }) settingsModule;
  nativeTriple = (import ../target-traits.nix { inherit lib; }).nativeTriple pkgs;
  util = import ../util.nix { inherit lib; };
  manifest = import ../manifest.nix { inherit lib util; };
  inherit
    (import ../instantiate.nix {
      inherit lib util;
      featureGates = import ../nix-features.nix { inherit lib; };
    })
    rootNameRegex
    ;

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
  };

  # The workspace-only option of `workspaces.<ws>.targets.<triple>`; the
  # rest is ./target-spec.nix, merged with `targets.<triple>` per workspace
  # by lib/repository.nix. Keyed, so the module system imports it once.
  workspaceTarget = {
    key = "breakbulk/modules/workspaces.nix#workspaceTarget";
    _file = ./workspaces.nix;
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
        `windows` feature", "wasm has no default features"). They are a
        layer under each variant's own settings, and its
        `variants.<v>.target.<triple>` is over both: lists concatenate,
        and a single value set in two of these places takes the higher
        one's, without `lib.mkForce`, so the variant's own value wins over
        this one. Priorities still count across them: `lib.mkForce` here
        wins over a plain value in the variant, for a fact the variants
        must not change
        ([layers and priorities](../../how-to/targets.md#layers-and-priorities)).

        Its `features` reach every variant as written. A variant that
        selects packages (`variants.<v>.packages`, such as the
        package-scope runs of `breakbulk.variants.featurePowerset`) is
        planned with `-p <pkg> --features …`, which Cargo rejects when no
        selected package accepts a feature. A function module that reads
        the variant's `config.packages` can give such variants only what
        they accept, with `breakbulk.lib.acceptsFeature`
        ([features and package selections](../../how-to/targets.md#features-and-package-selections)).
      '';
    };
  };

  # The keys of a variant's `cargoConfig` that breakbulk sets itself, with
  # what to use instead. The planner's own `--config` file comes before
  # the variant's (crates/breakbulk-plan/src/trace.rs, `run`), so one of
  # its keys there would win and break planning (rustc, the wrapper, the
  # target directory, the test runner); the toolchain spec's comes after
  # (spec.rs, `config_text`), and would replace a linker silently; the
  # planner passes `--target` and `--profile`; vendoring replaces every
  # source.
  ownedCargoConfigKeys =
    cfg:
    let
      fixed = [
        {
          path = [
            "build"
            "rustc"
          ];
          use = "set `workspaces.<ws>.toolchain.rustc`";
        }
        {
          path = [
            "build"
            "rustdoc"
          ];
          use = "set `workspaces.<ws>.toolchain.rustc`";
        }
        {
          path = [
            "build"
            "rustc-wrapper"
          ];
          use = "set the variant's `rustcWrapper`";
        }
        {
          path = [
            "build"
            "rustc-workspace-wrapper"
          ];
          use = "set the variant's `rustcWorkspaceWrapper`, or use a clippy variant (`mode = \"clippy\"`)";
        }
        {
          path = [
            "build"
            "target-dir"
          ];
          use = "every unit has its own output";
        }
        {
          path = [
            "build"
            "build-dir"
          ];
          use = "every unit has its own output";
        }
        {
          path = [
            "build"
            "target"
          ];
          use = "set `workspaces.<ws>.targets`";
        }
        {
          path = [
            "build"
            "profile"
          ];
          use = "set the variant's `profile` and `testProfile`";
        }
        {
          path = [ "source" ];
          use = "crates come from Cargo.lock, vendored";
        }
        {
          path = [
            "host"
            "linker"
          ];
          use = "set `targets.<triple>.host.linker`";
        }
        {
          path = [
            "host"
            "runner"
          ];
          use = "set `targets.<triple>.runner`";
        }
      ];
      perTarget = lib.concatMap (
        key:
        let
          t = cfg.target.${key};
        in
        lib.optionals (builtins.isAttrs t) (
          lib.optional (t ? linker) {
            path = [
              "target"
              key
              "linker"
            ];
            use = "set `targets.<triple>.linker`";
          }
          ++ lib.optional (t ? runner) {
            path = [
              "target"
              key
              "runner"
            ];
            use = "set `targets.<triple>.runner`";
          }
        )
      ) (lib.attrNames (if builtins.isAttrs (cfg.target or null) then cfg.target else { }));
    in
    lib.filter (k: lib.hasAttrByPath k.path cfg) fixed ++ perTarget;

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
      unknownTargets = lib.filter (t: !(ws.targets ? ${t})) (
        if config.targets == null then [ ] else config.targets
      );
      planned = if config.targets == null then lib.attrNames ws.targets else config.targets;
      unplannedLayers = lib.filter (t: !(lib.elem t planned)) (lib.attrNames config.target);
      selections = [
        "packages"
        "tests"
        "products"
        "benches"
      ];
    in
    {
      # The workspace's `variantDefaults`, the lowest layer: in the
      # variant's own evaluation, as they do not depend on the target.
      imports = [ ({ options, ... }: bt.layer options (-0.5) (_: v: v) ws.variantDefaults) ];

      # Through extendModules, so the variant's own definitions keep their
      # priorities: a value merged first could not be replaced by a plain
      # definition in a later layer. The target's defaults rank below the
      # variant's own settings (rank 0), its `target.<triple>` above them.
      config.onTarget =
        defaults: triple:
        let
          layer = bt.layer options;
        in
        (extendModules {
          modules = [
            (layer (-0.25) (_: v: v) defaults)
          ]
          ++ lib.optional (config.target ? ${triple}) (layer 0.5 (_: v: v) config.target.${triple});
        }).config;

      config.assertions = [
        {
          assertion = !(config.benches != false && checkMode);
          message = "breakbulk: ${at}${bt.setIn options.benches}: `benches` needs a build variant, not `${config.mode}`";
        }
        {
          assertion = !(config.mode == "clippy" && config.rustcWorkspaceWrapper != null);
          message = "breakbulk: ${at}${bt.setIn options.rustcWorkspaceWrapper}: a clippy variant's workspace wrapper is clippy-driver; for another, use `mode = \"check\"` with `rustcWorkspaceWrapper`";
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
      ++ map (k: {
        assertion = false;
        message = "breakbulk: ${at}.cargoConfig${bt.setIn options.cargoConfig}: `${lib.concatStringsSep "." k.path}` is set by breakbulk itself; ${k.use}";
      }) (ownedCargoConfigKeys config.cargoConfig)
      ++ lib.concatMap (
        o:
        lib.optionals (builtins.isAttrs config.${o}) (
          map (m: {
            assertion = false;
            message = "breakbulk: ${at}.${o}.exclude${bt.setIn options.${o}}: ${m}";
          }) (manifest.excludeMembers (lib.attrNames ws.members) config.${o}.exclude).errors
        )
      ) selections;

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
        cargoConfig = mkOption {
          type = bt.cargoConfig;
          default = { };
          example = lib.literalExpression ''
            {
              profile.release = {
                panic = "abort";
                strip = "debuginfo";
              };
            }
          '';
          description = ''
            Cargo configuration for this variant's plans, as the content
            of a config file: what `--config` or `CARGO_*` variables set
            for one CI job. It is written to one TOML file that the
            planner passes to Cargo as `--config <file>`, over the
            project's own `.cargo/config.toml` files: a value replaces
            theirs, and an array (`build.rustflags`) is appended to
            theirs. breakbulk's own reader of the project's config
            (`build.rustflags`, `target.<triple>.rustflags`, `[env]`)
            reads it last, the same way. It applies to every plan of the
            variant, so a `profile.<name>` table reaches only the plans
            of that profile (`profile`, `testProfile`). The dev shell does
            not apply it.

            Keys that breakbulk sets itself are an evaluation error:
            `build.rustc`, `build.rustdoc`, `build.rustc-wrapper`,
            `build.rustc-workspace-wrapper`, `build.target-dir`,
            `build.build-dir`, `build.target`, `build.profile`,
            `target.<key>.linker`, `target.<key>.runner`, `host.linker`,
            `host.runner` and `source`.

            When the project can be edited, a named profile in its
            `Cargo.toml` (`[profile.dist]` with `inherits = "release"`,
            and `profile = "dist"` here) does the same for profile
            settings, and local Cargo sees it too.
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
            unit and is in `repo.checks` (`checks.check`). `clippy`: as `check`, with
            clippy-driver as `RUSTC_WORKSPACE_WRAPPER` (workspace members
            only, so dependencies are shared with `check`), and the
            `clippy.toml` files of each member's directory and its parents
            up to the repository root (`CLIPPY_CONF_DIR`). A member that
            is also a build-dependency is linted twice, and its host copy
            without the project's rustflags, so with `-D warnings` it can
            fail where `cargo clippy` passes; give its host units their
            own `CLIPPY_ARGS` with
            `packages.<name>.variant.<v>.forHost.env` (see [Run the checks
            in CI](../../how-to/ci.md#a-clippy-check-fails-where-cargo-clippy-passes)).
            `coverage`: `build` with `-C instrument-coverage` on target
            units. Use the same profile as the build variant to share host
            units; Cargo's own `clippy` uses the dev profile.
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
            units clippy-driver compiles (workspace members), on both
            sides. A `CLIPPY_ARGS` in a package's `env` replaces them for
            that package's units.
          '';
        };
        rustcWrapper = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = lib.literalExpression ''"''${verus}/bin/verus-driver"'';
          description = ''
            A program every rustc invocation of the variant goes through,
            as Cargo's `build.rustc-wrapper` (`RUSTC_WRAPPER`): Cargo
            starts `<wrapper> <rustc> ARGS…` for every crate, dependencies,
            build scripts and its own queries (`rustc -vV`) included. Use
            it for a rustc driver (a verifier, a model checker) that must
            see every crate, and set what it reads from the environment
            with `cargoConfig.env` (the queries too) or
            `packages.<name>.env` (that package's units). A path to an
            executable in the store; the units of every crate then depend
            on it. It applies in every mode, and to every plan but the doc
            plan. A unit's derivation names the wrapper, so units are not
            shared with a variant without it.

            When the wrapper is a rustc driver, it must be built for this
            rustc: a driver with its own sysroot makes the units name that
            sysroot's crates, which instantiation rejects as undeclared
            inputs.
          '';
        };
        rustcWorkspaceWrapper = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = lib.literalExpression ''"''${my-lints}/bin/my-lint-driver"'';
          description = ''
            As `rustcWrapper`, for workspace members only, as Cargo's
            `build.rustc-workspace-wrapper` (`RUSTC_WORKSPACE_WRAPPER`):
            Cargo starts `[<rustcWrapper>] <wrapper> <rustc> ARGS…` for
            members, so dependencies stay shared with a variant without
            it. A clippy variant's is clippy-driver; set this with
            `mode = "check"` for another lint driver.
          '';
        };
        sideFiles = mkOption {
          type = types.listOf (
            types.coercedTo types.str (suffix: { inherit suffix; }) (
              types.submodule {
                options = {
                  suffix = mkOption {
                    type = types.str;
                    example = ".vir";
                    description = "The end of the file's name.";
                  };
                  into = mkOption {
                    type = types.str;
                    default = "beside";
                    example = "debug";
                    description = ''
                      `beside`: a file `<stem><suffix>`, where `<stem>` is
                      an output file's name without its extension, goes
                      into that file's output beside it (into each, when
                      an `.rlib` and an `.rmeta` share the stem). Any other
                      value names a derivation output of the unit (`debug`
                      on units that have one); a unit without it discards
                      the file.
                    '';
                  };
                };
              }
            )
          );
          default = [ ];
          example = [ ".vir" ];
          apply = map (r: {
            inherit (r) suffix;
            into = if r.into == "beside" then "beside" else { output = r.into; };
          });
          description = ''
            Where a unit puts the files a wrapper (`rustcWrapper`,
            `rustcWorkspaceWrapper`) writes into rustc's output directory
            beyond the outputs: each rule sends a file whose name ends in
            `suffix` `into` a place; the first matching rule wins, and a
            file no rule keeps is discarded. A string is a rule with
            `into = "beside"`. The debuginfo files rustc writes beside a
            linked output (`.pdb`, `.dwp`, `.dwo`, `.dSYM`) are breakbulk's
            own rules, into the `debug` output, ahead of these.

            `beside` is for files that a dependent's compile reads: the
            file is beside the crate file both in the dependency's output
            and in a dependent's dependency directory (`-L dependency=`),
            where breakbulk links it next to the crate file's link. So a
            driver finds it beside the path it gets a crate by, whether
            it resolves symlinks or not (Verus reads `<stem>.vir` beside
            each `--extern`'s real path, and beside the path rustc loaded
            each other crate from). The rules apply to the units a wrapper
            runs on; the others are a plain variant's.
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
                tests = false;
              };
            }
          '';
          description = ''
            This variant's settings on one of its targets: any option of
            the variant (`features`, `noDefaultFeatures`, `profile`,
            `testProfile`, `cargoConfig`, `clippyArgs`, `packages`, `tests`, `benches`, `checks.tests`, …)
            except `targets`. They apply over the target's
            `variantDefaults`
            (`workspaces.<ws>.targets.<triple>.variantDefaults`) and the
            variant's own settings: lists concatenate, and a single value
            set here wins over theirs without `lib.mkForce`, unless one of
            theirs has a higher priority (`lib.mkForce`)
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
          type = bt.selection;
          default = true;
          example = [ "my-lib" ];
          description = ''
            The packages this variant plans on a target, in every plan.
            `true`: the whole workspace (`--workspace`). A list, or the
            exclude form: each traced with `-p`; features then name the
            selected packages' own features, as with `cargo build -p
            <pkg> --features <f>` (`breakbulk.variants.featurePowerset`
            makes such variants with `scope = "package"`). `false`:
            nothing, no plan is traced. For every variant on one target,
            set it in the target's `variantDefaults`
            (`workspaces.<ws>.targets.<triple>.variantDefaults.packages`).
            ${excludeFormDoc}
          '';
        };
        tests = mkOption {
          type = bt.selection;
          default = true;
          example = lib.literalExpression ''{ exclude = [ "*-bench" ]; }'';
          description = ''
            The test plan (`cargo test --no-run`; for a check or clippy
            variant, `cargo check --all-targets`): test binaries, test
            runs, test apps and doctests. `true`: those of the `packages`
            selection. `false`: none, and the test plan is not traced: a
            target that is only built (a wasm component whose tests run
            natively, with `targets.<triple>.variantDefaults.tests =
            false`), or on a check or clippy variant plain `cargo check`
            (libraries and binaries). A list of packages, or the exclude
            form: the test plan is `cargo test -p <pkg> …` for those only.
            ${excludeFormDoc}
          '';
        };
        products = mkOption {
          type = bt.selection;
          default = true;
          example = false;
          description = ''
            Products (`packages.<pkg>`) and their checks, from the build
            plan. `true`: one for every package `packages` selects.
            `false`: none, and the build plan is not traced: a target that
            is only tested (the native target of crates that ship as wasm
            and run their unit tests natively); a check or clippy
            variant's `check` then covers the test plan only. A list of
            packages, or the exclude form: products for those only, from
            the same build plan of `packages`. Test binaries, test runs,
            doctests and benches do not depend on it.
            ${excludeFormDoc}
          '';
        };
        checks = {
          products = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Put this build or coverage variant's products in
              `repo.checks`, as `<pkg>/build`, and their checks, as
              `<pkg>/<check>`, under the variant's prefix:
              `<ws>/<triple>/` for the default variant,
              `<ws>/<triple>/variant-<v>/` for the others. A product
              whose roots Cargo all skipped (required features) is left
              out. Variants made by `breakbulk.variants.featurePowerset`
              set this, `tests` and `benches` to `false` with
              `lib.mkDefault`, so any plain definition, such as one in its
              `variant`, overrides it.
            '';
          };
          tests = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Put this build or coverage variant's enabled test runs
              (`<pkg>/test-<name>`, `test.binaries.<key>.enable`) and
              doctests (`<pkg>/doctest`, `test.doctest.enable`) in
              `repo.checks`, on a target that can run tests
              (`canRunTests`).
            '';
          };
          benches = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Put this build or coverage variant's enabled bench runs
              (`<pkg>/bench-<name>`, each bench binary of
              [`benches`](#workspacesnamevariantsnamebenches) once in test
              mode, `bench.enable`) in `repo.checks`, on a target that can
              run tests. Timed runs never happen inside Nix.
            '';
          };
          docs = mkOption {
            type = types.bool;
            default = false;
            example = true;
            description = ''
              Put this variant's documentation
              (`target.<triple>.variants.<v>.docs`) in `repo.checks`, as
              `<ws>/<triple>/docs` for the default variant and
              `<ws>/<triple>/variant-<v>/docs` for the others, in any
              mode. Off by default: any change to a documented crate runs
              every rustdoc of the variant again.
            '';
          };
          check = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Put this check or clippy variant's `check` (every unit of
              its plans) in `repo.checks`, as
              `<ws>/<triple>/variant-<v>/check`.
            '';
          };
          buildScriptPaths = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Put the `buildScriptPaths` check of each plan whose outputs
              are in `repo.checks` there too
              ([missing build-script paths](../../explanation/configuration.md#missing-build-script-paths)):
              of a build or coverage variant, the build plan's with
              `products` (`buildScriptPaths/build`) and the test plan's
              with `tests` (`buildScriptPaths/test`), on any target; of a
              check or clippy variant, those of the plans its `check`
              builds. For the whole workspace, set it in
              [`variantDefaults`](#workspacesnamevariantdefaults); for one
              target, in that target's `variantDefaults`.
            '';
          };
        };
        sourcePaths = mkOption {
          type = types.enum [
            "auto"
            "cargo"
            "remap"
            "keep"
          ];
          default = "auto";
          description = ''
            How source paths are kept out of what this variant builds.
            Every value but `keep` gives each product the
            `noSourceReferences` check. A project that sets Cargo's
            `trim-paths` itself gets Cargo's remaps whatever the value.
            For every variant of the workspace, set it in
            [`variantDefaults`](#workspacesnamevariantdefaults).

            - `auto`: breakbulk turns Cargo's `trim-paths` on
              (`--config profile.<p>.trim-paths="all"`) when the toolchain
              has it (its `trimPaths` capability: Cargo 1.101 and later)
              and the project declares no `trim-paths` in any profile of
              the workspace root's `Cargo.toml` or of its
              `.cargo/config.toml` files (any profile, package override or
              value counts; the files are read, not merged as Cargo
              would). Units without Cargo's trim-paths get breakbulk's own
              remaps.
            - `cargo`: breakbulk always turns Cargo's `trim-paths` on,
              replacing the project's own setting. Planning fails when the
              toolchain lacks the `trimPaths` capability.
            - `remap`: breakbulk never turns Cargo's `trim-paths` on and
              hides paths with its own remaps (Rust `--remap-path-prefix`,
              C `-ffile-prefix-map`).
            - `keep`: breakbulk neither turns Cargo's `trim-paths` on nor
              adds remaps of its own, and products get no default
              `noSourceReferences` check; binaries then reference their
              sources' store paths.

            Under Cargo's trim-paths, breakbulk's own C prefix maps use
            Cargo's names, as cc-rs does.
          '';
        };

        docs.noDeps = mkOption {
          type = types.bool;
          default = true;
          example = false;
          description = ''
            Document only the planned packages, as `cargo doc --no-deps`
            does, in `target.<triple>.variants.<v>.docs`. `false`: their dependencies
            too, as `cargo doc`; links to a dependency's items then go to
            its pages in the same folder.
          '';
        };

        benches = mkOption {
          type = bt.selection;
          default = false;
          example = true;
          description = ''
            The bench plan, `cargo bench --no-run` with this variant's
            settings (use `profile = "bench"`): bench binaries, and lib
            and bin harnesses in bench mode, at
            `target.<triple>.variants.<v>.benches.<pkg>.<bench>`. `false`:
            none, the plan is not traced. `true`: those of the `packages`
            selection. A list of packages, or the exclude form: `cargo
            bench -p <pkg> …` for those only. Build and coverage variants
            only. `target.<triple>.benches` is the default variant's when
            it has benches, else the one variant's that has. The test plan
            builds no benches (`cargo test --no-run` does not). Each
            bench binary also runs once, with `--test`, as a check of the
            variant, under the package's
            [`bench`](packages.md#packagesnamebench) run settings.
            ${excludeFormDoc}
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
                features = mkOption {
                  type = types.attrsOf (types.listOf types.str);
                  description = ''
                    The package's `[features]` table as written: no
                    implicit features of optional dependencies.
                  '';
                };
                optionalDependencies = mkOption {
                  type = types.listOf types.str;
                  description = ''
                    The names (renamed names where renamed) of the
                    package's optional dependencies, in any dependency
                    table, `[target.<cfg>]` ones included.
                  '';
                };
                dependencies = mkOption {
                  type = types.listOf types.str;
                  description = ''
                    The names (renamed names where renamed) of all the
                    package's dependencies, of every kind, in any
                    dependency table, `[target.<cfg>]` ones included.
                  '';
                };
              };
            }
          );
          readOnly = true;
          default = lib.mapAttrs (_: m: m // manifest.featureFacts (manifest.readManifest root m.path)) (
            manifest.memberPackages {
              inherit root;
              wsDir = util.normalizeRel config.path;
            }
          );
          defaultText = lib.literalMD "the workspace's members, by name";
          example = lib.literalExpression ''
            {
              app = {
                name = "app";
                path = ".";
                features = { };
                optionalDependencies = [ ];
                dependencies = [ "core" ];
              };
              core = {
                name = "core";
                path = "crates/core";
                features = { default = [ "std" ]; std = [ ]; serde = [ "dep:serde" ]; };
                optionalDependencies = [ "serde" ];
                dependencies = [ "serde" ];
              };
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
              workspaces.default.targets.x86_64-unknown-linux-gnu.variantDefaults.tests =
                lib.filter (lib.hasPrefix "core-")
                  (lib.attrNames config.workspaces.default.members);
            }
            ```

            The selection options (`variants.<v>.packages`, `tests`,
            `products`, `benches`) also take `{ exclude = [ … ]; }`: every
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
                  (`breakbulk.toolchainFacts.of`). Whether Cargo allows
                  unstable features is not one of them: the planner asks
                  the cargo it runs.
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
                variantDefaults.packages = [ "ui" ];
                # Any `targets.<triple>` option, for this workspace only.
                rustflags = [ "--cfg" "getrandom_backend=\"wasm_js\"" ];
              };
            }
          '';
          description = ''
            The triples this workspace is built for. Each is planned on its
            own (`--target <triple>`). Besides `variantDefaults`, an entry takes
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
            changes it. For a feature matrix, import
            `breakbulk.variants.featurePowerset { … }` in
            `workspaces.<ws>.imports`
            ([feature matrices](../../how-to/feature-matrix.md)).
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

        roots =
          let
            rootName = types.strMatching rootNameRegex;
            rootEntry = types.either rootName (
              types.submodule {
                options = {
                  name = mkOption {
                    type = rootName;
                    description = "The root's name.";
                  };
                  platform = mkOption {
                    type = types.nullOr (
                      types.enum [
                        "host"
                        "target"
                      ]
                    );
                    default = null;
                    description = "The platform Cargo builds the root for; `null`: as predicted.";
                  };
                };
              }
            );
            rootList =
              plan: command:
              mkOption {
                type = types.nullOr (types.listOf rootEntry);
                default = null;
                example = lib.literalExpression ''
                  [
                    "app/bin/app"
                    "app/bin-test/app"
                    { name = "pm/lib-test/pm"; platform = "host"; }
                  ]
                '';
                description = ''
                  The roots of this workspace's ${plan} plans
                  (${command}), in place of the roots breakbulk predicts
                  from the manifests: the way around a bug in that
                  prediction, which fails instantiation with "the plan has
                  roots that were not predicted". `null` keeps the
                  prediction. Each entry is a root name as that error
                  lists them, `<package>/<kind>/<target>`, with `-test`
                  added to the kind of a test root other than a test
                  target (`app/bin-test/app`), or `{ name; platform; }`
                  for a root whose platform the prediction gets wrong
                  ("planned for the host platform, but was predicted for
                  the target platform"). `platform` is `host` for a
                  target Cargo builds for the build machine (a proc
                  macro's unit tests), else `target`; a bare name, or
                  `platform = null`, takes the platform predicted for the
                  root, or `target` when it is not predicted. Both
                  delivery modes use the list, for every target and
                  variant. A listed root that a plan lacks is a stub, as a
                  predicted one is.
                '';
              };
          in
          {
            build = rootList "build" "`cargo build`";
            test = rootList "test" "`cargo test --no-run`";
            bench = rootList "bench" "`cargo bench --no-run`";
            doctests = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              example = [ "mylib" ];
              description = ''
                The packages whose libraries `cargo test` doc-tests, in
                place of those breakbulk predicts from the manifests: the
                way around a bug in that prediction, which fails test
                plans with "the plan has doctests of …". `null` keeps the
                prediction. Packages the test plan does not select are
                left out, as predicted ones are. Both delivery modes use
                the list.
              '';
            };
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

        defaultTarget = mkOption {
          type = types.nullOr types.str;
          default =
            let
              ts = lib.attrNames config.targets;
              fromTargets = targetsDefaultTarget ts;
              # Read only when needed: an import-from-derivation unless the
              # workspace has no Cargo config file.
              buildTarget = projectBuildTarget config.path;
            in
            if fromTargets != null then
              fromTargets
            else if
              buildTarget != null && lib.length buildTarget == 1 && lib.elem (lib.head buildTarget) ts
            then
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

        variantDefaults = mkOption {
          type = types.deferredModule;
          default = { };
          example = lib.literalExpression ''
            {
              sourcePaths = "remap";
              docs.noDeps = false;
              checks.buildScriptPaths = false;
            }
          '';
          description = ''
            Settings for every variant of this workspace: a module with
            the options of [`variants.<v>`](#workspacesnamevariants). They
            are the lowest layer of each variant's settings, under the
            target's
            [`variantDefaults`](#workspacesnametargetsnamevariantdefaults),
            the variant's own settings and its `target.<triple>`: lists
            concatenate, and a single value set in a higher layer wins
            without `lib.mkForce`
            ([layers and priorities](../../how-to/targets.md#layers-and-priorities)).
            A function module gets the variant's settings as `config`,
            with every layer applied
            (`{ config, lib, ... }: { features = lib.optional (config.mode == "check") "strict"; }`).
          '';
        };

        memberDefaults = mkOption {
          type = settingsModule;
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
            of its `Cargo.lock`): a module with the options of
            [`packages.<name>`](packages.md), evaluated for each member,
            whose lockfile entry is its `package` argument. They are a
            layer under the package's own `packages.<name>` settings:
            lists concatenate (`lib.mkForce` in `packages.<name>` replaces
            them), `env` attributes merge, and the package's own value
            wins for single values (`test.runner`) unless this one has a
            higher priority (`lib.mkForce`)
            ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)).
            Dependencies from a registry or git do not get them.
          '';
        };

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
          {
            assertion = config.variants ? ${config.defaultVariant};
            message = "breakbulk: workspaces.${name}.defaultVariant `${config.defaultVariant}`${bt.setIn options.defaultVariant} is not one of its variants (${
              if config.variants == { } then
                "it has none"
              else
                lib.concatStringsSep ", " (lib.attrNames config.variants)
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
    };
in
{
  options.workspaces = mkOption {
    # A definition is a module, as a top-level one is, so that
    # `workspaces.<ws>.imports` takes workspace modules such as
    # `breakbulk.variants.featurePowerset`'s.
    type = types.attrsOf (
      types.submoduleWith {
        modules = [ workspace ];
        shorthandOnlyDefinesConfig = false;
      }
    );
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
      no modules; declaring any workspace turns that default off. A
      definition is a module of the workspace's options, so it can have
      `imports`, such as `breakbulk.variants.featurePowerset { … }`.
    '';
  };

  config.warnings = lib.concatMap (w: w.warnings) (lib.attrValues config.workspaces);
  config.assertions = lib.concatMap (w: w.assertions) (lib.attrValues config.workspaces);
}
