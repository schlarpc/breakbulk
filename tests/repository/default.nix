# Checks for mkRepository: overrides, multi-workspace sharing,
# invalidation, required features, failure hints, the dev shell and the
# option docs. IFD throughout (plans are read at evaluation time).
#
#   nix build -f tests/repository multi-ws-sharing
#
# Attributes are derivations (flake checks); `repos.<name>` exposes each
# repository for debugging.
#
# Invalidation tests compare the sets of unit .drv paths of the build and
# test plans before and after a scripted edit. Edits to files are made by a
# derivation that copies the fixture and edits it; its output is then used
# as the repository root (a path into the store, read after IFD realises
# it), so the "after" repository is evaluated exactly like the "before".
{
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      modules = modules ++ extraModules;
    };

  # One workspace at `path`, dev profile (faster; every check uses it).
  oneWs = path: {
    workspaces.main = {
      inherit path;
      variants.default.profile = "dev";
    };
  };

  # A check that asserts at evaluation time and records a report.
  evalCheck =
    name: report:
    pkgs.runCommand name { inherit report; } ''
      mkdir -p $out
      printf '%s\n' "$report" > $out/report
    '';

  # A copy of a fixture with an edit applied, usable as a repository root.
  edited =
    fixture: script:
    let
      drv = pkgs.runCommand "${fixture}-edited" { } ''
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} $out
        cd $out
        ${script}
      '';
      # Reading the directory realises it (IFD), which also makes the store
      # path readable in pure evaluation.
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  inst = repo: repo.workspaces.main.instances.${native}.default;

  # Unit .drv path -> "<derivation name>" for both plan kinds.
  unitDrvs =
    repo:
    let
      i = inst repo;
    in
    lib.listToAttrs (
      map (u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (
        lib.attrValues i.units.build ++ lib.attrValues i.units.test
      )
    );

  # The unit derivations that exist after the edit but not before, by
  # name, sorted and deduplicated.
  changedUnits =
    before: after:
    let
      b = unitDrvs before;
      a = unitDrvs after;
    in
    lib.sort lib.lessThan (lib.unique (lib.attrValues (lib.filterAttrs (d: _: !(b ? ${d})) a)));

  invalidation =
    name: before: after: expected:
    let
      got = changedUnits before after;
    in
    assert lib.assertMsg (
      got == expected
    ) "${name}: changed units ${builtins.toJSON got}, expected ${builtins.toJSON expected}";
    evalCheck name "changed units: ${builtins.toJSON got}";

  # Run a unit derivation's builder in a derivation that succeeds only when
  # the unit fails, and its output contains each of `patterns`.
  expectFailure =
    name: unit: patterns:
    let
      a = unit.drvAttrs;
    in
    derivation (
      a
      // {
        name = "${name}-expect-failure";
        builder = "${pkgs.bash}/bin/bash";
        args = [
          "-c"
          ''
            set -u
            result=$out
            for o in $unitOutputs; do
              d=$NIX_BUILD_TOP/unit-out-$o
              export "$o=$d"
            done
            unitArgs=()
            for ((i = 0; i < unitArgc; i++)); do
              v=unitArg$i
              unitArgs+=("''${!v}")
            done
            rc=0
            "$unitBuilder" "''${unitArgs[@]}" > $NIX_BUILD_TOP/log 2>&1 || rc=$?
            ${pkgs.coreutils}/bin/cat $NIX_BUILD_TOP/log
            if [ $rc -eq 0 ]; then
              echo "expected the unit to fail, but it succeeded" >&2
              exit 1
            fi
            ${lib.concatMapStrings (p: ''
              ${pkgs.gnugrep}/bin/grep -qF -- ${lib.escapeShellArg p} $NIX_BUILD_TOP/log || {
                echo "the failure does not mention: "${lib.escapeShellArg p} >&2
                exit 1
              }
            '') patterns}
            ${pkgs.coreutils}/bin/mkdir -p $result
            ${pkgs.coreutils}/bin/cp $NIX_BUILD_TOP/log $result/log
          ''
        ];
        outputs = [ "out" ];
        unitOutputs = a.outputs or [ "out" ];
        unitBuilder = a.builder;
        unitArgc = toString (lib.length (a.args or [ ]));
      }
      // lib.listToAttrs (lib.imap0 (i: v: lib.nameValuePair "unitArg${toString i}" v) (a.args or [ ]))
    );

  # Units of a plan, by derivation name.
  unitsNamed =
    i: kind: lib.listToAttrs (map (u: lib.nameValuePair u.name u) (lib.attrValues i.units.${kind}));

  # --- multi-ws --------------------------------------------------------------

  multiWs = mkRepo (fixtures + "/multi-ws") [
    {
      workspaces = lib.genAttrs [ "a" "b" "c" ] (ws: {
        path = ws;
        variants.default.profile = "dev";
      });
    }
  ];
  mwInst = ws: multiWs.workspaces.${ws}.instances.${native}.default;
  mwDrvs =
    ws:
    lib.mapAttrs' (
      _: u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name
    ) (mwInst ws).units.build;
  sharedNames =
    wss:
    let
      sets = map mwDrvs wss;
      common = lib.foldl' (acc: s: lib.filterAttrs (d: _: s ? ${d}) acc) (lib.head sets) (lib.tail sets);
    in
    lib.sort lib.lessThan (lib.attrValues common);
  sharedEverywhere = [
    "itoa-1.0.11-lib"
    "libc-0.2.191-build-run"
    "libc-0.2.191-build-script"
    "libc-0.2.191-lib"
    "shared-0.1.0-build-run"
    "shared-0.1.0-build-script"
    "shared-0.1.0-lib"
  ];

  # --- outside-reads -----------------------------------------------------------

  outsideModules = [
    (oneWs "ws")
    {
      packages.reader.extraSources = [ "schema" ];
      packages.app.extraSources = [ "assets" ];
    }
  ];
  outside = mkRepo (fixtures + "/outside-reads") outsideModules;
  outsideUnrelated = mkRepo (edited "outside-reads" "echo changed >> unrelated/notes.txt") outsideModules;
  outsideAsset = mkRepo (edited "outside-reads" "echo 'asset v2' > assets/data.txt") outsideModules;
  outsideSchema = mkRepo (edited "outside-reads" "echo 'hello v2' > schema/greeting.txt") outsideModules;

  # --- own-view ------------------------------------------------------------------

  ownViewModules = [
    {
      workspaces.main = {
        path = ".";
        variants.default.profile = "dev";
      };
      workspaces.virt = {
        path = "virtual";
        variants.default.profile = "dev";
      };
      packages.app.extraSources = [ "crates/lib1/data" ];
      packages.lib1.extraSources = [ "assets" ];
      packages.vmember.extraSources = [ "assets" ];
    }
  ];
  ownView = mkRepo (fixtures + "/own-view") ownViewModules;
  ownViewNotes = mkRepo (edited "own-view" "echo changed >> notes.txt") ownViewModules;
  ownViewApp = mkRepo (edited "own-view" "echo '// edited' >> src/main.rs") ownViewModules;
  ownViewAsset = mkRepo (edited "own-view" "echo 'asset v2' > assets/data.txt") ownViewModules;

  # --- stamps --------------------------------------------------------------------

  stampsWith =
    rev:
    mkRepo (fixtures + "/stamps") [
      (oneWs ".")
      {
        packages.app.env = {
          GIT_REV = rev;
          SOURCE_DATE_EPOCH = 1700000000;
        };
      }
    ];
  stampsA = stampsWith "aaaaaaa";
  stampsB = stampsWith "bbbbbbb";

  # --- required-features -------------------------------------------------------

  rf = mkRepo (fixtures + "/required-features") [
    (oneWs ".")
    {
      workspaces.main.variants.full.features = [
        "rf/cli"
        "rft/extra"
      ];
    }
    { workspaces.main.variants.full.profile = "dev"; }
  ];
  rfDefault = rf.workspaces.main.packages.rf;
  rfFull = rf.workspaces.main.target.${native}.variants.full;

  # --- features that change the resolve ------------------------------------------

  optionalDep = mkRepo (fixtures + "/optional-dependency") [
    (oneWs ".")
    {
      workspaces.main.variants = {
        fast = {
          features = [ "fast" ];
          profile = "dev";
        };
      }
      // breakbulk.variants.featurePowerset {
        features = [ "fast" ];
        profile = "dev";
        prefix = "fp";
      };
    }
  ];
  optionalDepVariants = optionalDep.workspaces.main.target.${native}.variants;

  exclusive = mkRepo (fixtures + "/exclusive-features") [
    (oneWs ".")
    {
      workspaces.main.variants.b = {
        noDefaultFeatures = true;
        features = [ "b" ];
        profile = "dev";
      };
    }
  ];

  # --- missing-input ---------------------------------------------------------

  mylib = pkgs.runCommand "mylib" { } ''
    mkdir -p $out/include
    echo 3.1 > $out/include/mylib.h
  '';
  missing = mkRepo (fixtures + "/missing-input") [ (oneWs ".") ];
  provided = mkRepo (fixtures + "/missing-input") [
    (oneWs ".")
    {
      packages.mylib-sys = {
        env.MYLIB_DIR = mylib;
        extraSources = [ "vendor" ];
      };
    }
  ];

  # --- declared-paths ----------------------------------------------------------

  # app selected: tool's script runs only for the build machine (app's
  # build-dependency) and devdep's only in the test plan (its
  # dev-dependency).
  declaredPaths =
    modules:
    mkRepo (fixtures + "/declared-paths") (
      [
        (oneWs ".")
        { workspaces.main.variants.default.packages = [ "app" ]; }
      ]
      ++ modules
    );
  declaredMissing = declaredPaths [ ];
  # app's path in its view; the other headers allowed: dep's by a path
  # glob, tool's by `*`, devdep's by its path.
  declaredProvided = declaredPaths [
    {
      packages.app.extraSources = [ "shared" ];
      packages.dep.buildScriptPaths.allow = [ "/nonexistent/*" ];
      packages.tool.buildScriptPaths.allow = [ "*" ];
      packages.devdep.buildScriptPaths.allow = [ "/nonexistent/breakbulk-dev-dep.h" ];
    }
  ];
  # The test of `declared-paths`, over both repositories, for
  # tests/dynamic to build in dynamic-derivation mode too.
  declaredPathsTest =
    let
      missing = declaredMissing.workspaces.main.target.${native};
      provided = declaredProvided.workspaces.main.target.${native};
    in
    assert lib.assertMsg (
      !(missing.packages.app.checks ? buildScriptPaths)
    ) "declared-paths: the product still has a buildScriptPaths check";
    assert lib.assertMsg
      (
        lib.attrNames missing.buildScriptPaths == [
          "build"
          "test"
        ]
      )
      "declared-paths: expected a check per plan, got ${toString (lib.attrNames missing.buildScriptPaths)}";
    assert lib.assertMsg (
      declaredMissing.checks ? "main/${native}/buildScriptPaths/build"
      && declaredMissing.checks ? "main/${native}/buildScriptPaths/test"
    ) "declared-paths: the plan checks are not in repo.checks";
    pkgs.runCommand "declared-paths"
      {
        missingApp = missing.packages.app;
        providedApp = provided.packages.app;
        buildFailure = pkgs.testers.testBuildFailure missing.buildScriptPaths.build;
        testFailure = pkgs.testers.testBuildFailure missing.buildScriptPaths.test;
        buildPassing = provided.buildScriptPaths.build;
        testPassing = provided.buildScriptPaths.test;
        inherit native;
      }
      ''
        set -euo pipefail
        [ "$($missingApp/bin/app)" = "app unknown absent" ]
        [ "$($providedApp/bin/app)" = "app 1.2.3 absent" ]

        log=$buildFailure/testBuildFailure.log
        cat $log
        grep -qF 'buildScriptPaths: build scripts of the build plan of workspace main' $log
        grep -qE "^  app 0\.1\.0 \(for $native\): .*\`rerun-if-changed=\.\./shared/version\.txt\`.*\`packages\.app\.extraSources\`$" $log
        # The path as its place in the view, `..` resolved.
        grep -qE -- '-source/shared/version\.txt is not in the sandbox' $log
        grep -qE "^  dep 0\.1\.0 \(for $native\): .*\`rerun-if-changed=/nonexistent/breakbulk-tool\.h\`.*\`packages\.dep\.inputs\`" $log
        # A build-dependency's run, for the build machine.
        grep -qE '^  tool 0\.1\.0 \(for the build machine\): .*`rerun-if-changed=/nonexistent/breakbulk-build-dep\.h`.*`packages\.tool\.' $log
        ! grep -q devdep $log
        grep -qxF '  packages.app.buildScriptPaths.allow = [ "../shared/version.txt" ];' $log
        grep -qxF '  packages.dep.buildScriptPaths.allow = [ "/nonexistent/breakbulk-tool.h" ];' $log
        grep -qxF '  packages.tool.buildScriptPaths.allow = [ "/nonexistent/breakbulk-build-dep.h" ];' $log

        log=$testFailure/testBuildFailure.log
        cat $log
        grep -qF 'buildScriptPaths: build scripts of the test plan of workspace main' $log
        # A dev-dependency's run, only in the test plan.
        grep -qE "^  devdep 0\.1\.0 \(for $native\): .*\`rerun-if-changed=/nonexistent/breakbulk-dev-dep\.h\`.*\`packages\.devdep\.inputs\`" $log
        grep -qE '^  tool 0\.1\.0 \(for the build machine\): ' $log
        grep -qxF '  packages.devdep.buildScriptPaths.allow = [ "/nonexistent/breakbulk-dev-dep.h" ];' $log

        # Passing because the paths are allowed, not because no run was read.
        cat $buildPassing/allowed $testPassing/allowed
        sort $buildPassing/allowed | diff - <(printf '%s\n' \
          "dep 0.1.0 (for $native): /nonexistent/breakbulk-tool.h" \
          "tool 0.1.0 (for the build machine): /nonexistent/breakbulk-build-dep.h")
        sort $testPassing/allowed | diff - <(printf '%s\n' \
          "dep 0.1.0 (for $native): /nonexistent/breakbulk-tool.h" \
          "devdep 0.1.0 (for $native): /nonexistent/breakbulk-dev-dep.h" \
          "tool 0.1.0 (for the build machine): /nonexistent/breakbulk-build-dep.h")
        touch $out
      '';

  # --- pkgid-short -------------------------------------------------------------

  pkgidShort = mkRepo (fixtures + "/pkgid-short") [
    (oneWs "app")
    {
      gitTrees."https://example.invalid/me/gitdep" = fixtures + "/pkgid-short/repo";
      gitTrees."https://example.invalid/me/tools" = fixtures + "/pkgid-short/tools";
    }
  ];

  # --- env-repository-path -----------------------------------------------------

  envRepoPathModule = {
    gitTrees."https://example.invalid/me/envdep" = fixtures + "/env-repository-path/envdep";
  };
  envRepoPath = mkRepo (fixtures + "/env-repository-path") [
    (oneWs "app")
    envRepoPathModule
  ];
  # With the setting the hint names.
  envRepoPathFixed = mkRepo (fixtures + "/env-repository-path") [
    (oneWs "app")
    envRepoPathModule
    { packages.envdep.env.ENVDEP_DIR = fixtures + "/env-repository-path/app/vendor/envdep"; }
  ];

  # --- roots-override ----------------------------------------------------------

  # The variant selects `tool`, a path dependency outside the workspace:
  # Cargo plans its bin, unit tests and doctest, and the prediction has
  # them from tool's own manifest.
  rootsSelection = {
    workspaces.main = {
      path = "ws";
      variants.default = {
        profile = "dev";
        packages = [
          "app"
          "tool"
        ];
      };
    };
  };
  rootsPredicted = mkRepo (fixtures + "/roots-override") [ rootsSelection ];
  # A test env function of the run: its workspace root is app's
  # workspace for app, and tool's own directory for tool (no workspace).
  rootsEnvFn = mkRepo (fixtures + "/roots-override") [
    rootsSelection
    { workspaces.main.memberDefaults.test.env.WS_ROOT = run: run.workspaceRoot; }
  ];
  # A `roots.build` that leaves out tool's bin: wrong on purpose, for the
  # error naming an unpredicted root.
  rootsMissing = mkRepo (fixtures + "/roots-override") [
    rootsSelection
    { workspaces.main.roots.build = [ "app/bin/app" ]; }
  ];
  rootsOverride = mkRepo (fixtures + "/roots-override") [
    rootsSelection
    {
      workspaces.main.roots = {
        build = [
          "app/bin/app"
          "tool/bin/tool"
        ];
        test = [
          "app/bin-test/app"
          "tool/bin-test/tool"
          { name = "tool/lib-test/tool"; }
        ];
        doctests = [ "tool" ];
      };
    }
  ];

  # --- overrides and options ---------------------------------------------------

  # Evaluation only: the repository is never built.
  overrideRepo = mkRepo (fixtures + "/multi-ws") [
    {
      workspaces.b = {
        path = "b";
        variants.default.profile = "dev";
        memberDefaults.variant.not-a-variant-of-b.env.X = "1";
      };
      packages = {
        "itoa@^1".env.ITOA_CARET = "1";
        itoa = {
          version = ">=2";
          env.ITOA_TWO = "1";
        };
        libc = {
          env.LIBC = "plain";
          # The variant layer, and its own target layer.
          variant.default = {
            forTarget.env.LIBC_VARIANT = "1";
            target.${native}.forHost.env.LIBC_VARIANT_HOST = "1";
          };
          variant.not-a-variant.env.X = "1";
          # A registry crate has no source view: a warning.
          target.${native}.sourceOverlay."ui/dist" = "/nowhere";
        };
        # A variant layer's sources reach the package's source view.
        app-b.variant.default.extraSources = [ "c" ];
        "libc@=0.2.191".env.LIBC = "exact";
        not-in-any-lockfile.env.X = "1";
        shared.nativeInputs = p: [ p.pkg-config ];
        app-b.pipelining = true;
      };
      targets.${native} = {
        rustflags = [
          "--cfg"
          "bb_target_mark"
        ];
        env.TARGET_MARK = "t";
      };
    }
  ];
  # --- test-only ---------------------------------------------------------------

  testOnlyScope = {
    packages.proto.test.sourceScope = [ "proto/testdata" ];
  };
  testOnlyOptOut = {
    packages.proto.test.scopeTestsDir = false;
  };
  testOnlyRepo =
    edit: modules:
    mkRepo (if edit == null then fixtures + "/test-only" else edited "test-only" edit) (
      [
        (oneWs ".")
        testOnlyScope
        # test-only reads the run's output.
        { packages.proto.test.keepLog = true; }
      ]
      ++ modules
    );
  testOnly = testOnlyRepo null [ ];
  addFixture = "echo 43 > proto/tests/fixtures/extra.txt";
  editTestdata = "echo 42 >> proto/testdata/more.txt";
  includeFrom =
    file: "echo 'pub const DATA: &str = include_str!(\"../${file}\");' >> proto/src/lib.rs";
  protoLib = repo: (unitsNamed (inst repo) "build")."proto-0.1.0-lib";

  # --- target-views --------------------------------------------------------------

  targetViewsRepo =
    edit: modules:
    mkRepo (if edit == null then fixtures + "/target-views" else edited "target-views" edit) (
      [
        (oneWs ".")
        # The check reads a run's output.
        { packages.tv.test.keepLog = true; }
      ]
      ++ modules
    );
  targetViews = targetViewsRepo null [ ];

  # --- predict-sources -----------------------------------------------------------

  predictSourcesRepo =
    edit: modules:
    mkRepo (if edit == null then fixtures + "/predict-sources" else edited "predict-sources" edit) (
      [
        (oneWs ".")
        {
          packages.ps.predictSources = {
            enable = true;
            keep = [ "templates" ];
          };
        }
      ]
      ++ modules
    );
  predictSources = predictSourcesRepo null [ ];

  # --- sources -------------------------------------------------------------------

  # The fixture's source-view functions. `cli`, the root package, keeps
  # only what it compiles from, and its runs add `data/`. `lint` leaves
  # its snapshots, README and manifest out of its "build" view. lint's
  # run view takes one function from each of three layers, which give
  # `data/input.txt` and `data/other.txt` only when they run in layer
  # order.
  sourcesModule =
    { lib, ... }:
    let
      fs = lib.fileset;
      onRun = f: { default, kind, ... }@a: if kind == "run" then f a else default;
    in
    {
      packages.cli.sources = [
        (
          { default, root, ... }:
          fs.intersection default (
            fs.unions [
              (root + "/Cargo.toml")
              (root + "/src")
              (root + "/tests")
            ]
          )
        )
        (onRun ({ default, root, ... }: fs.union default (root + "/data")))
      ];
      packages.lint.sources = [
        (
          {
            default,
            kind,
            root,
            packageDir,
            ...
          }:
          if kind == "build" then
            fs.difference default (fs.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}/src"))
          else
            default
        )
        (
          {
            default,
            kind,
            root,
            packageDir,
            ...
          }:
          if kind == "build" then
            fs.difference default (
              fs.unions [
                (root + "/${packageDir}/README.md")
                (root + "/${packageDir}/Cargo.toml")
              ]
            )
          else
            default
        )
        (onRun (
          { default, root, ... }:
          fs.difference default (
            fs.unions [
              (root + "/data/unused.txt")
              (root + "/data/other.txt")
            ]
          )
        ))
      ];
      packages.lint.variant.default.sources = [
        (onRun ({ default, root, ... }: fs.union default (root + "/data/other.txt")))
      ];
      workspaces.main.memberDefaults.sources = [
        (onRun ({ default, root, ... }: fs.union default (root + "/data")))
      ];
      # The checks read the runs' output.
      workspaces.main.memberDefaults.test.keepLog = true;
    };
  sourcesRepo =
    edit:
    mkRepo (if edit == null then fixtures + "/sources" else edited "sources" edit) [
      (oneWs ".")
      sourcesModule
    ];
  sources = sourcesRepo null;

  # --- snapshots -----------------------------------------------------------------

  # insta's settings, and the snapshots kept out of every view but the
  # test runs', are the curated default (`sysDefaults.dependents.insta`);
  # snapbox and expect-test need nothing.
  snapshotsModule = {
    # The checks read the runs' output.
    workspaces.main.memberDefaults.test.keepLog = true;
  };
  snapshotsRepo =
    edit: modules:
    mkRepo (if edit == null then fixtures + "/snapshots" else edited "snapshots" edit) (
      [
        (oneWs "ws")
        snapshotsModule
      ]
      ++ modules
    );
  snapshots = snapshotsRepo null [ ];

  inst' = repo: ws: repo.workspaces.${ws}.instances.${native}.default;

  # --- view-hints ----------------------------------------------------------------

  viewHints = mkRepo (fixtures + "/view-hints") [
    (oneWs ".")
    {
      packages.chosen-reads.sources = [
        (
          {
            default,
            kind,
            root,
            packageDir,
            ...
          }:
          if kind == "build" then
            lib.fileset.difference default (root + "/${packageDir}/data.txt")
          else
            default
        )
      ];
    }
  ];
  # With the options the hints name.
  viewHintsFixed = mkRepo (fixtures + "/view-hints") [
    (oneWs ".")
    {
      packages = {
        lib-reads.extraSources = [ "shared" ];
        script-reads.extraSources = [ "shared" ];
        test-reads.test.sourceScope = [ "shared" ];
        run-reads.test.sourceScope = [ "shared" ];
        doc-reads.test.sourceScope = [ "shared" ];
        lib-to-tests.test.scopeTestsDir = false;
      };
    }
  ];

  # --- host units across debugInfo ---------------------------------------------

  # One workspace with build scripts and a proc macro, planned for a target
  # whose debug info is split off and for one that keeps it.
  debugInfoRepo =
    debugInfo:
    mkRepo (fixtures + "/same-triple") [
      (oneWs ".")
      { targets.${native}.debugInfo = debugInfo; }
    ];
  # Host unit derivation name -> .drv path, both plans.
  hostDrvs =
    repo:
    let
      i = inst repo;
    in
    lib.listToAttrs (
      lib.concatMap
        (
          kind:
          let
            plan = builtins.fromJSON (
              builtins.unsafeDiscardStringContext (builtins.readFile "${i.plans.${kind}}/plan.json")
            );
          in
          lib.mapAttrsToList (
            id: u:
            lib.nameValuePair i.units.${kind}.${id}.name (
              builtins.unsafeDiscardStringContext i.units.${kind}.${id}.drvPath
            )
          ) (lib.filterAttrs (_: u: u.platform == "host") plan.units)
        )
        [
          "build"
          "test"
        ]
    );
in
{
  repos = {
    inherit
      multiWs
      outside
      ownView
      stampsA
      rf
      optionalDep
      exclusive
      missing
      provided
      declaredMissing
      declaredProvided
      declaredPathsTest
      overrideRepo
      testOnly
      targetViews
      predictSources
      viewHints
      viewHintsFixed
      pkgidShort
      envRepoPath
      envRepoPathFixed
      sources
      rootsPredicted
      rootsMissing
      rootsOverride
      snapshots
      ;
  };

  # Host units (build scripts, the proc macro, their runs) are the same
  # derivations whatever the target's `debugInfo`: host units never ship,
  # so their remap scope does not follow it.
  host-units-shared =
    let
      split = hostDrvs (debugInfoRepo "split");
      keep = hostDrvs (debugInfoRepo "keep");
      differ = lib.attrNames (lib.filterAttrs (n: d: keep.${n} or null != d) split);
      names = lib.attrNames split;
    in
    assert lib.assertMsg
      (lib.any (lib.hasSuffix "-build-script") names && lib.any (lib.hasPrefix "pm-") names)
      "host-units-shared: expected build scripts and the proc macro among host units: ${toString names}";
    assert lib.assertMsg (lib.attrNames keep == names)
      "host-units-shared: host units differ by name: ${toString names} vs ${toString (lib.attrNames keep)}";
    assert lib.assertMsg (
      differ == [ ]
    ) "host-units-shared: host units differ between split and keep: ${toString differ}";
    evalCheck "host-units-shared" "host units: ${toString names}";

  # Check groups over the three workspaces: every proper prefix of a check
  # name holds exactly the checks under it, `all` every check, and
  # checkGroups select by glob and take derivations; a group name that
  # is taken, a workspace named `all` and a pattern that matches nothing
  # are evaluation errors.
  check-groups =
    let
      groupsRepo =
        extra:
        mkRepo (fixtures + "/multi-ws") (
          [
            {
              workspaces = lib.genAttrs [ "a" "b" ] (ws: {
                path = ws;
                variants.default.profile = "dev";
              });
            }
          ]
          ++ extra
        );
      marker = pkgs.writeText "marker" "";
      repo = groupsRepo [
        {
          checkGroups = {
            builds = [ "*/*/*/build" ];
            extra = [
              "a/**"
              marker
            ];
          };
        }
      ];
      c = repo.checks;
      isGroup = n: c.${n}.breakbulkCheckGroup or false;
      leaves = lib.filter (n: !(isGroup n)) (lib.attrNames c);
      entriesOf = n: lib.sort lib.lessThan (lib.attrNames c.${n}.passthru.entries);
      under = p: lib.filter (lib.hasPrefix "${p}/") leaves;
      failsOn = extra: !(builtins.tryEval (lib.attrNames (groupsRepo extra).checks)).success;
    in
    assert lib.assertMsg (
      c ? a && c ? b && c ? "a/${native}" && c ? all
    ) "check-groups: groups ${toString (lib.filter isGroup (lib.attrNames c))}";
    assert lib.assertMsg (
      entriesOf "a" == under "a"
    ) "check-groups: a holds ${toString (entriesOf "a")}";
    assert lib.assertMsg (
      entriesOf "a/${native}" == under "a/${native}"
    ) "check-groups: a/${native} holds ${toString (entriesOf "a/${native}")}";
    assert lib.assertMsg (
      entriesOf "all" == lib.sort lib.lessThan leaves
    ) "check-groups: all holds ${toString (entriesOf "all")}";
    assert lib.assertMsg (
      entriesOf "builds"
      == lib.filter (n: lib.hasSuffix "/build" n && lib.length (lib.splitString "/" n) == 4) leaves
    ) "check-groups: builds holds ${toString (entriesOf "builds")}";
    assert lib.assertMsg (
      lib.filter (n: !(lib.hasPrefix "derivations/" n)) (entriesOf "extra") == under "a"
      && lib.any (lib.hasPrefix "derivations/0-marker") (entriesOf "extra")
    ) "check-groups: extra holds ${toString (entriesOf "extra")}";
    assert lib.assertMsg (failsOn [
      { checkGroups.a = [ "b/**" ]; }
    ]) "check-groups: a group named like a prefix group";
    assert lib.assertMsg (failsOn [
      { checkGroups.all = [ "b/**" ]; }
    ]) "check-groups: a group named all";
    assert lib.assertMsg (
      !(builtins.tryEval (groupsRepo [ { checkGroups.none = [ "c/**" ]; } ]).checks.none.drvPath).success
    ) "check-groups: a pattern matching nothing";
    assert lib.assertMsg (failsOn [
      {
        workspaces.all = {
          path = "c";
          variants.default.profile = "dev";
        };
      }
    ]) "check-groups: a workspace named all";
    evalCheck "check-groups" "groups: ${toString (lib.filter isGroup (lib.attrNames c))}";

  # Exactly the registry crates and the path crate outside every root are
  # shared by all three workspaces; `inner` (inside a's root) is shared
  # only by b and c, which both see it from outside.
  multi-ws-sharing =
    let
      all3 = sharedNames [
        "a"
        "b"
        "c"
      ];
      bc = sharedNames [
        "b"
        "c"
      ];
      ab = sharedNames [
        "a"
        "b"
      ];
      inner = multiWs.explainSharing {
        a = multiWs.workspaces.a.plans.${native}.default.build;
        b = "b";
        package = "inner";
      };
      innerUnit = lib.head inner.units;
    in
    assert lib.assertMsg (
      all3 == sharedEverywhere
    ) "multi-ws: shared by a, b, c: ${builtins.toJSON all3}";
    assert lib.assertMsg (
      bc == lib.sort lib.lessThan (sharedEverywhere ++ [ "inner-0.1.0-lib" ])
    ) "multi-ws: shared by b, c: ${builtins.toJSON bc}";
    assert lib.assertMsg (ab == sharedEverywhere) "multi-ws: shared by a, b: ${builtins.toJSON ab}";
    # repo.sources: fetched once for all lockfiles, by name and name@version.
    assert lib.assertMsg (
      multiWs.sources ? itoa && multiWs.sources ? "libc@0.2.191" && !(multiWs.sources ? shared)
    ) "multi-ws: sources ${builtins.toJSON (lib.attrNames multiWs.sources)}";
    # explainSharing names why `inner` differs: Cargo passes a member's
    # source path relative to the workspace root and runs rustc there, and
    # marks it as a primary package.
    assert lib.assertMsg (
      !inner.shared
      && innerUnit.fields.env ? CARGO_PRIMARY_PACKAGE
      && innerUnit.fields ? cwd
      && lib.elem "inner/src/lib.rs" innerUnit.fields.args.onlyA
    ) "multi-ws: explainSharing inner: ${inner.text}";
    assert lib.assertMsg ((multiWs.explainSharing {
      a = "a";
      b = "c";
      package = "shared";
    }).shared
    ) "multi-ws: explainSharing shared reports a difference";
    pkgs.runCommand "multi-ws-sharing"
      {
        a = multiWs.workspaces.a.packages.app-a;
        b = multiWs.workspaces.b.packages.app-b;
        c = multiWs.workspaces.c.packages.app-c;
        text = inner.text;
      }
      ''
        for x in a b c; do
          got=$(''${!x}/bin/app-$x)
          echo "$got"
          [ "$got" = "app-$x shared:7+cfg inner 1" ]
        done
        mkdir -p $out
        printf '%s\n' "$text" > $out/explain-inner
      '';

  # Builds, with files read from outside the crate directories made
  # visible by extraSources; editing an unrelated sibling changes no unit;
  # editing a file read by the proc macro's caller changes only that
  # caller's units; editing the include_str! file changes its reader and
  # the reader's dependents.
  outside-reads = pkgs.runCommand "outside-reads" { app = outside.workspaces.main.packages.app; } ''
    got=$($app/bin/app)
    echo "$got"
    [ "$got" = "hello from schema | asset v1" ]
    touch $out
  '';
  outside-reads-unrelated = invalidation "outside-reads-unrelated" outside outsideUnrelated [ ];
  outside-reads-asset = invalidation "outside-reads-asset" outside outsideAsset [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];
  outside-reads-schema = invalidation "outside-reads-schema" outside outsideSchema [
    "app-0.1.0-bin"
    "app-0.1.0-test"
    "reader-0.1.0-lib"
    "reader-0.1.0-test"
  ];

  # Repository paths resolve in each unit's own view. lib1, a member of a
  # workspace whose root is the package app, compiles in the workspace
  # root, in its own view; config `[env]` paths reach a crate that lists
  # them in extraSources, also in another package's directory, and the
  # registry crate itoa's units in both workspaces (the virtual one too)
  # as the empty directory, keeping the trailing `/` of the root.
  own-view =
    let
      # The build plan's compile unit of a package, by an infix of its id.
      unitOf =
        ws: infix:
        let
          plan = builtins.fromJSON (
            builtins.unsafeDiscardStringContext (
              builtins.readFile "${ownView.workspaces.${ws}.instances.${native}.default.plans.build}/plan.json"
            )
          );
        in
        lib.head (
          lib.attrValues (
            lib.filterAttrs (_: u: u.kind == "compile" && lib.hasInfix infix u.package) plan.units
          )
        );
      lib1 = unitOf "main" "/crates/lib1#";
      itoaPaths =
        ws:
        let
          u = unitOf ws "#itoa@";
        in
        lib.assertMsg
          (
            u.env.BB_ROOT == [
              { empty = ""; }
              "/"
            ]
            && u.env.BB_ASSETS == [ { empty = "assets"; } ]
          )
          "own-view: itoa's config paths in ${ws} are ${
            builtins.toJSON { inherit (u.env) BB_ROOT BB_ASSETS; }
          }";
    in
    assert itoaPaths "main";
    assert itoaPaths "virt";
    assert lib.assertMsg
      (
        lib1.cwd == {
          src = lib1.package;
          rel = "";
        }
        &&
          lib1.env.BB_LIB1_DATA == [
            {
              src = lib1.package;
              rel = "crates/lib1/data";
            }
          ]
      )
      "own-view: lib1's cwd ${builtins.toJSON lib1.cwd} and BB_LIB1_DATA ${builtins.toJSON lib1.env.BB_LIB1_DATA}";
    pkgs.runCommand "own-view"
      {
        app = ownView.workspaces.main.packages.app;
        vmember = ownView.workspaces.virt.packages.vmember;
        # Every test run (lib1's integration test) and product.
        all = ownView.checks.all;
      }
      ''
        got=$($app/bin/app); echo "$got"
        [ "$got" = "app: asset v1 | lib1 data | lib1: lib1 data | asset v1 | 7" ]
        got=$($vmember/bin/vmember); echo "$got"
        [ "$got" = "vmember: asset v1 3" ]
        touch $out
      '';
  # A file of the root package's directory reaches only the root package's
  # units: not the member's, whose working directory is the workspace
  # root, nor the registry crate's, which carry the root as a config path.
  own-view-notes = invalidation "own-view-notes" ownView ownViewNotes [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];
  own-view-app = invalidation "own-view-app" ownView ownViewApp [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];
  # The root-level directory reaches the root package and lib1, which lists
  # it, and their dependents; not itoa.
  own-view-asset = invalidation "own-view-asset" ownView ownViewAsset [
    "app-0.1.0-bin"
    "app-0.1.0-test"
    "lib1-0.1.0-lib"
    "lib1-0.1.0-test"
    "lib1-0.1.0-test-it"
  ];

  # A per-package stamp reaches only that package's units.
  stamps =
    pkgs.runCommand "stamps"
      {
        app = stampsA.workspaces.main.packages.app;
        tool = stampsA.workspaces.main.packages.tool;
      }
      ''
        got=$($app/bin/app); echo "$got"
        [ "$got" = "app rev=aaaaaaa epoch=1700000000 util:42:yes" ]
        got=$($tool/bin/tool); echo "$got"
        [ "$got" = "tool rev=unset util:1:yes" ]
        touch $out
      '';
  stamps-invalidation = invalidation "stamps-invalidation" stampsA stampsB [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];

  # Targets skipped for missing features have attributes: the product
  # root is a stub that fails with the reason, the test a stub that
  # succeeds and says it was skipped. The variant with the features builds
  # and runs them.
  required-features =
    let
      admin = rfDefault.roots."bin/admin";
      reason = admin.breakbulkRoot.reason;
    in
    assert lib.assertMsg (
      admin.breakbulkRoot.unit == null
    ) "required-features: admin was built without `cli`";
    assert lib.assertMsg (lib.hasInfix "cli" reason)
      "required-features: the stub's reason does not name the feature: ${reason}";
    assert lib.assertMsg (
      map (u: u.root) rfDefault.unbuilt == [ "bin/admin" ]
    ) "required-features: unbuilt ${builtins.toJSON rfDefault.unbuilt}";
    pkgs.runCommand "required-features"
      {
        rf = rfDefault;
        skipped = rf.workspaces.main.tests.rft.needs-extra;
        plain = rf.workspaces.main.tests.rft.plain;
        adminFull = rfFull.packages.rf;
        testFull = rfFull.tests.rft.needs-extra;
        adminStub = expectFailure "rf-admin" admin [ "cli" ];
      }
      ''
        [ "$($rf/bin/rf)" = rf ]
        [ ! -e $rf/bin/admin ]
        ls -R $skipped
        $plain/bin/plain
        [ "$($adminFull/bin/admin)" = "admin cli=true" ]
        $testFull/bin/needs-extra
        touch $out
      '';

  # A variant whose feature turns on an optional dependency plans and
  # builds it, by name and from featurePowerset.
  optional-dependency =
    pkgs.runCommand "optional-dependency"
      {
        plain = optionalDep.workspaces.main.packages.od;
        fast = optionalDepVariants.fast.packages.od;
        fpFast = optionalDepVariants.fp-fast.packages.od;
      }
      ''
        [ "$($plain/bin/od)" = "od 42 fast=false" ]
        [ "$($fast/bin/od)" = "od 42 fast=true" ]
        [ "$($fpFast/bin/od)" = "od 42 fast=true" ]
        touch $out
      '';

  # Mutually exclusive features: each variant enables one, and plans
  # although every feature at once would not compile.
  exclusive-features =
    pkgs.runCommand "exclusive-features"
      {
        a = exclusive.workspaces.main.packages.ef;
        b = exclusive.workspaces.main.target.${native}.variants.b.packages.ef;
      }
      ''
        [ "$($a/bin/ef)" = "ef a" ]
        [ "$($b/bin/ef)" = "ef b" ]
        touch $out
      '';

  # An undeclared input fails the build-script run with a message naming
  # the options to set; declaring them builds.
  missing-input =
    let
      run = (unitsNamed (inst missing) "build")."mylib-sys-0.1.0-build-run";
    in
    pkgs.runCommand "missing-input"
      {
        failure = expectFailure "mylib-sys-run" run [
          "packages.mylib-sys.env.MYLIB_DIR"
          "packages.mylib-sys.extraSources"
        ];
        app = provided.workspaces.main.packages.app;
      }
      ''
        cat $failure/log
        got=$($app/bin/app); echo "$got"
        [ "$got" = "app 3.1 vendored 7" ]
        touch $out
      '';

  # Build scripts that declare missing `rerun-if-changed` paths and run
  # on without them: the product builds, and the build plan's
  # `buildScriptPaths` check fails naming each path with its package, the
  # run's platform and the option to add it to (`extraSources` for app's
  # path in the repository, `inputs` for the headers outside it), and the
  # `allow` setting for each. The build-dependency's run is for the build
  # machine; the dev-dependency's is only in the test plan, whose check
  # fails naming it. With app's path in `extraSources` and the headers
  # allowed, both checks pass.
  declared-paths = declaredPathsTest;

  # `tests/` and in-package `test.sourceScope` paths are test-only: editing
  # them changes only proto's test units (and its test runs), not its
  # library or app; `scopeTestsDir = false` keeps `tests/` in every view,
  # set on the package, in `memberDefaults` or per triple (`target.<t>`),
  # and a package's `true` overrides `memberDefaults`' `false`. The
  # integration tests, with and without the libtest harness, read both at
  # their paths; the example reads `tests/`.
  test-only =
    let
      runOf = repo: (inst repo).testRuns.proto.read.drvPath;
      fixtureEdit = testOnlyRepo addFixture [ ];
      testdataEdit = testOnlyRepo editTestdata [ ];
      testUnits = [
        "proto-0.1.0-test"
        "proto-0.1.0-test-datadriven"
        "proto-0.1.0-test-read"
        "proto-0.1.0-test-reads_tests"
      ];
      changedWith = m: changedUnits (testOnlyRepo null [ m ]) (testOnlyRepo addFixture [ m ]);
      optOuts = {
        package = testOnlyOptOut;
        memberDefaults.workspaces.main.memberDefaults.test.scopeTestsDir = false;
        target.packages.proto.target.${native}.test.scopeTestsDir = false;
      };
      optOutChanged = lib.mapAttrs (_: changedWith) optOuts;
      backOn = changedWith {
        workspaces.main.memberDefaults.test.scopeTestsDir = false;
        packages.proto.test.scopeTestsDir = true;
      };
    in
    assert lib.assertMsg (
      changedUnits testOnly fixtureEdit == testUnits
    ) "test-only: a fixture edit changed ${builtins.toJSON (changedUnits testOnly fixtureEdit)}";
    assert lib.assertMsg (
      changedUnits testOnly testdataEdit == testUnits
    ) "test-only: a testdata edit changed ${builtins.toJSON (changedUnits testOnly testdataEdit)}";
    assert lib.assertMsg (
      runOf fixtureEdit != runOf testOnly && runOf testdataEdit != runOf testOnly
    ) "test-only: the edits left proto's test run unchanged";
    assert lib.assertMsg
      (lib.all (c: lib.elem "proto-0.1.0-lib" c && lib.elem "app-0.1.0-bin" c) (
        lib.attrValues optOutChanged
      ))
      "test-only: with scopeTestsDir = false, a fixture edit changed only ${builtins.toJSON optOutChanged}";
    assert lib.assertMsg (backOn == testUnits)
      "test-only: the package's scopeTestsDir = true did not override memberDefaults: ${builtins.toJSON backOn}";
    pkgs.runCommand "test-only"
      {
        read = (inst testOnly).testRuns.proto.read;
        datadriven = (inst testOnly).testRuns.proto.datadriven;
        example = (inst testOnly).testBins."proto/example/reads_tests";
        app = testOnly.workspaces.main.packages.app;
      }
      ''
        grep -q 'test reads_fixtures ... ok' $read/log
        grep -q 'datadriven: ok' $datadriven/log
        [ "$($example/bin/reads_tests)" = 42 ]
        [ "$($app/bin/app)" = 42 ]
        touch $out
      '';

  # Per-target views (`scopeTargetRoots`): an edit to one integration
  # test's root changes only that test's compile; a shared module under
  # `tests/` changes the test compiles, and no library, bin or build
  # script. tv's build-script run reads the package's whole view, as
  # Cargo re-runs a script on any edit to its package, so an example or
  # bin edit re-runs it and rebuilds the package; with `predictSources`,
  # which narrows the run to its `rerun-if-changed` paths, the edit
  # changes only that target's units (and the tests that link the bin).
  # With `scopeTargetRoots = false` every target
  # sees every root again. A test that reads another test's root fails
  # with a hint naming the option. Test runs read the package's views:
  # an edit to one test re-runs the other.
  target-views =
    let
      changedBy =
        edit: modules: changedUnits (targetViewsRepo null modules) (targetViewsRepo edit modules);
      runOf = repo: t: (inst repo).testRuns.tv.${t}.drvPath;
      fooEdit = "echo '// edited' >> tv/tests/foo.rs";
      exampleEdit = "echo '// edited' >> tv/examples/x.rs";
      predicted = [ { packages.tv.predictSources.enable = true; } ];
      got = {
        foo = changedBy fooEdit [ ];
        example = changedBy exampleEdit predicted;
        tool = changedBy "echo '// edited' >> tv/src/bin/tool/cli.rs" predicted;
        common = changedBy "echo '// edited' >> tv/tests/common/mod.rs" [ ];
      };
      exampleRun = changedBy exampleEdit [ ];
      off = changedBy fooEdit [ { packages.tv.scopeTargetRoots = false; } ];
      want = {
        foo = [ "tv-0.1.0-test-foo" ];
        example = [ "tv-0.1.0-test-x" ];
        # The integration tests link the bin (CARGO_BIN_EXE_tool).
        tool = [
          "tv-0.1.0-bin-tool"
          "tv-0.1.0-test-bar"
          "tv-0.1.0-test-foo"
          "tv-0.1.0-test-tool"
        ];
        # Not a root: in every test view, as other files under `tests/`.
        common = [
          "tv-0.1.0-test"
          "tv-0.1.0-test-bar"
          "tv-0.1.0-test-foo"
          "tv-0.1.0-test-tool"
          "tv-0.1.0-test-x"
          "tv-0.1.0-test-y"
        ];
      };
      reader = targetViewsRepo "echo '#[path = \"bar.rs\"] mod bar;' >> tv/tests/foo.rs" [ ];
      readerUnit = (unitsNamed (inst reader) "test")."tv-0.1.0-test-foo";
    in
    assert lib.assertMsg (
      got == want
    ) "target-views: changed units ${builtins.toJSON got}, expected ${builtins.toJSON want}";
    assert lib.assertMsg
      (lib.elem "tv-0.1.0-build-run" exampleRun && lib.elem "tv-0.1.0-lib" exampleRun)
      "target-views: without predictSources, an example edit changed only ${builtins.toJSON exampleRun}";
    assert lib.assertMsg (lib.elem "tv-0.1.0-test-bar" off && lib.elem "tv-0.1.0-test" off)
      "target-views: with scopeTargetRoots = false, an edit to tests/foo.rs changed only ${builtins.toJSON off}";
    assert lib.assertMsg (
      runOf (targetViewsRepo fooEdit [ ]) "bar" != runOf targetViews "bar"
    ) "target-views: an edit to tests/foo.rs left bar's test run unchanged";
    pkgs.runCommand "target-views"
      {
        foo = (inst targetViews).testRuns.tv.foo;
        lib = (inst targetViews).testRuns.tv."lib/tv";
        tool = targetViews.workspaces.main.packages.tv;
        hint = expectFailure "target-views-hint" readerUnit [
          "tests/bar.rs"
          "packages.tv.scopeTargetRoots = false"
        ];
      }
      ''
        grep -q 'test foo ... ok' $foo/log
        [ "$($tool/bin/tool)" = 43 ]
        touch $out
      '';

  # Source prediction (`predictSources`): an edit to a file no unit of ps
  # reads (README.md, a comment in Cargo.toml) changes no unit; without
  # it, the README edit changes every unit of ps. A file the build script
  # declares changes the run and what reads its output; one the library
  # includes changes the library's compiles and what links them. A proc
  # macro's read that prediction does not see fails with a hint naming
  # predictSources.keep, and the kept path builds.
  predict-sources =
    let
      changedBy =
        edit: modules: changedUnits (predictSourcesRepo null modules) (predictSourcesRepo edit modules);
      readme = "echo more >> ps/README.md";
      psUnits = lib.filter (lib.hasPrefix "ps-");
      got = {
        readme = changedBy readme [ ];
        manifest = changedBy "sed -i 's/^# A comment.*/# An edited comment./' ps/Cargo.toml" [ ];
        notes = changedBy "echo more >> ps/NOTES.md" [ ];
        proto = psUnits (changedBy "echo more >> ps/proto/x.proto" [ ]);
        data = psUnits (changedBy "echo -n more >> ps/src/data.txt" [ ]);
      };
      want = {
        readme = [ ];
        manifest = [ ];
        notes = [ ];
        proto = [
          "ps-0.1.0-bin"
          "ps-0.1.0-build-run"
          "ps-0.1.0-lib"
          "ps-0.1.0-test"
          "ps-0.1.0-test-t"
        ];
        data = [
          "ps-0.1.0-bin"
          "ps-0.1.0-lib"
          "ps-0.1.0-test"
          "ps-0.1.0-test-t"
        ];
      };
      off = psUnits (changedBy readme [ { packages.ps.predictSources.enable = lib.mkForce false; } ]);
      missing = predictSourcesRepo null [ { packages.ps.predictSources.keep = lib.mkForce [ ]; } ];
      specsOf = repo: variant: repo.workspaces.main.instances.${native}.${variant}.sources.predictedSpecs;
      specs = specsOf predictSources "default";
      runKey = "src:ps#run/custom-build/build-script-build";
      # A clippy variant keeps the workspace's Cargo.toml (the compiles'
      # working directory's), which clippy reads.
      clippy = predictSourcesRepo null [
        {
          workspaces.main.variants.clippy.mode = "clippy";
        }
      ];
      noRuns = specsOf (predictSourcesRepo null [
        { packages.ps.predictSources.buildScriptRuns = false; }
      ]) "default";
      overlaid = specsOf (predictSourcesRepo null [
        { packages.ps.sourceOverlay."assets" = ./.; }
      ]) "default";
      missingLib = (unitsNamed (inst missing) "build")."ps-0.1.0-lib";
    in
    assert lib.assertMsg (
      got == want
    ) "predict-sources: changed units ${builtins.toJSON got}, expected ${builtins.toJSON want}";
    assert lib.assertMsg (lib.elem "ps-0.1.0-lib" off)
      "predict-sources: without predictSources, a README edit changed only ${builtins.toJSON off}";
    assert lib.assertMsg
      (specs.${runKey}.kind == "run" && specs."src:ps#lib/ps".keep == [ "ps/templates" ])
      "predict-sources: specs ${builtins.toJSON (lib.mapAttrs (_: s: { inherit (s) kind keep; }) specs)}";
    assert lib.assertMsg (lib.elem "Cargo.toml"
      (specsOf clippy "clippy")."src:ps#lib/ps".keep
    ) "predict-sources: a clippy variant's lib view does not keep the workspace's Cargo.toml";
    assert lib.assertMsg (
      !(noRuns ? ${runKey}) && noRuns ? "src:ps#lib/ps"
    ) "predict-sources: with buildScriptRuns = false the run is still predicted";
    assert lib.assertMsg (
      overlaid == { }
    ) "predict-sources: a package with a sourceOverlay is predicted";
    pkgs.runCommand "predict-sources"
      {
        ps = predictSources.workspaces.main.packages.ps;
        t = (inst predictSources).testRuns.ps.t;
        hint = expectFailure "predict-sources-hint" missingLib [
          "ps/templates/page.txt"
          "packages.ps.predictSources.keep"
        ];
      }
      ''
        [ "$($ps/bin/ps)" = "42 data page proto" ]
        touch $out
      '';

  # A nextest run's synthesized cargo metadata names other packages only
  # by name: bumping the version of `solo`, which nx does not depend on,
  # leaves nx's nextest runs the same derivations.
  nextest-unrelated-version =
    let
      repo =
        root:
        mkRepo root [
          (oneWs ".")
          {
            packages.nx.test = {
              runner = "nextest";
              nextest.profile = "ci";
            };
          }
        ];
      before = repo (fixtures + "/nextest");
      after = repo (
        edited "nextest" ''
          sed -i 's/^version = "0.1.0"/version = "0.1.1"/' solo/Cargo.toml
          sed -i '/^name = "solo"/{n;s/0.1.0/0.1.1/}' Cargo.lock
        ''
      );
      runs = r: lib.mapAttrs (_: d: d.drvPath) (inst r).testRuns.nx;
      soloRun = r: (inst r).testRuns.solo."lib/solo".drvPath;
    in
    assert lib.assertMsg (
      soloRun before != soloRun after
    ) "nextest-unrelated-version: the edit did not change solo";
    assert lib.assertMsg (runs before == runs after)
      "nextest-unrelated-version: solo's version bump changed nx's runs ${builtins.toJSON (runs after)}";
    evalCheck "nextest-unrelated-version" (builtins.toJSON (runs before));

  # The same test units where Cargo passes no `--test`: in the clippy
  # variant (`cargo check --all-targets`, which checks the integration test
  # and the bench without the libtest harness, and the example), and in the
  # bench variant (the bench reads `testdata/`, in `test.sourceScope`).
  test-only-variants =
    let
      repo = testOnlyRepo null [
        {
          workspaces.main.variants = {
            clippy = {
              mode = "clippy";
              profile = "dev";
            };
            bench = {
              profile = "bench";
              benches = true;
            };
          };
        }
      ];
      i = repo.workspaces.main.instances.${native};
      t = repo.workspaces.main.target.${native};
      clippyTest = lib.attrNames (unitsNamed i.clippy "test");
      benchUnits = lib.attrNames (unitsNamed i.bench "bench");
    in
    assert lib.assertMsg (lib.all (n: lib.elem n clippyTest) [
      "proto-0.1.0-test-datadriven"
      "proto-0.1.0-test-unharnessed"
      "proto-0.1.0-test-reads_tests"
    ]) "test-only-variants: clippy test-plan units ${builtins.toJSON clippyTest}";
    assert lib.assertMsg (lib.elem "proto-0.1.0-test-unharnessed" benchUnits)
      "test-only-variants: bench-plan units ${builtins.toJSON benchUnits}";
    pkgs.runCommand "test-only-variants"
      {
        clippy = t.variants.clippy.check;
        bench = t.variants.bench.benches.proto.unharnessed;
      }
      ''
        [ "$($bench/bin/unharnessed)" = "unharnessed: ok" ]
        cp $clippy/units $out
      '';

  # A library that reads a test-only path at compile time fails with a hint
  # naming the option that keeps it; with `scopeTestsDir = false` it builds.
  test-only-hint =
    pkgs.runCommand "test-only-hint"
      {
        tests =
          expectFailure "test-only-tests"
            (protoLib (testOnlyRepo (includeFrom "tests/fixtures/input.txt") [ ]))
            [
              "proto/tests/fixtures/input.txt"
              "packages.proto.test.scopeTestsDir = false"
            ];
        scope =
          expectFailure "test-only-scope" (protoLib (testOnlyRepo (includeFrom "testdata/more.txt") [ ]))
            [
              "proto/testdata/more.txt"
              "packages.proto.test.sourceScope"
              "packages.proto.extraSources"
            ];
        optOut = protoLib (testOnlyRepo (includeFrom "tests/fixtures/input.txt") [ testOnlyOptOut ]);
      }
      ''
        cat $tests/log $scope/log
        touch $out
      '';

  # `packages.<name>.sources` (`sourcesModule`): an edit to a file only
  # lint's unit tests read (a snapshot, its README, a comment in its
  # manifest) changes only lint's test harness; an edit to run-only data
  # or to a root file cli leaves out changes no unit; the data edit
  # changes cli's test run. Each view holds what the functions chose, the
  # layers' functions in order, and every unit builds and passes.
  sources =
    let
      lintTest = [ "lint-0.1.0-test" ];
      changedBy = edit: changedUnits sources (sourcesRepo edit);
      cases = {
        snapshot = [
          "echo >> lint/src/snapshots/answer.snap"
          lintTest
        ];
        readme = [
          "echo More. >> lint/README.md"
          lintTest
        ];
        manifest = [
          "echo '# A comment.' >> lint/Cargo.toml"
          lintTest
        ];
        data = [
          "echo >> data/input.txt"
          [ ]
        ];
        notes = [
          "echo More. >> notes.md"
          [ ]
        ];
      };
      got = lib.mapAttrs (_: c: changedBy (lib.head c)) cases;
      wrong = lib.filterAttrs (n: g: g != lib.last cases.${n}) got;
      i = inst sources;
      runOf = repo: (inst repo).testRuns.cli.data;
      lintRun = i.testRuns.lint."lib/lint";
    in
    assert lib.assertMsg (wrong == { }) "sources: changed units ${builtins.toJSON wrong}";
    assert lib.assertMsg (
      (runOf sources).drvPath != (runOf (sourcesRepo (lib.head cases.data))).drvPath
    ) "sources: the data edit left cli's test run unchanged";
    pkgs.runCommand "sources"
      {
        cliView = i.sources.workspace."";
        lintView = i.sources.workspace.lint;
        cliRun = runOf sources;
        cliDir = (runOf sources).passthru.breakbulkTest.sourceDir;
        inherit lintRun;
        lintDir = lintRun.passthru.breakbulkTest.sourceDir;
        app = sources.workspaces.main.packages.cli;
      }
      ''
        [ "$(cd $cliView && find . -type f | sort | tr '\n' ' ')" = "./Cargo.toml ./src/main.rs " ]
        [ "$(cd $lintView && find . -type f | sort | tr '\n' ' ')" = "./lint/src/lib.rs " ]
        [ -f $cliDir/data/input.txt ] && [ ! -e $cliDir/notes.md ]
        [ -f $lintDir/../data/input.txt ] && [ -f $lintDir/../data/other.txt ] && [ ! -e $lintDir/../data/unused.txt ]
        [ -f $lintDir/src/snapshots/answer.snap ]
        grep -q 'test reads_run_data ... ok' $cliRun/log
        grep -q 'test tests::matches_snapshot ... ok' $lintRun/log
        [ "$($app/bin/cli)" = 42 ]
        touch $out
      '';

  # A unit of each kind that fails reading a path its source view lacks
  # names the path and the option that adds it; with those options set,
  # each builds.
  view-hints =
    let
      i = inst viewHints;
      fixed = inst viewHintsFixed;
      build = unitsNamed i "build";
      test = unitsNamed i "test";
      missing = "`shared/data.txt` is not in this unit's source view; if it is in the repository, add it to";
    in
    pkgs.runCommand "view-hints"
      {
        lib = expectFailure "view-hints-lib" build."lib-reads-0.1.0-lib" [
          "${missing} `packages.lib-reads.extraSources`"
        ];
        # A `sources` function left the file out: the option for the kind.
        chosen = expectFailure "view-hints-chosen" build."chosen-reads-0.1.0-lib" [
          "`crates/chosen-reads/data.txt` is not in this unit's source view; if it is in the repository, add it to `packages.chosen-reads.extraSources`"
        ];
        run = expectFailure "view-hints-run" build."script-reads-0.1.0-build-run" [
          "${missing} `packages.script-reads.extraSources`"
        ];
        testCompile = expectFailure "view-hints-test" test."test-reads-0.1.0-test-reads" [
          "${missing} `packages.test-reads.test.sourceScope`"
        ];
        testRun = expectFailure "view-hints-test-run" i.testRuns.run-reads.reads [
          "${missing} `packages.run-reads.test.sourceScope`"
        ];
        doctest = expectFailure "view-hints-doctest" i.doctests.doc-reads [
          "${missing} `packages.doc-reads.test.sourceScope`"
        ];
        libToTests = expectFailure "view-hints-lib-to-tests" i.testRuns.lib-to-tests.fixture [
          "`crates/lib-to-tests/tests/fixtures/input.txt` is in the package's `tests/` directory"
          "`packages.lib-to-tests.test.scopeTestsDir = false`"
        ];
        fixedLib = (unitsNamed fixed "build")."lib-reads-0.1.0-lib";
        fixedRun = (unitsNamed fixed "build")."script-reads-0.1.0-build-run";
        fixedTestRun = fixed.testRuns.run-reads.reads;
        fixedDoctest = fixed.doctests.doc-reads;
        fixedLibToTests = fixed.testRuns.lib-to-tests.fixture;
        # The test run built the integration test that failed to compile.
        fixedTestCompile = fixed.testRuns.test-reads.reads;
      }
      ''
        cat $lib/log $chosen/log $run/log $testCompile/log $testRun/log $doctest/log $libToTests/log
        touch $out
      '';

  # Snapshot tests (`snapshotsModule`), in a workspace at `ws/`: snapbox
  # and expect-test find their files through the workspace's root
  # Cargo.toml in the test view, insta through INSTA_WORKSPACE_ROOT; all
  # three pass. The curated insta default sets INSTA_WORKSPACE_ROOT (a
  # function of the run) to the workspace directory of the files each
  # run reads: the "run" view for a test run (narrower with `runFiles`),
  # the test view for the doctest (a test app with `checkout`:
  # tests/test-runs).
  # `other` does not depend on insta and gets nothing; `null` turns the
  # default off. A function in `memberDefaults` gets each member's own
  # root. The root manifest is in no "build" view: an edit to it
  # changes only the members' test units, and none with
  # `test.workspaceManifest = false`. The curated default also leaves the
  # snapshots out of every view but the runs', so an edit to the snapshot
  # under src/ changes no unit, only snaps' test runs, which read the
  # "run" view with them (INSTA_WORKSPACE_ROOT there).
  snapshots =
    let
      changedBy = edit: modules: changedUnits (snapshotsRepo null modules) (snapshotsRepo edit modules);
      rootEdit = "echo '# A comment.' >> ws/Cargo.toml";
      got = {
        root = changedBy rootEdit [ ];
        rootOff = changedBy rootEdit [ { workspaces.main.memberDefaults.test.workspaceManifest = false; } ];
        snapshot = changedBy "echo >> ws/crates/snaps/src/snapshots/snaps__tests__render.snap" [ ];
        snapshotOff = changedBy "echo >> ws/crates/snaps/src/snapshots/snaps__tests__render.snap" [
          { sysDefaults.dependents.insta = null; }
        ];
      };
      want = rec {
        root = [
          "other-0.1.0-test"
          "snaps-0.1.0-test"
          "snaps-0.1.0-test-expect"
          "snaps-0.1.0-test-snapbox"
        ];
        rootOff = [ ];
        snapshot = [ ];
        # Without the default the snapshot is in every view.
        snapshotOff = [
          "snaps-0.1.0-lib"
          "snaps-0.1.0-test"
          "snaps-0.1.0-test-expect"
          "snaps-0.1.0-test-snapbox"
        ];
      };
      snapshotEdit = snapshotsRepo "echo >> ws/crates/snaps/src/snapshots/snaps__tests__render.snap" [ ];
      i = inst snapshots;
      runs = i.testRuns.snaps;
      runRoot = lib.head (exported runs."lib/snaps" "INSTA_WORKSPACE_ROOT");
      script = r: r.drvAttrs.buildCommand;
      exported = r: k: builtins.match ".*\nexport ${k}=([^\n]*)\n.*" (script r);
      doctestEnv =
        inst: p:
        builtins.fromJSON (
          builtins.unsafeDiscardStringContext inst.doctests.${p}.drvAttrs.BREAKBULK_TEST_ENV
        );
      testView = i: p: "${i.sources.workspaceTest."ws/crates/${p}"}";
      wsIn = v: "${v}/ws";
      narrowed = inst (snapshotsRepo null [ { packages.snaps.test.runFiles = [ "src/snapshots" ]; } ]);
      narrowedRoot = lib.head (exported narrowed.testRuns.snaps."lib/snaps" "INSTA_WORKSPACE_ROOT");
      off = inst (snapshotsRepo null [ { sysDefaults.dependents.insta = null; } ]);
      ownFn = inst (
        snapshotsRepo null [
          { workspaces.main.memberDefaults.test.env.MY_ROOT = run: "${run.workspaceRoot}/x"; }
        ]
      );
    in
    assert lib.assertMsg (
      got == want
    ) "snapshots: changed units ${builtins.toJSON got}, expected ${builtins.toJSON want}";
    assert lib.assertMsg (
      (inst snapshotEdit).testRuns.snaps."lib/snaps".drvPath != runs."lib/snaps".drvPath
    ) "snapshots: an edit to a snapshot left the test run unchanged";
    assert lib.assertMsg
      (
        runRoot != wsIn (testView i "snaps")
        && lib.hasSuffix "/ws" runRoot
        && builtins.pathExists "${runRoot}/crates/snaps/src/snapshots/snaps__tests__render.snap"
        && !(builtins.pathExists "${testView i "snaps"}/ws/crates/snaps/src/snapshots/snaps__tests__render.snap")
      )
      "snapshots: the run's INSTA_WORKSPACE_ROOT is ${runRoot}, not the workspace directory of the run view with the snapshots";
    assert lib.assertMsg (
      exported runs."lib/snaps" "INSTA_UPDATE" == [ "no" ]
    ) "snapshots: INSTA_UPDATE";
    assert lib.assertMsg (
      (doctestEnv i "snaps").INSTA_WORKSPACE_ROOT or null == wsIn (testView i "snaps")
    ) "snapshots: the doctest's env ${builtins.toJSON (doctestEnv i "snaps")}";
    assert lib.assertMsg (
      exported i.testRuns.other."lib/other" "INSTA_WORKSPACE_ROOT" == null
      && !((doctestEnv i "other") ? INSTA_UPDATE)
    ) "snapshots: other, which does not depend on insta, got insta's settings";
    assert lib.assertMsg
      (
        narrowedRoot != wsIn (testView narrowed "snaps")
        && lib.hasSuffix "/ws" narrowedRoot
        && builtins.pathExists "${narrowedRoot}/crates/snaps/src/snapshots"
        && !(builtins.pathExists "${narrowedRoot}/crates/snaps/tests")
      )
      "snapshots: with runFiles, INSTA_WORKSPACE_ROOT is ${narrowedRoot}, not the run view's workspace directory";
    assert lib.assertMsg (
      exported off.testRuns.snaps."lib/snaps" "INSTA_WORKSPACE_ROOT" == null
    ) "snapshots: `sysDefaults.dependents.insta = null` left the default";
    assert lib.assertMsg (
      exported ownFn.testRuns.other."lib/other" "MY_ROOT" == [ "${wsIn (testView ownFn "other")}/x" ]
      &&
        exported ownFn.testRuns.snaps."lib/snaps" "MY_ROOT"
        == [ "${lib.head (exported ownFn.testRuns.snaps."lib/snaps" "INSTA_WORKSPACE_ROOT")}/x" ]
    ) "snapshots: a memberDefaults function did not get each member's root";

    pkgs.runCommand "snapshots"
      {
        view = i.sources.workspace."ws/crates/snaps";
        lib = runs."lib/snaps";
        inherit (runs) snapbox expect;
      }
      ''
        [ ! -e $view/ws/Cargo.toml ] && [ ! -e $view/ws/crates/snaps/src/snapshots ]
        grep -q 'test tests::render ... ok' $lib/log
        grep -q 'test render ... ok' $snapbox/log
        grep -q 'test render ... ok' $expect/log
        touch $out
      '';

  # Override keys: name, name@requirement, the version option; merging
  # order (versioned last); warnings for unmatched and unimplemented
  # options.
  overrides =
    let
      units = unitsNamed (inst' overrideRepo "b") "build";
      envOf =
        n: (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
      itoa = envOf "itoa-1.0.11-lib";
      libc = envOf "libc-0.2.191-lib";
      libcRun = envOf "libc-0.2.191-build-run";
      captureOf =
        n:
        (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT))
        .envCapture or "";
      ws = overrideRepo.warnings;
      has = s: lib.any (lib.hasInfix s) ws;
    in
    # Inputs give the package its own env capture on both platforms; other
    # packages keep the base capture.
    assert lib.assertMsg (
      lib.hasInfix "breakbulk-env-shared" (captureOf "shared-0.1.0-lib")
      && lib.hasInfix "breakbulk-env-shared" (captureOf "shared-0.1.0-build-script")
      && lib.hasInfix "breakbulk-env-base" (captureOf "itoa-1.0.11-lib")
    ) "overrides: env captures `${captureOf "shared-0.1.0-lib"}` `${captureOf "itoa-1.0.11-lib"}`";
    assert lib.assertMsg (
      itoa.ITOA_CARET or null == "1" && !(itoa ? ITOA_TWO)
    ) "overrides: itoa env ${builtins.toJSON itoa}";
    assert lib.assertMsg (
      libc.LIBC or null == "exact" && libcRun.LIBC or null == "exact"
    ) "overrides: libc env ${builtins.toJSON libc}";
    assert lib.assertMsg (!((envOf "shared-0.1.0-lib") ? LIBC)) "overrides: libc's env reached shared";
    # targets.<triple>.env reaches target units only, never host units
    # (build-script compiles).
    assert lib.assertMsg (
      libc.TARGET_MARK or null == "t" && !((envOf "libc-0.2.191-build-script") ? TARGET_MARK)
    ) "overrides: target env placement";
    assert lib.assertMsg (has "`packages.not-in-any-lockfile` matches no package")
      "overrides: no unmatched warning: ${builtins.toJSON ws}";
    assert lib.assertMsg (has "`packages.itoa` matches no package")
      "overrides: itoa >=2 should match nothing";
    assert lib.assertMsg (has "`packages.libc.sourceOverlay` has no effect on libc 0.2.191")
      "overrides: no sourceOverlay warning: ${builtins.toJSON ws}";
    assert lib.assertMsg (has "packages.app-b.pipelining")
      "overrides: no warning for pipelining (not implemented)";
    # targets.<triple>.rustflags reach target units only.
    assert lib.assertMsg (
      lib.hasInfix "bb_target_mark" units."libc-0.2.191-lib".drvAttrs.BREAKBULK_UNIT
      && !(lib.hasInfix "bb_target_mark" units."libc-0.2.191-build-script".drvAttrs.BREAKBULK_UNIT)
    ) "overrides: target rustflags placement";
    assert lib.assertMsg (!(has "openssl-sys")) "overrides: a curated default warned";
    assert lib.assertMsg (
      libc.LIBC_VARIANT or null == "1"
      && !((envOf "libc-0.2.191-build-script") ? LIBC_VARIANT)
      && (envOf "libc-0.2.191-build-script").LIBC_VARIANT_HOST or null == "1"
      && !(libc ? LIBC_VARIANT_HOST)
    ) "overrides: variant layer env placement";
    assert lib.assertMsg (
      (builtins.readDir (inst' overrideRepo "b").sources.workspace.b) ? c
    ) "overrides: the variant layer's extraSources are not in b's view";
    assert lib.assertMsg (
      has "`packages.libc.variant.not-a-variant` names no variant of any workspace"
      && has "`workspaces.b.memberDefaults.variant.not-a-variant-of-b` names no variant of workspaces.b (default)"
    ) "overrides: no warning for a variant layer that names no variant: ${builtins.toJSON ws}";
    evalCheck "overrides" (builtins.toJSON ws);

  # Version requirements, against the semver crate's rules.
  version-req =
    let
      m = breakbulk.versionReq.matches;
      cases = [
        [
          "1.2.3"
          "1.2.3"
          true
        ]
        [
          "1.2.3"
          "1.3.0"
          true
        ]
        [
          "1.2.3"
          "2.0.0"
          false
        ]
        [
          "^0.2.3"
          "0.2.9"
          true
        ]
        [
          "^0.2.3"
          "0.3.0"
          false
        ]
        [
          "^0.0.3"
          "0.0.4"
          false
        ]
        [
          "~1.2"
          "1.2.9"
          true
        ]
        [
          "~1.2"
          "1.3.0"
          false
        ]
        [
          "~1.2.3"
          "1.2.2"
          false
        ]
        [
          "=1.2"
          "1.2.7"
          true
        ]
        [
          ">=0.42.0"
          "0.42.0"
          true
        ]
        [
          "<0.42.0"
          "0.41.9"
          true
        ]
        [
          "<0.42.0"
          "0.42.0"
          false
        ]
        [
          ">=1, <2"
          "1.9.9"
          true
        ]
        [
          ">=1, <2"
          "2.0.0"
          false
        ]
        [
          "1.*"
          "1.7.0"
          true
        ]
        [
          "1.2.*"
          "1.3.0"
          false
        ]
        [
          "*"
          "9.9.9"
          true
        ]
        [
          "1.2.3"
          "1.2.4-alpha"
          false
        ]
        [
          ">=1.2.4-alpha"
          "1.2.4-beta"
          true
        ]
        [
          ">1.2"
          "1.2.9"
          false
        ]
        [
          ">1.2"
          "1.3.0"
          true
        ]
        [
          "<=1.2"
          "1.2.9"
          true
        ]
      ];
      bad = lib.filter (c: m (lib.elemAt c 0) (lib.elemAt c 1) != lib.elemAt c 2) cases;
      # `isReq` (the `versionReq` option type): every requirement above, and
      # none of these.
      notReqs = [
        ""
        " , "
        "1.2.3.4"
        ">=nope"
        "1.2, foo"
        "=>1"
      ];
      badReqs =
        lib.filter (c: !breakbulk.versionReq.isReq (lib.head c)) cases
        ++ lib.filter breakbulk.versionReq.isReq notReqs;
    in
    assert lib.assertMsg (bad == [ ]) "version-req: wrong results for ${builtins.toJSON bad}";
    assert lib.assertMsg (badReqs == [ ]) "version-req: isReq wrong for ${builtins.toJSON badReqs}";
    evalCheck "version-req" "ok";

  # The dev shell: CARGO_BUILD_TARGET, inputs of the packages present, and
  # the warning for CARGO_* variables.
  devshell =
    let
      shell = provided.workspaces.main.devShell;
    in
    pkgs.runCommand "devshell"
      {
        inherit (shell) shellHook;
        target = shell.CARGO_BUILD_TARGET or shell.env.CARGO_BUILD_TARGET or "";
      }
      ''
        [ "$target" = ${native} ]
        export HOME=$TMPDIR CARGO_INCREMENTAL=1 CARGO_TARGET_DIR=x RUSTFLAGS=-g breakbulkOwnEnv=CARGO_BUILD_TARGET
        out_=$out
        eval "$shellHook" 2> warnings
        cat warnings
        grep -q 'CARGO_INCREMENTAL is set' warnings
        grep -q 'RUSTFLAGS is set' warnings
        ! grep -q CARGO_TARGET_DIR warnings
        touch $out_
      '';

  # The dev shell does not need the plan. With a member's
  # Cargo.toml broken (planning would fail), the shell still evaluates and
  # carries the native spec's Cargo env config (the default linux
  # preset's linker), computed from Cargo config files and rustc only.
  devshell-broken-manifest =
    let
      broken = mkRepo (edited "stamps" "echo 'this is [not toml' >> tool/Cargo.toml") [ (oneWs ".") ];
      shell = broken.workspaces.main.devShell;
      linkerVar = "CARGO_TARGET_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] native)}_LINKER";
      linker = shell.${linkerVar} or shell.env.${linkerVar} or "";
    in
    assert lib.assertMsg (lib.hasSuffix "cc-default" linker)
      "devshell-broken-manifest: no linker in the shell (${linker})";
    pkgs.runCommand "devshell-broken-manifest"
      {
        inherit (shell) shellHook;
        inherit linker;
      }
      ''
        export HOME=$TMPDIR
        eval "$shellHook"
        [ -x "$linker" ]
        echo "$linker" > $out
      '';

  # #23: a build script that places a file next to the binaries (Cargo's
  # `target/<profile>`) gets the default `buildScriptFiles` check, which
  # fails naming the file and the two ways out; with the
  # `buildScriptFiles` stage the product holds the file and the check
  # passes. Only products that depend on the build script are asked for
  # its files: in a workspace with an unrelated member, that member's
  # check passes.
  build-script-files =
    let
      wsOf =
        extra:
        (mkRepo (fixtures + "/out-dir-walk") [
          (oneWs ".")
          extra
        ]).workspaces.main;
      plain = (wsOf { }).packages.out-dir-walk;
      staged =
        (wsOf {
          packages.out-dir-walk.stages.buildScriptFiles = {
            after = "splitDebug";
            before = "install";
            run = breakbulk.stages.helpers.buildScriptFiles { };
          };
        }).packages.out-dir-walk;
      off = (wsOf { packages.out-dir-walk.checks.buildScriptFiles = null; }).packages.out-dir-walk;
      # The fixture as one member of a workspace with `other`, which does not
      # depend on it: only out-dir-walk's check names walked.txt.
      twoMembers = edited "out-dir-walk" ''
        mkdir walk other other/src
        mv build.rs src tests walk/
        sed -e '/^\[workspace\]/d' -e '/^#/d' Cargo.toml > walk/Cargo.toml
        printf '[workspace]\nresolver = "2"\nmembers = ["walk", "other"]\n' > Cargo.toml
        printf '[package]\nname = "other"\nversion = "0.1.0"\nedition = "2021"\n' > other/Cargo.toml
        echo 'fn main() {}' > other/src/main.rs
        printf '\n[[package]]\nname = "other"\nversion = "0.1.0"\n' >> Cargo.lock
      '';
      twoWs = (mkRepo twoMembers [ (oneWs ".") ]).workspaces.main.packages;
    in
    assert lib.assertMsg (
      !(off.checks ? buildScriptFiles)
    ) "build-script-files: the check is not removable";
    pkgs.runCommand "build-script-files"
      {
        failure = pkgs.testers.testBuildFailure plain.checks.buildScriptFiles;
        inherit staged;
        stagedCheck = staged.checks.buildScriptFiles;
        otherCheck = twoWs.other.checks.buildScriptFiles;
        walkFailure = pkgs.testers.testBuildFailure twoWs.out-dir-walk.checks.buildScriptFiles;
      }
      ''
        log=$failure/testBuildFailure.log
        cat $log
        grep -qF 'but out-dir-walk does not include them' $log
        grep -qF 'walked.txt (from ' $log
        # The message's stanza is the one used above.
        grep -qF 'packages.out-dir-walk.stages.buildScriptFiles = { after = "splitDebug"; before = "install"; run = breakbulk.stageHelpers.buildScriptFiles { }; };' $log
        grep -qF 'packages.out-dir-walk.checks.buildScriptFiles = null' $log
        [ "$(cat $staged/walked.txt)" = profile ]
        grep -qF 'walked.txt (from ' $walkFailure/testBuildFailure.log
        [ -x $staged/bin/out-dir-walk ]
        touch $out
      '';

  # Cargo config `include` (stable since Cargo 1.93): the files a
  # `.cargo/config.toml` includes, transitively, are in the planning and
  # config skeletons. Planning sees the included `build.rustflags` (`app`
  # fails to compile without them), the dev shell's `cargo-env.json` builds,
  # and `defaultTarget` reads an included `build.target`. A missing
  # optional include is skipped.
  cargo-config-include =
    let
      root = edited "stamps" ''
        mkdir -p .cargo
        cat > .cargo/config.toml <<'TOML'
        include = ["shared.toml", { path = "absent.toml", optional = true }]
        TOML
        cat > .cargo/shared.toml <<'TOML'
        include = ["../more.toml"]
        [build]
        rustflags = ["--cfg", "included_flag", "--check-cfg", "cfg(included_flag)"]
        TOML
        cat > more.toml <<'TOML'
        [build]
        target = "aarch64-unknown-uefi"
        TOML
        printf '#[cfg(not(included_flag))]\ncompile_error!("the included rustflags are missing");\n' >> app/src/main.rs
      '';
      ws = (mkRepo root [ (oneWs ".") ]).workspaces.main;
      uefi =
        (mkRepo root [
          (oneWs ".")
          {
            workspaces.main.targets = {
              x86_64-unknown-uefi = { };
              aarch64-unknown-uefi = { };
            };
          }
        ]).workspaces.main;
      got = {
        configFiles = breakbulk.skeleton.configFiles { inherit root; };
        defaultTarget = uefi.devShell.drvAttrs.CARGO_BUILD_TARGET or null;
        cargoEnvWarnings =
          (builtins.fromJSON (
            builtins.unsafeDiscardStringContext (
              builtins.readFile "${ws.instances.${native}.default.cargoEnv}/cargo-env.json"
            )
          )).warnings;
      };
      want = {
        configFiles = [
          ".cargo/config.toml"
          ".cargo/shared.toml"
          "more.toml"
        ];
        defaultTarget = "aarch64-unknown-uefi";
        cargoEnvWarnings = [ ];
      };
    in
    assert lib.assertMsg (got == want) "cargo-config-include: ${builtins.toJSON got}";
    pkgs.runCommand "cargo-config-include" { app = ws.packages.app; } ''
      [ -x $app/bin/app ]
      touch $out
    '';

  # On Cargo 1.101 (rust-overlay's nightly) the dev shell
  # decides CARGO_PROFILE_DEV_TRIM_PATHS by the planner's file-reading
  # rule, without a plan: with the workspace root's Cargo.toml broken, the
  # shell still evaluates and sets it (cargo-env.json carries a warning
  # naming the file); a project that declares trim-paths in any profile
  # gets no variable; `cargoTrimPaths = false` and `sourcePaths = "keep"`
  # set none either, and `cargoTrimPaths = true` sets it over the
  # project's own setting.
  devshell-trim-paths-files =
    let
      nightly = pkgs.rust-bin.nightly.latest.minimal;
      ws =
        root: extra:
        (mkRepo root [
          (oneWs ".")
          {
            workspaces.main = {
              toolchain = {
                rustc = nightly;
                cargo = nightly;
              };
            }
            // extra;
          }
        ]).workspaces.main;
      brokenRoot = edited "stamps" "echo 'this is [not toml' >> Cargo.toml";
      declares = edited "stamps" ''printf '\n[profile.bench.package.tool]\ntrim-paths = "none"\n' >> Cargo.toml'';
      var = "CARGO_PROFILE_DEV_TRIM_PATHS";
      shellVar = w: w.devShell.${var} or w.devShell.env.${var} or null;
      cargoEnvOf =
        w:
        builtins.fromJSON (
          builtins.unsafeDiscardStringContext (
            builtins.readFile "${w.instances.${native}.default.cargoEnv}/cargo-env.json"
          )
        );
      broken = ws brokenRoot { };
      got = {
        broken = shellVar broken;
        brokenWarned = lib.any (lib.hasInfix "is not valid TOML") (cargoEnvOf broken).warnings;
        declares = shellVar (ws declares { });
        forced = shellVar (ws declares { cargoTrimPaths = true; });
        off = shellVar (ws (fixtures + "/stamps") { cargoTrimPaths = false; });
        keep = shellVar (ws (fixtures + "/stamps") { sourcePaths = "keep"; });
      };
      want = {
        broken = "all";
        brokenWarned = true;
        declares = null;
        forced = "all";
        off = null;
        keep = null;
      };
    in
    assert lib.assertMsg (got == want) "devshell-trim-paths-files: ${builtins.toJSON got}";
    evalCheck "devshell-trim-paths-files" (builtins.toJSON got);

  # Git dependencies built through units: instantiation finds each fetched
  # source under Cargo's package id, which keeps `git+` and the reference
  # query, and leaves the name out when the URL ends in it.
  pkgid-short = pkgs.runCommand "pkgid-short" { app = pkgidShort.workspaces.main.packages.app; } ''
    [ "$($app/bin/app)" = "gitdep 43" ]
    touch $out
  '';

  # A git crate's build script reads a repository path from Cargo config
  # `[env]`: the run fails, and the hint names the package's `env` setting
  # with that path; with it set, the product builds.
  env-repository-path =
    pkgs.runCommand "env-repository-path"
      {
        run =
          expectFailure "env-repository-path-run"
            (unitsNamed (inst envRepoPath) "build")."envdep-0.1.0-build-run"
            [
              "`envdep` was given the repository path `app/vendor/envdep` in `ENVDEP_DIR` (from Cargo config `[env]`)"
              "set `packages.envdep.env.ENVDEP_DIR = ./app/vendor/envdep;`"
            ];
        app = envRepoPathFixed.workspaces.main.packages.app;
      }
      ''
        cat $run/log
        [ "$($app/bin/app)" = 42 ]
        touch $out
      '';

  # With the prediction alone, and with `roots` replacing it, the
  # repository builds tool's product, test runs and doctest, with no "not
  # implemented" warning. A `roots` list that lacks a root of the plan
  # fails instantiation, naming the root and the option.
  roots-override =
    let
      fnInst = inst rootsEnvFn;
      wsRootOf =
        pkg: key:
        builtins.match ".*\nexport WS_ROOT=([^\n]*)\n.*"
          fnInst.testRuns.${pkg}.${key}.drvAttrs.buildCommand;
      check =
        name: repo:
        let
          w = repo.workspaces.main;
        in
        assert lib.assertMsg (
          repo.warnings or [ ] == [ ]
        ) "${name}: warnings ${builtins.toJSON repo.warnings}";
        assert lib.assertMsg (
          lib.mapAttrs (_: lib.attrNames) w.tests == {
            app = [ "bin-app" ];
            tool = [
              "bin-tool"
              "lib"
            ];
          }
        ) "${name}: tests ${builtins.toJSON (lib.mapAttrs (_: lib.attrNames) w.tests)}";
        {
          "${name}_app" = w.packages.app;
          "${name}_tool" = w.packages.tool;
          "${name}_toolLib" = w.tests.tool.lib;
          "${name}_toolBin" = w.tests.tool.bin-tool;
          "${name}_doctest" = w.target.${native}.doctests.tool;
        };
    in
    assert lib.assertMsg
      (
        wsRootOf "app" "bin/app" == [ "${fnInst.sources.workspaceTest.ws}/ws" ]
        && wsRootOf "tool" "lib/tool" == [ "${fnInst.sources.workspace.tool}/tool" ]
      )
      "roots-override: WS_ROOT ${
        builtins.toJSON [
          (wsRootOf "app" "bin/app")
          (wsRootOf "tool" "lib/tool")
        ]
      }";
    pkgs.runCommand "roots-override"
      (
        check "predicted" rootsPredicted
        // check "override" rootsOverride
        // {
          unpredicted = expectFailure "roots-unpredicted" (inst rootsMissing).unitsJson.build [
            "the plan has roots that were not predicted: tool/bin/tool"
            "`roots` option"
          ];
        }
      )
      ''
        for v in predicted override; do
          app=''${v}_app tool=''${v}_tool
          [ "$(''${!app}/bin/app)" = "app: hello" ]
          [ "$(''${!tool}/bin/tool)" = "tool: hello" ]
        done
        cat $unpredicted/log
        touch $out
      '';
  # The native target gets presets.linux unless another
  # preset is set, both through `preset` and by defining the target
  # directly from a preset (no doubled rustflags, no conflicting linker);
  # `preset = null` turns it off. The default reaches the plan: units carry
  # the linker wrapper of nixpkgs' rustc's choice, the cc's own linker.
  native-preset =
    let
      t =
        modules:
        (mkRepo (fixtures + "/multi-ws") ([ (oneWs "a") ] ++ modules))
        .workspaces.main.target.${native}.spec;
      dflt = t [ ];
      off = t [ { targets.${native}.preset = lib.mkForce null; } ];
      static = breakbulk.presets.linuxStatic { inherit pkgs; };
      direct = t [ { targets.${native} = static; } ];
      viaOption = t [ { targets.${native}.preset = breakbulk.presets.linuxStatic; } ];
      linkerOf = x: builtins.unsafeDiscardStringContext (toString x.linker);
      isStatic = x: lib.elem "target-feature=+crt-static" x.rustflags;
      unitText = lib.concatMapStrings (u: u.BREAKBULK_UNIT or "") (
        lib.attrValues (mwInst "a").units.build
      );
      checks = {
        # linux: the cc's own linker, and no static-linking rustflags.
        defaultIsLinuxGnu = lib.hasSuffix "cc-default" (linkerOf dflt) && dflt.rustflags == [ ];
        offIsEmpty = off.linker == null && off.rustflags == [ ] && off.packageSet == null;
        directKeepsOwn = isStatic direct && direct.rustflags == static.rustflags;
        optionKeepsOwn = isStatic viaOption && viaOption.rustflags == static.rustflags;
        planUsesWrapper = lib.hasInfix "cc-default" unitText;
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (bad == [ ]) "native-preset: failed ${toString bad}";
    evalCheck "native-preset" (builtins.toJSON checks);

  # The native default follows the `pkgs` given to
  # mkRepository, not the evaluating machine. With `pkgs.pkgsMusl` the
  # native triple is the musl one and its default preset linuxStatic
  # (+crt-static, PKG_CONFIG_ALL_STATIC, the musl stdenv's cc). Evaluation
  # only: nothing here builds a musl-hosted toolchain or plans (the
  # rust-overlay toolchain is never forced).
  native-preset-musl =
    let
      mp = pkgs.pkgsMusl;
      mNative = mp.stdenv.hostPlatform.rust.rustcTarget;
      repo = breakbulk.mkRepository {
        pkgs = mp;
        root = fixtures + "/multi-ws";
        tools = breakbulk.mkTools mp;
        modules = [ (oneWs "a") ];
      };
      spec = repo.workspaces.main.target.${mNative}.spec;
      ccOf = x: builtins.unsafeDiscardStringContext (toString x.cc);
      checks = {
        nativeIsMusl = mNative == "${mp.stdenv.hostPlatform.parsed.cpu.name}-unknown-linux-musl";
        defaultIsLinuxMusl = lib.hasSuffix "cc-default" (
          builtins.unsafeDiscardStringContext (toString spec.linker)
        );
        crtStatic = lib.elem "target-feature=+crt-static" spec.rustflags;
        pkgConfigStatic = (spec.env.PKG_CONFIG_ALL_STATIC or null) == "1";
        muslCc = lib.hasPrefix (builtins.unsafeDiscardStringContext (toString mp.stdenv.cc)) (ccOf spec);
        glibcStillGnu =
          (mkRepo (fixtures + "/multi-ws") [ (oneWs "a") ]).workspaces.main.target.${native}.spec.rustflags
          == [ ];
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (bad == [ ]) "native-preset-musl: failed ${toString bad}";
    evalCheck "native-preset-musl" (builtins.toJSON checks);

  # The curated -sys defaults set no switch that swaps a
  # bundled C library for a system one; their library inputs stay.
  sys-defaults-no-switches =
    let
      repo = mkRepo (fixtures + "/multi-ws") [ (oneWs "a") ];
      sysCfg = repo.config.sysDefaults.packages;
      # Every entry at an old and a new version (aws-lc-sys differs).
      settings = lib.concatMap (
        n:
        map
          (
            version:
            sysCfg.${n} {
              inherit version;
              name = n;
            }
          )
          [
            "0.41.0"
            "0.42.0"
          ]
      ) (lib.attrNames sysCfg);
      envNames = lib.concatMap (p: lib.attrNames p.env) settings;
      switches = lib.filter (
        n: builtins.match ".*_(USE_PKG_CONFIG|USE_SYSTEM|NO_VENDOR|SYSTEM)" n != null
      ) envNames;
      inputsOf =
        n: version:
        map lib.getName (
          (sysCfg.${n} {
            inherit version;
            name = n;
          }).inputs
            pkgs
        );
      awsOld = sysCfg.aws-lc-sys {
        name = "aws-lc-sys";
        version = "0.41.0";
      };
    in
    assert lib.assertMsg (switches == [ ]) "sys-defaults: system-library switches ${toString switches}";
    assert lib.assertMsg (
      inputsOf "libsqlite3-sys" "0.30.0" == [ "sqlite" ]
    ) "sys-defaults: libsqlite3-sys inputs";
    # aws-lc-sys by version: a function of the lockfile entry.
    assert lib.assertMsg (
      inputsOf "aws-lc-sys" "0.42.0" == [ "aws-lc" ]
    ) "sys-defaults: aws-lc-sys 0.42 inputs";
    assert lib.assertMsg (
      inputsOf "aws-lc-sys" "0.41.0" == [ ] && awsOld.env.AWS_LC_SYS_CMAKE_BUILDER or null == "1"
    ) "sys-defaults: aws-lc-sys 0.41 settings";
    # The reference docs list every curated name.
    assert lib.assertMsg (lib.all
      (n: lib.hasInfix "`${n}`" repo.options.sysDefaults.packages.description)
      (lib.attrNames breakbulk.sysDefaults)
    ) "sys-defaults: a curated name is missing from the option's description";
    # Curated entries are not `packages` keys (no warnings, no internal keys).
    assert lib.assertMsg (
      repo.config.packages == { }
    ) "sys-defaults: packages ${toString (lib.attrNames repo.config.packages)}";
    evalCheck "sys-defaults-no-switches" (toString envNames);

  # `sysDefaults.packages`: the lowest layer under `packages`, replaced by a
  # plain definition (`null` opts out), and off with `sysDefaults.enable`.
  # On a target without a package set, only host units get them
  # (tests/loose-ends, sys-defaults-no-package-set).
  sys-defaults =
    let
      repo = mkRepo (fixtures + "/multi-ws") [
        (oneWs "b")
        {
          # Stand-ins for curated entries, at the curated priority.
          sysDefaults.packages = lib.mapAttrs (_: lib.mkDefault) {
            itoa = _: {
              env.SYS_ITOA = "curated";
              env.SYS_BOTH = "curated";
            };
            libc = _: { env.SYS_LIBC = "curated"; };
          };
        }
        {
          packages.itoa.env.SYS_BOTH = "user";
          sysDefaults.packages.libc = null;
          sysDefaults.packages.libsqlite3-sys = null;
        }
      ];
      units = unitsNamed (repo.workspaces.main.instances.${native}.default) "build";
      envOf =
        n: (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
      itoa = envOf "itoa-1.0.11-lib";
      libc = envOf "libc-0.2.191-lib";
      off = mkRepo (fixtures + "/multi-ws") [
        (oneWs "b")
        { sysDefaults.enable = false; }
      ];
    in
    assert lib.assertMsg (
      itoa.SYS_ITOA or null == "curated" && itoa.SYS_BOTH or null == "user"
    ) "sys-defaults: itoa env ${builtins.toJSON itoa}";
    assert lib.assertMsg (!(libc ? SYS_LIBC)) "sys-defaults: libc = null left ${builtins.toJSON libc}";
    assert lib.assertMsg (
      repo.config.sysDefaults.packages.libsqlite3-sys == null
    ) "sys-defaults: libsqlite3-sys not null";
    assert lib.assertMsg (off.config.sysDefaults.packages == { }) "sys-defaults: enable = false";
    evalCheck "sys-defaults" (builtins.toJSON itoa);

  # `workspaces.<ws>.memberDefaults`: a package-shaped layer under every
  # member's own settings. A member's `test.env` merges over it, its
  # `test.runner` wins, and `extraSources` reaches every member's source
  # view (path packages: app-b, a/inner, shared) but no registry crate's.
  member-defaults =
    let
      base = [ (oneWs "b") ];
      md = {
        workspaces.main.memberDefaults = {
          env.MD_UNIT = "md";
          test.env = {
            MD_ONLY = "md";
            MD_BOTH = "md";
          };
          test.runner = "nextest";
          extraSources = [ "c" ];
        };
        packages.app-b.test = {
          env.MD_BOTH = "own";
          runner = "libtest";
        };
      };
      repo = mkRepo (fixtures + "/multi-ws") (base ++ [ md ]);
      plain = mkRepo (fixtures + "/multi-ws") base;
      i = repo.workspaces.main.instances.${native}.default;
      run = repo.workspaces.main.target.${native}.testRuns.app-b."bin/app-b";
      script = run.drvAttrs.buildCommand;
      hasC = view: (builtins.readDir view) ? c;
      units = unitsNamed i "build";
      envOf =
        n: (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
    in
    assert lib.assertMsg (
      lib.hasInfix "export MD_ONLY=md" script && lib.hasInfix "export MD_BOTH=own" script
    ) "member-defaults: test env in ${script}";
    # The package's `test.runner = "libtest"` wins over the default nextest.
    assert lib.assertMsg (
      !(run.drvAttrs ? nextestCargoMetadata)
    ) "member-defaults: app-b runs under nextest";
    assert lib.assertMsg (lib.all (n: hasC i.sources.workspace.${n}) [
      "b"
      "a/inner"
      "shared"
    ]) "member-defaults: a member's view lacks c/";
    assert lib.assertMsg (
      i.sources.crates == (plain.workspaces.main.instances.${native}.default).sources.crates
    ) "member-defaults: registry crate sources changed";
    assert lib.assertMsg (
      (envOf "shared-0.1.0-lib").MD_UNIT or null == "md" && !((envOf "libc-0.2.191-lib") ? MD_UNIT)
    ) "member-defaults: unit env placement";
    evalCheck "member-defaults" script;

  # Single values across package layers: a more specific layer wins
  # without mkForce; mkForce in a lower layer wins over a plain value in a
  # higher one, mkDefault in a higher layer loses to a plain value in a
  # lower one.
  package-layer-priorities =
    let
      repo = mkRepo (fixtures + "/multi-ws") [
        (oneWs "b")
        {
          workspaces.main.memberDefaults.test = {
            runner = lib.mkForce "nextest";
            keepLog = false;
          };
          packages.app-b = {
            test.runner = "libtest";
            test.includeIgnored = true;
            target.${native}.test.includeIgnored = false;
            variant.default.test.keepLog = lib.mkDefault true;
          };
        }
      ];
      run = repo.workspaces.main.target.${native}.testRuns.app-b."bin/app-b";
      checks = {
        targetLayerWins = !(lib.elem "--include-ignored" run.passthru.breakbulkTest.args);
        forcedLowerWins = run.drvAttrs ? nextestCargoMetadata;
        defaultHigherLoses = !(lib.hasInfix ''"$out/log"'' run.drvAttrs.buildCommand);
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (bad == [ ]) "package-layer-priorities: failed ${toString bad}";
    evalCheck "package-layer-priorities" (builtins.toJSON checks);

  # Env variables, stages and checks across package layers, each by
  # itself: `lib.mkForce` in memberDefaults wins over a plain value in
  # `packages.<name>`, a plain value in a more specific layer wins, and
  # variables and stages no other layer sets still merge in.
  package-layer-attr-priorities =
    let
      probe = { product, ... }: product.linked;
      repo = mkRepo (fixtures + "/multi-ws") [
        (oneWs "b")
        {
          workspaces.main.memberDefaults = {
            env = {
              FORCED = lib.mkForce "low";
              PLAIN = "low";
            };
            forTarget.env = lib.mkForce { FORCED_TARGET = "low"; };
            test.env.FORCED_TEST = lib.mkForce "low";
            test.binaries."bin/app-b".env.FORCED_BIN = lib.mkForce "low";
            stages.probe = lib.mkForce null;
            checks.noSourceReferences = lib.mkForce null;
            checks.lowOnly = {
              on = "linked";
              run = probe;
            };
          };
          packages.shared = {
            env = {
              FORCED = "high";
              PLAIN = "high";
              HIGH_ONLY = "high";
            };
            forTarget.env.FORCED_TARGET = "high";
          };
          packages.app-b = {
            test.env.FORCED_TEST = "high";
            test.binaries."bin/app-b".env.FORCED_BIN = "high";
            stages.probe = {
              after = "install";
              run = probe;
            };
            checks.noSourceReferences.run = probe;
          };
        }
      ];
      t = repo.workspaces.main.target.${native};
      units = unitsNamed (repo.workspaces.main.instances.${native}.default) "build";
      envOf =
        n: (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
      bin = envOf "shared-0.1.0-lib";
      run = t.testRuns.app-b."bin/app-b".drvAttrs.buildCommand;
      product = t.packages.app-b;
      checks = {
        env = bin.FORCED == "low" && bin.PLAIN == "high" && bin.HIGH_ONLY == "high";
        forTargetEnv = bin.FORCED_TARGET == "low";
        testEnv = lib.hasInfix "export FORCED_TEST=low" run;
        binaryEnv = lib.hasInfix "export FORCED_BIN=low" run;
        stages = !(product.stages ? probe);
        checks = !(product.checks ? noSourceReferences) && product.checks ? lowOnly;
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (
      bad == [ ]
    ) "package-layer-attr-priorities: failed ${toString bad} (${builtins.toJSON bin})";
    evalCheck "package-layer-attr-priorities" (builtins.toJSON checks);

  # `forHost`/`forTarget` sides and the package-shaped `target.<triple>`
  # layer. libc has a build script: its compile is a host unit, its run
  # and lib are target units. `target.<other triple>` reaches nothing
  # here. memberDefaults and sysDefaults take the same shape.
  package-sides =
    let
      other = "aarch64-unknown-linux-gnu";
      repo = mkRepo (fixtures + "/multi-ws") [
        (oneWs "b")
        {
          packages.libc = {
            forTarget.env.FT = "1";
            target.${native} = {
              forHost.env.FH = "1";
              env.TB = "1";
            };
            target.${other}.forHost.env.FH_OTHER = "1";
          };
          workspaces.main.memberDefaults.target.${native}.forTarget.env.MDT = "1";
          sysDefaults.packages.itoa = _: { target.${native}.forTarget.env.SYST = "1"; };
        }
      ];
      units = unitsNamed (repo.workspaces.main.instances.${native}.default) "build";
      envOf =
        n: (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
      lib' = envOf "libc-0.2.191-lib";
      run = envOf "libc-0.2.191-build-run";
      script = envOf "libc-0.2.191-build-script";
      checks = {
        forTargetRunAndLib = lib' ? FT && run ? FT && !(script ? FT);
        forHostOneTriple = script ? FH && !(lib' ? FH) && !(run ? FH);
        otherTriple = !(script ? FH_OTHER);
        bothSidesOneTriple = lib' ? TB && script ? TB && run ? TB;
        memberDefaults = (envOf "shared-0.1.0-lib") ? MDT && !((envOf "shared-0.1.0-build-script") ? MDT);
        sysDefaults = (envOf "itoa-1.0.11-lib") ? SYST;
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (bad == [ ]) "package-sides: failed ${toString bad}";
    evalCheck "package-sides" (builtins.toJSON checks);

  # Modules receive `root` (a path, also when the caller passed a
  # string-like root), the repository object (`repo`) and the library
  # (`breakbulk`) without the caller wiring them through specialArgs; the
  # caller's specialArgs still win.
  module-args =
    let
      probe =
        {
          root,
          repo,
          breakbulk,
          ...
        }:
        {
          workspaces.a.path = "a";
          packages.app-a.env = {
            ROOT_IS_PATH = lib.boolToString (builtins.isPath root);
            ROOT_READS = lib.boolToString (builtins.pathExists (root + "/a/Cargo.lock"));
            REPO_HAS_WS = lib.boolToString (repo.workspaces ? a);
            LIB_HAS_PRESETS = lib.boolToString (breakbulk.presets ? linux);
          };
        };
      env = (mkRepo (fixtures + "/multi-ws") [ probe ]).config.packages.app-a.env;
      overridden =
        (breakbulk.mkRepository {
          inherit pkgs tools;
          root = fixtures + "/multi-ws";
          modules = [
            (
              { marker, ... }:
              {
                workspaces.a.path = "a";
                packages.app-a.env.MARKER = marker;
              }
            )
          ];
          specialArgs.marker = "mine";
        }).config.packages.app-a.env.MARKER;
      want = lib.genAttrs [ "ROOT_IS_PATH" "ROOT_READS" "REPO_HAS_WS" "LIB_HAS_PRESETS" ] (_: "true");
    in
    assert lib.assertMsg (env == want) "module-args: ${builtins.toJSON env}";
    assert lib.assertMsg (overridden == "mine") "module-args: caller specialArgs lost";
    evalCheck "module-args" (builtins.toJSON env);

  # Zero configuration: `mkRepository { pkgs; root; }` with no modules is
  # one workspace, `default`, at the root, when the root has a
  # `Cargo.toml`; declaring any workspace turns it off, and a root without
  # one has no workspaces.
  zero-config =
    let
      zero = breakbulk.mkRepository {
        inherit pkgs tools;
        root = fixtures + "/walking-skeleton";
      };
      declared = mkRepo (fixtures + "/walking-skeleton") [ (oneWs ".") ];
      noManifest = mkRepo (fixtures + "/multi-ws") [ ];
    in
    assert lib.assertMsg (
      lib.attrNames zero.workspaces == [ "default" ]
    ) "zero-config: ${toString (lib.attrNames zero.workspaces)}";
    assert lib.assertMsg (lib.attrNames declared.workspaces == [ "main" ]) "zero-config: declared";
    assert lib.assertMsg (noManifest.workspaces == { }) "zero-config: no Cargo.toml";
    pkgs.runCommand "zero-config" { bb = zero.workspaces.default.packages.walking-skeleton; } ''
      got=$($bb/bin/walking-skeleton)
      echo "$got"
      [ "$got" = "walking-skeleton 42 cfg-on hello-from-build-script release" ]
      touch $out
    '';

  # A crate at the repository root (#32): its default source view is the
  # whole repository, so editing a Nix file or a note changes its units. A
  # filtered `root` (lib.fileset.toSource) keeps them unchanged, and builds.
  filtered-root =
    let
      withRepoFiles =
        v:
        edited "walking-skeleton" ''
          mkdir nix
          echo ${v} > nix/rust.nix
          echo ${v} > NOTES.md
        '';
      filtered =
        r:
        lib.fileset.toSource {
          root = r;
          fileset = lib.fileset.unions [
            (r + "/Cargo.toml")
            (r + "/Cargo.lock")
            (r + "/build.rs")
            (r + "/src")
          ];
        };
      repoOf = r: mkRepo r [ (oneWs ".") ];
      whole = changedUnits (repoOf (withRepoFiles "a")) (repoOf (withRepoFiles "b"));
      narrow = changedUnits (repoOf (filtered (withRepoFiles "a"))) (
        repoOf (filtered (withRepoFiles "b"))
      );
    in
    assert lib.assertMsg (whole != [ ]) "filtered-root: the unfiltered root changed no units";
    assert lib.assertMsg (narrow == [ ]) "filtered-root: changed units ${builtins.toJSON narrow}";
    pkgs.runCommand "filtered-root"
      {
        bin = (repoOf (filtered (withRepoFiles "a"))).workspaces.main.packages.walking-skeleton;
      }
      ''
        $bin/bin/walking-skeleton
        echo ${lib.escapeShellArg (builtins.toJSON whole)} > $out
      '';

  # `workspaces.<ws>.fmt` (#32): `cargo fmt --check` over the members. The
  # (rustfmt-clean) walking skeleton passes; a misformatted file fails
  # naming it; a `rustfmt.toml` above a workspace in a subdirectory
  # applies; a toolchain without cargo-fmt fails naming the option.
  fmt =
    let
      checkOf =
        root: ws:
        (mkRepo root [
          {
            workspaces.main = {
              path = ".";
              fmt.enable = true;
            }
            // ws;
          }
        ]).checks."main/fmt";
      clean = checkOf (fixtures + "/walking-skeleton") { };
      messy = checkOf (edited "walking-skeleton" "echo 'fn  unused( ){}' >> src/main.rs") { };
      nested = checkOf (edited "walking-skeleton" ''
        mkdir ws
        mv Cargo.toml Cargo.lock build.rs src ws/
        echo 'hard_tabs = true' > rustfmt.toml
      '') { path = "ws"; };
      minimal = pkgs.rust-bin.stable."1.99.0".minimal;
      noCargoFmt = checkOf (fixtures + "/walking-skeleton") {
        toolchain = {
          rustc = minimal;
          cargo = minimal;
        };
      };
      off = (mkRepo (fixtures + "/walking-skeleton") [ (oneWs ".") ]).checks;
    in
    assert lib.assertMsg (!(off ? "main/fmt")) "fmt: a check without fmt.enable";
    # The resolved toolchain is an output, for treefmt's rustfmt.
    assert lib.assertMsg (
      (mkRepo (fixtures + "/walking-skeleton") [ (oneWs ".") ]).workspaces.main.toolchain.rustfmt
      == pkgs.rustfmt
    ) "fmt: repo.workspaces.main.toolchain.rustfmt";
    pkgs.runCommand "fmt"
      {
        inherit clean;
        messy = pkgs.testers.testBuildFailure messy;
        nested = pkgs.testers.testBuildFailure nested;
        noCargoFmt = pkgs.testers.testBuildFailure noCargoFmt;
      }
      ''
        grep -q 'Diff in .*src/main.rs' $messy/testBuildFailure.log
        # hard_tabs from the repository root's rustfmt.toml.
        grep -q 'Diff in .*ws/src/main.rs' $nested/testBuildFailure.log
        grep -q 'set workspaces.main.toolchain.rustfmt' $noCargoFmt/testBuildFailure.log
        touch $out
      '';

  # `variants.default` is a definition merged with the user's while
  # `defaultVariant` is "default" (#32): adding a clippy variant keeps it,
  # `variants.default.profile` changes it, and a renamed default variant
  # brings no empty `default` along.
  default-variant =
    let
      variantsOf =
        ws:
        (mkRepo (fixtures + "/walking-skeleton") [
          {
            workspaces.main = {
              path = ".";
            }
            // ws;
          }
        ]).config.workspaces.main.variants;
      withClippy = variantsOf { variants.clippy.mode = "clippy"; };
      changed = variantsOf { variants.default.profile = "release"; };
      renamed = variantsOf {
        defaultVariant = "release";
        variants.release.profile = "release";
      };
    in
    assert lib.assertMsg (
      lib.attrNames withClippy == [
        "clippy"
        "default"
      ]
    ) "default-variant: with clippy: ${toString (lib.attrNames withClippy)}";
    assert lib.assertMsg (
      lib.attrNames changed == [ "default" ] && changed.default.profile == "release"
    ) "default-variant: changed";
    assert lib.assertMsg (
      lib.attrNames renamed == [ "release" ]
    ) "default-variant: renamed: ${toString (lib.attrNames renamed)}";
    evalCheck "default-variant" "ok";

  # Option checks are the modules' `assertions` (#28): each failing one's
  # message names the option and the file that set it, and reading the
  # repository fails with all of them. A bad `packages.<name>.version` is
  # a type error on that option.
  option-assertions =
    let
      file = "/checks/flake.nix";
      repoOf =
        m:
        mkRepo (fixtures + "/walking-skeleton") [
          {
            _file = file;
            workspaces.main = m;
          }
        ];
      failed = r: map (a: a.message) (lib.filter (a: !a.assertion) r.config.assertions);
      at = "(set in `${file}')";
      ws = "breakbulk: workspaces.main";
      cases = {
        ok = {
          m = { };
          want = [ ];
        };
        defaultVariant = {
          m.defaultVariant = "relase";
          want = [ "${ws}.defaultVariant `relase` ${at} is not one of its variants (it has none)" ];
        };
        defaultTarget = {
          m.defaultTarget = "foo";
          want = [ "${ws}.defaultTarget `foo` ${at} is not one of its targets (${native})" ];
        };
        shellTarget = {
          m.devShell.target = "foo";
          want = [ "${ws}.devShell.target `foo` ${at} is not one of its targets (${native})" ];
        };
        setTarget = {
          m.devShell.setTarget = true;
          want = [
            "${ws}.devShell.setTarget ${at} was removed; use devShell.target: a triple, or null for none"
          ];
        };
        benches = {
          m.variants.c = {
            mode = "check";
            benches = true;
          };
          want = [ "${ws}.variants.c ${at}: `benches` needs a build variant, not `check`" ];
        };
        allTargets = {
          m.variants.default.allTargets = false;
          want = [
            "${ws}.variants.default ${at}: `allTargets = false` needs a check or clippy variant, not `build`"
          ];
        };
        variantTargets = {
          m.variants.default.targets = [ "riscv64gc-unknown-linux-gnu" ];
          want = [
            "${ws}.variants.default.targets ${at}: riscv64gc-unknown-linux-gnu not among the workspace's targets (${native})"
          ];
        };
      };
      got = lib.mapAttrs (_: c: failed (repoOf c.m)) cases;
      bad = lib.attrNames (lib.filterAttrs (n: c: got.${n} != c.want) cases);
      badKey = mkRepo (fixtures + "/walking-skeleton") [
        {
          _file = "/checks/key.nix";
          packages."foo@>=nope" = { };
        }
      ];
      badVersion = mkRepo (fixtures + "/walking-skeleton") [ { packages.foo.version = "not a req"; } ];
      fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
    in
    assert lib.assertMsg (bad == [ ]) "option-assertions: ${builtins.toJSON (lib.getAttrs bad got)}";
    assert lib.assertMsg (
      failed badKey == [
        "breakbulk: packages.\"foo@>=nope\" (set in `/checks/key.nix'): `>=nope` is not a Cargo version requirement"
      ]
    ) "option-assertions: key: ${builtins.toJSON (failed badKey)}";
    assert lib.assertMsg (fails
      (repoOf { defaultVariant = "x"; }).workspaces
    ) "option-assertions: workspaces read despite a failed assertion";
    assert lib.assertMsg (fails badVersion.config.packages.foo.version)
      "option-assertions: a bad version requirement was accepted";
    assert lib.assertMsg (
      !(fails badVersion.config.packages.foo.env)
    ) "option-assertions: the version's type error reached another option";
    evalCheck "option-assertions" (builtins.toJSON got);

  # `workspaces.<ws>.members` is what `cargo metadata` lists (glob
  # `members`, `[workspace] exclude`, a path dependency), and the exclude
  # form of each selection option selects what `--workspace --exclude`
  # does: both compared with Cargo in the check. A module reads `members`
  # from `config` for its selection. An entry that matches no member, or is
  # not a valid pattern, fails the repository.
  workspace-members =
    let
      file = "/checks/members.nix";
      repoWith =
        m:
        mkRepo (fixtures + "/workspace-members") [
          (oneWs ".")
          {
            _file = file;
            workspaces.main = m;
          }
        ];
      t = r: r.workspaces.main.target.${native};
      testPkgs = r: lib.attrNames (t r).tests;
      # The exclude lists compared with `cargo tree --workspace --exclude`.
      cargoCases = {
        globs = [
          "core-*"
          "helper"
        ];
        class = [ "[a-c]*" ];
      };
      viaTests = lib.mapAttrs (
        _: ex:
        testPkgs (repoWith {
          targets.${native}.tests.exclude = ex;
        })
      ) cargoCases;
      viaPackages = testPkgs (repoWith {
        targets.${native}.packages.exclude = [ "[a-c]*" ];
      });
      viaVariant = testPkgs (repoWith {
        variants.default.packages.exclude = [ "ws-util" ];
      });
      products =
        lib.attrNames
          (t (repoWith {
            targets.${native}.products.exclude = [ "app" ];
          })).packages;
      fromConfig = mkRepo (fixtures + "/workspace-members") [
        (oneWs ".")
        (
          { config, ... }:
          {
            workspaces.main.targets.${native}.tests = lib.subtractLists [ "app" ] (
              lib.attrNames config.workspaces.main.members
            );
          }
        )
      ];
      members = lib.mapAttrs (_: m: { inherit (m) name path; }) fromConfig.config.workspaces.main.members;
      failed = r: map (a: a.message) (lib.filter (a: !a.assertion) r.config.assertions);
      fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
      all = "app, core-a, core-b, helper, ws-util";
    in
    assert lib.assertMsg (
      viaPackages == [
        "helper"
        "ws-util"
      ]
    ) "workspace-members: packages.exclude: ${toString viaPackages}";
    assert lib.assertMsg (
      viaVariant == [
        "app"
        "core-a"
        "core-b"
        "helper"
      ]
    ) "workspace-members: variant packages.exclude: ${toString viaVariant}";
    assert lib.assertMsg (
      products == [
        "core-a"
        "core-b"
        "ws-util"
      ]
    ) "workspace-members: products.exclude: ${toString products}";
    assert lib.assertMsg (
      testPkgs fromConfig == [
        "core-a"
        "core-b"
        "helper"
        "ws-util"
      ]
    ) "workspace-members: from config: ${toString (testPkgs fromConfig)}";
    assert lib.assertMsg (
      failed (repoWith {
        variants.default.packages.exclude = [ "nope" ];
      }) == [
        "breakbulk: workspaces.main.variants.default.packages.exclude (set in `${file}'): `nope` matches no member (${all})"
      ]
    ) "workspace-members: variant message";
    assert lib.assertMsg (fails
      (repoWith { targets.${native}.tests.exclude = [ "zz*" ]; }).workspaces
    ) "workspace-members: an unmatched pattern was accepted";
    assert lib.assertMsg (fails
      (repoWith { targets.${native}.products.exclude = [ "core**" ]; }).checks
    ) "workspace-members: an invalid pattern was accepted";
    assert lib.assertMsg (fails
      (repoWith { targets.${native}.packages.exclude = [ "nope" ]; }).workspaces
    ) "workspace-members: an unmatched name was accepted";
    pkgs.runCommand "workspace-members"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.jq
        ];
        src = fixtures + "/workspace-members";
        members = builtins.toJSON members;
        cases = builtins.toJSON (
          lib.mapAttrs (n: ex: {
            inherit ex;
            got = viaTests.${n};
          }) cargoCases
        );
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode $src ws
        cd ws
        cargo metadata --no-deps --offline --format-version 1 \
          | jq -S --arg root "$PWD/" '.packages | map({ key: .name, value: { name, path: (.manifest_path | ltrimstr($root) | rtrimstr("Cargo.toml") | rtrimstr("/") | if . == "" then "." else . end) } }) | from_entries' > want.json
        printf '%s' "$members" | jq -S . > got.json
        diff -u want.json got.json
        for c in $(printf '%s' "$cases" | jq -r 'keys[]'); do
          args=()
          while IFS= read -r e; do args+=(--exclude "$e"); done < <(printf '%s' "$cases" | jq -r --arg c "$c" '.[$c].ex[]')
          cargo tree --offline --workspace "''${args[@]}" --depth 0 --prefix none --format '{p}' \
            | awk 'NF { print $1 }' | sort > want
          printf '%s' "$cases" | jq -r --arg c "$c" '.[$c].got[]' | sort > got
          echo "$c: ''${args[*]}"
          diff -u want got
        done
        mkdir -p $out
        cp want.json $out/members.json
      '';

  # `targets.<t>.stdenv` replaces the target
  # captures' stdenv (base and per-package), `host.stdenv` the host
  # captures'; unset, both are the package set's. The capture then records
  # clang's wrapper as `cc`, and the product still builds.
  stdenv-override =
    let
      withInput = {
        packages.app-a.inputs = p: [ p.zlib ];
      };
      dflt = mkRepo (fixtures + "/multi-ws") [
        (oneWs "a")
        withInput
      ];
      clang = mkRepo (fixtures + "/multi-ws") [
        (oneWs "a")
        withInput
        { targets.${native}.stdenv = pkgs.clangStdenv; }
      ];
      hostClang = mkRepo (fixtures + "/multi-ws") [
        (oneWs "a")
        { targets.${native}.host.stdenv = pkgs.clangStdenv; }
      ];
      i = r: r.workspaces.main.instances.${native}.default;
      stdenvOf = d: builtins.unsafeDiscardStringContext d.drvAttrs.stdenv.outPath;
      drv = d: builtins.unsafeDiscardStringContext d.drvPath;
      out = d: builtins.unsafeDiscardStringContext d.outPath;
      # app-a's own capture (it has inputs), as its units name it.
      pkgCapture =
        stdenv:
        out (
          breakbulk.envCapture.forPackage {
            inherit pkgs stdenv;
            platform = "target";
            name = "app-a";
            inputs = p: [ p.zlib ];
          }
        );
      units = r: lib.concatMapStrings (u: u.BREAKBULK_UNIT or "") (lib.attrValues (i r).units.build);
      checks = {
        defaultIsSets = stdenvOf (i dflt).captures.target == out pkgs.stdenv;
        targetClang = stdenvOf (i clang).captures.target == out pkgs.clangStdenv;
        hostKept = drv (i clang).captures.host == drv (i dflt).captures.host;
        hostClang = stdenvOf (i hostClang).captures.host == out pkgs.clangStdenv;
        targetKeptByHost = drv (i hostClang).captures.target == drv (i dflt).captures.target;
        pkgCaptureClang =
          lib.hasInfix (pkgCapture pkgs.clangStdenv) (units clang)
          && lib.hasInfix (pkgCapture null) (units dflt)
          && pkgCapture null != pkgCapture pkgs.clangStdenv;
      };
      bad = lib.attrNames (lib.filterAttrs (_: v: !v) checks);
    in
    assert lib.assertMsg (bad == [ ]) "stdenv-override: failed ${toString bad}";
    pkgs.runCommand "stdenv-override"
      {
        capture = (i clang).captures.target;
        app = clang.workspaces.main.packages.app-a;
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -r .PATH $capture/env.json | tr : '\n' | grep -q clang-wrapper
        $app/bin/app-a
        touch $out
      '';

  # `productInputs` that cannot work, named from the declarations and
  # Cargo.lock without planning (feature-unification: a and b depend on
  # shared): a product whose package depends on the declaring one, a
  # package's own product, and a product the second outer derivation
  # makes for another declaration.
  product-inputs-conflicts =
    let
      conflicts =
        decls:
        (mkRepo (fixtures + "/feature-unification") [
          (oneWs ".")
          { packages = lib.mapAttrs (_: l: { productInputs = l; }) decls; }
        ]).workspaces.main.instances.${native}.default.productInputConflicts;
      cases = [
        {
          decls.shared = [ "a" ];
          want = [
            "breakbulk: `a` depends on `shared` in Cargo.lock (a -> shared), and `packages.shared.productInputs` says the settings of `shared` use the product of `a`: that product would need itself."
          ];
        }
        {
          decls.a = [ "a" ];
          want = [
            "breakbulk: `packages.a.productInputs` names `a` itself: the settings of `a` cannot use its own product, which is built with them."
          ];
        }
        {
          decls = {
            shared = [ "itoa" ];
            b = [ "a" ];
          };
          want = [
            "breakbulk: `packages.b.productInputs` names `a`, but `a` depends on `shared` in Cargo.lock (a -> shared), which declares products of its plan (`packages.shared.productInputs`). Dynamic-derivation mode builds a plan's units in two steps, the products that settings use and then the packages whose settings use them (with everything that depends on those), so `a` is in the second step and its product cannot be an input of `b`."
          ];
        }
        {
          decls.a = [ "b" ];
          want = [ ];
        }
      ];
      bad = lib.filter (c: conflicts c.decls != c.want) cases;
    in
    assert lib.assertMsg (bad == [ ])
      "product-inputs-conflicts: ${builtins.toJSON (map (c: c // { got = conflicts c.decls; }) bad)}";
    evalCheck "product-inputs-conflicts" "ok";

  # Instantiating a plan needs only the names of package settings; their
  # values reach a unit's derivation when it is substituted. Here every
  # value-carrying setting of `app` (package level and `target.<triple>`,
  # both sides, test settings, stages, checks) and the workspace's
  # `devShell.env` throw when read, and the products of the other members
  # of the same plan still evaluate, to the same derivations as without
  # these settings, and so do their test runs, whose library paths name
  # only the build-script runs below them (not `app`'s). An option that
  # takes a value belongs in `settings` too.
  poisoned-settings =
    let
      poison = what: throw "poisoned-settings: ${what} was read";
      side = at: {
        env.POISON = poison "${at}env";
        inputs = _: [ (poison "an element of ${at}inputs") ];
        nativeInputs = _: [ (poison "an element of ${at}nativeInputs") ];
      };
      settings =
        at:
        side at
        // {
          forHost = side "${at}forHost.";
          forTarget = side "${at}forTarget.";
          stages.poison = poison "${at}stages";
          checks.poison = poison "${at}checks";
          test = {
            env.POISON = poison "${at}test.env";
            path = [ (poison "an element of ${at}test.path") ];
            postRun = poison "${at}test.postRun";
            binaries."bin/app" = {
              env.POISON = poison "${at}test.binaries.\"bin/app\".env";
              postRun = poison "${at}test.binaries.\"bin/app\".postRun";
            };
            doctest = {
              env.POISON = poison "${at}test.doctest.env";
              args = [ (poison "an element of ${at}test.doctest.args") ];
              postRun = poison "${at}test.doctest.postRun";
            };
            nextest = {
              package = poison "${at}test.nextest.package";
              configFile = poison "${at}test.nextest.configFile";
            };
          };
        };
      fixture = fixtures + "/same-workspace-products";
      poisoned = mkRepo fixture [
        (oneWs ".")
        {
          packages.app = settings "packages.app." // {
            target.${native} = settings "packages.app.target.${native}.";
          };
          workspaces.main.devShell.env.POISON = poison "devShell.env";
        }
      ];
      clean = mkRepo fixture [ (oneWs ".") ];
      drv = d: builtins.unsafeDiscardStringContext d.drvPath;
      drvsOf =
        repo:
        lib.genAttrs [ "tool" "shared" ] (p: drv repo.workspaces.main.packages.${p})
        // {
          tool-test = drv repo.workspaces.main.testRuns.tool."bin/tool";
          shared-test = drv repo.workspaces.main.testRuns.shared."lib/shared";
        };
      got = drvsOf poisoned;
    in
    assert lib.assertMsg (
      got == drvsOf clean
    ) "poisoned-settings: other members' derivations differ: ${builtins.toJSON got}";
    evalCheck "poisoned-settings" (builtins.toJSON got);

  # `nixFeatures` is what Nix must allow for `mode` and `ca` (set, and at
  # their defaults on this evaluator), import from derivation in dynamic
  # mode only where a site may import. Reading it plans nothing; in
  # dynamic mode on a stock evaluator it does not need dynamic derivations.
  # `repo.config` holds what was chosen.
  nix-features =
    let
      repoWith =
        settings:
        breakbulk.mkRepository {
          inherit pkgs tools;
          root = fixtures + "/multi-ws";
          modules = [ { workspaces.a.path = "a"; } ] ++ lib.toList settings;
        };
      features = settings: (repoWith settings).nixFeatures;
      record = ca: dyn: ifd: {
        caDerivations = ca;
        dynamicDerivations = dyn;
        importFromDerivation = ifd;
      };
      # No dev shell (its Cargo env is read by IFD in either mode).
      noShell = {
        workspaces.a.devShell.target = null;
      };
      g = breakbulk.nixFeatures;
      cases = [
        {
          settings = {
            mode = "ifd";
            ca = false;
          };
          want = record false false true;
        }
        {
          settings = {
            mode = "ifd";
            ca = true;
          };
          want = record true false true;
        }
        {
          settings = [
            noShell
            {
              mode = "dynamic";
              ca = false;
            }
          ];
          want = record true true false;
        }
        {
          settings = [
            noShell
            { mode = "dynamic"; }
          ];
          want = record true true false;
        }
        # The dev shell's Cargo env.
        {
          settings = {
            mode = "dynamic";
          };
          want = record true true true;
        }
        # A rustc whose `version` is not a Rust release is probed.
        {
          settings = [
            noShell
            {
              mode = "dynamic";
              workspaces.a.toolchain.rustc = pkgs.rustc // {
                version = "2026-10-15";
              };
            }
          ];
          want = record true true true;
        }
        # Several targets, none native: `defaultTarget` may read the
        # project's `build.target`, but this fixture has no Cargo config.
        {
          settings = [
            noShell
            {
              mode = "dynamic";
              workspaces.a.targets = {
                wasm32-unknown-unknown = { };
                aarch64-unknown-linux-gnu = { };
              };
            }
          ];
          want = record true true false;
        }
        {
          settings = [ noShell ];
          want = record g.defaultCa g.available (!g.available);
        }
      ];
      bad = lib.filter (c: features c.settings != c.want) cases;
      # With a Cargo config file, `build.target` may be read.
      configured =
        (breakbulk.mkRepository {
          inherit pkgs tools;
          root = fixtures + "/feature-unification";
          modules = [
            {
              mode = "dynamic";
              workspaces.main = {
                path = ".";
                devShell.target = null;
                targets = {
                  wasm32-unknown-unknown = { };
                  aarch64-unknown-linux-gnu = { };
                };
              };
            }
          ];
        }).nixFeatures;
      chosen = repoWith { };
    in
    assert lib.assertMsg (bad == [ ])
      "nix-features: wrong for ${builtins.toJSON (map (c: c // { got = features c.settings; }) bad)}";
    assert lib.assertMsg (
      chosen.config.mode == g.defaultMode
      && chosen.config.ca == (g.defaultMode == "dynamic")
      && chosen.options.ca.highestPrio == 1500
      && (repoWith { mode = "dynamic"; }).config.ca
      && !(repoWith { ca = false; }).config.ca
    ) "nix-features: repo.config.mode and repo.config.ca are not what was chosen";
    assert lib.assertMsg configured.importFromDerivation
      "nix-features: a Cargo config's build.target is not counted";
    evalCheck "nix-features" (builtins.toJSON (map (c: features c.settings) cases));

  # Every option has a description, so the docs generate.
  options-doc = (mkRepo (fixtures + "/multi-ws") [ ]).optionsDoc.optionsCommonMark;
}
