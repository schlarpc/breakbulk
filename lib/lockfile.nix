# Reading Cargo.lock at evaluation time.
#
# The lockfile format is documented by Cargo and parsed here with
# builtins.fromTOML. Source strings follow cargo's `SourceId::from_url`
# (cargo src/workspace/source_id.rs, rust-1.99.0): `registry+URL`,
# `sparse+URL`, `git+URL?branch=|tag=|rev=#<locked rev>`. Path packages have
# no `source`.
{ lib, util }:
let
  inherit (builtins)
    attrNames
    elemAt
    filter
    fromTOML
    head
    length
    listToAttrs
    match
    readFile
    ;

  cratesIoIndex = "https://github.com/rust-lang/crates.io-index";
  cratesIoSparse = "sparse+https://index.crates.io/";
in
rec {
  inherit cratesIoIndex;

  # Parse a `source` string from Cargo.lock.
  #
  # For git sources, `id` is the source id without the locked revision; that
  # is what source replacement matches on (cargo compares SourceKind, which
  # includes the GitReference, and the canonical URL, but ignores `precise`:
  # `impl Ord for SourceId` in cargo src/workspace/source_id.rs).
  parseSource =
    source:
    if source == null then
      { kind = "path"; }
    else if lib.hasPrefix "registry+" source then
      let
        url = lib.removePrefix "registry+" source;
      in
      {
        kind = "registry";
        inherit url source;
        id = source;
        isCratesIo = url == cratesIoIndex;
      }
    else if lib.hasPrefix "sparse+" source then
      {
        kind = "registry";
        # Cargo keeps the `sparse+` prefix as part of a sparse registry's URL
        # (`SourceId::from_url`), and source replacement's `registry = ` key
        # expects it too.
        url = source;
        inherit source;
        id = source;
        isCratesIo = source == cratesIoSparse;
      }
    else if lib.hasPrefix "git+" source then
      let
        noPrefix = lib.removePrefix "git+" source;
        hashSplit = util.splitOn "#" noPrefix;
        withQuery = head hashSplit;
        precise = if length hashSplit >= 2 then elemAt hashSplit 1 else null;
        querySplit = util.splitOn "?" withQuery;
        url = head querySplit;
        query = if length querySplit >= 2 then elemAt querySplit 1 else "";
        pairs = map (
          kv:
          let
            m = match "([^=]*)=?(.*)" kv;
          in
          {
            k = util.percentDecode (elemAt m 0);
            v = util.percentDecode (elemAt m 1);
          }
        ) (filter (s: s != "") (util.splitOn "&" query));
        # GitReference::from_query: the last of branch/ref/rev/tag wins;
        # `ref` is the old spelling of `branch`.
        reference = lib.foldl' (
          acc: p:
          if p.k == "branch" || p.k == "ref" then
            { type = "branch"; value = p.v; }
          else if p.k == "tag" then
            { type = "tag"; value = p.v; }
          else if p.k == "rev" then
            { type = "rev"; value = p.v; }
          else
            acc
        ) { type = "default"; value = null; } pairs;
      in
      {
        kind = "git";
        inherit url reference precise source;
        id = withQuery;
      }
    else
      throw "breakbulk: unsupported source in Cargo.lock: ${source}";

  # Read one lockfile. Returns a list of entries:
  #   { name, version, source, checksum, dependencies, parsed, id, key }
  # `id` is Cargo's package id spec (`<source>#<name>@<version>`); `key` is the
  # merge key (source, name, version, checksum).
  read = path: fromLockText (readFile path);

  fromLockText =
    text:
    let
      toml = fromTOML text;
      # Lockfile v1 stored checksums in [metadata] as
      # "checksum <name> <version> (<source>)" = "<sha256>".
      v1Checksums = lib.filterAttrs (k: _: lib.hasPrefix "checksum " k) (toml.metadata or { });
      v1Checksum =
        p: v1Checksums."checksum ${p.name} ${p.version} (${p.source or ""})" or null;
    in
    map (
      p:
      let
        source = p.source or null;
        checksum =
          let
            c = p.checksum or (v1Checksum p);
          in
          if c == "<none>" then null else c;
      in
      mkEntry {
        inherit (p) name version;
        inherit source checksum;
        dependencies = p.dependencies or [ ];
      }
    ) (toml.package or [ ]);

  mkEntry =
    {
      name,
      version,
      source,
      checksum,
      dependencies ? [ ],
    }:
    {
      inherit
        name
        version
        source
        checksum
        dependencies
        ;
      parsed = parseSource source;
      id = if source == null then "path#${name}@${version}" else "${source}#${name}@${version}";
      key = builtins.concatStringsSep "\n" [
        (if source == null then "" else source)
        name
        version
        (if checksum == null then "" else checksum)
      ];
    };

  # Entries that need fetching: registry and git packages.
  remoteEntries = entries: filter (e: e.parsed.kind != "path") entries;

  # Merge entries from several lockfiles, deduplicated by `key`. Returns an
  # attrset keyed by `key`. Entries with the same (source, name, version) but
  # different checksums are kept apart; that is a corrupted or tampered
  # lockfile, and fetching both makes the fixed-output hash fail loudly.
  merge =
    entryLists:
    listToAttrs (map (e: lib.nameValuePair e.key e) (lib.concatLists entryLists));

  # Same, read from paths.
  mergeFiles = paths: merge (map read paths);

  # Index entries by "<name>@<version>" and by "<name>" for `sources.<crate>`
  # lookups. Ambiguous names map to a list.
  byName =
    entries:
    let
      groups = lib.groupBy (e: e.name) entries;
    in
    lib.mapAttrs (_: es: if length es == 1 then head es else es) groups;
}
