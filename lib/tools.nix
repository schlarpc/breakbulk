# breakbulk's own binaries, built from this repository with nixpkgs'
# rustPlatform. One derivation per binary, each built from a narrow source:
# the workspace Cargo.toml and Cargo.lock, every member's Cargo.toml, and
# the full directories of only the crates the binary depends on (normal and
# build dependencies, transitively). Other members get empty stand-ins for
# their auto-discovered target files, so Cargo still loads the whole
# workspace and the lockfile stays as it is.
#
# So an edit to the planner, the instantiator or breakbulk-format never
# changes breakbulk-unit's store path, which every unit depends on (decision
# 50), and neither does an edit to a member's integration tests (`tests/`),
# which are left out. Edits to any member's Cargo.toml, or to Cargo.lock,
# still do.
#
#   tools = breakbulk.mkTools pkgs;
#   tools.breakbulk-plan  tools.breakbulk-shim  tools.breakbulk-unit
#   tools.breakbulk-instantiate
#   tools.<name>.passthru.crates     the member crates in its source
#
# `root` is overridable for tests (tests/plan's tools-narrow check builds
# from a modified copy of the repository).
{
  lib,
  root ? ../.,
}:
pkgs:
let
  members = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir (root + "/crates")));
  manifestOf = c: builtins.fromTOML (builtins.readFile (root + "/crates/${c}/Cargo.toml"));

  # Path dependencies of a member: [dependencies] and [build-dependencies],
  # also under target.<cfg>. Dev-dependencies are not built for a binary.
  pathDeps =
    c:
    let
      m = manifestOf c;
      tables = [
        (m.dependencies or { })
        (m.build-dependencies or { })
      ]
      ++ lib.concatMap (t: [
        (t.dependencies or { })
        (t.build-dependencies or { })
      ]) (lib.attrValues (m.target or { }));
      paths = lib.concatMap (
        t: lib.concatMap (d: lib.optional (builtins.isAttrs d && d ? path) d.path) (lib.attrValues t)
      ) tables;
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

  closure =
    c:
    lib.unique (
      builtins.genericClosure {
        startSet = [ { key = c; } ];
        operator = x: map (k: { key = k; }) (pathDeps x.key);
      }
    );
  cratesOf = c: lib.sort lib.lessThan (map (x: x.key) (closure c));

  # Target files Cargo discovers by itself; a member outside the closure
  # gets an empty one wherever the real one exists. Explicit `path =`
  # targets need no file until they are compiled.
  autoTargets = [
    "src/lib.rs"
    "src/main.rs"
  ];

  # A member's directory without its integration tests (`tests/`), which a
  # binary's build never compiles (`cargo build -p`, no check phase): a
  # test edit then changes no tool's store path, so breakbulk-unit (an
  # input of every unit) stays the same when only its tests change.
  crateFiles =
    c:
    let
      dir = root + "/crates/${c}";
    in
    if builtins.pathExists (dir + "/tests") then lib.fileset.difference dir (dir + "/tests") else dir;

  srcFor =
    name:
    let
      inside = cratesOf name;
      outside = lib.subtractLists inside members;
    in
    {
      src = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions (
          [
            (root + "/Cargo.toml")
            (root + "/Cargo.lock")
          ]
          ++ map (c: root + "/crates/${c}/Cargo.toml") outside
          ++ map crateFiles inside
        );
      };
      stubs = lib.concatMap (
        c: map (f: "crates/${c}/${f}") (lib.filter (f: builtins.pathExists (root + "/crates/${c}/${f}")) autoTargets)
      ) outside;
      crates = inside;
    };

  build =
    pname:
    let
      s = srcFor pname;
    in
    pkgs.rustPlatform.buildRustPackage {
      inherit pname;
      inherit (s) src;
      version = "0.1.0";
      cargoLock.lockFile = root + "/Cargo.lock";
      postPatch = lib.concatMapStrings (f: ''
        mkdir -p "$(dirname ${f})"
        touch ${f}
      '') s.stubs;
      cargoBuildFlags = [
        "-p"
        pname
      ];
      doCheck = false;
      passthru.crates = s.crates;
    };
in
lib.genAttrs [
  "breakbulk-shim"
  "breakbulk-plan"
  "breakbulk-unit"
  "breakbulk-instantiate"
] build
