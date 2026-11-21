# Settings that name a path in a fetched tree as a string: a target
# rustflag (`-L native=<tree>/tools`) and a package env value
# (`LAZY_FILE = "<tree>/README.md"`, which the fixture's binary embeds
# with `include_str!`). With `lazy-trees = true` (Determinate Nix), a
# `builtins.fetchGit` tree interpolated into a string is a virtual store
# path, new on every fetch; breakbulk writes such strings as the real path
# (`util.devirtualize`). The tree is tests/git-multi-workspace's
# repository. Wired into the flake's checks as `lazy-strings-*`.
#
#   nix build -f tests/lazy-strings stable
#
#   repo      the fixture (tests/fixtures/lazy-strings) with its own fetch
#             of the tree (tests/rebuild, tests/dynamic)
#   stable    two repositories, each with its own fetch of the same
#             revision, have the same plan and unit derivations; the
#             build plan names the tree's real path, which exists; the
#             product prints the file the env value names
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
  extraModules ? [ ],
}:
let
  inherit (pkgs) lib;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  source = import ../git-multi-workspace { inherit pkgs breakbulk; };

  # Each call fetches again: under lazy trees, a new virtual path.
  fetch =
    _:
    builtins.fetchGit {
      url = source.repoUrl;
      inherit (source) rev;
    };
  real = (breakbulk.mkFetch pkgs { }).realTree (fetch 0);

  mk =
    tree:
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = ../fixtures/lazy-strings;
      modules = extraModules ++ [
        {
          workspaces.main = {
            path = ".";
            variants.default.profile = "dev";
          };
          targets.${native}.rustflags = [
            "-L"
            "native=${tree}/tools"
          ];
          packages.lazy-strings.env.LAZY_FILE = "${tree}/README.md";
        }
      ];
    };

  repo = mk (fetch 1);
  other = mk (fetch 2);

  instance = r: r.workspaces.main.instances.${native}.default;
  drvs = lib.mapAttrs (_: d: builtins.unsafeDiscardStringContext d.drvPath);
  plansOf = r: drvs (instance r).plans;
  unitsOf = r: drvs (instance r).units.build;
  planJson = builtins.readFile "${(instance repo).plans.build}/plan.json";

  same =
    what: a: b:
    lib.assertMsg (a == b) "lazy-strings: ${what} differ between two fetches of the same tree: ${builtins.toJSON a} vs ${builtins.toJSON b}";
  realFlag = "native=${builtins.unsafeDiscardStringContext real}/tools";
in
{
  inherit repo;

  stable =
    assert same "the plans" (plansOf repo) (plansOf other);
    assert same "the build plan's units" (unitsOf repo) (unitsOf other);
    assert lib.assertMsg (lib.hasInfix realFlag planJson)
      "lazy-strings: the build plan does not name the tree's real path (${realFlag})";
    pkgs.runCommand "lazy-strings-stable"
      {
        product = repo.workspaces.main.packages.lazy-strings;
        # With context, so that the real tree is in the sandbox.
        inherit real;
      }
      ''
        [ -d "$real/tools" ]
        $product/bin/lazy-strings > got
        diff -u "$real/README.md" got
        touch $out
      '';
}
