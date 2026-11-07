# Fetch derivations for every remote package in one or more lockfiles.
#
# Registry crates: a fixed-output `fetchurl` keyed by the lockfile's SHA-256,
# plus a small unpack derivation that adds the `.cargo-checksum.json` Cargo's
# directory sources require. Both download and unpack at build time.
#
# Git sources: `builtins.fetchGit` during evaluation, because finding a crate
# inside the repository needs its tree. Keyed by URL and locked revision.
{
  lib,
  pkgs,
  util,
  lockfile,
  manifest,
}:
{
  # registries.<name> = { index = "<index URL as in Cargo.lock>"; dl = "<template>"; }
  # `index` may be given with or without the `registry+` prefix; sparse
  # registries keep their `sparse+` prefix.
  registries ? { },
  # gitHashes."<Cargo.lock source string>" = "sha256-…": the NAR hash of the
  # fetched tree. Passed to builtins.fetchGit as `narHash`, which lets Nix
  # substitute the tree from a binary cache instead of cloning.
  gitHashes ? { },
  # gitSubdirs."<Cargo.lock source string or URL>"."<crate name>" = "path/in/repo":
  # skips the walk that locates a crate inside the tree.
  gitSubdirs ? { },
  # gitSubmodules."<URL>" = false: Cargo checks out submodules of git
  # dependencies (cargo src/sources/git/utils.rs, `GitCheckout::reset` calls
  # `update_submodules`), so this defaults to true.
  gitSubmodules ? { },
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elemAt
    filter
    hasAttr
    head
    isAttrs
    length
    pathExists
    readDir
    readFileType
    replaceStrings
    stringLength
    substring
    toJSON
    ;

  cratesIoDl = "https://static.crates.io/crates/{crate}/{crate}-{version}.crate";

  normIndex = i: if lib.hasPrefix "sparse+" i then i else lib.removePrefix "registry+" i;

  dlByIndex = lib.listToAttrs (
    lib.mapAttrsToList (name: r: lib.nameValuePair (normIndex r.index) (r // { inherit name; })) (
      lib.filterAttrs (_: r: r ? index) registries
    )
  );

  # cargo-util src/registry.rs, `make_dep_path(name, true)`.
  prefixOf =
    name:
    let
      n = stringLength name;
    in
    if n == 1 then
      "1"
    else if n == 2 then
      "2"
    else if n == 3 then
      "3/${substring 0 1 name}"
    else
      "${substring 0 2 name}/${substring 2 2 name}";

  # cargo-util src/registry.rs, `crate_url`: a template without any marker
  # gets `/{crate}/{version}/download` appended.
  crateUrl =
    dl: e:
    let
      markers = [ "{crate}" "{version}" "{prefix}" "{lowerprefix}" "{sha256-checksum}" ];
      hasMarker = lib.any (m: lib.hasInfix m dl) markers;
      prefix = prefixOf e.name;
    in
    if !hasMarker then
      "${dl}/${e.name}/${e.version}/download"
    else
      replaceStrings markers [ e.name e.version prefix (lib.toLower prefix) e.checksum ] dl;

  registryDl =
    e:
    if e.parsed.isCratesIo then
      cratesIoDl
    else
      (dlByIndex.${e.parsed.url} or (throw ''
        breakbulk: no download URL for registry ${e.parsed.url} (needed by ${e.name} ${e.version}).
        Set registries.<name> = { index = "${e.parsed.url}"; dl = "<dl template from the registry's config.json>"; };
      '')).dl;

  # Store-path-safe name fragment.
  safeName = s: replaceStrings [ "+" ] [ "_" ] s;

  fetchRegistryTarball =
    e:
    if e.checksum == null then
      throw "breakbulk: ${e.id} has no checksum in Cargo.lock"
    else
      pkgs.fetchurl {
        name = "${safeName e.name}-${e.version}.tar.gz";
        url = crateUrl (registryDl e) e;
        sha256 = e.checksum;
      };

  # The unpacked crate, laid out as a Cargo directory-source entry.
  unpackRegistryCrate =
    e:
    pkgs.runCommand "${safeName e.name}-${e.version}"
      {
        tarball = fetchRegistryTarball e;
        checksumJson = toJSON {
          files = { };
          package = e.checksum;
        };
        passAsFile = [ "checksumJson" ];
      }
      ''
        mkdir -p $out
        tar -xzf "$tarball" -C $out --strip-components=1 --no-same-owner
        cp "$checksumJsonPath" $out/.cargo-checksum.json
      '';

  # Lix does not know `exportIgnore` (and never applied export-ignore).
  isLix = lib.hasInfix "lix" (lib.toLower builtins.nixVersion);

  gitTree =
    parsed:
    let
      hash = gitHashes.${parsed.source} or null;
      submodules = gitSubmodules.${parsed.url} or true;
    in
    builtins.fetchGit (
      {
        url = parsed.url;
        rev = parsed.precise;
        allRefs = true;
        shallow = true;
        inherit submodules;
      }
      # Cargo checks out the tree as is; `git archive` export-ignore rules
      # do not apply (builtins.fetchGit turns them on by default).
      // lib.optionalAttrs (!isLix) { exportIgnore = false; }
      // lib.optionalAttrs (hash != null) { narHash = hash; }
    );

  # Find the directory of package `name`@`version` inside a git tree the way
  # cargo's `PathSource::read_packages` does (cargo src/sources/path.rs):
  # depth-first, entries sorted by name, skipping dot directories below the
  # top and `target` directories next to a manifest, and following `path`
  # dependencies of every package found. The first match wins, as in
  # `first_package`.
  locateInTree =
    tree: name: version:
    let
      isDir = rel: let p = manifest.at tree rel; in pathExists p && readFileType p == "directory";
      hasManifest = rel: pathExists (manifest.at tree (util.joinRel rel "Cargo.toml"));

      # Workspace root for inheritance of `version`, as find_workspace_root.
      findWsRoot =
        rel:
        let
          go =
            r:
            let
              m = if hasManifest r then manifest.readManifest tree r else null;
            in
            if m != null && m ? workspace then
              m
            else if r == "" then
              null
            else
              go (util.normalizeRel "${r}/..");
        in
        go rel;

      pkgAt =
        rel:
        let
          m = manifest.readManifest tree rel;
          p = m.package or m.project or null;
          v = if p == null then null else p.version or "0.0.0";
          version' =
            if isAttrs v && (v.workspace or false) then
              ((findWsRoot rel).workspace.package.version or null)
            else
              v;
        in
        if p == null then null else { inherit rel m; name = p.name; version = version'; };

      matches = info: info != null && info.name == name && info.version == version;

      # readNested: returns { found; visited; }
      readNested =
        st: rel:
        if st.found != null || st.visited ? ${rel} || !(hasManifest rel) then
          st
        else
          let
            info = pkgAt rel;
            st' = st // { visited = st.visited // { ${rel} = true; }; };
          in
          if matches info then
            st' // { found = rel; }
          else if info == null then
            st'
          else
            lib.foldl' (
              s: d: readNested s (util.joinRel rel d)
            ) st' (lib.concatMap (t: lib.concatMap (dep: if isAttrs dep && dep ? path then [ dep.path ] else [ ]) (builtins.attrValues t)) (manifest.dependencyTables info.m));

      walk =
        st: rel: top:
        if st.found != null then
          st
        else
          let
            base = baseNameOf rel;
            parent = util.normalizeRel "${rel}/..";
            skip = (!top && lib.hasPrefix "." base) || (base == "target" && hasManifest parent);
          in
          if skip then
            st
          else
            let
              st' = if hasManifest rel then readNested st rel else st;
              entries = readDir (manifest.at tree rel);
              dirs = lib.sort (a: b: a < b) (filter (n: entries.${n} == "directory") (attrNames entries));
            in
            lib.foldl' (s: d: walk s (util.joinRel rel d) false) st' dirs;

      result = walk { found = null; visited = { }; } "" true;
    in
    if result.found == null then
      throw "breakbulk: could not find package ${name} ${version} in git tree ${toString tree}"
    else
      result.found;

  gitCrate =
    e:
    let
      tree = gitTree e.parsed;
      hint =
        let
          h = gitSubdirs.${e.parsed.source} or gitSubdirs.${e.parsed.url} or { };
        in
        h.${e.name} or null;
      subdir = if hint != null then util.normalizeRel hint else locateInTree tree e.name e.version;
    in
    {
      inherit tree subdir;
      # String with context: the crate directory inside the fetched tree.
      path = if subdir == "" then "${tree}" else "${tree}/${subdir}";
    };
in
rec {
  inherit
    crateUrl
    gitTree
    gitCrate
    locateInTree
    unpackRegistryCrate
    fetchRegistryTarball
    ;

  # The source of one lockfile entry:
  #   registry: { kind = "registry"; path = <unpacked crate drv>; }
  #   git:      { kind = "git"; path = "<tree>/<subdir>"; tree; subdir; }
  crateSource =
    e:
    if e.parsed.kind == "registry" then
      {
        kind = "registry";
        path = unpackRegistryCrate e;
        entry = e;
      }
    else if e.parsed.kind == "git" then
      (gitCrate e) // { kind = "git"; entry = e; }
    else
      throw "breakbulk: ${e.id} is a path package and is not fetched";

  # Sources for a list of entries (or merged attrset), keyed by entry key.
  sourcesFor =
    entries:
    let
      list = if isAttrs entries then builtins.attrValues entries else entries;
    in
    lib.listToAttrs (map (e: lib.nameValuePair e.key (crateSource e)) (lockfile.remoteEntries list));

  # `sources.<crate>` and `sources."<crate>@<version>"` views. A name locked
  # at several versions or from several sources is only reachable by the
  # versioned key (and throws a helpful error by bare name).
  byName =
    srcs:
    let
      list = builtins.attrValues srcs;
      byVersion = lib.groupBy (s: "${s.entry.name}@${s.entry.version}") list;
      byBare = lib.groupBy (s: s.entry.name) list;
      pick =
        k: ss:
        if length ss == 1 then
          (head ss).path
        else
          throw "breakbulk: sources.${k} is ambiguous: ${concatStringsSep ", " (map (s: s.entry.id) ss)}";
    in
    lib.mapAttrs pick byBare // lib.mapAttrs pick byVersion;
}
