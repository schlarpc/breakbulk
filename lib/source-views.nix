# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Which files a view holds is a pipeline of steps per package and kind of
# unit: "build" (non-test compiles, build scripts and their runs), "test"
# (test compiles and doctests), "run" (test runs). Each step is a function
# from `{ default, kind, root, packageDir, ... }` to a file set, and gets
# the previous step's result as `default`. The built-in steps
# (`defaultSteps`) come first, then the package's `sources` functions.
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

  # The built-in steps of one package, in order, from its settings
  # (`extraSources` and `test`, as `packages.<name>` has them).
  defaultSteps =
    {
      root,
      pkgDir,
      memberDirs ? [ ],
      settings ? { },
    }:
    let
      at = manifest.at root;
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
      ({ default, ... }: fs.union default (packageFileset { inherit root pkgDir memberDirs; }))
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
      ({ default, kind, ... }: if kind == "build" && tests != null then fs.difference default (at tests) else default)
      # test.runFiles: only the listed paths, relative to the package.
      (
        { default, kind, ... }:
        if kind != "run" || runFiles == null then
          default
        else
          fs.unions (map (p: at (util.joinRel pkgDir p)) runFiles)
      )
    ];

  # The files of one package's units of `kind`: every step in turn, from
  # the empty set. `name`: the package's, for errors.
  viewFileset =
    {
      root,
      name,
      pkgDir,
      steps,
      kind,
    }:
    lib.foldl' (
      acc: step:
      let
        r = step {
          inherit root kind;
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
        path: type: files.filter path type || (type == "directory" && (path == dir || lib.hasPrefix "${path}/" dir));
    };

  # A package's views, rooted at the repository root (`<view>/<pkgDir>`
  # is the package directory): `src` for its "build" units; for a package
  # that is `tested`, `testSrc` for its "test" units and `runDir`, the
  # package directory of its "run" view, or null when that view is
  # `testSrc`. `settings`: `extraSources`, `test` and `sources`, as
  # `packages.<name>` has them.
  packageViews =
    {
      root,
      name,
      pkgDir,
      memberDirs ? [ ],
      settings ? { },
      tested ? true,
    }:
    let
      steps = defaultSteps { inherit root pkgDir memberDirs settings; } ++ settings.sources or [ ];
      view =
        kind:
        realize {
          inherit root pkgDir;
          fileset = viewFileset {
            inherit
              root
              name
              pkgDir
              steps
              kind
              ;
          };
        };
      src = view "build";
      testSrc = view "test";
      run = view "run";
    in
    {
      inherit src;
      # Whether `sources` functions choose files: then the failure hints
      # count paths in the package directory too.
      custom = settings.sources or [ ] != [ ];
      testOnly = testOnlyPaths {
        inherit root pkgDir;
        sourceScope = settings.test.sourceScope or [ ];
        scopeTestsDir = settings.test.scopeTestsDir or null;
      };
    }
    // lib.optionalAttrs tested {
      inherit testSrc;
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
      ancestors =
        d: [ d ] ++ lib.optionals (d != "") (ancestors (util.normalizeRel (builtins.dirOf d)));
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
  workspaceViews =
    {
      root,
      wsDir ? "",
      packages ? { },
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
            inherit root;
            inherit (info) name;
            pkgDir = dir;
            memberDirs = ws.members;
            settings = packages.${info.name} or { };
          }
        )
      ) ws.members
    );
}
