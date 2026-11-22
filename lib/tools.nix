# breakbulk's own binaries, built from this repository with nixpkgs'
# rustPlatform. One derivation per binary, each built from a narrow source:
# the workspace Cargo.toml, the full directories of only the crates the
# binary depends on (normal and build dependencies, transitively) with their
# dev-dependencies removed, and a Cargo.lock trimmed to what those crates
# reach. The other members are left out, and the workspace's `crates/*`
# glob finds only the ones that are there.
#
# So an edit to the planner, the instantiator or breakbulk-format never
# changes breakbulk-unit's store path, which every unit depends on (decision
# 50), and neither does an edit to a member's integration tests (`tests/`),
# its dev-dependencies, or a Cargo.lock entry outside its closure. Edits to
# the workspace Cargo.toml still do.
#
#   tools = breakbulk.mkTools pkgs;
#   tools.breakbulk-plan  tools.breakbulk-shim  tools.breakbulk-unit
#   tools.breakbulk-hints  tools.breakbulk-instantiate  tools.breakbulk-predict
#   tools.<name>.passthru.crates     the member crates in its source
#   tools.<name>.passthru.lockFile   its trimmed Cargo.lock
#
# `root` is overridable for tests (tests/plan's tools-narrow check builds
# from a modified copy of the repository).
{
  lib,
  root ? ../.,
}:
pkgs:
let
  # The directories under crates/ that the workspace does not exclude
  # (crates/breakbulk-drv is a workspace of its own).
  excluded = (builtins.fromTOML (builtins.readFile (root + "/Cargo.toml"))).workspace.exclude or [ ];
  members = lib.filter (c: !lib.elem "crates/${c}" excluded) (
    lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir (root + "/crates")))
  );
  manifestText = c: builtins.readFile (root + "/crates/${c}/Cargo.toml");
  manifestOf = c: builtins.fromTOML (manifestText c);

  # A member's [dependencies] and [build-dependencies] tables, also under
  # target.<cfg>. Dev-dependencies are not built for a binary.
  depTables =
    c:
    let
      m = manifestOf c;
    in
    [
      (m.dependencies or { })
      (m.build-dependencies or { })
    ]
    ++ lib.concatMap (t: [
      (t.dependencies or { })
      (t.build-dependencies or { })
    ]) (lib.attrValues (m.target or { }));

  pathDeps =
    c:
    let
      paths = lib.concatMap (
        t: lib.concatMap (d: lib.optional (builtins.isAttrs d && d ? path) d.path) (lib.attrValues t)
      ) (depTables c);
      dirOf =
        p:
        let
          m' = builtins.match "\\.\\./([^/]+)/?" p;
        in
        if m' != null && lib.elem (lib.head m') members then
          lib.head m'
        else
          throw "lib/tools.nix: crates/${c} has a path dependency `${p}` outside crates/<member>";
    in
    map dirOf paths;

  # The package names a member depends on (a `package = ` key renames).
  depNames =
    c:
    lib.unique (
      lib.concatMap (lib.mapAttrsToList (
        k: d: if builtins.isAttrs d && d ? package then d.package else k
      )) (depTables c)
    );

  closure =
    c:
    lib.unique (
      builtins.genericClosure {
        startSet = [ { key = c; } ];
        operator = x: map (k: { key = k; }) (pathDeps x.key);
      }
    );
  cratesOf = c: lib.sort lib.lessThan (map (x: x.key) (closure c));

  # The manifest without its dev-dependencies (top-level and per target):
  # Cargo resolves a workspace member's dev-dependencies even for
  # `cargo build`, so they would have to be in the trimmed lockfile, and
  # breakbulk-unit's would pull breakbulk-format into its source.
  devHeader = "[[:space:]]*[[](target[.].*[.])?dev[-_]dependencies([.].*)?[]][[:space:]]*(#.*)?";
  anyHeader = "[[:space:]]*[[].*";
  strippedManifest =
    c:
    let
      kept =
        (lib.foldl'
          (
            acc: line:
            let
              skip =
                if builtins.match anyHeader line != null then builtins.match devHeader line != null else acc.skip;
            in
            {
              inherit skip;
              lines = acc.lines ++ lib.optional (!skip) line;
            }
          )
          {
            skip = false;
            lines = [ ];
          }
          (lib.splitString "\n" (manifestText c))
        ).lines;
      text = lib.concatStringsSep "\n" kept;
      noDev =
        m:
        removeAttrs m [
          "dev-dependencies"
          "dev_dependencies"
        ]
        // lib.optionalAttrs (m ? target) { target = lib.mapAttrs (_: noDev) m.target; };
    in
    # Dev-dependencies written another way (dotted keys, inline tables) are
    # not removed by the line filter; fail rather than build with them.
    assert lib.assertMsg (builtins.fromTOML text == noDev (manifestOf c))
      "lib/tools.nix: cannot remove the dev-dependencies of crates/${c}/Cargo.toml; write them as [dev-dependencies] tables";
    builtins.toFile "Cargo.toml" text;

  # Cargo.lock trimmed to a binary's closure: its members' entries and every
  # registry or git package reachable from them, in the lockfile's order.
  # Without trimming, every lockfile change would change breakbulk-unit,
  # and so every unit.
  #
  # The trimmed lockfile can have more than the resolve: an optional
  # dependency of a kept package (an edge, or an entry) that only a
  # left-out member's features turn on. serde_core's edge to serde_derive
  # is one, for breakbulk-shim. So the build does not pass `--locked`, which
  # would fail on those, and Cargo drops them from its copy. It still
  # cannot change a version or add a package: it keeps every locked version
  # and builds offline from a vendor directory made from this lockfile, so
  # a package missing from the trim fails the build.
  lock = builtins.fromTOML (builtins.readFile (root + "/Cargo.lock"));
  packages =
    assert lib.assertMsg (
      lib.attrNames lock == [
        "package"
        "version"
      ]
    ) "lib/tools.nix: Cargo.lock has sections other than `version` and `package`";
    lock.package;
  byName = lib.groupBy (p: p.name) packages;
  idOf = p: "${p.name} ${p.version} ${p.source or ""}";
  # A `dependencies` entry: `name`, `name version` or `name version (source)`.
  resolveDep =
    from: dep:
    let
      m = builtins.match "([^ ]+)( ([^ ]+))?( \\((.*)\\))?" dep;
      name = lib.elemAt m 0;
      version = lib.elemAt m 2;
      source = lib.elemAt m 4;
      found = lib.filter (
        p: (version == null || p.version == version) && (source == null || p.source or null == source)
      ) (byName.${name} or [ ]);
    in
    if lib.length found == 1 then
      lib.head found
    else
      throw "lib/tools.nix: Cargo.lock: ${from.name}'s dependency `${dep}` matches ${toString (lib.length found)} packages";
  # A package's edges; a member's without those of its dev-dependencies,
  # which its stripped manifest no longer has.
  edgesOf =
    p:
    if p ? source then
      p.dependencies or [ ]
    else
      lib.filter (d: lib.elem (lib.head (lib.splitString " " d)) (depNames p.name)) (
        p.dependencies or [ ]
      );
  trimmedLock =
    crates:
    let
      node = p: {
        key = idOf p;
        inherit p;
      };
      reached = builtins.genericClosure {
        startSet = map node (lib.filter (p: !(p ? source) && lib.elem p.name crates) packages);
        operator = x: map (d: node (resolveDep x.p d)) (edgesOf x.p);
      };
      keys = map (x: x.key) reached;
      kept = lib.filter (p: lib.elem (idOf p) keys) packages;
      str = builtins.toJSON;
      entry =
        p:
        assert lib.assertMsg (
          lib.subtractLists [
            "name"
            "version"
            "source"
            "checksum"
            "dependencies"
          ] (lib.attrNames p) == [ ]
        ) "lib/tools.nix: Cargo.lock: unexpected keys in ${p.name}'s entry";
        let
          deps = edgesOf p;
        in
        ''
          [[package]]
          name = ${str p.name}
          version = ${str p.version}
        ''
        + lib.optionalString (p ? source) "source = ${str p.source}\n"
        + lib.optionalString (p ? checksum) "checksum = ${str p.checksum}\n"
        + lib.optionalString (deps != [ ]) (
          "dependencies = [\n" + lib.concatMapStrings (d: " ${str d},\n") deps + "]\n"
        );
    in
    builtins.toFile "Cargo.lock" (
      ''
        # This file is automatically @generated by Cargo.
        # It is not intended for manual editing.
        version = ${toString lock.version}

      ''
      + lib.concatMapStringsSep "\n" entry kept
    );

  # A member's directory without its integration tests (`tests/`), which a
  # binary's build never compiles (`cargo build -p`, no check phase), and
  # without its Cargo.toml (strippedManifest replaces it).
  crateFiles =
    c:
    let
      dir = root + "/crates/${c}";
    in
    lib.fileset.difference dir (
      lib.fileset.unions (
        [ (dir + "/Cargo.toml") ] ++ lib.optional (builtins.pathExists (dir + "/tests")) (dir + "/tests")
      )
    );

  build =
    pname:
    let
      crates = cratesOf pname;
      lockFile = trimmedLock crates;
    in
    pkgs.rustPlatform.buildRustPackage {
      inherit pname;
      version = "0.1.0";
      src = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions ([ (root + "/Cargo.toml") ] ++ map crateFiles crates);
      };
      cargoLock = { inherit lockFile; };
      prePatch = ''
        install -m644 ${lockFile} Cargo.lock
      ''
      + lib.concatMapStrings (c: ''
        install -m644 ${strippedManifest c} crates/${c}/Cargo.toml
      '') crates;
      cargoBuildFlags = [
        "-p"
        pname
      ];
      doCheck = false;
      passthru = { inherit crates lockFile; };
    };
in
lib.genAttrs [
  "breakbulk-shim"
  "breakbulk-plan"
  "breakbulk-unit"
  "breakbulk-hints"
  "breakbulk-instantiate"
  "breakbulk-predict"
] build
