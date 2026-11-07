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

      # breakbulk built by breakbulk (./breakbulk.nix, tests/self-host):
      # breakbulk-bb-<package>, each with bin/<program>. The binaries plans
      # and units use still come from lib/tools.nix (the bootstrap). The
      # names are listed here: the products' names come from the plan,
      # and listing the flake's packages must not plan (IFD).
      packages = forAllSystems (pkgs:
        let
          selfBuilt = (import ./tests/self-host {
            inherit pkgs;
            breakbulk = self.lib;
          }).selfBuilt;
        in
        nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "breakbulk-bb-${n}" v) selfBuilt);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt pkgs.rust-analyzer ];
        };
      });

      # Library tests. `roots-metadata-crates-io` uses import-from-derivation
      # and downloads from crates.io; `vendor-collision` fetches two GitHub
      # repositories during evaluation. `instantiate` and `instantiate-eval`
      # (IFD) build the unit-smoke plan through breakbulk-instantiate; that
      # plan targets x86_64-unknown-linux-gnu. Env capture builds a cross
      # toolchain.
      checks = forAllSystems (pkgs:
        import ./tests/nix {
          inherit pkgs;
          breakbulk = self.lib;
        }
        // import ./tests/env-capture {
          inherit pkgs;
          breakbulk = self.lib;
        }
        # Toolchain-preset building blocks. HEAVY: msvc-sdk downloads the
        # MSVC CRT and Windows SDK (unfree, ~250 MB); msvc-x86_64 and
        # msvc-aarch64 cross-build a Rust+C program against it (x86_64 runs
        # under wine); wasm-bindgen-build compiles a wasm-bindgen-cli.
        # allowUnfree is scoped: only this package set, used only for the
        # SDK, admits unfree packages, and only the one named xwin-sdk.
        // import ./tests/presets {
          inherit pkgs;
          breakbulk = self.lib;
          xwinPkgs = import nixpkgs {
            system = pkgs.stdenv.hostPlatform.system;
            config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "xwin-sdk";
          };
        }
        # Post-link stages and helpers (stages-*). stages-wasm-browser
        # downloads a rust-overlay toolchain with the wasm32 target.
        // import ./tests/stages {
          inherit pkgs;
          breakbulk = self.lib;
        }
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux") (
          let
            t = import ./tests/instantiate {
              inherit pkgs;
              breakbulk = self.lib;
            };
            p = import ./tests/plan {
              inherit pkgs;
              breakbulk = self.lib;
            };
            r = import ./tests/repository {
              inherit pkgs;
              breakbulk = self.lib;
            };
          in
          {
            instantiate = t.check;
            # breakbulk builds itself; the self-built programs give
            # byte-identical plans, units.json and products (IFD).
            self-host = (import ./tests/self-host {
              inherit pkgs;
              breakbulk = self.lib;
            }).self-host;
            # Directive differential test: 32 random workspaces, real
            # `cargo build -vv` and `cargo test --no-run -vv` against the
            # traced plans, argv and env per unit. No network.
            differential = (import ./tests/differential {
              inherit pkgs;
              breakbulk = self.lib;
            }).differential;
            instantiate-eval = t.eval-checks;
          }
          # End-to-end fixtures through the traced planner (IFD).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "plan-${n}" v) (
            builtins.removeAttrs p [ "workspaces" ]
          )
          # mkRepository (M2): sharing, invalidation and override tests.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "repository-${n}" v) (
            builtins.removeAttrs r [ "repos" ]
          )
          # Test runs, doctests and test apps over the doctests and
          # test-control fixtures (IFD).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "test-runs-${n}" v) (
            builtins.removeAttrs (import ./tests/test-runs {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "workspaces" ]
          )
        ));
    };
}
