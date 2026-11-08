# breakbulk builds itself (M2 exit: "the tool builds itself").
#
# `repo` is mkRepository over this repository's own workspace; its
# products are breakbulk's four programs, built crate by crate through
# breakbulk. lib/tools.nix (nixpkgs' buildRustPackage) still builds the
# binaries every plan and unit uses: that is the bootstrap, and switching
# it would make every unit depend on a breakbulk build of breakbulk.
#
# The `self-host` check shows the two builds behave the same: with the
# self-built breakbulk-plan, breakbulk-shim, breakbulk-instantiate and
# breakbulk-unit, the walking-skeleton and directives fixtures give
# byte-identical plan.json and units.json (build and test plans) and
# byte-identical products.
#
#   nix build -f tests/self-host self-host
#   nix build -f tests/self-host packages.breakbulk-unit
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
  root ? ../..,
  # Extra modules, e.g. for timing a cold build with a salted toolchain.
  modules ? [ ],
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;

  repo = breakbulk.mkRepository {
    inherit pkgs root;
    modules = [
      {
        workspaces.breakbulk = {
          path = ".";
          # The profile lib/tools.nix's buildRustPackage builds with.
          variants.default.profile = "release";
        };
      }
    ]
    ++ modules;
  };
  packages = repo.workspaces.breakbulk.packages;

  bootstrap = breakbulk.mkTools pkgs;
  # mkTools' shape: tools.<program> with bin/<program>.
  selfBuilt = lib.genAttrs [
    "breakbulk-shim"
    "breakbulk-plan"
    "breakbulk-unit"
    "breakbulk-instantiate"
  ] (p: packages.${p});

  mk =
    tools: fixture: args:
    breakbulk.mkWorkspace pkgs (
      {
        root = fixtures + "/${fixture}";
        inherit tools;
        name = fixture;
      }
      // args
    );

  fixtureArgs = {
    walking-skeleton = {
      bins = [ "walking-skeleton" ];
      args = { };
    };
    directives = {
      bins = [
        "app"
        "app-tool"
      ];
      # Every build script includes ../common/build_common.rs.
      args.extraSources = lib.genAttrs [ "a-sys" "b-sys" "c" "pm" "hostdep" "app" "oldsyn" ] (_: [
        "common"
      ]);
    };
  };

  # `cmp` lines for one fixture: plans, units.json and products of the
  # bootstrap tools against the self-built ones.
  compareFixture =
    fixture:
    let
      f = fixtureArgs.${fixture};
      a = mk bootstrap fixture f.args;
      b = mk selfBuilt fixture f.args;
      kinds = [
        "build"
        "test"
      ];
    in
    lib.concatMapStrings (k: ''
      same ${a.plans.${k}}/plan.json ${b.plans.${k}}/plan.json
      same ${a.unitsJson.${k}} ${b.unitsJson.${k}}
    '') kinds
    + lib.concatMapStrings (bin: ''
      same ${a.packages.${bin}}/bin/${bin} ${b.packages.${bin}}/bin/${bin}
      [ ${a.packages.${bin}} != ${b.packages.${bin}} ]
    '') f.bins;
in
{
  inherit repo packages selfBuilt;

  self-host =
    pkgs.runCommand "self-host-check"
      {
        # The self-built programs are really breakbulk's builds.
        units = lib.concatStringsSep " " (
          lib.attrNames repo.workspaces.breakbulk.instances.${pkgs.stdenv.hostPlatform.rust.rustcTarget}.default.units.build
        );
      }
      ''
        same() {
          echo "comparing $1 with $2"
          cmp "$1" "$2"
        }
        # The products' unit derivations differ (other builders), so the
        # comparison is not vacuous.
        ${compareFixture "walking-skeleton"}
        ${compareFixture "directives"}
        for p in ${lib.concatStringsSep " " (lib.attrValues (lib.mapAttrs (n: d: "${d}/bin/${n}") selfBuilt))}; do
          [ -x "$p" ]
        done
        mkdir -p $out
        echo "$units" | tr ' ' '\n' > $out/units
      '';
}
