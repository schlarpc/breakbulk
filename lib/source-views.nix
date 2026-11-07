# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Default fileset: the package directory, minus `target/`, `.git` and
# `result*` at its top level, and minus the directories of other workspace
# members nested inside it. Other nested Cargo.toml files (test fixtures,
# examples of generated projects) stay, because the package may read them.
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
      base = fs.difference (at pkgDir) (fs.unions (map (n: at (util.joinRel pkgDir n)) junk ++ map at nested));
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
    }:
    fs.toSource {
      inherit root;
      fileset = packageFileset {
        inherit
          root
          pkgDir
          extraSources
          memberDirs
          ;
      };
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
            memberDirs = ws.members;
            extraSources = extraSources.${info.name} or [ ];
          };
        }
      ) ws.members
    );
}
