# The outside-reads fixture through breakbulk's flake-parts module with no
# `root`: it defaults to the flake's `self`. tests/flake-self/run.sh copies
# this file next to a copy of the fixture and compares `described` with
# ../flake.nix's `root = ./.` repository; `packages` must list the
# fixture's product (the module's outputs depend on `self`, the flake's
# own outputs: this would recurse forever if reading `self` forced them).
{
  inputs.breakbulk.url = "@BREAKBULK@";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts/ea2630b7470978622c7689a1ff75d2b389175399";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "breakbulk/nixpkgs";

  outputs =
    inputs@{ flake-parts, breakbulk, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { config, lib, ... }:
      {
        imports = [ breakbulk.lib.flakeModule ];
        systems = [ "x86_64-linux" ];
        perSystem =
          { ... }:
          {
            breakbulk.pkgs = import breakbulk.inputs.nixpkgs { system = "x86_64-linux"; };
            breakbulk.modules = [
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
        flake.described =
          let
            repo = config.allSystems.x86_64-linux.breakbulk.repo;
            native = "x86_64-unknown-linux-gnu";
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
      }
    );
}
