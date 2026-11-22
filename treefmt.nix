# `nix fmt` (treefmt-nix): Rust and every Nix file. `checks.<system>.formatting`
# fails on unformatted files, and the pre-push hook runs the same
# formatters on the files being pushed.
{
  projectRootFile = "flake.nix";

  programs.rustfmt = {
    enable = true;
    edition = "2024";
  };
  programs.nixfmt.enable = true;

  settings.excludes = [
    # Test fixtures are inputs to tests that edit them by line or compare
    # their store paths, and some are deliberately written one way (the
    # rustfmt fixtures). They are formatted, if at all, by their tests.
    "tests/**/fixture/**"
    "tests/**/fixtures/**"
    "tests/fixtures/**"
  ];
}
