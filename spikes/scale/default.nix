# Scale spike: a generated plan (spikes/scale/gen.py) through IFD-mode
# instantiation, as in tests/instantiate.
#
#   nix eval -f spikes/scale --argstr dir /path/to/generated drvPaths --json
#   nix build -f spikes/scale --argstr dir /path/to/generated root
#
# `dir` is a string, so the generated tree can live outside the repository.
# Each library crate's source is its own store path (`builtins.path` of
# crates/<name>), standing in for a fetched registry crate; `app`'s source
# view is the generated root filtered to app/.
#
# Attributes:
#   inst        breakbulk.instantiate's result
#   drvPaths    unit id -> .drv path (forces every unit derivation)
#   root        the bin root
#   check       runs the bin
#   sources     the source map alone (to time its evaluation separately)
#   instantiateBin  the breakbulk-instantiate package
#   unitsJson   the instantiate derivation
#   trivial     trivialCount bare derivations (per-derivation cost baseline)
#   wide.all    wideCount bare derivations with wideInputs inputs each
{
  dir,
  # A value placed in every unit's env (BB_SALT), to get fresh unit .drv
  # files without rerunning instantiation (only the key reaches it).
  salt ? "0",
  # How many independent trivial derivations `trivial` has.
  trivialCount ? "100",
  # `wide`: how many derivations, and how many inputs each.
  wideCount ? "200",
  wideInputs ? "0",
  # "drvs": each wide derivation lists the inputs itself; "refs": it lists
  # one bundle derivation whose output references them (same sandbox
  # closure, one input derivation).
  wideVia ? "drvs",
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
}:
let
  inherit (pkgs) lib;
  smoke = import ../../tests/unit-smoke { inherit pkgs; };
  instantiateBin = (import ../../tests/instantiate { inherit pkgs breakbulk; }).breakbulk-instantiate;
  system = pkgs.stdenv.buildPlatform.system;

  planText = builtins.readFile (dir + "/plan.json");
  plan = builtins.toFile "plan.json" (
    builtins.unsafeDiscardStringContext (
      builtins.replaceStrings [ "@bb:rustc@" ] [ "${pkgs.rustc}/bin/rustc" ] planText
    )
  );
  # The package ids, from the plan's units (registry crates only).
  ids = lib.unique (
    lib.filter (lib.hasPrefix "registry+") (
      lib.mapAttrsToList (_: u: u.package) (builtins.fromJSON planText).units
    )
  );
  nameOf = id: lib.head (lib.splitString "@" (lib.last (lib.splitString "#" id)));

  sources = {
    crates = lib.genAttrs ids (
      id:
      builtins.path {
        path = dir + "/crates/${nameOf id}";
        name = "${nameOf id}-0.1.0";
      }
    );
    workspace.app = builtins.path {
      path = dir;
      name = "scale-app-source";
      filter =
        p: _:
        let
          rel = lib.removePrefix (toString dir + "/") (toString p);
        in
        rel == "app" || lib.hasPrefix "app/" rel;
    };
  };

  inst = breakbulk.instantiate {
    breakbulkInstantiate = instantiateBin;
    inherit system plan sources;
    tools = {
      rustc = pkgs.rustc;
      breakbulk-unit = "${smoke.breakbulk-unit}/bin/breakbulk-unit";
      shell = "${pkgs.bash}/bin/bash";
    };
    host = {
      envCapture = smoke.capture;
      env.BB_SALT = salt;
    };
    target = {
      envCapture = smoke.capture;
      env.BB_SALT = salt;
    };
  };
  root = inst.roots."app/bin/app";
  unitsData = builtins.fromJSON (builtins.readFile inst.unitsJson);
in
{
  inherit
    inst
    root
    sources
    instantiateBin
    plan
    ;
  breakbulkUnit = smoke.breakbulk-unit;
  inherit (inst) unitsJson;
  drvPaths = lib.mapAttrs (_: u: u.drvPath) inst.units;
  sourcePaths = lib.mapAttrs (_: toString) sources.crates;

  # Evaluation cost breakdown. parseOnly reads and parses units.json;
  # substOnly also assembles every unit's BREAKBULK_UNIT the way
  # lib/instantiate.nix does, but with one context-free fake path for every
  # reference, so no derivation is computed.
  parseOnly = builtins.length (builtins.attrNames unitsData.units);
  substOnly =
    let
      fake = "/nix/store/00000000000000000000000000000000-fake";
      part = p: if builtins.isString p then p else fake;
      value = v: if builtins.isAttrs v then lib.concatMapStrings part v.parts else v;
    in
    lib.foldl' (n: d: n + builtins.stringLength (value d.attrs.BREAKBULK_UNIT)) 0 (
      builtins.attrValues unitsData.units
    );
  # The bare cost of a derivation: trivialCount independent ones, each bash
  # writing one file, and one that depends on all of them.
  trivial =
    let
      one =
        i:
        derivation {
          name = "scale-trivial-${toString i}";
          inherit system salt;
          builder = "${pkgs.bash}/bin/bash";
          args = [
            "-c"
            "echo $salt > $out"
          ];
        };
    in
    derivation {
      name = "scale-trivial-all";
      inherit system;
      builder = "${pkgs.bash}/bin/bash";
      deps = map one (lib.range 1 (lib.toInt trivialCount));
      args = [
        "-c"
        "echo $deps > $out"
      ];
    };

  # The cost of inputs: wideCount independent derivations, each with the
  # same wideInputs small store paths as inputs (built once, unsalted).
  wide =
    let
      base = map (
        i:
        derivation {
          name = "scale-wide-input-${toString i}";
          inherit system;
          builder = "${pkgs.bash}/bin/bash";
          args = [
            "-c"
            "echo ${toString i} > $out"
          ];
        }
      ) (lib.range 1 (lib.toInt wideInputs));
      bundle = derivation {
        name = "scale-wide-bundle";
        inherit system;
        builder = "${pkgs.bash}/bin/bash";
        deps = base;
        args = [
          "-c"
          "echo $deps > $out"
        ];
      };
      one =
        i:
        derivation {
          name = "scale-wide-${toString i}";
          inherit system salt;
          deps = if wideVia == "refs" then [ bundle ] else base;
          builder = "${pkgs.bash}/bin/bash";
          args = [
            "-c"
            "echo $salt > $out"
          ];
        };
    in
    {
      inputs = bundle;
      all = derivation {
        name = "scale-wide-all";
        inherit system;
        builder = "${pkgs.bash}/bin/bash";
        deps = map one (lib.range 1 (lib.toInt wideCount));
        args = [
          "-c"
          "echo $deps > $out"
        ];
      };
    };

  check = pkgs.runCommand "scale-check" { } ''
    ${root}/app-* | tee $out
    grep -q '^scale ok: ' $out
  '';
}
