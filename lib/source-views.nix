# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Default fileset: the package directory, minus `target/`, `.git`, `result*`
# at its top level, and minus the directories of other packages nested inside
# it (other workspace members, or any directory with its own Cargo.toml).
# Plus `extraSources` at their original relative paths.
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
    pathExists
    readDir
    ;
  fs = lib.fileset;
in
rec {
  # Directories below `pkgDir` that hold another package. Walks the package
  # directory, skipping `target` and dot directories, and stops descending at
  # the first nested Cargo.toml.
  nestedPackageDirs =
    root: pkgDir:
    let
      go =
        rel:
        let
          entries = readDir (manifest.at root rel);
          dirs = filter (n: entries.${n} == "directory" && n != "target" && !(lib.hasPrefix "." n)) (attrNames entries);
        in
        lib.concatMap (
          n:
          let
            sub = util.joinRel rel n;
          in
          if manifest.hasManifest root sub then [ sub ] else go sub
        ) dirs;
    in
    go pkgDir;

  # The fileset of one package.
  packageFileset =
    {
      root,
      pkgDir,
      extraSources ? [ ],
      excludeDirs ? null,
    }:
    let
      at = manifest.at root;
      top = readDir (at pkgDir);
      junk =
        filter (n: n == "target" || n == ".git" || lib.hasPrefix "result" n) (attrNames top);
      nested = if excludeDirs == null then nestedPackageDirs root pkgDir else excludeDirs;
      toFs =
        x:
        if isPath x then
          x
        else if isString x then
          at (util.normalizeRel x)
        else
          throw "breakbulk: extraSources entries must be paths or strings relative to the repository root";
      base = fs.difference (at pkgDir) (
        fs.unions (map (n: at (util.joinRel pkgDir n)) junk ++ map at nested)
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
      excludeDirs ? null,
    }:
    fs.toSource {
      inherit root;
      fileset = packageFileset { inherit root pkgDir extraSources excludeDirs; };
    };

  # Views for every member of a workspace, keyed by package name.
  # `extraSources.<package name>` adds per-package extras.
  workspaceViews =
    {
      root,
      wsDir ? "",
      extraSources ? { },
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
        lib.nameValuePair info.name {
          inherit dir;
          src = sourceView {
            inherit root;
            pkgDir = dir;
            extraSources = extraSources.${info.name} or [ ];
          };
        }
      ) ws.members
    );
}
