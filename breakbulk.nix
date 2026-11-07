# breakbulk's own workspace, built by breakbulk (dogfooding, "Determinism
# and dogfooding" in docs/implementation.md). A module for mkRepository:
#
#   repo = breakbulk.lib.mkRepository {
#     inherit pkgs;
#     root = ./.;
#     modules = [ ./breakbulk.nix ];
#   };
#   repo.workspaces.breakbulk.packages.breakbulk-unit   # bin/breakbulk-unit
#
# The flake exposes the products as packages.<system>.breakbulk-bb-<pkg>.
# lib/tools.nix, which builds the binaries every plan and unit uses, stays
# on nixpkgs' rustPlatform: breakbulk cannot be built by itself before it
# exists (tests/self-host checks that the two builds behave the same).
{
  workspaces.breakbulk = {
    path = ".";
    # The profile lib/tools.nix's buildRustPackage builds with.
    variants.default.profile = "release";
  };
}
