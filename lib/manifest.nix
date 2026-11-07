# Reading Cargo.toml manifests and finding workspace members.
#
# Membership follows cargo's `Workspace::find_members` and `find_path_deps`
# (cargo src/workspace/workspace.rs, rust-1.99.0):
#   1. every directory matched by `workspace.members` (globs via the `glob`
#      crate; a pattern that matches nothing is kept literally);
#   2. the root manifest, if it has a [package];
#   3. transitively, every `path` dependency (any kind, any target) of a
#      member whose directory lies inside the workspace root;
# minus anything under `workspace.exclude` that is not also under an explicit
# `members` entry (`WorkspaceRootConfig::is_excluded`).
#
# Paths are handled as normalized strings relative to a repository `root`
# (a Nix path), so workspaces may reach outside their own directory.
{ lib, util }:
let
  inherit (builtins)
    attrNames
    attrValues
    concatLists
    filter
    fromTOML
    isAttrs
    isString
    pathExists
    readFile
    ;
in
rec {
  # Absolute Nix path for a relative string under root.
  at = root: rel: if rel == "" then root else root + "/${rel}";

  readManifest = root: dir: fromTOML (readFile (at root (util.joinRel dir "Cargo.toml")));

  hasManifest = root: dir: pathExists (at root (util.joinRel dir "Cargo.toml"));

  # All dependency tables of a manifest: [dependencies], [dev-dependencies],
  # [build-dependencies] (and the old underscore spellings), and the same
  # under every [target.<cfg>].
  dependencyTables =
    m:
    let
      kinds = [
        "dependencies"
        "dev-dependencies"
        "dev_dependencies"
        "build-dependencies"
        "build_dependencies"
      ];
      top = map (k: m.${k} or { }) kinds;
      targets = concatLists (map (t: map (k: t.${k} or { }) kinds) (attrValues (m.target or { })));
    in
    top ++ targets;

  # Path dependencies of the package at `dir` (relative to root), as
  # normalized directories relative to root. `wsDir` and `wsManifest` resolve
  # `dep.workspace = true` against `workspace.dependencies`, whose paths are
  # relative to the workspace root.
  pathDeps =
    {
      root,
      dir,
      manifest,
      wsDir,
      wsManifest,
    }:
    let
      wsDeps = wsManifest.workspace.dependencies or { };
      one =
        name: dep:
        if isAttrs dep && dep ? path then
          [ (util.joinRel dir dep.path) ]
        else if isAttrs dep && (dep.workspace or false) then
          let
            w = wsDeps.${dep.package or name} or wsDeps.${name} or null;
          in
          if isAttrs w && w ? path then [ (util.joinRel wsDir w.path) ] else [ ]
        else
          [ ];
    in
    concatLists (map (t: concatLists (lib.mapAttrsToList one t)) (dependencyTables manifest));

  # Workspace description for the workspace rooted at `wsDir`.
  #
  # Returns { dir, manifest, members = [ <dir relative to root> ... ] } with
  # members sorted.
  workspace =
    { root, wsDir ? "" }:
    let
      wsManifest = readManifest root wsDir;
      ws = wsManifest.workspace or null;
      memberPatterns = if ws == null then [ ] else ws.members or [ ];
      excludes = map (e: util.joinRel wsDir e) (if ws == null then [ ] else ws.exclude or [ ]);
      explicitMembers = map (m: util.joinRel wsDir m) memberPatterns;

      # WorkspaceRootConfig::is_excluded: excluded unless below an explicit
      # (unexpanded) members entry. Cargo uses Path::starts_with, which is a
      # component-wise prefix test.
      isExcluded =
        dir:
        lib.any (ex: util.isUnder ex dir) excludes && !(lib.any (m: util.isUnder m dir) explicitMembers);

      expandMember =
        pat:
        let
          joined = util.joinRel wsDir pat;
          expanded = util.expandGlob root joined;
          dirs = filter (
            d: pathExists (at root d) && builtins.readFileType (at root d) == "directory"
          ) expanded;
        in
        # members_paths: no match at all keeps the original path; otherwise
        # non-directories are dropped.
        if expanded == [ ] then [ joined ] else dirs;

      memberSeeds = concatLists (map expandMember memberPatterns);

      # find_path_deps, as a worklist. `isPathDep` distinguishes the seeds
      # (explicit members and the root), which are never filtered by location.
      walk =
        seen: queue:
        if queue == [ ] then
          seen
        else
          let
            item = builtins.head queue;
            rest = builtins.tail queue;
            dir = item.dir;
            outside = item.isPathDep && !(util.isUnder wsDir dir);
          in
          if seen ? ${dir} || outside || isExcluded dir then
            walk seen rest
          else
            let
              m = readManifest root dir;
              deps =
                if m ? package then
                  pathDeps {
                    inherit root dir wsDir wsManifest;
                    manifest = m;
                  }
                else
                  [ ];
            in
            walk (seen // { ${dir} = m ? package; }) (
              rest
              ++ map (d: {
                dir = d;
                isPathDep = true;
              }) deps
            );

      found =
        if ws == null then
          { ${wsDir} = true; }
        else
          walk { } (
            map (d: {
              dir = d;
              isPathDep = false;
            }) memberSeeds
            ++ [
              {
                dir = wsDir;
                isPathDep = false;
              }
            ]
          );
    in
    {
      dir = wsDir;
      manifest = wsManifest;
      # Directories of member packages (virtual manifests excluded).
      members = lib.sort (a: b: a < b) (attrNames (lib.filterAttrs (_: isPkg: isPkg) found));
    };

  # Package-level fields with workspace inheritance applied for the fields
  # that discovery needs (name, version, edition).
  packageInfo =
    {
      root,
      dir,
      wsManifest ? null,
    }:
    let
      m = readManifest root dir;
      pkg = m.package or m.project or (throw "breakbulk: ${dir}/Cargo.toml has no [package]");
      wsPkg = if wsManifest == null then { } else wsManifest.workspace.package or { };
      field =
        f: default:
        let
          v = pkg.${f} or null;
        in
        if v == null then
          default
        else if isAttrs v && (v.workspace or false) then
          wsPkg.${f} or (throw "breakbulk: ${dir}/Cargo.toml inherits `${f}` but workspace.package.${f} is not set")
        else
          v;
    in
    {
      inherit dir;
      manifest = m;
      name = pkg.name;
      # Cargo defaults version to 0.0.0 since 1.75.
      version = field "version" "0.0.0";
      edition = field "edition" "2015";
    };
}
