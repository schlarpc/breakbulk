# The nixpkgs pinned by the repository's flake.lock, without needing --impure.
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  n = lock.nodes.nixpkgs.locked;
in
builtins.fetchTarball {
  url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
  sha256 = n.narHash;
}
