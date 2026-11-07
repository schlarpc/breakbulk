# Dynamic-derivation mode (M5) against IFD mode, over the same fixtures.
# Needs Nix 2.36 (master) with `dynamic-derivations` and `ca-derivations`;
# tests/dynamic/run.sh runs it in a private store and compares the modes
# (`nix run .#test-dynamic`). This file only describes what to build.
#
#   mode = "ifd" | "dynamic"
#
# Attributes:
#   repos.<fixture>          the mkRepository results
#   build.<fixture>          a derivation linking every product and test
#                            run of the fixture's default variant (the
#                            products under products/<pkg>, test runs under
#                            runs/<pkg>/<binary>)
#   unitDrvs.<fixture>       (IFD mode) a JSON file: plan kind -> unit id
#                            -> .drv path
#   outer.<fixture>.{build,test}   (dynamic mode) the outer derivations
#   prereqs                  (IFD mode) every fixture's unit inputs, plans,
#                            breakbulk tools and the tools products and
#                            test runs use: what run.sh copies into the
#                            private store so that only breakbulk's own
#                            derivations are built there
{
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
  mode ? "auto",
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs // {
    breakbulk-drv = breakbulk.dynamic.mkBreakbulkDrv pkgs;
  };

  mkRepo =
    fixture: modules:
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/${fixture}";
      modules = [
        {
          inherit mode;
          workspaces.main = {
            path = ".";
            variants.default.profile = "dev";
          };
        }
      ]
      ++ modules;
    };

  directivesPackages = [
    "a-sys"
    "b-sys"
    "c"
    "pm"
    "hostdep"
    "app"
    "oldsyn"
  ];

  repos = {
    walking-skeleton = mkRepo "walking-skeleton" [ ];
    # Every build script includes ../common/build_common.rs.
    directives = mkRepo "directives" [
      { packages = lib.genAttrs directivesPackages (_: { extraSources = [ "common" ]; }); }
    ];
  };

  inst = repo: repo.workspaces.main.instances.${native}.default;

  build =
    name: repo:
    let
      i = inst repo;
      products = repo.workspaces.main.packages;
    in
    pkgs.runCommand "${name}-${mode}" { } (
      ''
        mkdir -p $out/products $out/runs
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (p: d: ''
          ln -s ${d} $out/products/${p}
        '') products
      )
      + lib.concatStrings (
        lib.concatLists (
          lib.mapAttrsToList (
            p: bs:
            lib.mapAttrsToList (b: d: ''
              mkdir -p "$(dirname "$out/runs/${p}/${b}")"
              ln -s ${d} "$out/runs/${p}/${b}"
            '') bs
          ) i.testRuns
        )
      )
    );

  discard = builtins.unsafeDiscardStringContext;

  unitDrvs =
    repo:
    let
      i = inst repo;
    in
    pkgs.writeText "unit-drvs.json" (
      builtins.toJSON (
        lib.mapAttrs (_: us: lib.mapAttrs (_: u: discard u.drvPath) us) {
          inherit (i.units) build test;
        }
      )
    );

  # What instantiation needs that no unit or product depends on: the
  # plans (read at evaluation time in IFD mode, an input of the outer
  # derivation in dynamic mode) and breakbulk's tools. run.sh copies these
  # and every output upstream of the units into the private store.
  prereqs = pkgs.writeText "dynamic-prereqs" (
    lib.concatStringsSep "\n" (
      lib.concatMap (
        repo:
        map toString (
          lib.attrValues (inst repo).plans
        )
      ) (lib.attrValues repos)
      ++ map toString (
        lib.attrValues tools
        ++ [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ]
      )
    )
  );
in
{
  inherit repos prereqs;
  build = lib.mapAttrs build repos;
  unitDrvs = lib.mapAttrs (_: unitDrvs) repos;
  outer = lib.mapAttrs (_: repo: (inst repo).outer) repos;
}
