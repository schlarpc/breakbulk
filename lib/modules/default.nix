# breakbulk's option declarations ("Options" in docs/implementation.md).
# mkRepository evaluates these with the user's modules; `pkgs` is passed as
# a module argument.
[
  ./top.nix
  ./workspaces.nix
  ./targets.nix
  ./packages.nix
]
