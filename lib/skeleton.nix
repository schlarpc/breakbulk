# The planning skeleton for one workspace: everything Cargo reads while
# planning, and nothing else, so the plan derivations rerun only when one of
# these files changes.
#
# Real files (copied):
#   - Cargo.toml of every member and every path package reachable from them
#     (including [patch] and [replace] path entries and packages outside the
#     workspace root), and the workspace root manifest of each such package;
#   - the workspace's Cargo.lock;
#   - .cargo/config.toml and .cargo/config in the workspace directory and
#     every ancestor up to the repository root (Cargo's config discovery);
#   - rust-toolchain.toml / rust-toolchain in the same directories.
# Empty files (names only):
#   - src/lib.rs, src/main.rs, build.rs where they exist;
#   - every `*.rs` and `*/main.rs` in src/bin, examples, tests, benches;
#   - every explicit `path =` target and `package.build` script that exists;
#   - README.md, README.txt and README in each package and workspace root,
#     because Cargo derives CARGO_PKG_README from their existence
#     (cargo src/workspace/parser/mod.rs, default_readme_from_package_root).
{
  lib,
  util,
  manifest,
  roots,
}:
let
  inherit (builtins)
    attrValues
    concatLists
    filter
    isAttrs
    pathExists
    readFileType
    ;

  existsFile = root: rel: pathExists (manifest.at root rel) && readFileType (manifest.at root rel) != "directory";

  # Ancestors of a relative directory, from itself up to the root ("").
  ancestors =
    rel:
    if rel == "" then
      [ "" ]
    else if rel == ".." || lib.hasPrefix "../" rel then
      [ rel ] # outside the repository root: nothing above is visible
    else
      [ rel ] ++ ancestors (util.normalizeRel "${rel}/..");

  findWsRoot =
    root: dir:
    lib.findFirst (
      d: manifest.hasManifest root d && (manifest.readManifest root d) ? workspace
    ) null (ancestors dir);

  patchPathDeps =
    wsDir: m:
    let
      tables = attrValues (m.patch or { }) ++ [ (m.replace or { }) ];
    in
    concatLists (
      map (
        t: concatLists (lib.mapAttrsToList (_: d: if isAttrs d && d ? path then [ (util.joinRel wsDir d.path) ] else [ ]) t)
      ) tables
    );
in
rec {
  # Every package directory Cargo may load for this workspace.
  packageClosure =
    { root, wsDir ? "" }:
    let
      ws = manifest.workspace { inherit root wsDir; };
      seeds = ws.members ++ patchPathDeps wsDir ws.manifest;
      walk =
        seen: queue:
        if queue == [ ] then
          seen
        else
          let
            dir = builtins.head queue;
            rest = builtins.tail queue;
          in
          if seen ? ${dir} || !(manifest.hasManifest root dir) then
            walk seen rest
          else
            let
              m = manifest.readManifest root dir;
              wsRootDir = findWsRoot root dir;
              wsM = if wsRootDir == null then { } else manifest.readManifest root wsRootDir;
              deps =
                if m ? package || m ? project then
                  manifest.pathDeps {
                    inherit root dir;
                    manifest = m;
                    wsDir = if wsRootDir == null then dir else wsRootDir;
                    wsManifest = wsM;
                  }
                else
                  [ ];
            in
            walk (seen // { ${dir} = wsRootDir; }) (rest ++ deps);
      found = walk { } seeds;
    in
    {
      inherit ws;
      packages = lib.attrNames found;
      workspaceRoots = lib.unique ([ wsDir ] ++ filter (d: d != null) (attrValues found));
    };

  # Names of target files of one package that exist on disk.
  targetFiles =
    root: pkgDir:
    let
      wsRootDir = findWsRoot root pkgDir;
      wsManifest = if wsRootDir == null then null else manifest.readManifest root wsRootDir;
      m = manifest.readManifest root pkgDir;
      pkg = m.package or m.project or { };
      listDir = d: map (i: i.path) (roots.inferFromDirectory root pkgDir d);
      conventional = [
        "src/lib.rs"
        "src/main.rs"
        "build.rs"
        "README.md"
        "README.txt"
        "README"
      ];
      explicit =
        lib.optional (m ? lib && m.lib ? path) m.lib.path
        ++ concatLists (
          map (k: map (t: t.path) (filter (t: t ? path) (m.${k} or [ ]))) [ "bin" "example" "test" "bench" ]
        )
        ++ (
          let
            b = pkg.build or null;
          in
          if builtins.isString b then [ b ] else if builtins.isList b then b else [ ]
        );
      # Legacy 2015-edition paths are only found through discovery itself.
      predicted =
        let
          r = builtins.tryEval (
            let
              ts = (roots.packageTargets { inherit root pkgDir wsManifest; }).targets;
            in
            builtins.deepSeq ts ts
          );
        in
        if r.success then map (t: t.path) r.value else [ ];
      candidates = lib.unique (
        map util.normalizeRel (conventional ++ listDir "src/bin" ++ listDir "examples" ++ listDir "tests" ++ listDir "benches" ++ explicit ++ predicted)
      );
    in
    map (f: util.joinRel pkgDir f) (filter (f: existsFile root (util.joinRel pkgDir f)) candidates);

  # Description of the skeleton as relative paths.
  describe =
    { root, wsDir ? "" }:
    let
      c = packageClosure { inherit root wsDir; };
      manifests = map (d: util.joinRel d "Cargo.toml") (lib.unique (c.packages ++ c.workspaceRoots));
      configDirs = ancestors wsDir;
      configFiles = filter (existsFile root) (
        concatLists (
          map (d: [
            (util.joinRel d ".cargo/config.toml")
            (util.joinRel d ".cargo/config")
            (util.joinRel d "rust-toolchain.toml")
            (util.joinRel d "rust-toolchain")
          ]) configDirs
        )
      );
      lock = filter (existsFile root) [ (util.joinRel wsDir "Cargo.lock") ];
      readmes = concatLists (
        map (d: filter (existsFile root) (map (f: util.joinRel d f) [ "README.md" "README.txt" "README" ])) c.workspaceRoots
      );
      empty = lib.unique (concatLists (map (targetFiles root) c.packages) ++ readmes);
      real = lib.unique (manifests ++ configFiles ++ lock);
    in
    {
      inherit real;
      empty = filter (f: !(lib.elem f real)) empty;
      inherit (c) packages workspaceRoots;
    };

  # The project's Cargo config files for a workspace (`.cargo/config.toml`
  # or `.cargo/config` in the workspace directory and every ancestor up to
  # the repository root), as relative paths. Unlike `describe`, it reads
  # no manifest, so it works while a manifest is broken.
  configFiles =
    { root, wsDir ? "" }:
    filter (existsFile root) (
      concatLists (
        map (d: [
          (util.joinRel d ".cargo/config.toml")
          (util.joinRel d ".cargo/config")
        ]) (ancestors wsDir)
      )
    );

  # A tree with only those config files and the workspace directory: what
  # the dev shell's `cargo-env.json` derivation reads (lib/plan.nix
  # mkCargoEnv; decision 81).
  mkConfigSkeleton =
    pkgs:
    {
      root,
      wsDir ? "",
      name ? "breakbulk-config-skeleton",
    }:
    let
      files = configFiles { inherit root wsDir; };
      tree = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions (map (manifest.at root) files);
      };
    in
    pkgs.runCommand name { } ''
      mkdir -p $out/${lib.escapeShellArg wsDir}
      ${lib.optionalString (files != [ ]) "cp -r --no-preserve=mode ${tree}/. $out/"}
    '';

  mkSkeleton =
    pkgs:
    {
      root,
      wsDir ? "",
      name ? "breakbulk-skeleton",
    }:
    let
      d = describe { inherit root wsDir; };
      realTree = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions (map (manifest.at root) d.real);
      };
    in
    pkgs.runCommand name
      {
        emptyFiles = lib.concatMapStrings (f: f + "\n") d.empty;
        passAsFile = [ "emptyFiles" ];
        passthru = {
          description = d;
          inherit wsDir;
        };
      }
      ''
        mkdir -p $out
        cp -r --no-preserve=mode ${realTree}/. $out/
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          mkdir -p "$out/$(dirname "$f")"
          : > "$out/$f"
        done < "$emptyFilesPath"
      '';
}
