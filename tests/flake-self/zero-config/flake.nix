# The walking-skeleton fixture through breakbulk's flake-parts module with
# no configuration at all: no `root` (the flake's `self`) and no `modules`
# (one workspace, `default`, at the root). tests/flake-self/run.sh copies
# this file next to a copy of the fixture and checks that `packages` lists
# the fixture's product and `devShells` has `default`.
{
  inputs.breakbulk.url = "@BREAKBULK@";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts/ea2630b7470978622c7689a1ff75d2b389175399";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "breakbulk/nixpkgs";

  outputs =
    inputs@{ flake-parts, breakbulk, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ breakbulk.lib.flakeModule ];
      systems = [ "x86_64-linux" ];
      perSystem =
        { ... }:
        {
          breakbulk.pkgs = import breakbulk.inputs.nixpkgs { system = "x86_64-linux"; };
        };
    };
}
