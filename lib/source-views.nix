# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Default fileset: the package directory, minus `target/`, `.git` and
# `result*` at its top level, and minus the directories of other workspace
# members nested inside it. Other nested Cargo.toml files (test fixtures,
# examples of generated projects) stay, because the package may read them.
# Plus `extraSources` at their original relative paths.
#
# Test-only paths (`testOnlyPaths`: the package's `tests/` directory and
# the `test.sourceScope` entries inside the package) are left out of the
# normal view and kept in the package's test view, so editing a fixture
# does not rebuild the library and its dependents.
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
    ;
  fs = lib.fileset;
in
rec {
  # The fileset of one package. `memberDirs`: directories of the other
  # workspace members (relative to root); those below `pkgDir` are removed.
  packageFileset =
    {
      root,
      pkgDir,
      extraSources ? [ ],
      memberDirs ? [ ],
      # Paths relative to the repository root, inside `pkgDir`
      # (`testOnlyPaths`), removed before `extraSources` are added.
      testOnly ? [ ],
    }:
    let
      at = manifest.at root;
      top = readDir (at pkgDir);
      junk = filter (n: n == "target" || n == ".git" || lib.hasPrefix "result" n) (attrNames top);
      nested = filter (d: d != pkgDir && util.isUnder pkgDir d) memberDirs;
      toFs =
        x:
        if isPath x then
          x
        else if isString x then
          at (util.normalizeRel x)
        else
          throw "breakbulk: extraSources entries must be paths or strings relative to the repository root";
      base = fs.difference (at pkgDir) (
        fs.unions (map (n: at (util.joinRel pkgDir n)) junk ++ map at nested ++ map at testOnly)
      );
    in
    fs.unions ([ base ] ++ map toFs extraSources);

  # The store path of one package's source view, rooted at the repository
  # root: `<view>/<pkgDir>` is the package directory.
  sourceView =
    {
      root,
      pkgDir,
      extraSources ? [ ],
      memberDirs ? [ ],
      testOnly ? [ ],
    }:
    fs.toSource {
      inherit root;
      fileset = packageFileset {
        inherit
          root
          pkgDir
          extraSources
          memberDirs
          testOnly
          ;
      };
    };

  # The paths only a package's test units see, relative to the repository
  # root: its `tests/` directory (unless `scopeTestsDir` is false), which
  # Cargo builds only as integration tests, and the `sourceScope` entries
  # (paths, or strings relative to the root) inside `pkgDir`. Entries
  # outside the package only widen its test view.
  testOnlyPaths =
    {
      root,
      pkgDir,
      sourceScope ? [ ],
      scopeTestsDir ? true,
    }:
    let
      at = manifest.at root;
      rel =
        x:
        if isPath x then
          (if lib.path.hasPrefix root x then util.normalizeRel (lib.path.removePrefix root x) else null)
        else
          util.normalizeRel x;
      inside = filter (r: r != null && util.isUnder pkgDir r) (map rel sourceScope);
      tests = util.joinRel pkgDir "tests";
      hasTests = scopeTestsDir && (readDir (at pkgDir)).tests or null == "directory";
    in
    lib.unique (lib.optional hasTests tests ++ inside);

  # A package's views: `src`, its normal view, and `testSrc`, the view of
  # its test units, or null when it would be the same. `test` holds the
  # package's `sourceScope` and `scopeTestsDir`.
  packageViews =
    {
      root,
      pkgDir,
      extraSources ? [ ],
      memberDirs ? [ ],
      test ? { },
    }:
    let
      scope = test.sourceScope or [ ];
      testOnly = testOnlyPaths {
        inherit root pkgDir;
        sourceScope = scope;
        scopeTestsDir = if test.scopeTestsDir or null == null then true else test.scopeTestsDir;
      };
    in
    {
      inherit testOnly;
      src = sourceView {
        inherit
          root
          pkgDir
          extraSources
          memberDirs
          testOnly
          ;
      };
      testSrc =
        if scope == [ ] && testOnly == [ ] then
          null
        else
          sourceView {
            inherit root pkgDir memberDirs;
            extraSources = extraSources ++ scope;
          };
    };

  # A clippy-mode unit's config tree, rooted at the repository root: every
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
  # (`packageViews`, plus `dir`). `extraSources.<package name>` adds
  # per-package extras; `test.<package name>` is `packageViews`' `test`.
  workspaceViews =
    {
      root,
      wsDir ? "",
      extraSources ? { },
      test ? { },
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
            pkgDir = dir;
            memberDirs = ws.members;
            extraSources = extraSources.${info.name} or [ ];
            test = test.${info.name} or { };
          }
        )
      ) ws.members
    );
}
