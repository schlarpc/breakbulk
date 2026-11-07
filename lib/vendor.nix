# The per-workspace vendor directory used for planning, and the Cargo config
# that replaces every remote source with it.
#
# Layout (crane's, lib/vendorCargoRegistries.nix and lib/vendorGitDeps.nix):
#   <vendor>/<hash of registry source>/<name>-<version> -> unpacked crate
#   <vendor>/<hash of git source id>/<name>-<version>/  -> symlinks into the
#                                                          fetched tree, plus
#                                                          .cargo-checksum.json
#   <vendor>/<hash of git source id>/Cargo.toml         -> the crate's
#                                                          [workspace] table,
#                                                          when it inherits
#   <vendor>/<hash of git source id>/.breakbulk-workspace-<hash>/Cargo.toml
#                                  -> instead, one per workspace, when the
#                                     source's crates inherit from several
#                                     (see `pointerLayout`)
#
# Source replacement is matched on SourceId: kind (including the git
# reference: branch, tag, rev or default) and canonical URL, never on the
# `[source.<name>]` label (cargo src/sources/config.rs, `SourceConfigMap::load`
# looks up `id2name` by SourceId; `SourceConfigMap::add_config` builds the id
# from `registry` or `git` + `branch`/`tag`/`rev`). The labels used here follow
# `cargo vendor` (cargo src/ops/cargo_vendor.rs): `crates-io` for crates.io,
# the source URL without the locked revision for git sources.
#
# Workspace inheritance in git crates is left to Cargo: the crate's manifest
# is kept byte-identical and the stub `Cargo.toml` one level up gives Cargo's
# `find_workspace_root` the [workspace] table it would find in a checkout
# (or, with several workspaces in one source, `package.workspace` names the
# crate's stub: docs/spikes/git-multi-workspace.md). Only `readme`/`license-file` inherited from the workspace are rewritten,
# because Cargo resolves them relative to the workspace root and the vendor
# layout has a different depth (CARGO_PKG_README would differ otherwise).
{
  lib,
  pkgs,
  util,
  lockfile,
  manifest,
}:
let
  inherit (builtins)
    attrNames
    attrValues
    concatStringsSep
    head
    isAttrs
    length
    pathExists
    readFileType
    toJSON
    ;

  q = toJSON;
in
{
  # `fetch` is an instance of fetch.nix; `entries` the lockfile entries of
  # one workspace (lockfile.read).
  mkVendor =
    {
      fetch,
      entries,
      registries ? { },
      name ? "breakbulk-vendor",
    }:
    let
      remote = lockfile.remoteEntries entries;

      sourceDirName = e: util.shortHash e.parsed.id;
      crateDirName = e: "${e.name}-${e.version}";

      groups = lib.groupBy sourceDirName remote;

      # --- git crates -------------------------------------------------------

      # The workspace root of the crate at `subdir` inside `tree`, as
      # cargo's find_workspace_root: the nearest ancestor (including the
      # crate's own directory) whose manifest has [workspace].
      findWsRoot =
        tree: subdir:
        let
          go =
            r:
            let
              p = manifest.at tree (util.joinRel r "Cargo.toml");
              m = if pathExists p then builtins.fromTOML (builtins.readFile p) else null;
            in
            if m != null && m ? workspace then
              { dir = r; manifest = m; }
            else if r == "" then
              null
            else
              go (util.normalizeRel "${r}/..");
        in
        go subdir;

      usesInheritance =
        m:
        let
          inheritsField = v: isAttrs v && (v.workspace or false);
          pkgFields = lib.any inheritsField (attrValues (m.package or { }));
          deps = lib.any (t: lib.any inheritsField (attrValues t)) (manifest.dependencyTables m);
          lints = (m.lints.workspace or false);
        in
        pkgFields || deps || lints;

      gitCrate =
        e:
        let
          src = fetch.crateSource e;
          m = manifest.readManifest src.tree src.subdir;
          inherits = usesInheritance m && !(m ? workspace);
          ws = if inherits then findWsRoot src.tree src.subdir else null;
          wsPkg = if ws == null then { } else ws.manifest.workspace.package or { };
          pkg = m.package or { };
          inheritsKey = k: isAttrs (pkg.${k} or null) && (pkg.${k}.workspace or false);

          # InheritableFields::readme / license_file + resolve_relative_path
          # (cargo src/workspace/parser/mod.rs): paths relative to the
          # workspace root, re-expressed relative to the package root.
          rel = p: util.relativeTo (util.joinRel ws.dir p) src.subdir;
          defaultReadme = lib.findFirst (
            f:
            let
              p = manifest.at src.tree (util.joinRel ws.dir f);
            in
            pathExists p && readFileType p != "directory"
          ) null [ "README.md" "README.txt" "README" ];
          wsReadme =
            let
              r = wsPkg.readme or null;
            in
            if r == null then
              (if defaultReadme == null then throw "breakbulk: ${e.id} inherits readme, but the workspace has none" else rel defaultReadme)
            else if r == false then
              false
            else if r == true then
              rel "README.md"
            else
              rel r;
          rewrites =
            lib.optionalAttrs (inheritsKey "readme") { readme = wsReadme; }
            // lib.optionalAttrs (inheritsKey "license-file") { license-file = rel wsPkg.license-file; };
          dropPointer = inherits && pkg ? workspace;
          # The manifest to vendor, or null to keep the crate's own. With
          # `pointer`, `package.workspace` names the crate's stub (see
          # `pointerLayout`).
          rewritten =
            pointer:
            if rewrites == { } && !dropPointer && pointer == null then
              null
            else
              util.toTOML (
                m
                // {
                  package =
                    (builtins.removeAttrs pkg (lib.optional dropPointer "workspace"))
                    // rewrites
                    // lib.optionalAttrs (pointer != null) { workspace = pointer; };
                }
              );
          stub =
            if ws == null then
              null
            else
              util.toTOML {
                workspace = lib.filterAttrs (k: _: lib.elem k [ "package" "dependencies" "lints" ]) ws.manifest.workspace;
              };
        in
        {
          inherit (src) path;
          inherit stub rewritten;
        };

      # --- the directory ----------------------------------------------------

      # Each source's entries, with what gitCrate found for git crates.
      analysed = lib.mapAttrs (
        _:
        map (e: {
          inherit e;
          g = if e.parsed.kind == "git" then gitCrate e else null;
        })
      ) groups;

      # The distinct stubs of each git source's inheriting crates.
      stubsBySource = lib.mapAttrs (
        _: cs: lib.unique (lib.concatMap (c: lib.optional (c.g != null && c.g.stub != null) c.g.stub) cs)
      ) analysed;

      # A git source whose inheriting crates come from more than one
      # workspace (one repository, several workspaces: e.g. Sui's root
      # workspace and its external-crates/move workspace) cannot share the
      # one stub that `find_workspace_root` would find. Instead each stub
      # goes to a dot directory, which a directory source does not read as a
      # package (cargo src/sources/directory.rs, `DirectorySource::update`,
      # skips names starting with '.'), and each inheriting crate's
      # `package.workspace` names its stub. Cargo then loads the stub's
      # [workspace] table itself (cargo src/workspace/parser/mod.rs,
      # `load_inheritable_fields`, `WorkspaceConfig::Member { root: Some }`).
      # Sources with one workspace keep the stub one level up, unchanged.
      pointerLayout = h: length stubsBySource.${h} > 1;
      stubDirName = s: ".breakbulk-workspace-${util.shortHash s}";

      crateEntries = lib.concatLists (
        lib.mapAttrsToList (
          h: cs:
          map (
            { e, g }:
            let
              src = fetch.crateSource e;
              pointer = if g != null && g.stub != null && pointerLayout h then "../${stubDirName g.stub}" else null;
            in
            {
              inherit e;
              dir = "${h}/${crateDirName e}";
              sourceDir = h;
              path = toString src.path;
              kind = e.parsed.kind;
              rewritten = if g == null then null else g.rewritten pointer;
            }
          ) cs
        ) analysed
      );

      # Stubs one level above the crates: source directory -> contents.
      stubs = lib.mapAttrs (_: head) (lib.filterAttrs (h: ss: ss != [ ] && !(pointerLayout h)) stubsBySource);
      # Stubs named by `package.workspace`: vendor-relative directory ->
      # contents.
      pointerStubs = lib.concatMapAttrs (
        h: ss: lib.optionalAttrs (pointerLayout h) (lib.listToAttrs (map (s: lib.nameValuePair "${h}/${stubDirName s}" s) ss))
      ) stubsBySource;

      # Shell script that builds the directory. Paths are store paths with
      # context, so the derivation depends on every crate source.
      script = concatStringsSep "\n" (
        [ "mkdir -p $out" ]
        ++ map (h: "mkdir -p $out/${h}") (attrNames groups)
        ++ lib.mapAttrsToList (h: s: "cp ${pkgs.writeText "Cargo.toml" s} $out/${h}/Cargo.toml") stubs
        ++ lib.mapAttrsToList (
          d: s: "mkdir -p $out/${d}\ncp ${pkgs.writeText "Cargo.toml" s} $out/${d}/Cargo.toml"
        ) pointerStubs
        ++ map (
          c:
          if c.kind == "registry" then
            "ln -s ${c.path} $out/${lib.escapeShellArg c.dir}"
          else
            concatStringsSep "\n" (
              [
                "d=$out/${lib.escapeShellArg c.dir}"
                "mkdir -p \"$d\""
                "for f in ${c.path}/* ${c.path}/.[!.]* ${c.path}/..?*; do [ -e \"$f\" ] || [ -L \"$f\" ] || continue; ln -s \"$f\" \"$d/\"; done"
                "rm -f \"$d/.cargo-checksum.json\""
                "echo '{\"files\":{},\"package\":null}' > \"$d/.cargo-checksum.json\""
              ]
              ++ lib.optionals (c.rewritten != null) [
                "rm \"$d/Cargo.toml\""
                "cp ${pkgs.writeText "Cargo.toml" c.rewritten} \"$d/Cargo.toml\""
              ]
            )
        ) crateEntries
      );

      dir = pkgs.runCommand name { } script;

      # --- source replacement config ----------------------------------------

      regNameByIndex = lib.listToAttrs (
        lib.mapAttrsToList (
          n: r:
          lib.nameValuePair (if lib.hasPrefix "sparse+" r.index then r.index else lib.removePrefix "registry+" r.index) n
        ) (lib.filterAttrs (_: r: r ? index) registries)
      );

      replacement =
        h: "breakbulk-${h}";

      sourceSection =
        h: es:
        let
          p = (head es).parsed;
          target = replacement h;
        in
        if p.kind == "registry" && p.isCratesIo then
          ''
            [source.crates-io]
            replace-with = ${q target}
          ''
        else if p.kind == "registry" then
          ''
            [source.${q (regNameByIndex.${p.url} or "breakbulk-registry-${h}")}]
            registry = ${q p.url}
            replace-with = ${q target}
          ''
        else
          ''
            [source.${q p.id}]
            git = ${q p.url}
          ''
          + lib.optionalString (p.reference.type != "default") ''
            ${p.reference.type} = ${q p.reference.value}
          ''
          + ''
            replace-with = ${q target}
          '';

      config = concatStringsSep "\n" (
        lib.mapAttrsToList (h: es: sourceSection h es + ''
          [source.${q (replacement h)}]
          directory = ${q "${dir}/${h}"}
        '') groups
      );
    in
    {
      inherit dir config;
      # Pass to cargo as `--config <file>`: an inline `--config` value may
      # hold only one dotted key (cargo src/context/mod.rs, toml_dotted_keys).
      configFile = pkgs.writeText "breakbulk-source-replacement.toml" config;
      # For the planner's path rewriting: vendor-relative crate directory ->
      # package id and the crate source store path.
      crates = lib.listToAttrs (
        map (c: lib.nameValuePair c.dir {
          inherit (c.e) id name version;
          inherit (c) path kind;
        }) crateEntries
      );
    };
}
