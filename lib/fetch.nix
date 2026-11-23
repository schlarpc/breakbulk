# Fetch derivations for every remote package in one or more lockfiles.
#
# Each entry's source comes from the first of `crateSources` that returns
# one, else from the built-in fetchers:
#
# Registry crates: a fixed-output fetch (`registries.<name>.fetch`, by
# default `fetchurl`) keyed by the lockfile's SHA-256, plus a small unpack
# derivation that adds the `.cargo-checksum.json` Cargo's directory sources
# require. Both download and unpack at build time.
#
# Git sources: `builtins.fetchGit` during evaluation, because finding a crate
# inside the repository needs its tree. Keyed by URL and locked revision.
{
  lib,
  pkgs,
  util,
  featureGates,
  lockfile,
  manifest,
}:
{
  # registries.<name> = { index = "<index URL as in Cargo.lock>"; dl = "<template>"; fetch = pkgs: pkgs.fetchurl; }
  # `index` may be given with or without the `registry+` prefix; sparse
  # registries keep their `sparse+` prefix. Merged field by field over
  # lib/registries.nix.
  registries ? { },
  # git."<Cargo.lock source string or URL>" = { hash; tree; subdirs; submodules; }:
  # the entry under the source string, else the one under the URL.
  #   hash        the NAR hash of the fetched tree, passed to builtins.fetchGit
  #               as `narHash`, which lets Nix substitute the tree from a
  #               binary cache instead of cloning
  #   tree        a tree to use instead of fetching (a local checkout, a test
  #               fixture, or a fetched tree such as a flake input)
  #   subdirs.<crate> = "path/in/repo": skips the walk that locates a crate
  #   submodules  Cargo checks out submodules of git dependencies (cargo
  #               src/sources/git/utils.rs, `GitCheckout::reset` calls
  #               `update_submodules`), so this defaults to true
  git ? { },
  # crateSources = [ (entry: null | { path; subdir ? ""; }) ]: consulted in
  # order before the built-in fetchers; the first non-null result is the
  # entry's source, the crate at `subdir` inside the tree `path`. `entry`
  # is the lockfile entry plus `defaultSource`, what the built-in fetchers
  # give in the same shape.
  crateSources ? [ ],
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    head
    isAttrs
    isString
    length
    pathExists
    readDir
    readFileType
    replaceStrings
    stringLength
    substring
    toJSON
    ;

  defaultRegistries = import ./registries.nix;
  allRegistries = lib.mapAttrs (n: r: (defaultRegistries.${n} or { }) // r) (
    defaultRegistries // registries
  );

  # An index URL as Cargo.lock spells it, with crates.io's sparse index
  # folded into its git one: both are crates.io (`SourceId::is_crates_io`),
  # and one `registries.crates-io` entry serves both.
  canonicalIndex =
    i:
    let
      n = if lib.hasPrefix "sparse+" i then i else lib.removePrefix "registry+" i;
    in
    if n == lockfile.cratesIoSparse then lockfile.cratesIoIndex else n;

  byIndex = lib.listToAttrs (
    lib.mapAttrsToList (name: r: lib.nameValuePair (canonicalIndex r.index) (r // { inherit name; })) (
      lib.filterAttrs (_: r: r ? index) allRegistries
    )
  );

  # The `registries` entry (with its `name`) that serves a registry
  # entry's index, or null.
  registryOf = e: byIndex.${canonicalIndex e.parsed.url} or null;

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
      markers = [
        "{crate}"
        "{version}"
        "{prefix}"
        "{lowerprefix}"
        "{sha256-checksum}"
      ];
      hasMarker = lib.any (m: lib.hasInfix m dl) markers;
      prefix = prefixOf e.name;
    in
    if !hasMarker then
      "${dl}/${e.name}/${e.version}/download"
    else
      replaceStrings markers [ e.name e.version prefix (lib.toLower prefix) e.checksum ] dl;

  registryFor =
    e:
    let
      r = registryOf e;
    in
    if r == null || !(r ? dl) then
      throw ''
        breakbulk: no download URL for registry ${e.parsed.url} (needed by ${e.name} ${e.version}).
        Set registries.<name> = { index = "${e.parsed.url}"; dl = "<dl template from the registry's config.json>"; };
      ''
    else
      r;

  # Store-path-safe name fragment.
  safeName = s: replaceStrings [ "+" ] [ "_" ] s;

  fetchRegistryTarball =
    e:
    let
      r = registryFor e;
      fetch = r.fetch or (p: p.fetchurl);
    in
    if e.checksum == null then
      throw "breakbulk: ${e.id} has no checksum in Cargo.lock"
    else
      fetch pkgs {
        name = "${safeName e.name}-${e.version}.tar.gz";
        url = crateUrl r.dl e;
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

  # The `git` entry of a git source: by source string, else by URL.
  gitSettings =
    parsed:
    let
      s = git.${parsed.source} or git.${parsed.url} or { };
    in
    {
      hash = s.hash or null;
      tree = s.tree or null;
      subdirs = s.subdirs or { };
      submodules = s.submodules or true;
    };

  gitTree =
    parsed:
    let
      s = gitSettings parsed;
    in
    builtins.fetchGit (
      {
        url = parsed.url;
        rev = parsed.precise;
        allRefs = true;
        shallow = true;
        inherit (s) submodules;
      }
      # Cargo checks out the tree as is; `git archive` export-ignore rules
      # do not apply (builtins.fetchGit turns them on by default).
      // lib.optionalAttrs featureGates.fetchGitExportIgnore { exportIgnore = false; }
      // lib.optionalAttrs (s.hash != null) { narHash = s.hash; }
    );

  # A fetched tree (a `fetchGit` or `fetchTree` result, or a flake input)
  # as a real store path. Not its `outPath`: under lazy trees that is a
  # virtual path, real only where string context carries it into a
  # derivation, so the string without context names nothing and changes
  # with every evaluation. The NAR hash lets Nix skip the copy when the
  # path is in the store. A string naming such a tree (`"${inputs.foo}"`)
  # has no NAR hash; `util.devirtualize` makes it real. Not for reading the
  # tree: read-only evaluation only computes this path.
  realTree =
    t:
    if isAttrs t && t ? narHash && t ? outPath && !(t ? drvPath) then
      builtins.path {
        path = t.outPath;
        name = substring 33 (-1) (baseNameOf (builtins.unsafeDiscardStringContext t.outPath));
        sha256 = t.narHash;
      }
    else if isString t then
      util.devirtualize t
    else
      t;

  # Find the directory of package `name`@`version` inside a git tree the way
  # cargo's `PathSource::read_packages` does (cargo src/sources/path.rs):
  # depth-first, entries sorted by name, skipping dot directories below the
  # top and `target` directories next to a manifest, and following `path`
  # dependencies of every package found. The first match wins, as in
  # `first_package`.
  locateInTree =
    tree: name: version:
    let
      isDir =
        rel:
        let
          p = manifest.at tree rel;
        in
        pathExists p && readFileType p == "directory";
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
        if p == null then
          null
        else
          {
            inherit rel m;
            name = p.name;
            version = version';
          };

      matches = info: info != null && info.name == name && info.version == version;

      # readNested: returns { found; visited; }
      readNested =
        st: rel:
        if st.found != null || st.visited ? ${rel} || !(hasManifest rel) then
          st
        else
          let
            info = pkgAt rel;
            st' = st // {
              visited = st.visited // {
                ${rel} = true;
              };
            };
          in
          if matches info then
            st' // { found = rel; }
          else if info == null then
            st'
          else
            lib.foldl' (s: d: readNested s (util.joinRel rel d)) st' (
              lib.concatMap (
                t:
                lib.concatMap (dep: if isAttrs dep && dep ? path then [ dep.path ] else [ ]) (builtins.attrValues t)
              ) (manifest.dependencyTables info.m)
            );

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

      result = walk {
        found = null;
        visited = { };
      } "" true;
    in
    if result.found == null then
      throw "breakbulk: could not find package ${name} ${version} in git tree ${toString tree}"
    else
      result.found;

  # A crate inside a tree, as crateSource returns it. `path` is a string
  # with context: the crate directory inside the tree.
  inTree = tree: subdir: {
    inherit tree subdir;
    path = if subdir == "" then "${realTree tree}" else "${realTree tree}/${subdir}";
  };

  gitCrate =
    e:
    let
      s = gitSettings e.parsed;
      tree = if s.tree != null then s.tree else gitTree e.parsed;
      hint = s.subdirs.${e.name} or null;
    in
    inTree tree (if hint != null then util.normalizeRel hint else locateInTree tree e.name e.version);

  # What the built-in fetchers give. `checksummed`: `path` is a Cargo
  # directory-source entry as is, `.cargo-checksum.json` included.
  builtinSource =
    e:
    if e.parsed.kind == "registry" then
      let
        path = unpackRegistryCrate e;
      in
      {
        tree = path;
        subdir = "";
        inherit path;
        checksummed = true;
      }
    else if e.parsed.kind == "git" then
      gitCrate e // { checksummed = false; }
    else
      throw "breakbulk: ${e.id} is a path package and is not fetched";

  # The first of `crateSources` that returns a source for `e`, or null.
  # Later functions are not called (`lib.findFirst` stops at the first
  # match, and `map` is lazy).
  suppliedSource =
    e:
    let
      builtin = builtinSource e;
      e' = e // {
        defaultSource = {
          inherit (builtin) subdir;
          path = builtin.tree;
        };
      };
      check =
        r:
        if
          r == null || (isAttrs r && r ? path && lib.all (k: k == "path" || k == "subdir") (attrNames r))
        then
          r
        else
          throw "breakbulk: a `crateSources` function returned something other than null or { path; subdir ? \"\"; } for ${e.id}";
    in
    lib.findFirst (r: r != null) null (map (f: check (f e')) crateSources);
in
rec {
  inherit
    crateUrl
    gitTree
    realTree
    gitCrate
    locateInTree
    registryOf
    unpackRegistryCrate
    fetchRegistryTarball
    ;

  # The source of one lockfile entry:
  #   { kind = "registry" | "git"; entry; tree; subdir; path; checksummed; }
  # `path` is the crate directory, `subdir` its place in `tree`.
  crateSource =
    e:
    let
      r = suppliedSource e;
    in
    (
      if r == null then
        builtinSource e
      else
        inTree r.path (util.normalizeRel (r.subdir or "")) // { checksummed = false; }
    )
    // {
      kind = e.parsed.kind;
      entry = e;
    };

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
