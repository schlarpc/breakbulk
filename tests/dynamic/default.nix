# Dynamic-derivation mode against IFD mode, over the same fixtures.
# Needs Nix 2.36 (master) with `dynamic-derivations` and `ca-derivations`;
# tests/dynamic/run.sh runs it in a private store and compares the modes
# (`nix run .#test-dynamic`). This file only describes what to build.
#
#   mode = "ifd" | "dynamic"   (default: the evaluator's)
#   ca = null | true | false   (null: `ca`'s default)
#
# Attributes:
#   repos.<fixture>          the mkRepository results: most are the
#                            repositories of the IFD-mode tests
#                            (tests/products, tests/repository,
#                            tests/presets), with `mode` added
#   build.<fixture>          a derivation linking every product, test
#                            run, bench run and doctest of every
#                            workspace, target and variant (<i> is
#                            <ws>/<triple>/<variant>): products/<i>/<pkg>,
#                            runs/<i>/<pkg>/<binary>,
#                            runs/<i>/bench/<pkg>/<binary>,
#                            doctests/<i>/<pkg>, for the doc fixtures
#                            products/<i>/doc (the docs); in dynamic mode also
#                            units/<i>/<kind>, every unit of each plan),
#                            its repo.checks
#                            (checks/<name>), for test-control and
#                            test-wrapper `apps`, a run of test apps, for
#                            source-paths-dwo/-dwp `gdb`, gdb in a
#                            dependency through the product's debug
#                            output, and for the fixtures of
#                            `closureChecked`
#                            closures/<i>/<pkg>/<binary>/closure, each
#                            test run's input closure
#   unitDrvs.<fixture>       a JSON file: "<i>/<kind>" -> unit id (or
#                            `doctest:<pkg>`, or `docs`) -> .drv path (IFD
#                            mode)
#   nixFeatures.<fixture>    its repo.nixFeatures (run.sh builds
#                            `nixFeaturesFixtures` with exactly these)
#   explain.<fixture>        whether repo.explainSharing finds every unit
#                            of the first workspace's build plan shared
#                            with itself (it must)
#   outer.<fixture>."<i>/<kind>"   the outer derivations (dynamic mode)
#   mayDiffer.<fixture>      a regex of unit derivation names that may
#                            differ between the modes (embedding chains)
#   cutoff.<name>.{before,after}
#                            test runs before and after an edit that
#                            changes nothing the `kept` run reads (dynamic
#                            mode: run.sh checks it is not re-run)
#   checkVariant             (dynamic mode) a check variant's check of the
#                            walking skeleton: every unit of both plans,
#                            through the outer derivations' `units.drv`
#   declaredPaths            tests/repository's declared-paths test: the
#                            plans' `buildScriptPaths` checks fail naming
#                            the build-dependency's and the
#                            dev-dependency's paths, and pass with them
#                            allowed (run.sh builds it in dynamic mode)
#   unpredicted              roots-override with a `roots.build` that
#                            leaves out a root: a product whose plan has a
#                            root that was not predicted (run.sh checks
#                            that it fails)
#   prereqs.<fixture>, prereqs.tools
#                            the plans and breakbulk's tools: with the
#                            outputs upstream of the units, what run.sh
#                            copies into the private store, so that only
#                            breakbulk's own derivations are built there
{
  # nixpkgs and rust-overlay as the flake pins them (the preset fixtures
  # need rust-overlay's toolchains).
  pkgs ?
    let
      lock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes;
      fetch =
        n:
        fetchTarball {
          url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
          sha256 = n.narHash;
        };
    in
    import (fetch lock.nixpkgs.locked) {
      overlays = [ (import (fetch lock.rust-overlay.locked)) ];
    },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
  mode ? breakbulk.nixFeatures.defaultMode,
  ca ? null,
  # `cutoff`'s edit: a number other than 1, new on each run.sh run, so
  # that the edited fixtures and settings are new to the store.
  cutoffEdit ? "2",
}:
let
  inherit (pkgs) lib;
  mkWorkspace = import ../lib/workspace.nix { inherit lib breakbulk; };
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;

  mkRepo =
    fixture: modules:
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/${fixture}";
      modules = testArgs.extraModules ++ modules;
    };
  oneWs = {
    workspaces.main = {
      path = ".";
      variants.default.profile = "dev";
    };
  };

  # The repositories of the IFD-mode tests, in this mode.
  # Every workspace keeps its runs' output in `$out/log`: run.sh
  # compares the test outcomes of both modes from it.
  keepLogs = {
    options.workspaces = lib.mkOption {
      # As lib/modules/workspaces.nix declares it: the two must agree.
      type = lib.types.attrsOf (
        lib.types.submoduleWith {
          shorthandOnlyDefinesConfig = false;
          modules = [
            { config.memberDefaults.test.postRun = lib.mkDefault ''cp "$log" "$out/log"''; }
          ];
        }
      );
    };
  };
  testArgs = {
    inherit pkgs breakbulk;
    extraModules = [
      { inherit mode; }
      keepLogs
    ]
    ++ lib.optional (ca != null) { inherit ca; };
  };
  productTests = import ../products testArgs;
  products = productTests.repos;
  repository = (import ../repository testArgs).repos;
  presetFixtures =
    (import ../presets/fixtures.nix (
      testArgs
      // {
        # As the flake's: unfree admitted for the xwin SDK only.
        xwinPkgs = import pkgs.path {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfreePredicate = p: lib.getName p == "xwin-sdk";
        };
      }
    )).repos;
  extraTargets = (import ../presets/extra-targets.nix testArgs).repos;
  # As the flake's: Apple's SDK admitted, for these tests only.
  darwin = (import ../presets/darwin.nix testArgs).repo;
  buildStd = (import ../presets/build-std.nix testArgs).repos;
  nightly = pkgs.rust-bin.nightly.latest.minimal;

  # test-control's test configuration, as tests/test-runs uses it: a
  # per-binary skip list, test.env and test.path.
  ctlTest = {
    env.CTL_EXPECT_NIX = "1";
    path = [ pkgs.hello ];
    binaries.net.args = [
      "--skip"
      "needs_network"
    ];
  };

  directivesPackages = [
    "a-sys"
    "b-sys"
    "c"
    "pm"
    "hostdep"
    "app"
    "oldsyn"
  ];

  repos = {
    # Without a dev shell (whose Cargo env is read at evaluation time), so
    # that its dynamic mode imports nothing: run.sh builds it with
    # import from derivation off (`nixFeaturesFixtures`).
    walking-skeleton = mkRepo "walking-skeleton" [
      oneWs
      { workspaces.main.devShell.target = null; }
    ];
    # #23: a build script writes next to the binaries. The product takes
    # the file with the `buildScriptFiles` stage (read in dynamic mode from
    # the root's `breakbulk-root.json`), its check passes,
    # and the test run finds `<profile>` and `deps` on its library path.
    out-dir-walk = mkRepo "out-dir-walk" [
      oneWs
      {
        packages.out-dir-walk.stages.buildScriptFiles = {
          after = "splitDebug";
          before = "install";
          run = breakbulk.stages.helpers.buildScriptFiles { };
        };
      }
    ];
    # Every build script includes ../common/build_common.rs.
    directives = mkRepo "directives" [
      oneWs
      {
        packages = lib.genAttrs directivesPackages (_: {
          extraSources = [ "common" ];
        });
      }
    ];
    # The `host` workspace embeds the `payload` workspace's product, as in
    # tests/products (embed).
    embed =
      let
        repo = mkRepo "embed" [
          {
            workspaces = {
              payload = {
                path = "payload";
                variants.default.profile = "dev";
              };
              host = {
                path = "host";
                variants.default.profile = "dev";
              };
            };
            packages.embedder.env.PAYLOAD_BIN = "${repo.workspaces.payload.packages.payload}/bin/payload";
          }
        ];
      in
      repo;
    # The project's `[env]` (tests/loose-ends, config-env): the fixture's
    # tests assert the values, so its test runs check them in both modes.
    config-env = breakbulk.mkRepository {
      inherit pkgs tools;
      root = ../loose-ends/fixtures/config-env;
      modules = [
        { inherit mode; }
        keepLogs
        oneWs
        # As tests/loose-ends: the tests compare a source path the library
        # embedded at compile time with the test run's, one view for both.
        {
          packages.config-env = {
            scopeTargetRoots = false;
            test.scopeTestsDir = false;
          };
        }
      ];
    };
    # Doctests: a dev-dependency, should_panic, rustc-env and rustc-cfg
    # from a build script, an edition-2024 crate.
    doctests = mkRepo "doctests" [ oneWs ];
    # Skip lists, #[ignore], a skipped (required-features) test, the
    # runtime env; its test apps are `apps` in build.test-control.
    # With ca-derivations on (as here), IFD mode's test runs put
    # content-addressed copies of the build scripts' library directories on
    # the dynamic-library path (testRuns.stableSpec); the env
    # binary's dylib-path test accepts those copies.
    test-control = mkRepo "test-control" [
      oneWs
      { packages.ctl.test = ctlTest; }
    ];
    # Test runs of a debug-stripped copy (test.stages.strip) in
    # a narrowed working directory (test.runFiles); its tests
    # assert the working directory and CARGO_MANIFEST_DIR, and read only
    # listed files.
    test-options = breakbulk.mkRepository {
      inherit pkgs tools;
      root = ../test-options/fixture;
      modules = [
        { inherit mode; }
        keepLogs
        oneWs
        {
          workspaces.main.memberDefaults.test.stages.strip = {
            run = breakbulk.stageHelpers.strip { buildId = false; };
          };
          packages.app.test.runFiles = [
            "data"
            "notes.md"
          ];
        }
      ];
    };
    # "run" views without content addressing: app's under libtest, with
    # stripped copies (whose debug info would name app's whole view),
    # util's (only its package directory) under nextest, from the unit's
    # output. `closures` in build.<fixture> lists each run's input
    # closure; run.sh compares them between the modes.
    run-files-ca-off = breakbulk.mkRepository {
      inherit pkgs tools;
      root = ../test-options/fixture;
      modules = [
        {
          inherit mode;
          ca = false;
        }
        keepLogs
        oneWs
        {
          packages.app.test = {
            runFiles = [
              "data"
              "notes.md"
            ];
            stages.strip = {
              run = breakbulk.stageHelpers.strip { buildId = false; };
            };
          };
          packages.util.test = {
            runFiles = [ ];
            runner = "nextest";
          };
        }
      ];
    };
    # A product with a bin Cargo skips (required features): left out; the
    # `full` variant builds it.
    required-features = repository.rf;
    # A product whose only bin Cargo skips: in dynamic mode
    # it and its checks build to the no-binaries marker; IFD mode leaves it
    # out (run.sh accepts the difference only for marker outputs).
    all-required = mkRepo "all-required" [ oneWs ];
    # Split debug info: with `unpacked` the wrapper of app's root links its
    # own and its libraries' `.dwo` files into its `debug` directory, which
    # splitDebug packs into app.dwp; with `packed` rustc's app.dwp. gdb
    # reads both (`gdb` in build.<fixture>).
    source-paths-dwo = mkRepo "source-paths" [
      {
        workspaces.main = {
          path = ".";
          variants.default.profile = "unpacked";
        };
      }
    ];
    source-paths-dwp = mkRepo "source-paths" [
      {
        workspaces.main = {
          path = ".";
          variants.default.profile = "packed";
        };
      }
    ];
    # The tests/plan fixtures, planned as there (mkWorkspace's defaults).
    crate-types = mkRepo "crate-types" [ oneWs ];
    dev-dep-features = mkRepo "dev-dep-features" [ oneWs ];
    build-dep-leak = mkRepo "build-dep-leak" [ oneWs ];
    bin-exe-not-built = mkRepo "bin-exe-not-built" [ oneWs ];
    rlib-example = mkRepo "rlib-example" [ oneWs ];
    sys-native = mkRepo "sys-native" [
      oneWs
      {
        packages = {
          openssl-sys = {
            nativeInputs = p: [ p.pkg-config ];
            inputs = p: [ p.openssl ];
            env.BB_MARKER = "ssl";
          };
          cm-sys.nativeInputs = p: [ p.cmake ];
          bg-sys.nativeInputs = p: [ p.rustPlatform.bindgenHook ];
        };
      }
    ];
    # A package named `build` with a build script, in nightly Cargo's new
    # build-directory layout (`build/build/<hash>`).
    package-named-build = mkRepo "package-named-build" [
      oneWs
      {
        workspaces.main.toolchain = {
          rustc = nightly;
          cargo = nightly;
        };
      }
    ];
    # Nightly `resolver.feature-unification = "package"`.
    feature-unification = mkRepo "feature-unification" [
      oneWs
      {
        workspaces.main.toolchain = {
          rustc = nightly;
          cargo = nightly;
        };
      }
    ];
    # Check and clippy variants with clippy.toml files. Without
    # tests/products' `-D clippy::disallowed_methods` the disallowed calls
    # are warnings, so the clippy units build.
    clippy-conf = mkRepo "clippy-conf" [
      {
        workspaces.main = {
          path = "ws";
          variants = {
            default.profile = "dev";
            check.mode = "check";
            clippy.mode = "clippy";
          };
        };
      }
    ];
    # Clippy variants whose views hold the workspace root's `Cargo.toml`,
    # predicted for every member. `lint_groups_priority` is a warning here,
    # so `inherited`'s clippy units build.
    lint-groups-priority = mkRepo "lint-groups-priority" [
      {
        workspaces = lib.genAttrs [ "inherited" "own" ] (path: {
          inherit path;
          variants.clippy = {
            mode = "clippy";
            clippyArgs = [
              "-W"
              "clippy::lint_groups_priority"
            ];
          };
          memberDefaults.predictSources.enable = true;
        });
      }
    ];
    # A git source whose crates come from two inheriting workspaces, as
    # tests/git-multi-workspace builds it.
    git-multi-workspace = breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/git-multi-workspace/consumer";
      modules = [
        { inherit mode; }
        keepLogs
        oneWs
        { git."file:///build/gitdep".tree = fixtures + "/git-multi-workspace/repo"; }
      ];
    };
    git-revisions = (import ../git-revisions testArgs).repos.repository;
    # A rustflag and an env value naming a path in a `builtins.fetchGit`
    # tree, as tests/lazy-strings sets them.
    lazy-strings = (import ../lazy-strings testArgs).repo;
    # tests/test-cutoff's fixture, as its stable-inputs check builds it.
    test-cutoff = mkRepo "test-cutoff" [ oneWs ];

    # tests/repository
    multi-ws = repository.multiWs;
    outside-reads = repository.outside;
    own-view = repository.ownView;
    stamps = repository.stampsA;
    missing-input = repository.provided;
    # The plans' `buildScriptPaths` checks (in repo.checks) read the
    # runs' missing-paths.json through the outer derivations' `runs.drv`;
    # `declaredPaths` checks their failures.
    declared-paths = repository.declaredProvided;
    test-only = repository.testOnly;
    target-views = repository.targetViews;
    # Its predicted views: the outer derivation makes them, and the units
    # must come out as IFD mode's (builtins.path of the same trees).
    predict-sources = repository.predictSources;
    sources = repository.sources;
    # With the options its hints name, so that everything builds.
    view-hints = repository.viewHintsFixed;
    result-names = repository.resultNamesFixed;
    snapshots = repository.snapshots;
    pkgid-short = repository.pkgidShort;
    # With the setting its hint names.
    env-repository-path = repository.envRepoPathFixed;
    optional-dependency = repository.optionalDep;
    exclusive-features = repository.exclusive;
    # A selected path package outside the workspace, its roots predicted
    # from its own manifest: products, test runs and the doctest.
    # `unpredicted` is the same repository with a `roots.build` that
    # leaves one out.
    roots-override = repository.rootsPredicted;

    # tests/products
    post-link = products.postLink;
    source-paths = products.sourcePaths;
    trim-paths = products.trimPathsRepo;
    trim-paths-cc = products.trimCc;
    # tests/products' variants without `strict`'s `-D clippy::len_zero`,
    # whose clippy unit fails by design in both modes, and without
    # `release-tests`, whose lib-a test run fails by design (it needs
    # debug assertions; products-variants-test-profile compares units).
    variants = breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/variants";
      modules = productTests.modules.variants ++ [
        { inherit mode; }
        keepLogs
        {
          workspaces.main.variants = {
            strict.clippyArgs = lib.mkForce [ ];
            release-tests.targets = [ ];
          };
        }
      ];
    };
    variants-coverage = products.coverageRepo;
    # A toy rustc driver as rustc wrapper and as workspace wrapper, with
    # the side files it writes kept beside each crate file.
    variants-driver = products.driver;
    cargo-config = products.cargoConfigRepo;
    benches = products.benchesRepo;
    stdpaths = products.rustSrcRepo;
    cdylib-debug = products.cdylibDebug;
    # A product installs a header published as `links` metadata and a
    # file in another package's OUT_DIR, read at build time.
    build-script-outputs = products.buildScriptOutputs;
    # With removeSourceReferences, so that its noSourceReferences passes.
    manifest-dir = products.manifestDirRepo;
    # A product of another target of the same workspace in a package's
    # env.
    ui-dist = products.uiDistRepo;
    # `cargo doc`, as tests/products' docs check: members only (release),
    # and with dependencies (dev). Their docs are compared as products.
    docs = products.docsNoDeps;
    docs-deps = products.docsDeps;
    # Another repository's wasm product at a path in `assets`' views.
    source-overlay = products.sourceOverlayRepo;
    # Products of the same plan in a package's env and inputs, declared in
    # `productInputs`: the build plan has two outer derivations.
    same-workspace-products = products.sameWsRepo;
    # A build script that runs Cargo, with the workspace's vendor directory
    # as CARGO_HOME; without noSourceReferences, which fails on its product
    # by design.
    nested-cargo = breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/nested-cargo";
      modules = productTests.modules.nestedCargo ++ [
        { inherit mode; }
        keepLogs
        { packages.outer.checks.noSourceReferences = null; }
      ];
    };
    # A `rustc_private` test binary, which finds librustc_driver through
    # its RUNPATH.
    rustc-private = products.rustcPrivate;

    # tests/presets
    same-triple = presetFixtures.sameTriple;
    static-musl = presetFixtures.musl;
    static-glibc = presetFixtures.glibcStatic;
    static-glibc-nonpie = presetFixtures.glibcNonPie;
    static-glibc-nonpie-nixpkgs = presetFixtures.glibcNonPieNixpkgs;
    linker-kind-mold = presetFixtures.moldKind;
    static-pkgconfig = presetFixtures.staticPkgconfig;
    sys-native-aarch64 = presetFixtures.sysNativeCross;
    cross-doctests-aarch64 = presetFixtures.crossDoctests;
    cross-lto = presetFixtures.crossLto;
    cross-lto-off = presetFixtures.crossLtoOff;
    wasm-browser = presetFixtures.wasmBrowser;
    wasm-component = presetFixtures.wasmComponent;
    msvc = presetFixtures.msvc;
    msvc-post-link = presetFixtures.msvcPostLink;
    wasip2 = extraTargets.wasip2Repo;
    riscv64 = extraTargets.riscv64Repo;
    windows-gnu = extraTargets.windowsGnuRepo;
    windows-gnullvm-aarch64 = extraTargets.windowsGnullvmA64Repo;
    uefi = extraTargets.uefiRepo;
    darwin = darwin;
    # Only the staged repository: the other's buildScriptFiles check fails
    # by design in both modes (the DLL beside the .exe is not staged).
    windows-dll-staged = extraTargets.windowsDllStagedRepo;
    linux-portable = extraTargets.zigRepo;
    linux-portable-native = extraTargets.zigNativeRepo;
    # Without the test plan: x86_64-unknown-none has no `test` crate, so its
    # test binaries do not compile (build-std-tests checks the plan's
    # instantiation only).
    build-std =
      (import ../presets/build-std.nix (
        testArgs
        // {
          extraModules = testArgs.extraModules ++ [
            { workspaces.main.targets.x86_64-unknown-none.variantDefaults.tests = false; }
          ];
        }
      )).repos.bare;
    build-std-deps = buildStd.hosted;

    # tests/test-runs' test-threads: RUST_TEST_THREADS from `test.env`,
    # `test.binaries.<bin>.env` and `[env]` wins over the default, under
    # libtest and nextest.
    test-threads = (import ../test-runs testArgs).repos.test-threads;
    # tests/test-runs' home: a test and a doctest writing under $HOME and
    # the user cache directory pass with no setting.
    test-home = (import ../test-runs testArgs).repos.home;
    # tests/test-runs' test-closure: a test run takes only the build-script
    # runs below it; a test starting its package's bin finds the library
    # the build script built.
    test-closure = (import ../test-runs testArgs).repos.test-closure;
    # tests/test-runs' test-wrapper: wrappers.cargoTargetLayout moves the
    # test binary under target/debug/deps, where it finds the repository;
    # its test app is `apps` in build.test-wrapper.
    test-wrapper = (import ../test-runs testArgs).repos.test-wrapper;
    # Doctests as plain `cargo test` selects them (`doctest = false`).
    doctest-false = mkRepo "doctest-false" [ oneWs ];
    # nextest runs, from the metadata the wrappers carry in dynamic mode.
    nextest = mkRepo "nextest" [
      oneWs
      {
        packages.nx.test = {
          runner = "nextest";
          nextest.profile = "ci";
          env.NX_FROM_TEST_ENV = "yes";
          env.NX_EXPECT_NIX = "1";
        };
        packages.other.test.runner = "nextest";
        # The ci profile's `binary()` and `rdeps()` overrides need the
        # targets and dependency edges in the synthesized metadata.
        packages.solo.test = {
          runner = "nextest";
          nextest.profile = "ci";
        };
      }
    ];
  };

  # Test apps run outside a test run (as tests/test-runs `test-control-app`):
  # the network binary with the skipped test filtered out, and the env
  # binary against a checkout of the fixture (mkWorkspace, for `checkout`).
  ctlApps =
    let
      mkCtl =
        args:
        mkWorkspace pkgs (
          {
            root = fixtures + "/test-control";
            inherit tools;
            name = "test-control";
            delivery = breakbulk.dynamic.checkMode mode;
            packages.ctl.test = ctlTest;
          }
          // args
        );
      ws = mkCtl { };
      wsCheckout = mkCtl { checkout = "/build/checkout"; };
      # What `nix run` runs for a derivation.
      program = drv: "${drv.outPath}/bin/${drv.meta.mainProgram}";
    in
    pkgs.runCommand "test-control-apps-${mode}"
      {
        net = program ws.testApps.ctl.net;
        envApp = program wsCheckout.testApps.ctl.env;
        skipped = program ws.testApps.ctl.needs_feat;
      }
      ''
        $net --skip needs_network | tee net.log
        grep -q 'test offline_ok ... ok' net.log
        cp -r --no-preserve=mode ${fixtures + "/test-control"} /build/checkout
        export NIX_BUILD_CORES RUST_TEST_THREADS=$NIX_BUILD_CORES
        # The tests print what they got (grepped below). --show-output
        # prints it after the results, per test: with --nocapture it could
        # land inside another test's `test … ok` line, which the outcome
        # comparison reads.
        $envApp --show-output | tee env.log
        grep -q 'CARGO_MANIFEST_DIR=/build/checkout$' env.log
        # The binary uses CARGO_TARGET_TMPDIR: a private working directory of
        # links to the checkout's package directory, removed on exit. Two
        # runs at once each get their own.
        grep -q 'cwd=/build/breakbulk-run\.' env.log
        grep -q 'test result: ok. 5 passed' env.log
        $envApp --exact target_tmpdir_is_writable > a.log &
        $envApp --exact target_tmpdir_is_writable > b.log &
        wait %1
        wait %2
        grep -q 'test target_tmpdir_is_writable ... ok' a.log
        grep -q 'test target_tmpdir_is_writable ... ok' b.log
        if [ -n "$(find /build -maxdepth 1 -name 'breakbulk-run.*')" ]; then
          echo "a test app left its working directory behind" >&2
          exit 1
        fi
        if $skipped 2> skipped.log; then
          echo "the app of a skipped test succeeded" >&2
          exit 1
        fi
        cat skipped.log
        grep -q 'needs_feat. was skipped' skipped.log
        mkdir -p $out
        grep -h '^test .* \.\.\. ' net.log env.log | sort > $out/tests
      '';

  # The test-wrapper fixture's integration test as a test app, under
  # wrappers.cargoTargetLayout and in its private working directory.
  wrapperApps =
    repo:
    pkgs.runCommand "test-wrapper-apps-${mode}"
      { app = repo.apps."main/${native}/locate/test-locate".program; }
      ''
        $app | tee app.log
        grep -q 'test result: ok. 3 passed' app.log
        mkdir -p $out
        grep -h '^test .* \.\.\. ' app.log | sort > $out/tests
      '';

  # gdb on the source-paths product with only its debug output's
  # lib/debug as debug-file-directory, as tests/products' gdbCheck: a
  # breakpoint in the dependency `dep` with its argument (which only the
  # DWARF objects hold, so it needs the .dwp), dep's and app's files and
  # lines, and dep's source.
  gdbCheck =
    name: repo:
    let
      app = repo.workspaces.main.packages.app;
    in
    pkgs.runCommand "${name}-gdb-${mode}"
      {
        nativeBuildInputs = [
          pkgs.gdb
          pkgs.binutils-unwrapped
        ];
        inherit app;
        debug = app.debug;
      }
      ''
        set -euo pipefail
        id=$(readelf -n $app/bin/app | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
        test -f $debug/lib/debug/.build-id/''${id:0:2}/app.dwp
        readelf -S -W $debug/lib/debug/.build-id/''${id:0:2}/app.dwp | grep -q '\.debug_info\.dwo'
        test -z "$(find $debug -name '*.dwo')"
        gdb -batch -nx -iex "set debug-file-directory $debug/lib/debug" \
          -ex 'break dep::boom' -ex run -ex bt -ex 'frame 0' -ex list \
          $app/bin/app > gdb.txt 2>&1 || true
        cat gdb.txt
        grep -E '^#0 +dep::boom \(n=7\) at dep/src/lib.rs:1[0-9]$' gdb.txt
        grep -E '^#[1-9] .*app::main.* at app/src/main.rs:[0-9]+$' gdb.txt
        grep -qF 'panic!("boom {n}");' gdb.txt
        mkdir -p $out
        cp gdb.txt $out/
      '';
  gdbChecked = [
    "source-paths-dwo"
    "source-paths-dwp"
  ];

  # Fixtures whose test runs' input closures `closures/` in build.<fixture>
  # lists, with, per package, a file (relative to a source view's root)
  # that a path of each of its runs' closures must hold (`present`) and
  # one that none may (`absent`), or null.
  closureChecked = {
    run-files-ca-off = {
      # The "run" view, not the package's whole view.
      app = {
        present = "app/data/input.txt";
        absent = "app/src/lib.rs";
      };
      # Its "run" view holds only its (empty) package directory: nextest's
      # metadata names no other path of the whole view.
      util = {
        present = "util";
        absent = "util/src/lib.rs";
      };
    };
  };
  # A test run's input closure, as its sandbox's store holds it: a
  # derivation with every attribute of the run, as one string with their
  # context (so with the same inputs), lists /nix/store in its own sandbox
  # into `$out/closure`.
  closureOf =
    guard: key: run:
    pkgs.runCommand "closure-${lib.replaceStrings [ "/" ] [ "-" ] key}-${mode}"
      {
        runAttrs = builtins.toJSON run.drvAttrs;
      }
      ''
        if [ -e /nix/var/nix ]; then
          echo "listing a closure needs the sandbox" >&2
          exit 1
        fi
        for p in /nix/store/*; do echo "$p"; done > $TMPDIR/closure
        ${lib.optionalString (guard != null) ''
          present=
          while IFS= read -r p; do
            if [ -e "$p/${guard.absent}" ]; then
              echo "$p, in the closure of ${key}, holds ${guard.absent}" >&2
              exit 1
            fi
            [ ! -e "$p/${guard.present}" ] || present=$p
          done < $TMPDIR/closure
          if [ -z "$present" ]; then
            echo "nothing in the closure of ${key} holds ${guard.present}" >&2
            exit 1
          fi
        ''}
        mkdir $out
        cp $TMPDIR/closure $out/closure
      '';

  # Products differ between the modes (resolved at build time in dynamic
  # mode), so the units downstream of an embedded product do too: the
  # embedder and, through it, the host. Every other unit is identical.
  mayDiffer = {
    embed = "^(embedder|host)-";
    # `app`'s env names the wasm target's `ui`.
    ui-dist = "^app-";
    # `assets`' views link the product; `server` links `assets`.
    source-overlay = "^(assets|server)-";
    # `app`'s env and inputs name `tool`'s and `shared`'s products.
    same-workspace-products = "^app-";
  };

  # The fixtures whose doc plans are compared: every variant of them gets
  # one; the other fixtures' are never planned.
  docFixtures = [
    "docs"
    "docs-deps"
  ];

  # Every workspace, target and variant of the repository of fixture
  # `name`: `key` is `<ws>/<triple>/<variant>`, `inst` the mkWorkspace
  # result, `out` the repository's outputs for it (products, selected test
  # runs, ...), `kinds` its planned plan kinds (build, test, bench, and doc
  # for docFixtures).
  instancesOf =
    name: repo:
    lib.concatLists (
      lib.mapAttrsToList (
        wsName: w:
        lib.concatLists (
          lib.mapAttrsToList (
            triple: vs:
            lib.mapAttrsToList (
              v: inst:
              let
                out = w.target.${triple}.variants.${v};
                # The plans the variant traces: the test plan unless it
                # has `tests = false`, the build plan unless it has
                # `products = false` (each has its `buildScriptPaths`).
                traced = lib.attrNames out.buildScriptPaths;
              in
              {
                key = "${wsName}/${triple}/${v}";
                inherit triple inst out;
                inherit (w.target.${triple}) canRunTests;
                kinds = lib.filter (
                  k:
                  (
                    !(lib.elem k [
                      "build"
                      "test"
                    ])
                    || lib.elem k traced
                  )
                  && (k != "doc" || lib.elem name docFixtures)
                ) (lib.attrNames inst.units);
              }
            ) vs
          ) w.instances
        )
      ) repo.workspaces
    );

  linkEach =
    dir: attrs:
    lib.concatStrings (
      lib.mapAttrsToList (n: d: ''
        mkdir -p "$(dirname "${dir}/${n}")"
        ln -s ${d} "${dir}/${n}"
      '') attrs
    );
  # { pkg = { binary = run; }; } as { "pkg/binary" = run; }.
  flat2 = lib.concatMapAttrs (p: lib.mapAttrs' (b: lib.nameValuePair "${p}/${b}"));

  # Targets with no runner (`canRunTests = false`) have no test runs or
  # doctests in repo.checks; their test binaries are compared as products
  # (`test-<pkg>-<name>`) instead of run.
  build =
    name: repo:
    pkgs.runCommand "${name}-${mode}" { } (
      lib.concatMapStrings (
        i:
        ''
          mkdir -p $out/products/${i.key} $out/runs/${i.key}
        ''
        # Dynamic mode: every outer derivation runs (run.sh reads their
        # logs), also for a plan no product or test run needs.
        + linkEach "$out/units/${i.key}" (
          lib.filterAttrs (k: _: lib.elem k i.kinds) (i.inst.allUnits or { })
        )
        + linkEach "$out/products/${i.key}" (
          i.out.packages
          # The docs, compared as a product.
          // lib.optionalAttrs (lib.elem "doc" i.kinds) { doc = i.out.docs; }
        )
        + (
          if i.canRunTests then
            linkEach "$out/runs/${i.key}" (flat2 i.out.testRuns)
            + linkEach "$out/runs/${i.key}/bench" (flat2 (i.out.benchRuns or { }))
            + linkEach "$out/doctests/${i.key}" i.out.doctests
            + lib.optionalString (closureChecked ? ${name}) (
              linkEach "$out/closures/${i.key}" (
                lib.mapAttrs (
                  k: run:
                  closureOf (closureChecked.${name}.${lib.head (lib.splitString "/" k)} or null) "${i.key}/${k}" run
                ) (flat2 i.out.testRuns)
              )
            )
          else
            linkEach "$out/products/${i.key}" (
              lib.mapAttrs' (n: d: lib.nameValuePair "test-${lib.replaceStrings [ "/" ] [ "-" ] n}" d) (
                flat2 i.out.tests
              )
            )
        )
      ) (instancesOf name repo)
      # repo.checks (what `nix flake check` builds), every one.
      + ''
        mkdir -p $out/checks
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (n: d: ''
          ln -s ${d} "$out/checks/${lib.replaceStrings [ "/" ] [ "-" ] n}"
        '') repo.checks
      )
      + lib.optionalString (name == "test-control") ''
        ln -s ${ctlApps} $out/apps
      ''
      + lib.optionalString (name == "test-wrapper") ''
        ln -s ${wrapperApps repo} $out/apps
      ''
      + lib.optionalString (lib.elem name gdbChecked) ''
        ln -s ${gdbCheck name repo} $out/gdb
      ''
    );

  discard = builtins.unsafeDiscardStringContext;

  unitDrvs =
    name: repo:
    pkgs.writeText "unit-drvs.json" (
      builtins.toJSON (
        lib.listToAttrs (
          lib.concatMap (
            i:
            map (
              kind:
              lib.nameValuePair "${i.key}/${kind}" (
                lib.mapAttrs (_: u: discard u.drvPath) (
                  i.inst.units.${kind}
                  # The test plan's outer derivation also writes the doctests.
                  // lib.optionalAttrs (kind == "test") (
                    lib.mapAttrs' (p: d: lib.nameValuePair "doctest:${p}" d) i.inst.doctestDrvs
                  )
                  # The doc plan's, its docs derivation.
                  // lib.optionalAttrs (kind == "doc") { docs = i.inst.docsDrv; }
                )
              )
            ) i.kinds
          ) (instancesOf name repo)
        )
      )
    );

  # A check variant next to the default one: `variants.lint.check` builds
  # every unit of both plans; in dynamic mode through `units.drv`.
  lintRepo = mkRepo "walking-skeleton" [
    oneWs
    {
      workspaces.main.variants.lint = {
        profile = "dev";
        mode = "check";
      };
    }
  ];

  # What instantiation needs that no unit or product depends on: the
  # plans (read at evaluation time in IFD mode, an input of the outer
  # derivation in dynamic mode) and breakbulk's tools. run.sh copies these
  # and every output upstream of the units into the private store. Per
  # fixture, so that a run plans only the fixtures it compares.
  plansOf =
    name: repos':
    lib.concatMap (
      repo:
      lib.concatMap (
        i: map toString (lib.attrValues (lib.filterAttrs (k: _: lib.elem k i.kinds) i.inst.plans))
      ) (instancesOf name repo)
    ) repos';
  prereqs =
    lib.mapAttrs (
      name: repo:
      pkgs.writeText "dynamic-prereqs-${name}" (
        lib.concatStringsSep "\n" (
          plansOf name (
            [ repo ]
            ++ lib.optional (name == "walking-skeleton") lintRepo
            ++ lib.optional (name == "declared-paths") repository.declaredMissing
          )
          # The git repository lazy-strings fetches during evaluation.
          ++ lib.optional (name == "lazy-strings") (
            toString (import ../git-multi-workspace { inherit pkgs breakbulk; }).repo
          )
        )
      )
    ) repos
    // {
      tools = pkgs.writeText "dynamic-prereqs-tools" (
        lib.concatStringsSep "\n" (
          map toString (
            lib.attrValues tools
            ++ [
              pkgs.bash
              pkgs.coreutils
              pkgs.jq
            ]
          )
        )
      );
    };

  # Content-addressed cutoff of test runs, as tests/test-cutoff and
  # tests/test-options check it in IFD mode: `cutoff.<name>.{before,after}`
  # are test runs before and after an edit (`cutoffEdit`) that changes
  # nothing the `kept` run reads; run.sh builds `after` after `before` and
  # checks `kept` is not re-run.
  #   test-cutoff    BETA_SUB in beta's env, which decides only what
  #                  beta's build script writes into a subdirectory of its
  #                  OUT_DIR: the run is re-run and alpha's test binary
  #                  relinked, so alpha's test (`kept`) gets new
  #                  input-addressed paths with the same contents
  #   test-cutoff-source
  #                  the body of a function in beta's source that alpha's
  #                  test never calls, moved down: alpha's test binary
  #                  changes (beta's debug info), the debug-stripped copy
  #                  its run executes by default with `ca` does not
  #   test-options   util's README and app's notes.md, with
  #                  test.stages.strip and test.runFiles = [ "data" ] as in
  #                  tests/test-options: app's test binary changes (util's
  #                  debug info), its stripped copy does not
  cutoff =
    let
      edited =
        tag: src: script:
        let
          drv = pkgs.runCommand "dynamic-cutoff-${tag}-${cutoffEdit}" { } ''
            cp -r --no-preserve=mode ${src} $out
            cd $out
            ${script}
          '';
        in
        builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);
      runsOf =
        root: modules:
        (breakbulk.mkRepository {
          inherit pkgs tools root;
          modules = [
            { inherit mode; }
            oneWs
          ]
          ++ modules;
        }).workspaces.main.instances.${native}.default.testRuns;
      cutoffRuns = sub: {
        kept = (runsOf cutoffFixture [ { packages.beta.env.BETA_SUB = sub; } ]).alpha."lib/alpha";
      };
      options = [
        {
          workspaces.main.memberDefaults.test.stages.strip = {
            run = breakbulk.stageHelpers.strip { buildId = false; };
          };
          packages.app.test.runFiles = [ "data" ];
        }
      ];
      optionsRuns = root: { kept = (runsOf root options).app.data; };
      cutoffFixture = fixtures + "/test-cutoff";
      optionsFixture = ../test-options/fixture;
    in
    {
      test-cutoff = {
        before = cutoffRuns "1";
        after = cutoffRuns cutoffEdit;
      };
      test-cutoff-source = {
        before = cutoffRuns "1";
        after.kept =
          (runsOf (edited "test-cutoff-source" cutoffFixture ''
            sed -i -e 's/^    2$/    \/\/ edit ${cutoffEdit}\n    3/' -e 's/^pub fn unused/\npub fn unused/' beta/src/lib.rs
            grep -q 'edit ${cutoffEdit}' beta/src/lib.rs
          '') [ { packages.beta.env.BETA_SUB = "1"; } ]).alpha."lib/alpha";
      };
      test-options = {
        before = optionsRuns optionsFixture;
        after = optionsRuns (
          edited "test-options" optionsFixture ''
            echo 'More words ${cutoffEdit}.' >> util/README.md
            echo 'More notes ${cutoffEdit}.' >> app/notes.md
          ''
        );
      };
    };
in
{
  inherit
    repos
    prereqs
    mayDiffer
    cutoff
    ;
  build = lib.mapAttrs build repos;
  nixFeatures = lib.mapAttrs (_: r: r.nixFeatures) repos;
  unitDrvs = lib.mapAttrs unitDrvs repos;
  outer = lib.mapAttrs (
    name: repo:
    lib.listToAttrs (
      lib.concatMap (i: map (kind: lib.nameValuePair "${i.key}/${kind}" i.inst.outer.${kind}) i.kinds) (
        instancesOf name repo
      )
    )
  ) repos;
  checkVariant = lintRepo.workspaces.main.target.${native}.variants.lint.check;
  unpredicted = repository.rootsMissing.workspaces.main.packages.app;
  declaredPaths = repository.declaredPathsTest;
  explain = lib.mapAttrs (
    name: repo:
    let
      # The first instance (`<ws>/<triple>/<variant>`): a workspace may
      # have no native target.
      i = (lib.head (instancesOf name repo)).key;
    in
    (repo.explainSharing {
      a = i;
      b = i;
    }).shared
  ) repos;
}
