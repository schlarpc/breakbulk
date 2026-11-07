# CA island cost (M6 spike): the test-control fixture's test runs, as
# content-addressed (`ca = true`) or input-addressed (`ca = false`) test
# runs. See run.sh.
{
  ca ? false,
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
  breakbulk ? import ../../../lib { inherit (pkgs) lib; },
}:
let
  ws = breakbulk.mkWorkspace pkgs {
    root = ../../../tests/fixtures/test-control;
    tools = breakbulk.mkTools pkgs;
    name = "ca-island";
    inherit ca;
    packages.ctl.test.binaries.net.args = [
      "--skip"
      "needs_network"
    ];
  };
  runs = pkgs.lib.filterAttrs (_: r: r ? drvPath && r.breakbulkRoot or null == null) ws.testRuns.ctl;
in
{
  inherit runs;
  # What evaluation imports (IFD): copied into the private store with the
  # runs' closure, so it need not rebuild them.
  ifd = pkgs.linkFarm "ca-island-ifd" (
    pkgs.lib.mapAttrsToList (n: p: {
      name = "plan-${n}";
      path = p;
    }) ws.plans
    ++ pkgs.lib.mapAttrsToList (n: p: {
      name = "units-${n}";
      path = p;
    }) ws.unitsJson
  );
  # One derivation naming every run, for instantiating them together.
  all = pkgs.linkFarm "ca-island-runs" (
    pkgs.lib.mapAttrsToList (n: r: {
      name = builtins.replaceStrings [ "/" ] [ "-" ] n;
      path = r;
    }) runs
  );
}
