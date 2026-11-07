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
#                            run of the fixture's default variants
#                            (products/<ws>/<pkg>, runs/<ws>/<pkg>/<binary>;
#                            in dynamic mode also units-<ws>-<kind>, every
#                            unit of each plan)
#   unitDrvs.<fixture>       a JSON file: "<ws>/<kind>" -> unit id -> .drv
#                            path (IFD mode)
#   outer.<fixture>."<ws>/<kind>"   the outer derivations (dynamic mode)
#   mayDiffer.<fixture>      a regex of unit derivation names that may
#                            differ between the modes (embedding chains)
#   checkVariant             (dynamic mode) a check variant's check of the
#                            walking skeleton: every unit of both plans,
#                            through the outer derivations' `units.drv`
#   prereqs                  the plans and breakbulk's tools: with the
#                            outputs upstream of the units, what run.sh
#                            copies into the private store, so that only
#                            breakbulk's own derivations are built there
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
      modules = [ { inherit mode; } ] ++ modules;
    };
  oneWs = {
    workspaces.main = {
      path = ".";
      variants.default.profile = "dev";
    };
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
    walking-skeleton = mkRepo "walking-skeleton" [ oneWs ];
    # Every build script includes ../common/build_common.rs.
    directives = mkRepo "directives" [
      oneWs
      {
        packages = lib.genAttrs directivesPackages (_: {
          extraSources = [ "common" ];
        });
      }
    ];
    # The `host` workspace embeds the `payload` workspace's product, as in
    # tests/products (embed).
    embed =
      let
        repo = mkRepo "embed" [
          {
            workspaces = {
              payload = {
                path = "payload";
                variants.default.profile = "dev";
              };
              host = {
                path = "host";
                variants.default.profile = "dev";
              };
            };
            packages.embedder.env.PAYLOAD_BIN = "${repo.workspaces.payload.packages.payload}/bin/payload";
          }
        ];
      in
      repo;
    # The project's `[env]` (tests/loose-ends, config-env): the fixture's
    # tests assert the values, so its test runs check them in both modes.
    config-env = breakbulk.mkRepository {
      inherit pkgs tools;
      root = ../loose-ends/fixtures/config-env;
      modules = [
        { inherit mode; }
        oneWs
      ];
    };
  };

  # Products differ between the modes (resolved at build time in dynamic
  # mode), so the units downstream of an embedded product do too: the
  # embedder and, through it, the host. Every other unit is identical.
  mayDiffer = {
    embed = "^(embedder|host)-";
  };

  inst = repo: wsName: repo.workspaces.${wsName}.instances.${native}.default;

  build =
    name: repo:
    pkgs.runCommand "${name}-${mode}" { } (
      lib.concatStrings (
        lib.mapAttrsToList (
          wsName: w:
          ''
            mkdir -p $out/products/${wsName} $out/runs/${wsName}
          ''
          # Dynamic mode: every outer derivation runs (run.sh reads their
          # logs), also for a plan no product or test run needs.
          + lib.concatStrings (
            lib.mapAttrsToList (kind: d: ''
              ln -s ${d} $out/units-${wsName}-${kind}
            '') ((inst repo wsName).allUnits or { })
          )
          + lib.concatStrings (
            lib.mapAttrsToList (p: d: ''
              ln -s ${d} $out/products/${wsName}/${p}
            '') w.packages
          )
          + lib.concatStrings (
            lib.concatLists (
              lib.mapAttrsToList (
                p: bs:
                lib.mapAttrsToList (b: d: ''
                  mkdir -p "$(dirname "$out/runs/${wsName}/${p}/${b}")"
                  ln -s ${d} "$out/runs/${wsName}/${p}/${b}"
                '') bs
              ) (inst repo wsName).testRuns
            )
          )
        ) repo.workspaces
      )
    );

  discard = builtins.unsafeDiscardStringContext;

  unitDrvs =
    repo:
    pkgs.writeText "unit-drvs.json" (
      builtins.toJSON (
        lib.concatMapAttrs (
          wsName: _:
          lib.mapAttrs'
            (kind: us: lib.nameValuePair "${wsName}/${kind}" (lib.mapAttrs (_: u: discard u.drvPath) us))
            {
              inherit ((inst repo wsName).units) build test;
            }
        ) repo.workspaces
      )
    );

  # A check variant next to the default one: `variants.lint.check` builds
  # every unit of both plans; in dynamic mode through `units.drv`.
  lintRepo = mkRepo "walking-skeleton" [
    oneWs
    {
      workspaces.main.variants.lint = {
        profile = "dev";
        mode = "check";
      };
    }
  ];

  # What instantiation needs that no unit or product depends on: the
  # plans (read at evaluation time in IFD mode, an input of the outer
  # derivation in dynamic mode) and breakbulk's tools. run.sh copies these
  # and every output upstream of the units into the private store.
  prereqs = pkgs.writeText "dynamic-prereqs" (
    lib.concatStringsSep "\n" (
      lib.concatMap (
        repo:
        lib.concatLists (
          lib.mapAttrsToList (
            wsName: _: map toString (lib.attrValues (inst repo wsName).plans)
          ) repo.workspaces
        )
      ) (lib.attrValues repos)
      ++ map toString (lib.attrValues (inst lintRepo "main").plans)
      ++ map toString (lib.attrValues lintRepo.workspaces.main.instances.${native}.lint.plans)
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
  inherit repos prereqs mayDiffer;
  build = lib.mapAttrs build repos;
  unitDrvs = lib.mapAttrs (_: unitDrvs) repos;
  outer = lib.mapAttrs (
    _: repo:
    lib.concatMapAttrs (
      wsName: _: lib.mapAttrs' (kind: o: lib.nameValuePair "${wsName}/${kind}" o) (inst repo wsName).outer
    ) repo.workspaces
  ) repos;
  checkVariant = lintRepo.workspaces.main.target.${native}.variants.lint.check;
}
