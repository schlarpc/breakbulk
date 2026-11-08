# A flake around the outside-reads fixture, for tests/flake-self/run.sh:
# the same repository with `root = self` and `root = ./.`. run.sh copies
# this file next to a copy of the fixture and points `breakbulk` at the
# checkout under test.
{
  inputs.breakbulk.url = "@BREAKBULK@";

  outputs =
    { self, breakbulk }:
    let
      pkgs = import breakbulk.inputs.nixpkgs { system = "x86_64-linux"; };
      inherit (pkgs) lib;
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      repoWith =
        root:
        breakbulk.lib.mkRepository {
          inherit pkgs root;
          modules = [
            {
              workspaces.main = {
                path = "ws";
                variants.default.profile = "dev";
              };
              packages.reader.extraSources = [ "schema" ];
              packages.app.extraSources = [ "assets" ];
            }
          ];
        };
      # Every unit .drv path of both plans, and every source view's store
      # path, by name.
      describe =
        repo:
        let
          i = repo.workspaces.main.instances.${native}.default;
          drvs = us: lib.mapAttrs (_: u: builtins.unsafeDiscardStringContext u.drvPath) us;
        in
        {
          units = {
            build = drvs i.units.build;
            test = drvs i.units.test;
          };
          views = lib.mapAttrs (_: v: builtins.unsafeDiscardStringContext "${v}") i.sources.workspace;
          plans = lib.mapAttrs (_: p: builtins.unsafeDiscardStringContext p.drvPath) i.plans;
        };
    in
    {
      fromSelf = describe (repoWith self);
      fromPath = describe (repoWith ./.);
      fromOutPath = describe (repoWith self.outPath);
      # A wrong value: the error names what `root` accepts.
      wrong = (repoWith { foo = 1; }).workspaces;
    };
}
