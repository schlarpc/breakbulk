# The settings of one package's units: the options of `packages.<name>`
# other than its matching (`version`). Also the shape of
# `workspaces.<ws>.memberDefaults` and of `sysDefaults.packages.<name>`'s
# result.
{ lib }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };

  # Which units are on which side.
  sides = "[sides](../../explanation/configuration.md#host-and-target-sides)";

  # The source-view pipeline that `extraSources` and the `test` source
  # options are steps of.
  pipeline = "[`sources`](#packagesnamesources)";

  sourcesFunction = lib.mkOptionType {
    name = "sourcesFunction";
    description = "function from { default, kind, root, packageDir, ... } to a file set";
    descriptionClass = "noun";
    check = builtins.isFunction;
    merge = lib.options.mergeOneOption;
  };

  side = name: {
    env = bt.mkEnv "Environment for this package's ${name} units only (${sides}).";
    nativeInputs = bt.mkInputs "Build-machine tools for this package's ${name} units only (${sides}).";
    inputs = bt.mkInputs "Libraries for this package's ${name} units only (${sides}).";
  };

  # `priorityOf [ "test" "runner" ]`: the priority of an option's
  # definitions in this settings block (`highestPrio`: 1500 for the
  # default alone). Each layer is a block of its own, and module priorities
  # hold only within one; lib/repository.nix compares the layers' single
  # values by these.
  priorityOf =
    { options, ... }:
    {
      options.priorityOf = mkOption {
        type = types.raw;
        internal = true;
        visible = false;
        readOnly = true;
        description = "The priority of an option's definitions in this block, by its path.";
      };
      config.priorityOf = path: (lib.getAttrFromPath path options).highestPrio;
    };

  # The settings of one run over the package's: a test binary's or the
  # doctest run's.
  runSettings = what: {
    args = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "libtest arguments for ${what}, after `test.args`.";
    };
    env = bt.mkEnv "Environment for ${what}, over `test.env`.";
    postRun = mkOption {
      type = types.lines;
      default = "";
      description = "A shell snippet run after ${what} passes, after the package's `test.postRun` (see there).";
    };
  };

  testBinary = {
    imports = [ priorityOf ];
    options = runSettings "this test binary's run" // {
      enable = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether this binary's test run is part of `repo.checks` and the
          check groups; the binary is built either way. A more specific
          layer's value wins over the layers it refines
          ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)):
          `memberDefaults.test.binaries.<key>.enable = false` with `true`
          for a few packages runs only theirs. `null`: `true`.
        '';
      };
    };
  };

  doctest = {
    imports = [ priorityOf ];
    options = runSettings "the package's doctest run" // {
      enable = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Whether the package's doctest run is part of `repo.checks` and
          the check groups. A doctest compiles and runs in one rustdoc
          process, so with `false` the checks build nothing of it; it
          stays buildable as `doctests.<pkg>`. A more specific layer's
          value wins over the layers it refines
          ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)):
          `memberDefaults.test.doctest.enable = false` with `true` for a
          few packages runs only theirs. For a
          library whose manifest sets `doctest = false`, there is no
          doctest run to enable. `null`: `true`.
        '';
      };
    };
  };

  # Every setting but the per-triple and per-variant layers, which have
  # these same options.
  common = {
    key = "breakbulk/modules/package-settings.nix#common";
    _file = ./package-settings.nix;
    imports = [ priorityOf ];
    options = {
      env = bt.mkEnv ''
        Environment for every unit of this package, on both ${sides}
        (compiles and build-script runs). Values may be derivations,
        including the products of other packages, in this workspace or
        another, on any target; they are passed by reference, and only
        this package's units read them.
      '';
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
          ${pipeline}: added for every kind of unit.
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

          A function must take `...`. breakbulk passes one more argument,
          so that a function without `...` fails on its first use, not
          when breakbulk adds an argument. The error names an argument the
          function does not take; the extra one's name says to add `...`.

          The functions run after the built-in steps (the package
          directory, then `extraSources`, `test.sourceScope`,
          `test.scopeTestsDir` and `test.runFiles`), each on the result
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
        type = bt.stages;
        default = { };
        example = lib.literalExpression "{ noSourceReferences = null; }";
        description = ''
          Checks on this package's products, as `targets.<triple>.checks`.
          They are added to the target's checks and to the default checks
          (`noSourceReferences`, `buildScriptFiles`, `buildScriptPaths`). `null` removes a check
          from this package only.
        '';
      };

      test = {
        env = bt.mkEnv ''
          Environment for this package's test runs and doctests. They get
          a fresh, empty `HOME` in their temporary directory by default;
          `HOME = "/homeless-shelter"` makes a test that writes to its home
          fail, as compiles and build-script runs do.
        '';
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
            (`scopeTestsDir`). A built-in step of ${pipeline}.
          '';
        };
        scopeTestsDir = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Whether the package's `tests/` directory is test-only, as if
            listed in `sourceScope`: only the package's test units see it
            (integration tests, with or without the libtest harness,
            benches, examples, test harnesses, doctests and test runs), so
            a fixture edit there rebuilds no library, bin or product. Set
            it to `false` when the library, a bin or the build script
            reads from `tests/` at compile time
            (`include_str!("../tests/…")`, a build script that generates
            tests from fixtures); such a unit fails with a hint naming
            this option. `null`: `true`. A built-in step of ${pipeline}.
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
            `caDerivations` in
            [`repo.nixFeatures`](../outputs.md#nixfeatures) says whether
            `ca` is on.
          '';
        };
        stripForRun = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Run a copy of each test binary with its debug info (and build
            ID) stripped, content-addressed when `ca` is on. Workspace
            libraries keep real source paths in their debug info, so an
            edit to any file of such a library (a README) changes the bytes
            of every test binary that links it; the stripped copy does not
            change, and the test is not re-run. Backtraces still name
            functions, but not files and lines. The unstripped binary stays
            in `tests.<pkg>.<binary>` for debugging. `null`: off.
            `caDerivations` in
            [`repo.nixFeatures`](../outputs.md#nixfeatures) says whether
            `ca` is on.
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
            libtest arguments for every test binary of this package, and
            for its doctests: each is passed to `rustdoc --test` as
            `--test-args`, so `[ "--skip" "src/lib.rs - net" ]` skips a
            doctest by name. `test.binaries.<binary>.args` do not reach
            doctests.
          '';
        };
        includeIgnored = mkOption {
          type = types.bool;
          default = false;
          description = "Also run `#[ignore]` tests.";
        };
        postRun = mkOption {
          type = types.lines;
          default = "";
          example = ''cp -r "$nextestDir/ci" "$out/junit"'';
          description = ''
            A shell snippet run inside each passing test run and doctest
            run of this package, after the tests: `$log` is the run's raw
            output and `$out` the run's output directory, empty otherwise.
            With `test.runner = "nextest"`, `$nextestDir` is nextest's
            store (JUnit reports). The package's snippet runs first, then
            the binary's (`test.binaries.<binary>.postRun`) or the doctest
            run's (`test.doctest.postRun`), then `keepLog`'s. Whatever a
            snippet puts in `$out` decides whether the run is
            reproducible: breakbulk keeps `$out` empty so that `nix build
            --rebuild` of a passing run succeeds, and the output stays in
            the build log (`nix log`).
          '';
        };
        keepLog = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Keep each test run's and doctest run's raw output in
            `$out/log`, as a `postRun` of `cp "$log" "$out/log"`. For a
            binary cache that does not store build logs, or a CI that keeps
            them as artifacts. The output holds timings and, with more than
            one test thread, lines in a varying order, so such a run is
            not reproducible under `nix build --rebuild`. `null`: off.
          '';
        };
        binaries = mkOption {
          type = types.attrsOf (types.submodule testBinary);
          default = { };
          example = lib.literalExpression ''
            {
              net.args = [ "--skip" "needs_network" ];
              "lib/my_crate".env.RUST_LOG = "debug";
              "bin/my-tool".enable = false;
            }
          '';
          description = ''
            Settings for one test binary of this package, by its key (and
            the name of its check, `<ws>/<triple>/<pkg>/…`):

            - an integration test (`[[test]]`, `tests/cli.rs`): its name,
              `cli` (check `test-cli`);
            - the library's unit tests: `lib/` and the library's crate
              name, `lib/my_crate` (check `test-lib`);
            - a bin's unit tests: `bin/` and the bin's name, `bin/my-tool`
              (check `test-bin-my-tool`);
            - an example or bench with `test = true`: `example/<name>`,
              `bench/<name>` (check `test-example-<name>`,
              `test-bench-<name>`).

            A key that names no test binary of the package is an evaluation
            error listing the package's keys. The keys come from the
            package's manifest, so a test binary that only some targets or
            variants build (`required-features`) has its key on all of
            them. Under `memberDefaults`, a key must name a test binary of
            some member.
          '';
        };
        doctest = mkOption {
          type = types.submodule doctest;
          default = { };
          example = lib.literalExpression ''
            {
              enable = false;
            }
          '';
          description = ''
            Settings for the package's doctest run (`doctests.<pkg>`, check
            `<ws>/<triple>/<pkg>/doctest`), as `test.binaries.<key>` has
            for a test binary's.
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
            How this package's test binaries run: `libtest` (the binary
            itself, as `cargo test` runs it) or `nextest` (cargo-nextest's
            reuse-build mode over the one binary, with the project's
            nextest configuration: retries, timeouts, default filter, test
            groups). Each binary is still its own test run. `null`:
            `libtest`.
          '';
        };
        nextest = {
          profile = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "ci";
            description = "nextest profile for this package's test runs (`null`: `default`).";
          };
          configFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = lib.literalExpression "./.config/nextest.toml";
            description = ''
              nextest configuration file. `null`: the repository's
              `.config/nextest.toml` when it exists, else nextest's
              defaults.
            '';
          };
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "cargo-nextest to run with (`null`: the test platform's `cargo-nextest`).";
          };
        };
      };
    };
  };
  target = mkOption {
    type = types.attrsOf (types.submodule common);
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
      Settings for this package on one target triple, with every option
      of the package level (`env`, `forHost`, `forTarget`, `stages`,
      `test`, …). They apply to the plans for that triple, on top of the
      package-level settings of the same definition: `env` still means
      both ${sides} (the build-script compile of a plan for this triple
      included), `forTarget.env` the target side only.
    '';
  };

  # A variant's layer: every setting, and its own per-triple layer.
  variantLayer = {
    key = "breakbulk/modules/package-settings.nix#variant";
    _file = ./package-settings.nix;
    imports = [ common ];
    options = { inherit target; };
  };
in
{
  inherit common;

  # Keyed, so the module system imports it once wherever it is used.
  settings = {
    key = "breakbulk/modules/package-settings.nix#settings";
    _file = ./package-settings.nix;
    imports = [ common ];
    options = {
      inherit target;
      variant = mkOption {
        type = types.attrsOf (types.submodule variantLayer);
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
          (`workspaces.<ws>.variants.<v>`), with every option of the
          package level, `target.<triple>` included. They apply on top of
          the package-level settings and their `target.<triple>` layer of
          the same definition, and leave the units of other variants
          unchanged: a lint setting for a `clippy` variant does not
          rebuild the release variant. A variant layer's
          `target.<triple>` applies to that variant on that triple only.
          The layer applies in every workspace that has a variant of that
          name; a name that no workspace has is an evaluation warning.
        '';
      };
    };
  };
}
