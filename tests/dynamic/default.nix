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
#                            doctests/<i>/<pkg>; in dynamic mode also
#                            units/<i>/<kind>, every unit of each plan),
#                            its repo.checks
#                            (checks/<name>), for test-control `apps`,
#                            a run of its test apps, and for
#                            source-paths-dwo/-dwp `gdb`, gdb in a
#                            dependency through the product's debug output
#   unitDrvs.<fixture>       a JSON file: "<i>/<kind>" -> unit id (or
#                            `doctest:<pkg>`) -> .drv path (IFD mode)
#   explain.<fixture>        whether repo.explainSharing finds every unit
#                            of the first workspace's build plan shared
#                            with itself (it must)
#   outer.<fixture>."<i>/<kind>"   the outer derivations (dynamic mode)
#   mayDiffer.<fixture>      a regex of unit derivation names that may
#                            differ between the modes (embedding chains)
#   checkVariant             (dynamic mode) a check variant's check of the
#                            walking skeleton: every unit of both plans,
#                            through the outer derivations' `units.drv`
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
      modules = [ { inherit mode; } ] ++ modules;
    };
  oneWs = {
    workspaces.main = {
      path = ".";
      variants.default.profile = "dev";
    };
  };

  # The repositories of the IFD-mode tests, in this mode.
  testArgs = {
    inherit pkgs breakbulk;
    extraModules = [ { inherit mode; } ];
  };
  products = (import ../products testArgs).repos;
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
        oneWs
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
    crate-types = mkRepo "crate-types" [
      oneWs
      # The staticlib keeps its objects' debug info, which names the source
      # view (splitDebug splits linked files only): the check fails in both
      # modes.
      { packages.stat.checks.noSourceReferences = null; }
    ];
    dev-dep-features = mkRepo "dev-dep-features" [ oneWs ];
    build-dep-leak = mkRepo "build-dep-leak" [ oneWs ];
    bin-exe-not-built = mkRepo "bin-exe-not-built" [ oneWs ];
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
    stamps = repository.stampsA;
    missing-input = repository.provided;
    test-only = repository.testOnly;
    pkgid-short = repository.pkgidShort;

    # tests/products
    post-link = products.postLink;
    source-paths = products.sourcePaths;
    trim-paths = products.trimPathsRepo;
    trim-paths-cc = products.trimCc;
    variants = products.variantsRepo;
    benches = products.benchesRepo;
    stdpaths = products.rustSrcRepo;

    # tests/presets
    same-triple = presetFixtures.sameTriple;
    static-musl = presetFixtures.musl;
    static-glibc = presetFixtures.glibcStatic;
    static-pkgconfig = presetFixtures.staticPkgconfig;
    sys-native-aarch64 = presetFixtures.sysNativeCross;
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
    windows-dll = extraTargets.windowsDllRepo;
    windows-dll-staged = extraTargets.windowsDllStagedRepo;
    linux-portable = extraTargets.zigRepo;
    linux-portable-native = extraTargets.zigNativeRepo;
    build-std = buildStd.bare;
    build-std-deps = buildStd.hosted;

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
    in
    pkgs.runCommand "test-control-apps-${mode}"
      (
        {
          net = ws.testApps.ctl.net.program;
          envApp = wsCheckout.testApps.ctl.env.program;
        }
        # IFD mode has no app for a test binary Cargo did not build.
        // lib.optionalAttrs isDynamic { skipped = ws.testApps.ctl.needs_feat.program; }
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

  # Products differ between the modes (resolved at build time in dynamic
  # mode), so the units downstream of an embedded product do too: the
  # embedder and, through it, the host. Every other unit is identical.
  mayDiffer = {
    embed = "^(embedder|host)-";
  };

  # Every workspace, target and variant of a repository: `key` is
  # `<ws>/<triple>/<variant>`, `inst` the mkWorkspace result, `out` the
  # repository's outputs for it (products, selected test runs, ...).
  instancesOf =
    repo:
    lib.concatLists (
      lib.mapAttrsToList (
        wsName: w:
        lib.concatLists (
          lib.mapAttrsToList (
            triple: vs:
            lib.mapAttrsToList (v: inst: {
              key = "${wsName}/${triple}/${v}";
              inherit inst;
              out = w.target.${triple}.variants.${v};
            }) vs
          ) w.instances
        )
      ) repo.workspaces
    );

  # The plan kinds an instance has (build, test, and bench when planned).
  kindsOf = i: lib.attrNames i.inst.units;

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
        + linkEach "$out/units/${i.key}" (i.inst.allUnits or { })
        + linkEach "$out/products/${i.key}" (
          lib.filterAttrs (_: d: lib.length d.unbuilt < lib.length (lib.attrNames d.roots)) i.out.packages
        )
        + linkEach "$out/runs/${i.key}" (flat2 i.out.testRuns)
        + linkEach "$out/runs/${i.key}/bench" (flat2 (i.out.benchRuns or { }))
        + linkEach "$out/doctests/${i.key}" i.out.doctests
      ) (instancesOf repo)
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
    repo:
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
                )
              )
            ) (kindsOf i)
          ) (instancesOf repo)
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
    repos':
    lib.concatMap (
      repo: lib.concatMap (i: map toString (lib.attrValues i.inst.plans)) (instancesOf repo)
    ) repos';
  prereqs =
    lib.mapAttrs (
      name: repo:
      pkgs.writeText "dynamic-prereqs-${name}" (
        lib.concatStringsSep "\n" (plansOf ([ repo ] ++ lib.optional (name == "walking-skeleton") lintRepo))
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
in
{
  inherit repos prereqs mayDiffer;
  build = lib.mapAttrs build repos;
  unitDrvs = lib.mapAttrs (_: unitDrvs) repos;
  outer = lib.mapAttrs (
    _: repo:
    lib.listToAttrs (
      lib.concatMap (
        i: lib.mapAttrsToList (kind: o: lib.nameValuePair "${i.key}/${kind}" o) i.inst.outer
      ) (instancesOf repo)
    )
  ) repos;
  checkVariant = lintRepo.workspaces.main.target.${native}.variants.lint.check;
  explain = lib.mapAttrs (
    _: repo:
    let
      ws = lib.head (lib.attrNames repo.workspaces);
    in
    (repo.explainSharing {
      a = ws;
      b = ws;
    }).shared
  ) repos;
}
