{
  description = "breakbulk: one Nix derivation per Cargo unit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; overlays = [ rust-overlay.overlays.default ]; }));
    in
    {
      # The evaluation-time library (see lib/default.nix).
      lib = import ./lib { inherit (nixpkgs) lib; };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt pkgs.rust-analyzer ];
        };
      });

      # Library tests. `roots-metadata-crates-io` uses import-from-derivation
      # and downloads from crates.io; `vendor-collision` fetches two GitHub
      # repositories during evaluation.
      checks = forAllSystems (pkgs:
        import ./tests/nix {
          inherit pkgs;
          breakbulk = self.lib;
        }
        # Env capture (builds a cross toolchain) and the unit smoke test.
        // import ./tests/env-capture {
          inherit pkgs;
          breakbulk = self.lib;
        });
    };
}
