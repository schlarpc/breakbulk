# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Which files a view holds is a pipeline of steps per package and kind of
# unit: "build" (non-test compiles, build scripts and their runs), "test"
# (test compiles and doctests), "run" (test runs), and per Cargo target
# (`cargoTarget`, null for the package's view). Each step is a function
# from `{ default, kind, cargoTarget, root, packageDir, ... }` to a file
# set, and gets the previous step's result as `default`. The built-in
# steps (`defaultSteps`) come first, then the package's `sources`
# functions.
{
  lib,
  util,
  manifest,
}:
let
  inherit (builtins)
    attrNames
    filter
    isPath
    isString
    readDir
    typeOf
    ;
  fs = lib.fileset;

  # An argument every step gets, so that a function without `...` fails on
  # its first call, not when breakbulk adds an argument. Nix's error names
  # the unexpected argument, so its name is the message.
  sentinel = "breakbulk: add ... to this sources function's arguments, as in { default, kind, ... }";
in
rec {
  inherit sentinel;

  # A repository path from a path value or a string relative to the root.
  pathOf =
    root: what: x:
    if isPath x then
      x
    else if isString x then
      manifest.at root (util.normalizeRel x)
    else
      throw "breakbulk: ${what} entries must be paths or strings relative to the repository root";

  # The package directory, minus `target/`, `.git` and `result*` at its
  # top level, and minus the directories of other workspace members nested
  # inside it (`memberDirs`, relative to the root). Other nested
  # Cargo.toml files (test fixtures, examples of generated projects) stay,
  # because the package may read them.
  packageFileset =
    {
      root,
      pkgDir,
      memberDirs ? [ ],
    }:
    let
      at = manifest.at root;
      junk = filter (n: n == "target" || n == ".git" || lib.hasPrefix "result" n) (
        attrNames (readDir (at pkgDir))
      );
      nested = filter (d: d != pkgDir && util.isUnder pkgDir d) memberDirs;
    in
    fs.difference (at pkgDir) (fs.unions (map (n: at (util.joinRel pkgDir n)) junk ++ map at nested));

  # The `test.sourceScope` entries inside the package, relative to the
  # root: the ones its non-test units do not see. Entries outside the
  # package only widen its test view.
  scopeInside =
    {
      root,
      pkgDir,
      sourceScope ? [ ],
    }:
    let
      rel =
        x:
        if isPath x then
          (if lib.path.hasPrefix root x then util.normalizeRel (lib.path.removePrefix root x) else null)
        else
          util.normalizeRel x;
    in
    filter (r: r != null && util.isUnder pkgDir r) (map rel sourceScope);

  # The package's `tests/` directory relative to the root, when it exists
  # and `scopeTestsDir` is not false, else null. Cargo builds it only as
  # integration tests.
  testsDirOf =
    {
      root,
      pkgDir,
      scopeTestsDir ? null,
    }:
    if scopeTestsDir != false && (readDir (manifest.at root pkgDir)).tests or null == "directory" then
      util.joinRel pkgDir "tests"
    else
      null;

  # The paths the built-in steps leave out of a package's "build" view
  # (relative to the root), for the hint when a non-test unit misses one.
  testOnlyPaths =
    {
      root,
      pkgDir,
      sourceScope ? [ ],
      scopeTestsDir ? null,
    }:
    let
      tests = testsDirOf { inherit root pkgDir scopeTestsDir; };
    in
    lib.unique (lib.optional (tests != null) tests ++ scopeInside { inherit root pkgDir sourceScope; });

  # A target's own root, relative to the package directory: its crate
  # root file, or the directory of a `<dir>/main.rs` root outside the
  # conventional directories (`tests/it/main.rs`: `tests/it`), which holds
  # its modules.
  targetRoot =
    t:
    let
      dir = util.normalizeRel (builtins.dirOf t.path);
    in
    if
      baseNameOf t.path == "main.rs"
      && !lib.elem dir [
        ""
        "src"
        "src/bin"
        "tests"
        "benches"
        "examples"
      ]
    then
      dir
    else
      t.path;

  # The paths of the package (relative to the package directory) that the
  # view of `cargoTarget`'s units leaves out: the roots of the package's
  # other bins, examples, tests and benches, and for a library, bin or
  # build script the whole `examples/` and `benches/` directories. Never a
  # path that holds the target's own root, the library's or a build
  # script's, and never one inside the target's own root directory.
  targetExcluded =
    {
      root,
      pkgDir,
      targets,
      cargoTarget,
    }:
    let
      own = targetRoot cargoTarget;
      isOwn = t: t.kind == cargoTarget.kind && t.name == cargoTarget.name;
      roots = map targetRoot (
        filter (
          t:
          lib.elem t.kind [
            "bin"
            "example"
            "test"
            "bench"
          ]
          && !isOwn t
        ) targets
      );
      dirs =
        lib.optionals
          (lib.elem cargoTarget.kind [
            "lib"
            "bin"
            "custom-build"
          ])
          (
            filter (d: (readDir (manifest.at root pkgDir)).${d} or null == "directory") [
              "examples"
              "benches"
            ]
          );
      protected = [
        cargoTarget.path
      ]
      ++ map (t: t.path) (filter (t: t.kind == "lib" || t.kind == "custom-build") targets);
      keep =
        e:
        e != ""
        && e != ".."
        && !lib.hasPrefix "../" e
        && !lib.any (p: util.isUnder e p) protected
        && !(own != cargoTarget.path && util.isUnder own e);
    in
    lib.unique (filter keep (map util.normalizeRel (roots ++ dirs)));

  # Every path some target's view leaves out (relative to the root), for
  # the hint when a unit misses one.
  targetRootPaths =
    {
      root,
      pkgDir,
      targets,
    }:
    lib.unique (
      lib.concatMap (
        t:
        map (util.joinRel pkgDir) (targetExcluded {
          inherit root pkgDir targets;
          cargoTarget = t;
        })
      ) targets
    );

  # The built-in steps of one package, in order, from its settings
  # (`extraSources` and `test`, as `packages.<name>` has them). `wsDir`:
  # the directory of the package's workspace, relative to the root.
  defaultSteps =
    {
      root,
      pkgDir,
      wsDir ? "",
      memberDirs ? [ ],
      settings ? { },
      targets ? [ ],
    }:
    let
      at = manifest.at root;
      scopeTargets = settings.scopeTargetRoots or null != false;
      wsManifest = test.workspaceManifest or null != false;
      extra = map (pathOf root "extraSources") (settings.extraSources or [ ]);
      test = settings.test or { };
      scope = test.sourceScope or [ ];
      inside = scopeInside {
        inherit root pkgDir;
        sourceScope = scope;
      };
      tests = testsDirOf {
        inherit root pkgDir;
        scopeTestsDir = test.scopeTestsDir or null;
      };
      runFiles = test.runFiles or null;
    in
    [
      (
        { default, ... }:
        fs.union default (packageFileset {
          inherit root pkgDir memberDirs;
        })
      )
      # extraSources
      ({ default, ... }: fs.unions ([ default ] ++ extra))
      # test.sourceScope
      (
        { default, kind, ... }:
        if kind == "build" then
          fs.difference default (fs.unions (map at inside))
        else
          fs.unions ([ default ] ++ map (pathOf root "test.sourceScope") scope)
      )
      # test.scopeTestsDir
      (
        { default, kind, ... }:
        if kind == "build" && tests != null then fs.difference default (at tests) else default
      )
      # scopeTargetRoots. After test.sourceScope, which can add back a
      # whole directory of roots for the test kinds.
      (
        { default, cargoTarget, ... }:
        if cargoTarget == null || !scopeTargets then
          default
        else
          fs.difference default (
            fs.unions (
              map (e: fs.maybeMissing (at (util.joinRel pkgDir e))) (targetExcluded {
                inherit
                  root
                  pkgDir
                  targets
                  cargoTarget
                  ;
              })
            )
          )
      )
      # test.runFiles: only the listed paths, relative to the package.
      (
        { default, kind, ... }:
        if kind != "run" || runFiles == null then
          default
        else
          fs.unions (map (p: at (util.joinRel pkgDir p)) runFiles)
      )
      # test.workspaceManifest. After runFiles, because expect-test
      # searches upwards from the run's CARGO_MANIFEST_DIR. Not the
      # lockfile: no snapshot library reads it, and an edit to it would
      # re-run every member's tests.
      (
        { default, kind, ... }:
        if (kind == "test" || kind == "run") && wsManifest then
          fs.union default (at (util.joinRel wsDir "Cargo.toml"))
        else
          default
      )
    ];

  # The files of one package's units of `kind` (of `cargoTarget`'s units,
  # or every unit's when null): every step in turn, from the empty set.
  # `name`: the package's, for errors.
  viewFileset =
    {
      root,
      name,
      pkgDir,
      steps,
      kind,
      cargoTarget ? null,
    }:
    lib.foldl' (
      acc: step:
      let
        r = step {
          inherit root kind cargoTarget;
          packageDir = pkgDir;
          default = acc;
          ${sentinel} = null;
        };
      in
      if fs.isFileset r then
        r
      else
        throw "breakbulk: a function in packages.${name}.sources returned a ${typeOf r}, not a file set (lib.fileset)"
    ) fs.empty steps;

  # The store path of a view of the repository root: the files of
  # `fileset` at their places, and the package directory even when none of
  # its files are chosen. Not lib.fileset.toSource alone: a file set holds
  # files only, and a unit's working directory is its package directory,
  # which `runFiles = [ ]` (or any step) can leave empty.
  realize =
    {
      root,
      pkgDir,
      fileset,
    }:
    let
      files = fs.toSource { inherit root fileset; };
      dir = toString (manifest.at root pkgDir);
    in
    lib.sources.cleanSourceWith {
      name = "source";
      src = root;
      filter =
        path: type:
        files.filter path type || (type == "directory" && (path == dir || lib.hasPrefix "${path}/" dir));
    };

  # `view` with each `sourceOverlay` entry in place: a symbolic link at
  # the entry's path (relative to the package directory) to its value,
  # replacing what the view has there. Not a step of the pipeline: a file
  # set holds files of the evaluation's file system, and a derivation
  # output exists only once built, so a step that took one would make
  # every evaluation build it (import from derivation). Here the product
  # is only a reference in a derivation of its own, which instantiation
  # names by key and never reads. A link, not a copy: the view stays a
  # copy of the repository plus references, and canonical paths (as
  # rust-embed takes them) name the product itself.
  overlay =
    {
      runCommand,
      name,
      pkgDir,
      entries,
      view,
    }:
    let
      places = map (
        rel:
        let
          p = util.joinRel pkgDir rel;
        in
        if util.normalizeRel rel == "" then
          throw "breakbulk: packages.${name}.sourceOverlay: \"${rel}\" is the package directory itself"
        else if p == ".." || lib.hasPrefix "../" p then
          throw "breakbulk: packages.${name}.sourceOverlay: \"${rel}\" leaves the repository root"
        else
          {
            inherit p rel;
            value = entries.${rel};
          }
      ) (attrNames entries);
      nested = lib.filter (a: lib.any (b: a.p != b.p && util.isUnder b.p a.p) places) places;
    in
    if entries == { } then
      view
    else if nested != [ ] then
      throw "breakbulk: packages.${name}.sourceOverlay: \"${(lib.head nested).rel}\" is inside another entry's path"
    else
      runCommand "source" { } (
        ''
          cp -r ${view} $out
          chmod -R u+w $out
        ''
        + lib.concatMapStrings (e: ''
          rm -rf $out/${lib.escapeShellArg e.p}
          mkdir -p "$(dirname $out/${lib.escapeShellArg e.p})"
          ln -s ${lib.escapeShellArg "${e.value}"} $out/${lib.escapeShellArg e.p}
        '') places
      );

  # A package's views, rooted at the repository root (`<view>/<pkgDir>`
  # is the package directory): `src` for its "build" units; for a package
  # that is `tested`, `testSrc` for its "test" units and `runDir`, the
  # package directory of its "run" view, or null when that view is
  # `testSrc`. `targetSrc` and `targetTestSrc`: the views of single Cargo
  # targets' units, by `<kind>/<name>`, for the targets whose view can
  # differ from the package's: ones the built-in steps narrow, or every
  # target when `sources` functions choose files. `settings`:
  # `extraSources`, `scopeTargetRoots`, `test`, `sources` and
  # `sourceOverlay`, as `packages.<name>` has them. `targets`: the
  # package's Cargo targets (`{ kind; name; path; }`, `path` relative to
  # the package directory; lib/roots.nix `packageTargets`). `runCommand`:
  # for a package with a `sourceOverlay`.
  # Build-dependencies whose library code prints `rerun-if-changed`
  # directives (lib/directive-printers.nix).
  directivePrinters = import ./directive-printers.nix;

  # The crate names in a package's `[build-dependencies]` (and
  # `target.<cfg>.build-dependencies`), by the package they name.
  buildDependencies =
    { root, pkgDir }:
    let
      m = builtins.fromTOML (builtins.readFile (manifest.at root (util.joinRel pkgDir "Cargo.toml")));
      tables = [
        (m.build-dependencies or { })
        (m.build_dependencies or { })
      ]
      ++ lib.concatMap (t: [
        (t.build-dependencies or { })
        (t.build_dependencies or { })
      ]) (lib.attrValues (m.target or { }));
    in
    lib.unique (
      lib.concatMap (
        t: lib.mapAttrsToList (k: v: if builtins.isAttrs v && v ? package then v.package else k) t
      ) tables
    );

  # A package's `predictSources` settings, resolved: `enable` (false for a
  # package with a `sourceOverlay`, with a warning), `runs` (whether its
  # build-script runs are predicted), and `spec`, the predicted view spec
  # of one target's units (`breakbulk-predict`'s ViewSpec, `view` with its
  # context).
  predictSettings =
    {
      root,
      name,
      pkgDir,
      wsDir,
      settings,
      extraKeep,
    }:
    let
      ps = settings.predictSources or { };
      wanted = ps.enable or null == true;
      overlaid = settings.sourceOverlay or { } != { };
      enable =
        if wanted && overlaid then
          lib.warn "breakbulk: packages.${name}.predictSources: the package has a sourceOverlay, so its views are not predicted" false
        else
          wanted;
      rel =
        p: if lib.path.hasPrefix root p then util.normalizeRel (lib.path.removePrefix root p) else null;
      keepOf =
        args:
        lib.concatMap (
          k:
          if builtins.isString k then
            [ (util.joinRel pkgDir k) ]
          else if builtins.isPath k then
            lib.toList (rel k)
          else
            let
              r = k (args // { ${sentinel} = null; });
            in
            if fs.isFileset r then
              lib.filter (x: x != null) (map rel (fs.toList r))
            else
              throw "breakbulk: a function in packages.${name}.predictSources.keep returned a ${typeOf r}, not a file set (lib.fileset)"
        ) (ps.keep or [ ]);
    in
    {
      inherit enable;
      runs =
        ps.buildScriptRuns or null == true
        ||
          ps.buildScriptRuns or null == null
          && !lib.any (d: lib.elem d directivePrinters) (buildDependencies {
            inherit root pkgDir;
          });
      spec =
        {
          kind,
          cargoTarget,
          run,
          view,
        }:
        {
          view = "${view}";
          packageDir = pkgDir;
          kind = if run then "run" else "crate";
          root = util.joinRel pkgDir cargoTarget.path;
          keep = lib.unique (
            extraKeep
            ++ keepOf {
              inherit root kind cargoTarget;
              buildScriptRun = run;
              packageDir = pkgDir;
              workspaceDir = wsDir;
            }
          );
        };
    };

  packageViews =
    {
      root,
      name,
      pkgDir,
      wsDir ? "",
      memberDirs ? [ ],
      settings ? { },
      targets ? [ ],
      tested ? true,
      runCommand ? null,
      # Paths every predicted view of the package keeps, relative to the
      # root, besides `predictSources.keep` (the curated keeps of the
      # variant: clippy's `Cargo.toml`).
      extraKeep ? [ ],
    }:
    let
      cargoTargets = map (t: { inherit (t) kind name path; }) targets;
      steps =
        defaultSteps {
          inherit
            root
            pkgDir
            wsDir
            memberDirs
            settings
            ;
          targets = cargoTargets;
        }
        ++ settings.sources or [ ];
      custom = settings.sources or [ ] != [ ];
      view =
        kind: cargoTarget:
        overlay {
          inherit runCommand name pkgDir;
          entries = settings.sourceOverlay or { };
          view = realize {
            inherit root pkgDir;
            fileset = viewFileset {
              inherit
                root
                name
                pkgDir
                steps
                kind
                cargoTarget
                ;
            };
          };
        };
      realized = lib.genAttrs [ "build" "test" "run" ] (kind: view kind null);
      src = realized.build;
      testSrc = realized.test;
      run = realized.run;
      # Not every target: a view the steps cannot narrow is the package's
      # view again, and each costs a copy of the package at evaluation.
      narrowed =
        t:
        custom
        ||
          settings.scopeTargetRoots or null != false
          &&
            targetExcluded {
              inherit root pkgDir;
              targets = cargoTargets;
              cargoTarget = t;
            } != [ ];
      targetViews =
        kind: ts:
        lib.listToAttrs (
          map (t: lib.nameValuePair "${t.kind}/${t.name}" (view kind t)) (filter narrowed ts)
        );
      buildTargets = filter (
        t:
        lib.elem t.kind [
          "lib"
          "bin"
          "custom-build"
        ]
      ) cargoTargets;
      testTargets = filter (t: t.kind != "custom-build") cargoTargets;
      predict = predictSettings {
        inherit
          root
          name
          pkgDir
          wsDir
          settings
          extraKeep
          ;
      };
      # The view a target's predicted view narrows: its own when the steps
      # narrow it, else the package's.
      allowed = kind: t: if narrowed t then view kind t else realized.${kind};
      specsOf =
        kind: ts:
        lib.listToAttrs (
          lib.concatMap (
            t:
            [
              (lib.nameValuePair "${t.kind}/${t.name}" (
                predict.spec {
                  inherit kind;
                  cargoTarget = t;
                  run = false;
                  view = allowed kind t;
                }
              ))
            ]
            ++ lib.optional (t.kind == "custom-build" && predict.runs) (
              # Narrows the package's view, not the script's, as the run
              # reads it without prediction (instantiation's view_key).
              lib.nameValuePair "run/${t.kind}/${t.name}" (
                predict.spec {
                  inherit kind;
                  cargoTarget = t;
                  run = true;
                  view = realized.${kind};
                }
              )
            )
          ) ts
        );
    in
    {
      inherit src custom;
      # The predicted views' specs (lib/instantiate.nix `sources.predicted`),
      # by `<kind>/<name>` (`run/custom-build/<name>` for a build-script
      # run), for "build" and "test" units.
      predicted = lib.optionalAttrs predict.enable (
        {
          build = specsOf "build" buildTargets;
        }
        // lib.optionalAttrs tested { test = specsOf "test" testTargets; }
      );
      targetSrc = targetViews "build" buildTargets;
      targetRoots = lib.optionals (settings.scopeTargetRoots or null != false) (targetRootPaths {
        inherit root pkgDir;
        targets = cargoTargets;
      });
      testOnly = testOnlyPaths {
        inherit root pkgDir;
        sourceScope = settings.test.sourceScope or [ ];
        scopeTestsDir = settings.test.scopeTestsDir or null;
      };
    }
    // lib.optionalAttrs tested {
      inherit testSrc;
      targetTestSrc = targetViews "test" testTargets;
      # The view the test runs read: the "run" view when a step chose
      # other files for runs, else the test view.
      runSrc = if "${run}" == "${testSrc}" then testSrc else run;
      # Compared by store path, so that a run reads its test binary's own
      # view unless a step chose other files for runs.
      runDir =
        if "${run}" == "${testSrc}" then
          null
        else if pkgDir == "" then
          "${run}"
        else
          "${run}/${pkgDir}";
    };

  # A member's clippy config tree, rooted at the repository root: every
  # `.clippy.toml` and `clippy.toml` in `pkgDir` and its ancestors up to
  # the root, at their places. Clippy-driver gets
  # `CLIPPY_CONF_DIR=<tree>/<pkgDir>` and does its own lookup there, so
  # breakbulk picks no file. The package's `Cargo.toml` is in the tree only
  # so that `<pkgDir>` exists: clippy canonicalizes its start directory.
  # Not in the source views, because then every edit to a config file would
  # rebuild every build and check unit below it.
  clippyConfTree =
    { root, pkgDir }:
    let
      at = manifest.at root;
      ancestors = d: [ d ] ++ lib.optionals (d != "") (ancestors (util.normalizeRel (builtins.dirOf d)));
      configs = lib.concatMap (
        d:
        map (n: fs.maybeMissing (at (util.joinRel d n))) [
          ".clippy.toml"
          "clippy.toml"
        ]
      ) (ancestors pkgDir);
    in
    fs.toSource {
      inherit root;
      fileset = fs.unions ([ (at (util.joinRel pkgDir "Cargo.toml")) ] ++ configs);
    };

  # Views for every member of a workspace, keyed by package name
  # (`packageViews`, plus `dir`). `packages.<package name>`: its settings.
  # `runCommand`: as packageViews takes it.
  workspaceViews =
    {
      root,
      wsDir ? "",
      packages ? { },
      # The Cargo targets of the member at a directory (packageViews'
      # `targets`).
      targetsOf ? (_: [ ]),
      runCommand ? null,
      # packageViews' `extraKeep`, for every member.
      extraKeep ? [ ],
    }:
    let
      ws = manifest.workspace { inherit root wsDir; };
    in
    lib.listToAttrs (
      map (
        dir:
        let
          info = manifest.packageInfo {
            inherit root dir;
            wsManifest = ws.manifest;
          };
        in
        lib.nameValuePair info.name (
          {
            inherit dir;
          }
          // packageViews {
            inherit
              root
              wsDir
              runCommand
              extraKeep
              ;
            inherit (info) name;
            pkgDir = dir;
            memberDirs = ws.members;
            settings = packages.${info.name} or { };
            targets = targetsOf dir;
          }
        )
      ) ws.members
    );
}
