# A flake around the test-control fixture, for tests/flake-self/run.sh:
# `nix run` on a test app at its attribute path under `repo` (a derivation
# outside `apps`), and on its name in `apps` (repo.apps). run.sh copies
# this file next to a copy of the fixture and points `breakbulk` at the
# checkout under test.
{
  inputs.breakbulk.url = "@BREAKBULK@";

  outputs =
    { self, breakbulk }:
    let
      pkgs = import breakbulk.inputs.nixpkgs { system = "x86_64-linux"; };
      repo = breakbulk.lib.mkRepository {
        inherit pkgs;
        root = self;
        modules = [
          {
            workspaces.main = {
              path = ".";
              variants.default.profile = "dev";
            };
            packages.ctl.test.binaries.net.args = [
              "--skip"
              "needs_network"
            ];
          }
        ];
      };
    in
    {
      inherit repo;
      apps.x86_64-linux = repo.apps;
    };
}
