# Field trials: breakbulk on the author's own repositories (docs/field-trials.md).
#
# Nothing here contains the repositories' source. Each trial is a module
# (`<name>/nix/rust.nix`) written the way the repository would carry it,
# and this file points it at a checkout given as an argument:
#
#   nix build -f tests/field-trials --arg datboi2 /path/to/datboi2 datboi2.build
#
# The checkout must be a plain directory outside $HOME (Cargo reads
# `.cargo/config.toml` from every ancestor of the planner's directory only
# in local experiments, but keep it clean anyway), with the project's
# untracked build outputs (`target/`, `result*`, `node_modules/`) and
# secrets left out. Trials whose argument is null are absent.
#
# Each trial is `{ repo; build; checks; … }`: `repo` is the mkRepository
# result, `build` a linkFarm of the products the repository's own CI
# builds, `checks` a linkFarm of `repo.checks` (what CI would run).
{
  pkgs ?
    let
      lock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes;
      fetch =
        n:
        fetchTarball {
          url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
          sha256 = n.narHash;
        };
    in
    import (fetch lock.nixpkgs.locked) {
      overlays = [ (import (fetch lock.rust-overlay.locked)) ];
    },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
  datboi2 ? null,
  kmsrsos ? null,
  mtgac ? null,
}:
let
  inherit (pkgs) lib;
  tools = breakbulk.mkTools pkgs;

  asPath = p: if builtins.isPath p then p else /. + p;

  # mkRepository with the trial's module. mkRepository gives modules
  # `root`, the repository itself (`repo`, for products as inputs) and
  # `breakbulk`, as it would in the repository's own flake.
  trial =
    name: root: extra:
    let
      repo = breakbulk.mkRepository {
        inherit pkgs tools;
        root = asPath root;
        modules = [ (./. + "/${name}/nix/rust.nix") ];
        specialArgs = extra;
      };
      flat =
        attrs: lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) attrs;
    in
    {
      inherit repo;
      checks = pkgs.linkFarm "${name}-checks" (flat repo.checks);
    }
    // (import (./. + "/${name}/outputs.nix") { inherit pkgs lib repo; });
in
lib.optionalAttrs (datboi2 != null) { datboi2 = trial "datboi2" datboi2 { }; }
// lib.optionalAttrs (kmsrsos != null) { kmsrsos = trial "kmsrsos" kmsrsos { }; }
// lib.optionalAttrs (mtgac != null) { mtgac = trial "mtgac" mtgac { }; }
