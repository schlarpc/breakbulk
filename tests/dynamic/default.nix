# Dynamic-derivation mode against IFD mode, over the same fixtures.
# Needs Nix 2.36 (master) with `dynamic-derivations` and `ca-derivations`;
# tests/dynamic/run.sh runs it in a private store and compares the modes
# (`nix run .#test-dynamic`). This file only describes what to build.
#
#   mode = "ifd" | "dynamic"
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
#                            (checks/<name>), for test-control `apps`,
#                            a run of its test apps, for
#                            source-paths-dwo/-dwp `gdb`, gdb in a
#                            dependency through the product's debug
#                            output, and for the fixtures of
#                            `closureChecked`
#                            closures/<i>/<pkg>/<binary>/closure, each
#                            test run's input closure
#   unitDrvs.<fixture>       a JSON file: "<i>/<kind>" -> unit id (or
#                            `doctest:<pkg>`, or `docs`) -> .drv path (IFD
#                            mode)
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
#   unpredicted              roots-override without its `roots` option:
#                            a product whose plan has a root that was not
#                            predicted (run.sh checks that it fails)
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
  mode ? "auto",
  # `cutoff`'s edit: a number other than 1, new on each run.sh run, so
  # that the edited fixtures and settings are new to the store.
  cutoffEdit ? "2",
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs // {
    breakbulk-drv = breakbulk.dynamic.mkBreakbulkDrv pkgs;
  };

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
  # Every workspace keeps its runs' output (`test.keepLog`): run.sh
  # compares the test outcomes of both modes from it.
  keepLogs = {
    options.workspaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          config.memberDefaults.test.keepLog = lib.mkDefault true;
        }
      );
    };
  };
  testArgs = {
    inherit pkgs breakbulk;
    extraModules = [
      { inherit mode; }
      keepLogs
    ];
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
    walking-skeleton = mkRepo "walking-skeleton" [ oneWs ];
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
        { packages.config-env.test.scopeTestsDir = false; }
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
    # Test runs of a debug-stripped copy (test.stripForRun) in
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
          workspaces.main.memberDefaults.test.stripForRun = true;
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
            stripForRun = true;
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
    # A git source whose crates come from two inheriting workspaces, as
    # tests/git-multi-workspace builds it.
    git-multi-workspace = breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/git-multi-workspace/consumer";
      modules = [
        { inherit mode; }
        keepLogs
        oneWs
        { gitTrees."file:///build/gitdep" = fixtures + "/git-multi-workspace/repo"; }
      ];
    };
    git-revisions = (import ../git-revisions testArgs).repos.repository;
    # tests/test-cutoff's fixture, as its stable-inputs check builds it.
    test-cutoff = mkRepo "test-cutoff" [ oneWs ];

    # tests/repository
    multi-ws = repository.multiWs;
    outside-reads = repository.outside;
    own-view = repository.ownView;
    stamps = repository.stampsA;
    missing-input = repository.provided;
    # The `buildScriptPaths` check reads the runs' missing-paths.json
    # through the roots' breakbulk-root.json; `allowedListed` fails unless
    # it found dep's path.
    declared-paths = repository.declaredProvided;
    test-only = repository.testOnly;
    sources = repository.sources;
    # With the options its hints name, so that everything builds.
    view-hints = repository.viewHintsFixed;
    pkgid-short = repository.pkgidShort;
    optional-dependency = repository.optionalDep;
    exclusive-features = repository.exclusive;
    # Roots the prediction misses (a selected path package outside the
    # workspace), listed in `roots`: products, test runs and the doctest.
    # `unpredicted` is the same repository without `roots`.
    roots-override = repository.rootsOverride;

    # tests/products
    post-link = products.postLink;
    source-paths = products.sourcePaths;
    trim-paths = products.trimPathsRepo;
    trim-paths-cc = products.trimCc;
    # tests/products' variants without `strict`'s `-D clippy::len_zero`,
    # whose clippy unit fails by design in both modes, and without the
    # coverage variant: nixpkgs' rustc builds instrumented binaries that
    # crash at exit (variants-coverage has it on rust-overlay's rustc).
    # Nor `release-tests`, whose lib-a test run fails by design (it needs
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
            coverage.targets = [ ];
            release-tests.targets = [ ];
          };
        }
      ];
    };
    variants-coverage = products.coverageRepo;
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
    # Products of the same plan in a package's env and inputs: an infinite
    # recursion in dynamic mode (#126), so not in run.sh's default list.
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
            { workspaces.main.targets.x86_64-unknown-none.tests = false; }
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

  isDynamic = breakbulk.dynamic.resolveMode mode == "dynamic";

  # Test apps run outside a test run (as tests/test-runs `test-control-app`):
  # the network binary with the skipped test filtered out, and the env
  # binary against a checkout of the fixture (mkWorkspace, for `checkout`).
  ctlApps =
    let
      mkCtl =
        args:
        breakbulk.mkWorkspace pkgs (
          {
            root = fixtures + "/test-control";
            inherit tools;
            name = "test-control";
            delivery = breakbulk.dynamic.resolveMode mode;
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
      (
        {
          net = program ws.testApps.ctl.net;
          envApp = program wsCheckout.testApps.ctl.env;
        }
        # IFD mode has no app for a test binary Cargo did not build.
        // lib.optionalAttrs isDynamic { skipped = program ws.testApps.ctl.needs_feat; }
      )
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
        grep -q 'cwd=/build/checkout$' env.log
        grep -q 'test result: ok. 4 passed' env.log
        ${lib.optionalString isDynamic ''
          if $skipped 2> skipped.log; then
            echo "the app of a skipped test succeeded" >&2
            exit 1
          fi
          cat skipped.log
          grep -q 'needs_feat. was skipped' skipped.log
        ''}
        mkdir -p $out
        grep -h '^test .* \.\.\. ' net.log env.log | sort > $out/tests
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
      # nextest's metadata, and the unit's debug info, name the whole
      # view, in both modes.
      util = null;
    };
  };
  # A test run's input closure, as its sandbox's store holds it: a
  # derivation with every attribute of the run, as one string with their
  # context (so with the same inputs), lists /nix/store in its own sandbox
  # into `$out/closure`. In dynamic mode `$out/tools` lists the closure
  # of the jq the run reads its spec with at build time (IFD mode's reads
  # it at evaluation time), which run.sh lets only dynamic mode have.
  closureOf =
    guard: key: run:
    pkgs.runCommand "closure-${lib.replaceStrings [ "/" ] [ "-" ] key}-${mode}"
      (
        { runAttrs = builtins.toJSON run.drvAttrs; }
        // lib.optionalAttrs isDynamic {
          exportReferencesGraph = [
            "tools"
            pkgs.jq
          ];
        }
      )
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
        ${lib.optionalString isDynamic ''
          grep '^/nix/store/' "$NIX_BUILD_TOP/tools" | grep -v '\.drv$' | sort -u > $out/tools
        ''}
      '';

  # Products differ between the modes (resolved at build time in dynamic
  # mode), so the units downstream of an embedded product do too: the
  # embedder and, through it, the host. Every other unit is identical.
  mayDiffer = {
    embed = "^(embedder|host)-";
    # `app`'s env names the wasm target's `ui`.
    ui-dist = "^app-";
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
                # The test plan, unless a check variant checks the build
                # plan only, or the target has no tests
                # (`workspaces.<ws>.targets.<t>.tests = false`, which
                # leaves the variant no test binaries or doctests).
                testPlan =
                  if out ? check then
                    repo.config.workspaces.${wsName}.variants.${v}.allTargets
                  else
                    out.tests != { } || out.doctests != { };
              in
              {
                key = "${wsName}/${triple}/${v}";
                inherit triple inst out;
                inherit (w.target.${triple}) canRunTests;
                kinds = lib.filter (k: (k != "test" || testPlan) && (k != "doc" || lib.elem name docFixtures)) (
                  lib.attrNames inst.units
                );
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
          lib.filterAttrs (_: d: lib.length d.unbuilt < lib.length (lib.attrNames d.roots)) i.out.packages
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
                    lib.mapAttrs' (p: d: lib.nameValuePair "doctest:${p}" d) i.inst.doctests
                  )
                  # The doc plan's, its docs derivation.
                  // lib.optionalAttrs (kind == "doc") { docs = i.inst.docs; }
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
        lib.concatStringsSep "\n" (plansOf name ([ repo ] ++ lib.optional (name == "walking-skeleton") lintRepo))
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
  #   test-options   util's README and app's notes.md, with
  #                  test.stripForRun and test.runFiles = [ "data" ] as in
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
          workspaces.main.memberDefaults.test.stripForRun = true;
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
  unpredicted = repository.rootsPredicted.workspaces.main.packages.app;
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
