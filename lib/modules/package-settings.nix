# The settings of one package's units: the options of `packages.<name>`,
# `workspaces.<ws>.memberDefaults`, `sysDefaults.packages.<name>` and
# `sysDefaults.dependents.<name>`'s result. Each of those is a module of
# these options, a layer that lib/package-settings.nix evaluates with the
# others for one lockfile entry.
{ lib }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  testRunners = import ../test-runners.nix {
    inherit lib;
    util = import ../util.nix { inherit lib; };
  };

  testRunner = lib.mkOptionType {
    name = "testRunner";
    description = "test runner (function from the run's facts to a shell snippet)";
    descriptionClass = "noun";
    check = builtins.isFunction;
    merge = lib.options.mergeOneOption;
  };

  # Which units are on which side.
  sides = "[sides](../../explanation/configuration.md#host-and-target-sides)";

  # The source-view pipeline that `extraSources` and the `test` source
  # options are steps of.
  pipeline = "[`sources`](#packagesnamesources)";

  keepFunction = lib.mkOptionType {
    name = "keepFunction";
    description = "function from { kind, cargoTarget, buildScriptRun, root, packageDir, workspaceDir, ... } to a file set";
    descriptionClass = "noun";
    check = builtins.isFunction;
    merge = lib.options.mergeOneOption;
  };

  sourcesFunction = lib.mkOptionType {
    name = "sourcesFunction";
    description = "function from { default, kind, cargoTarget, root, packageDir, ... } to a file set";
    descriptionClass = "noun";
    check = builtins.isFunction;
    merge = lib.options.mergeOneOption;
  };

  side = name: {
    env = bt.mkEnv "Environment for this package's ${name} units only (${sides}).";
    nativeInputs = bt.mkInputs "Build-machine tools for this package's ${name} units only (${sides}).";
    inputs = bt.mkInputs "Libraries for this package's ${name} units only (${sides}).";
  };

  # Where run settings sit, for the texts of their options.
  runLevels = "[run settings](../../explanation/configuration.md#run-settings)";

  # The options of one run (a test binary's, the doctest run's or a bench
  # binary's): `test.<option>` for every run of the package, refined by
  # `test.binaries.<key>`, `test.doctest` and `bench`, which are modules
  # of these same options (lib/package-settings.nix `runsOf`).
  runOptions = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether a run is part of `repo.checks` and the check groups. The
        binary is built either way (a doctest compiles and runs in one
        rustdoc process, so a disabled doctest run builds nothing of it in
        the checks; `doctests.<pkg>` still builds it). For a library
        whose manifest sets `doctest = false`, there is no doctest run to
        enable. A single value (${runLevels}):
        `memberDefaults.test.binaries.<key>.enable = false` with `true`
        for a few packages runs only theirs.
      '';
    };
    args = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "--skip"
        "net::"
      ];
      description = ''
        Arguments for the test binary, which the test runner passes on
        (libtest's, for a binary with its harness). A doctest run passes each to
        `rustdoc --test` as `--test-args`, so `[ "--skip" "src/lib.rs -
        net" ]` skips a doctest by name. Bench runs start with `--test`
        (the `bench` layer's own definition: `lib.mkForce` replaces it).
        Lists concatenate (${runLevels}).
      '';
    };
    env = bt.mkTestEnv ''
      Environment for runs (test runs, doctests and bench runs) and test
      apps. It comes after the environment Cargo gives the binary
      (`[env]`, the build script's `rustc-env`, `CARGO_*`), so it can
      replace any of it. Variables merge (${runLevels}).
    '';
    path = mkOption {
      type = bt.inputs;
      default = [ ];
      example = lib.literalExpression "p: [ p.git ]";
      description = ''
        Packages whose `bin` directories go on `PATH` in runs and test
        apps, after the environment. A function of the package set of
        the machine that runs the test (the target's `testSystem`, else
        the build machine; the build machine's for doctests and test
        apps), or a list used as given. Lists concatenate (${runLevels}).

        ${bt.inputsNote}
      '';
    };
    preRun = mkOption {
      type = types.attrsOf (types.nullOr types.str);
      default = { };
      defaultText = lib.literalMD "`home` (see the description)";
      example = lib.literalExpression ''
        {
          home = null;  # keep Nix's /homeless-shelter
          db = "initdb -D \"$TMPDIR/db\" && pg_ctl -D \"$TMPDIR/db\" -w start";
        }
      '';
      description = ''
        Shell snippets run before the binary, in name order, in the run's
        shell after its environment (`env`, `path`) is set: what they
        export reaches the test. `null` removes an entry. Each entry is a
        single value of its own (${runLevels}), so a more specific layer
        replaces one entry and keeps the others. The entries breakbulk
        defines:

        - `home`: a fresh, empty `HOME` in `$TMPDIR`, as a test's home is
          under `cargo test`, unless the environment set another than
          Nix's `/homeless-shelter`. With `home = null` a run keeps
          `/homeless-shelter`, so a test that writes to its home fails, as
          compiles do. `XDG_*` stay unset, so tools fall back to
          directories under `HOME`.
        - `coverage`, in the variant of
          [`breakbulk.variants.coverage`](../presets.md#coverage) (its
          `memberDefaults.variant.<v>` layer): `LLVM_PROFILE_FILE` into
          `$TMPDIR/profraw`, which the run's `postRun` moves into
          `$out/profraw` when it passes.

        Doctests and test apps do not run them: rustdoc runs the examples
        itself, with a fresh `HOME` and `RUST_TEST_THREADS`
        (`test.doctest.preRun` is an error), and a test app keeps the
        user's environment.
      '';
    };
    postRun = mkOption {
      type = types.lines;
      default = "";
      example = ''cp -r "$TMPDIR/nextest-ws/target/nextest/ci" "$out/junit"'';
      description = ''
        A shell snippet run inside each passing run (test, doctest or
        bench), after the tests: `$log` is the run's raw output and `$out`
        the run's output directory, empty otherwise. Under
        `testRunners.nextest`, nextest's store (JUnit reports) is
        `$TMPDIR/nextest-ws/target/nextest`.
        Snippets concatenate (${runLevels}): the package's first, then the
        binary's or the doctest run's. Whatever a snippet puts in `$out`
        decides whether the run is reproducible: breakbulk keeps `$out`
        empty so that `nix build --rebuild` of a passing run succeeds,
        and the output stays in the build log (`nix log`).
        `cp "$log" "$out/log"` keeps the raw output, for a binary cache
        that does not store build logs or a CI that keeps them as
        artifacts; it holds timings and, with several test threads, lines
        in a varying order, so such a run is not reproducible under
        `nix build --rebuild`.
      '';
    };
    wrapper = mkOption {
      type = types.nullOr types.raw;
      default = null;
      example = lib.literalExpression "breakbulk.lib.wrappers.cargoTargetLayout { profile = \"debug\"; }";
      description = ''
        A program that starts the binary, in its runs and test apps:
        Cargo's runner protocol, `<wrapper> <binary> <args…>`, in the
        package directory, with `BREAKBULK_SOURCE_ROOT` (the root of the
        run's source view, or of the checkout for a test app with
        `checkout`) and `BREAKBULK_NEXT` (a program that starts the binary
        under the target's runner, or directly without one) in its
        environment. It ends with `exec "$BREAKBULK_NEXT" <binary>
        <args…>`, the binary possibly moved. It runs outside the target's
        runner, on the machine that runs the test. A program, or a
        function from the package set of that machine to one. The test
        runner gets it in its launcher (`testRunners.nextest` gives nextest
        the launcher as the target runner, for listing as for each test).
        [`breakbulk.lib.wrappers`](../presets.md#test-wrappers) has
        ready-made ones. Doctests do not use it: rustdoc runs each example
        itself (`test.doctest.wrapper` is an error). `null`: none.
      '';
    };
    runner = mkOption {
      type = testRunner;
      default = testRunners.direct;
      defaultText = lib.literalExpression "breakbulk.lib.testRunners.direct";
      example = lib.literalExpression "breakbulk.lib.testRunners.nextest { profile = \"ci\"; }";
      description = ''
        The test runner: what starts the binary in its run, a function
        from the run's facts (the binary, its `args`, its platform, a
        launcher that applies the `wrapper` and the target runner, the
        package graph, …) to a shell snippet, so a harness breakbulk does
        not know needs no change to breakbulk
        ([Test runners](../presets.md#test-runners) lists the facts and
        the contract). Each binary is its own run.
        [`breakbulk.lib.testRunners`](../presets.md#test-runners) has
        `direct` (the binary itself, as `cargo test` runs it; it sets
        libtest's `RUST_TEST_THREADS` to the build's cores unless the
        environment set it) and `nextest { profile; configFile; package; }`
        (cargo-nextest's reuse-build mode over the one binary, with the
        project's nextest configuration: retries, timeouts, default
        filter, test groups). Doctests run under rustdoc whatever this
        says (`test.doctest.runner` is an error). Test apps start the
        binary directly. Not the target runner
        ([`targets.<t>.runner`](targets.md#targetsnamerunner)), which
        starts every program of the target (wine, qemu).
      '';
    };
    stages = mkOption {
      type = bt.stages;
      default = { };
      defaultText = lib.literalMD "with [`ca`](repository.md#ca), `strip`; else none";
      example = lib.literalExpression ''
        { strip = null; }  # run the unit's own binary
      '';
      description = ''
        Stages the binary goes through before a run executes it, as a
        product's [`stages`](#packagesnamestages) (`{ after ? null;
        before ? null; run; }`; `null` removes one; there is no
        `install`): the run executes the last stage's output, a directory
        holding the one binary. A stage's `target` argument also has
        `packageSet`, the platform's package set or null.

        With [`ca`](repository.md#ca) (`repo.config.ca`) the default is
        `strip = { run = breakbulk.stageHelpers.strip { buildId = false; }; }`.
        Workspace libraries keep real source paths and line tables in
        their debug info, so an edit to any file of such a library (a
        README, a function the test never calls) changes the bytes of
        every test binary that links it; the stripped copy does not
        change, and the run is not re-run. Panic messages keep their file
        and line; backtraces still name functions, but not files, lines
        or inlined frames. The unstripped binary stays in
        `tests.<pkg>.<binary>` for debugging. Without `ca` a stage's
        output is input-addressed and saves no run, so there is none.
        Doctests have no binary to stage (`test.doctest.stages` is an
        error).
      '';
    };
  };

  # The options of `test.binaries.<key>`, `test.doctest` and `bench`, for
  # their documentation: those of `test`, without `refused`.
  runLayerOptions =
    what: refused:
    lib.mapAttrs (
      n: o:
      removeAttrs o [ "example" ]
      // {
        description = "[`test.${n}`](#packagesnametest${lib.toLower n}) for ${what}.";
        # Not the option's own default: a layer that leaves it unset
        # keeps what the layers it refines give.
        defaultText = lib.literalMD "`test.${n}`'s";
      }
    ) (removeAttrs runOptions refused);

  # A module of run settings, kept with its layer's rank for the
  # evaluation of each run (lib/package-settings.nix `runsOf`), as
  # `target` and `variant` keep theirs; documented with the run options.
  runLayer =
    what: refused:
    bt.subLayers
    // {
      description = "module of run settings";
      inherit (types.submoduleWith { modules = [ { options = runLayerOptions what refused; } ]; })
        getSubOptions
        ;
    };

  # What a doctest run cannot honour: rustdoc runs each example itself,
  # and its one hook, `--test-runtool`, starts the platform's runner.
  doctestRefused = [
    "wrapper"
    "runner"
    "preRun"
    "stages"
  ];

  # Every setting but the per-triple and per-variant layers, which have
  # these same options.
  common = {
    key = "breakbulk/modules/package-settings.nix#common";
    _file = ./package-settings.nix;
    options = {
      env = bt.mkEnv ''
        Environment for every unit of this package, on both ${sides}
        (compiles and build-script runs). Values may be derivations,
        including the products of other packages, in this workspace or
        another, on any target; they are passed by reference, and only
        this package's units read them.
      '';
      envSeparators = mkOption {
        type = types.lazyAttrsOf bt.envSeparator;
        default = { };
        example = {
          CMAKE_PREFIX_PATH = ":";
          RUSTDOCFLAGS = " ";
        };
        description = ''
          The separator a variable's lists are joined with, by name, for
          this package's `env`, `forHost.env`, `forTarget.env` and
          `test.env`: what goes between the earlier value and an appended
          list, and between the list's values. Without an entry, the
          built-in table's ([list variables](../unit-builder.md#list-variables)),
          else `:`.
        '';
      };
      nativeInputs = bt.mkInputs ''
        Tools that run on the build machine (`pkg-config`, `cmake`,
        `protoc`), for this package's units on both ${sides}. A function of
        the build platform's package set, or a list. Elements may be the
        products of other packages, as in `env`.
      '';
      inputs = bt.mkInputs ''
        Libraries for the platform being built (`openssl`), for this
        package's units on both ${sides}. A function of a package set
        (`p: [ p.openssl ]`), called with the build machine's set for host
        units and with the target's set for target units; or a list used
        as given. Elements may be the products of other packages, as in
        `env`. Their library search paths (`NIX_LDFLAGS`, not compiler
        flags or `PATH`) also reach the link steps of the packages that
        link this one (bins, tests, cdylibs, doctests of dependents), on
        the same platform, so a `-sys` crate may print `rustc-link-lib`
        without a search path; binaries get an rpath to the library.
      '';
      productInputs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "tool" ];
        description = ''
          The packages whose products, built by the same plan as this
          package, this package's settings use (in `env`, `inputs`,
          `nativeInputs` or `sourceOverlay`): `[ "tool" ]` for
          `env.TOOL = "''${repo.workspaces.main.packages.tool}/bin/tool"`.
          Products of another target, variant or workspace need no entry.
          Dynamic-derivation mode needs every such package named: it
          writes this package and every package that depends on it after
          those products. Without an entry, it is an infinite recursion
          there; IFD mode checks the entries in `repo.checks`. Lists
          concatenate across layers. See [Products as
          inputs](../../explanation/configuration.md#products-as-inputs).
        '';
      };
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
          are relative to the repository root. A built-in step of
          ${pipeline}: added for every kind of unit. A library, bin or
          build script that fails naming a path outside its source view
          ends with a hint naming the path and this option.
        '';
      };
      scopeTargetRoots = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether each Cargo target's units see only their own root among
          the package's targets. The view of one target's compiles leaves
          out the crate roots of the package's other bins, examples, tests
          and benches (a root `<dir>/main.rs` outside `src/`, `src/bin/`,
          `tests/`, `benches/` and `examples/` counts as its whole
          directory), and the view of the library, a bin or the build
          script also leaves out the `examples/` and `benches/`
          directories. So an edit to `tests/foo.rs` rebuilds only that
          test. Shared files, such as `tests/common/mod.rs`, stay in
          every view. Test runs, doctests and build-script runs read the
          package's own views, with every root: Cargo re-runs a build
          script on any edit to its package. So an edit to an example or
          a bin re-runs the package's build script, unless
          [`predictSources`](#packagesnamepredictsourcesenable) narrows
          the run to its `rerun-if-changed` paths; then it rebuilds no
          library, other bin or product. Set it to `false` when a target reads another
          target's root (`#[path = "../other.rs"]`, a library that
          `include_str!`s an example); such a unit fails with a hint
          naming this option. A built-in step of ${pipeline}.
        '';
      };
      predictSources = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether this package's compiles and build-script runs see
            only the files source prediction finds they read, so that an
            edit to any other file of the package (its `README.md`, a
            comment in its `Cargo.toml`, a file only a test reads) rebuilds
            none of them.

            A compile's predicted view is the module tree of its Cargo
            target's crate root, followed as rustc does (`mod` items,
            `#[path]` and `cfg_attr(…, path = …)`), and the files of every
            `include!`, `include_str!` and `include_bytes!` with a literal
            path (also `concat!(env!("CARGO_MANIFEST_DIR"), "…")`) and of
            `#[debugger_visualizer]`, out of the view the steps of
            ${pipeline} chose. A build-script run's is the paths its
            script declares with literal `rerun-if-changed` directives,
            which is what Cargo reruns it for. Test runs and doctests keep
            the package's views.

            Files read in a way the prediction does not see are misses: a
            proc macro reading a file (`askama` templates, `sqlx`'s
            `.sqlx`, `include_dir!`), a module a proc macro declares. rustc
            and most proc macros fail naming the file, and the failure ends
            with a hint naming `predictSources.keep`. A unit whose files
            cannot be predicted (a `mod` or include in a `macro_rules!`
            body, an include with a computed path, a file syn cannot parse,
            a build script whose directives are computed or that prints
            none) sees its whole view. A package with a `sourceOverlay` is
            not predicted (an evaluation warning says so).
          '';
        };
        keep = mkOption {
          type = types.listOf (
            types.oneOf [
              types.str
              types.path
              keepFunction
            ]
          );
          default = [ ];
          example = lib.literalExpression ''
            [
              "templates"
              ({ cargoTarget, root, packageDir, ... }:
                lib.fileset.fileFilter (f: f.hasExt "sql") (root + "/''${packageDir}/migrations"))
            ]
          '';
          description = ''
            Paths every predicted view of this package keeps, when
            ${pipeline} chose them: files a proc macro or build script reads
            that source prediction does not see. A string is relative to the
            package directory (a directory keeps everything under it); a
            path is absolute. A function gets `{ kind, cargoTarget,
            buildScriptRun, root, packageDir, workspaceDir, ... }` (`kind`
            and `cargoTarget` as `sources` functions get them, never null
            here; `buildScriptRun`: whether the view is a build-script
            run's; `workspaceDir`: the workspace's directory, relative to
            `root`) and returns a `lib.fileset` value. Lists concatenate in
            layer order. The curated defaults keep `Cargo.toml` for the
            dependents of `proc-macro-crate` (also the workspace's),
            `find-crate` and `bevy_macro_utils`, which read it from
            `CARGO_MANIFEST_DIR`, and a variant's `wrapperConfig.workingDirFiles`
            are kept (clippy's: the working directory's `Cargo.toml`).
          '';
        };
        buildScriptRuns = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether `predictSources` narrows this package's build-script
            runs to their declared `rerun-if-changed` paths. The curated
            [`sysDefaults.dependents`](repository.md#sysdefaultsdependents)
            entries set it to `false` for a package whose
            `[build-dependencies]` name a crate whose library code prints
            such directives, which source prediction cannot read.
          '';
        };
      };
      buildScriptPaths.allow = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "../Cargo.lock"
          "/usr/include/*"
        ];
        description = ''
          `rerun-if-changed` paths this package's build script declares
          and does not need, as shell glob patterns matched against the
          path as the script printed it (`"*"`: every path). The
          [`buildScriptPaths`](../../explanation/configuration.md#missing-build-script-paths)
          check of each plan fails when a build-script run declared a path
          that was not in its view, unless the run's package allows it
          here. It applies to the package's runs on both ${sides}. A path
          the script reads goes in `extraSources` (in the repository) or
          `inputs` (outside it) instead.
        '';
      };
      buildScript.outDirRemove = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              beside = mkOption {
                type = types.str;
                example = "CMakeCache.txt";
                description = "The file name that marks a directory the rule applies in.";
              };
              path = mkOption {
                type = types.str;
                example = "CMakeFiles";
                description = "What to delete there: a file or a directory, relative to it.";
              };
            };
          }
        );
        default = [ ];
        example = [
          {
            beside = "meson-info";
            path = "meson-logs";
          }
        ];
        description = ''
          State a tool leaves in this package's build-script output that
          nothing reads after the run and that differs between runs: after
          each successful run of the build script (on both ${sides}), in
          every directory of the output that holds a file named `beside`,
          `path` is deleted. Lists concatenate over the layers.

          The curated [`sysDefaults.dependents`](repository.md#sysdefaultsdependents)
          entry of the `cmake` crate gives every package that depends on it
          directly `{ beside = "CMakeCache.txt"; path = "CMakeFiles"; }`:
          CMake's configure log there names randomly named try-compile
          directories, and the `cmake` crate reads only `CMakeCache.txt`
          and `Makefile` of its build tree, within the run
          ([assumption E3](../assumptions.md#e3-cmake-rs-reads-nothing-from-cmakefiles-after-the-run)).
          `lib.mkForce [ ]` turns it off for a package that reads
          `CMakeFiles` later.
        '';
      };
      sourceOverlay = mkOption {
        type = types.lazyAttrsOf (
          types.oneOf [
            types.package
            types.path
            types.str
          ]
        );
        default = { };
        example = lib.literalExpression ''
          {
            "ui/dist" = repo.workspaces.ui.target.wasm32-unknown-unknown.packages.ui;
          }
        '';
        description = ''
          Products to place in this package's source views, by path
          relative to the package directory: for crates that read files
          at a fixed path next to their sources (`rust-embed`'s
          `#[folder = "ui/dist"]`, `include_dir!`, `include_bytes!`)
          rather than through an environment variable. Each value is a
          derivation (the product of another package, in this workspace
          or another, as in `env`), a path, or a string such as
          `"''${product}/share/ui"`. It appears in every view of the
          package (its build, test and run units) as a symbolic link to
          the value, which replaces whatever the repository has at that
          path. The value is passed by reference: only this package's
          units depend on it, and planning and instantiation do not.
          Workspace packages only: registry and git crates have no view,
          and setting it for one is an evaluation warning.
          See [Fetching and source
          views](../../explanation/internals/sources.md#products-in-a-view).
        '';
      };
      sources = mkOption {
        type = types.listOf sourcesFunction;
        default = [ ];
        example = lib.literalExpression ''
          [
            ({ default, kind, root, ... }:
              if kind == "run"
              then lib.fileset.union default (root + "/crates/linter/resources/fixtures")
              else default)
          ]
        '';
        description = ''
          Functions that choose the files of this package's source views.
          Each gets an attribute set and returns a `lib.fileset` value
          inside the repository root:

          - `default`: the files chosen so far.
          - `kind`: `"build"` (non-test compiles, build scripts and their
            runs), `"test"` (test compiles and doctests) or `"run"` (test
            runs). More kinds may be added: return `default` for a kind
            you do not know.
          - `root`: the repository root, a path.
          - `packageDir`: the package directory, relative to `root` (`""`
            for a package at the root).
          - `cargoTarget`: the Cargo target whose units the view is for,
            `{ kind, name, path }` (`kind`: `"lib"`, `"bin"`,
            `"example"`, `"test"`, `"bench"` or `"custom-build"`; `path`:
            its crate root, relative to the package directory), or null
            for the package's view, which test runs, doctests and any
            unit the planner matched to no target read.

          A function must take `...`. breakbulk passes one more argument,
          so that a function without `...` fails on its first use, not
          when breakbulk adds an argument. The error names an argument the
          function does not take; the extra one's name says to add `...`.

          The functions run after the built-in steps (the package
          directory, then `extraSources`, `test.sourceScope`,
          `test.scopeTestsDir`, `scopeTargetRoots`, `test.runFiles` and
          `test.workspaceManifest`), each on the result
          of the one before. Lists concatenate in [layer
          order](../../explanation/configuration.md#shared-settings-and-layer-order):
          a `memberDefaults` function runs before a `packages.<name>`
          one, and a `variant.<v>` function after the level it refines.
          Within one layer, `lib.mkBefore` and `lib.mkAfter` order them.
          See [Fetching and source
          views](../../explanation/internals/sources.md#source-views) and
          [Rebuild less when unrelated files
          change](../../how-to/filter-source.md).
        '';
      };

      forHost = side "host";
      forTarget = side "target";

      stages = mkOption {
        type = bt.stages;
        default = { };
        description = "Post-link stages for this package's products, as `targets.<triple>.stages` (`after = \"install\"` for wrappers and packaging).";
      };
      checks = mkOption {
        type = bt.checks;
        default = { };
        example = lib.literalExpression "{ noSourceReferences = null; }";
        description = ''
          Checks on this package's products, as `targets.<triple>.checks`.
          They are added to the target's checks and to the default checks
          (`noSourceReferences`, `buildScriptFiles`). `null` removes a check
          from this package only.
        '';
      };

      test = runOptions // {
        sourceScope = mkOption {
          type = types.listOf (types.either types.path types.str);
          default = [ ];
          example = [ "testdata" ];
          description = ''
            Repository paths (paths, or strings relative to the
            repository root) that only this package's test units see: the
            units Cargo builds with its dev-dependencies (test harnesses,
            integration tests and benches with or without the libtest
            harness, examples), its doctests and its test runs, whose
            working directory is the package directory of their view. A
            path outside the package is added to the test view. A path
            inside the package is also removed from the view of its other
            units (the library, bins, build script). Either way, editing
            it rebuilds only this package's test units and re-runs its
            tests. The package's `tests/` directory is in this scope too
            (`scopeTestsDir`). A built-in step of ${pipeline}. A test
            unit or test run that fails naming a path outside its source
            view ends with a hint naming the path and this option.
          '';
        };
        scopeTestsDir = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the package's `tests/` directory is test-only, as if
            listed in `sourceScope`: only the package's test units see it
            (integration tests, with or without the libtest harness,
            benches, examples, test harnesses, doctests and test runs), so
            a fixture edit there rebuilds no library, bin or product. Set
            it to `false` when the library, a bin or the build script
            reads from `tests/` at compile time
            (`include_str!("../tests/…")`, a build script that generates
            tests from fixtures), or when the library builds a path into
            `tests/` from `CARGO_MANIFEST_DIR` that the tests read; such a
            unit or test run fails with a hint naming this option. A
            built-in step of ${pipeline}.
          '';
        };
        runFiles = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = [ "tests/fixtures" ];
          description = ''
            Narrow what this package's test runs see: their working
            directory (and runtime `CARGO_MANIFEST_DIR`) is a view holding
            only these paths, relative to the package directory, at their
            usual places; `[ ]` gives an empty directory. Editing any other
            file of the package then leaves the test run's own inputs
            unchanged, so with content addressing (`ca`) a byte-identical
            test binary is not re-run. A test that reads a file not listed
            fails. `null`: the view of the package's test compiles, as
            `cargo test` sees it. Test apps keep that view. A built-in
            step of ${pipeline}, for kind `"run"`: a later function can
            still add files, such as another package's fixtures.
            `repo.config.ca` says whether [`ca`](repository.md#ca) is on.
          '';
        };
        workspaceManifest = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether this package's test units and test runs see the
            workspace's root `Cargo.toml` (not `Cargo.lock`). Snapshot-test
            libraries (snapbox, expect-test) look for the topmost
            directory above the package with a `Cargo.toml` and resolve
            their snapshot paths there. Its cost: an edit to the root
            manifest rebuilds this package's test units and re-runs its
            tests. Other units never see it. Set `false` (in
            `memberDefaults` for every member) when no test needs it. See
            [Run snapshot tests](../../how-to/snapshot-tests.md). A
            built-in step of ${pipeline}, after `runFiles`.
          '';
        };
        binaries = mkOption {
          type = types.attrsOf (runLayer "this binary's runs" [ ]);
          default = { };
          example = lib.literalExpression ''
            {
              net.args = [ "--skip" "needs_network" ];
              "lib/my_crate".env.RUST_LOG = "debug";
              "bin/my-tool".enable = false;
            }
          '';
          description = ''
            Run settings for one binary of this package, over `test`'s
            and, for a bench run, `bench`'s (${runLevels}), by its key
            (and the name of its check, `<ws>/<triple>/<pkg>/…`):

            - an integration test (`[[test]]`, `tests/cli.rs`): its name,
              `cli` (check `test/cli`);
            - the library's unit tests: `lib/` and the library's crate
              name, `lib/my_crate` (check `test/lib/my_crate`, and
              `bench/lib/my_crate` for its bench run);
            - a bin's unit tests: `bin/` and the bin's name, `bin/my-tool`
              (check `test/bin/my-tool`, `bench/bin/my-tool`);
            - an example, or a bench with `test = true`: `example/<name>`,
              `bench/<name>` (check `test/example/<name>`,
              `test/bench/<name>`);
            - a bench: `bench/<name>` (check `bench/bench/<name>`).

            The key is the binary's one name: in `tests`, `testRuns`,
            `testApps`, `benches`, `benchRuns`, checks and apps.

            A key that names no test or bench binary of the package is an
            evaluation error listing the package's keys. The keys come from
            the package's manifest, so a binary that only some targets or
            variants build (`required-features`) has its key on all of
            them. Under `memberDefaults`, a key must name a binary of some
            member.
          '';
        };
        doctest = mkOption {
          type = runLayer "the package's doctest run" doctestRefused;
          default = { };
          example = lib.literalExpression ''
            {
              enable = false;
            }
          '';
          description = ''
            Run settings for the package's doctest run (`doctests.<pkg>`,
            check `<ws>/<triple>/<pkg>/doctest`), over `test`'s
            (${runLevels}). rustdoc compiles and runs each example itself,
            so `wrapper`, `runner`, `preRun` and `stages` are an error
            here, and `test`'s do not apply to doctests.
          '';
        };
      };
      bench = mkOption {
        type = runLayer "the package's bench runs" [ ];
        default = { };
        example = lib.literalExpression ''
          {
            enable = false;
            runner = breakbulk.lib.testRunners.direct;
          }
        '';
        description = ''
          Run settings for the runs of the package's bench binaries (a
          bench, and the library's and bins' harnesses in bench mode),
          over `test`'s and under `test.binaries.<key>` (${runLevels}).
          A variant with [`benches`](workspaces.md#workspacesnamevariantsnamebenches)
          builds them with `cargo bench --no-run`, and each enabled one
          runs once with `--test`, as a check of that variant
          (`<pkg>/bench/<binary>`), so that a bench that no longer runs
          fails CI. Timed runs never happen inside Nix. A package whose
          `test.runner` is `testRunners.nextest` sets `bench.runner =
          breakbulk.lib.testRunners.direct` for a bench without the libtest
          harness (Criterion), which nextest cannot list.
        '';
      };
    };
    # Run in every run; `null` in a layer removes one (`test.preRun`).
    config.test.preRun = {
      home = lib.mkOptionDefault ''
        if [ "$HOME" = /homeless-shelter ]; then
          export HOME=$TMPDIR/home
          mkdir -p "$HOME"
        fi
      '';
    };
  };
  target = mkOption {
    type = types.attrsOf bt.subLayers;
    default = { };
    # The same options as the package level, documented there.
    visible = "shallow";
    example = lib.literalExpression ''
      {
        x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpegWin;
        x86_64-pc-windows-msvc.stages.sign = { after = "install"; run = sign; };
      }
    '';
    description = ''
      Settings for this package on one target triple: a module with every
      option of the package level (`env`, `forHost`, `forTarget`,
      `stages`, `test`, …). They apply to the plans for that triple, as a
      layer over the settings of the same definition
      ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)):
      `env` still means both ${sides} (the build-script compile of a plan
      for this triple included), `forTarget.env` the target side only.
    '';
  };

  variant = mkOption {
    type = types.attrsOf bt.subLayers;
    default = { };
    # The same options as the package level, documented there.
    visible = "shallow";
    example = lib.literalExpression ''
      {
        coverage.test.env.RUST_LOG = "debug";
        full.inputs = p: [ p.openssl ];
        full.target.x86_64-pc-windows-msvc.forTarget.env.OPENSSL_DIR = opensslWin;
      }
    '';
    description = ''
      Settings for this package in the plans of one variant
      (`workspaces.<ws>.variants.<v>`): a module with every option of the
      package level, `target.<triple>` included. They are a layer over
      the settings of the same definition and their `target.<triple>`
      layer
      ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)),
      and leave the units of other variants unchanged: a lint setting for
      a `clippy` variant does not rebuild the release variant. A variant
      layer's `target.<triple>` applies to that variant on that triple
      only. The layer applies in every workspace that has a variant of
      that name; a name that no workspace has is an evaluation warning.
    '';
  };
  # Keyed, so the module system imports it once wherever it is used.
  settings = {
    key = "breakbulk/modules/package-settings.nix#settings";
    _file = ./package-settings.nix;
    imports = [ common ];
    options = { inherit target variant; };
  };
in
{
  inherit settings doctestRefused;

  # The names of the run settings: what `test.binaries.<key>`,
  # `test.doctest` and `bench` may set.
  runOptionNames = lib.attrNames runOptions;

  # A layer of package settings: a module of these options, kept for the
  # evaluation of each package it applies to (lib/package-settings.nix).
  # The options are its sub-options for the documentation only; not
  # `types.deferredModuleWith`, which would import them with every layer.
  # Definitions that are `{ }` are left out, so that a layer no module
  # defines has no imports.
  settingsModule = lib.mkOptionType {
    name = "deferredModule";
    description = "module";
    descriptionClass = "noun";
    check = m: builtins.isAttrs m || builtins.isFunction m || builtins.isPath m;
    merge = loc: defs: {
      imports = map (
        def: lib.setDefaultModuleLocation "${def.file}, via option ${lib.showOption loc}" def.value
      ) (lib.filter (def: def.value != { }) defs);
    };
    inherit (types.submoduleWith { modules = [ settings ]; }) getSubOptions;
  };
}
