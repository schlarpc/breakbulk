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

      # HEAVY and opt-in: dynamic-derivation mode (M5) against IFD mode, on
      # Nix master (built from a pinned commit) in a private chroot store
      # under $WORK (default $TMPDIR/breakbulk-dynamic). `nix flake check`
      # cannot run it: stock Nix has no builder-rpc-v0.
      #   nix run .#test-dynamic -- [fixture ...]
      apps = forAllSystems (pkgs: {
        test-dynamic = {
          type = "app";
          program = toString (pkgs.writeShellScript "test-dynamic" ''
            export PATH=$PATH:${nixpkgs.lib.makeBinPath [ pkgs.python3 pkgs.coreutils pkgs.gnused pkgs.diffutils pkgs.findutils pkgs.gnugrep ]}
            export REPO=''${REPO:-${self}}
            exec ${pkgs.bash}/bin/bash "$REPO/tests/dynamic/run.sh" "$@"
          '');
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
            d = import ./tests/differential {
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
            differential = d.differential;
            instantiate-eval = t.eval-checks;
          }
          # The same on rust-overlay's 1.95, 1.97 and nightly, 6 seeds each.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "differential-${n}" v) d.versions
          # End-to-end fixtures through the traced planner (IFD).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "plan-${n}" v) (
            builtins.removeAttrs p [ "workspaces" ]
          )
          # mkRepository (M2): sharing, invalidation and override tests.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "repository-${n}" v) (
            builtins.removeAttrs r [ "repos" ]
          )
          # A git source locked at two revisions by different workspaces;
          # git package ids against real Cargo's (a local repository).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "git-revisions-${n}" v) (
            builtins.removeAttrs (import ./tests/git-revisions {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "repos" "repo" "lockfiles" ]
          )
          # Stable test-run inputs for content-addressed cutoff (decision
          # 61), built input-addressed; the CA check itself needs
          # ca-derivations: tests/test-cutoff/run.sh (private store).
          // {
            test-cutoff-stable-inputs = (import ./tests/test-cutoff {
              inherit pkgs;
              breakbulk = self.lib;
            }).stable-inputs;
          }
          # Test runs, doctests and test apps over the doctests and
          # test-control fixtures (IFD).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "test-runs-${n}" v) (
            builtins.removeAttrs (import ./tests/test-runs {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "workspaces" ]
          )
          # Products through stages, source paths, products as inputs and
          # variants through mkRepository (IFD).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "products-${n}" v) (
            builtins.removeAttrs (import ./tests/products {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "repos" ]
          )
          # Loose ends: [env] in test runs, test.sourceScope, the dev
          # shell's Cargo env config, wasm embedding, docs/options.md.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "loose-ends-${n}" v) (
            builtins.removeAttrs (import ./tests/loose-ends {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "workspaces" ]
          )
          # Dynamic-derivation mode's outer-derivation builder compiles (its
          # behaviour needs Nix master: `nix run .#test-dynamic`).
          // { breakbulk-drv = self.lib.dynamic.mkBreakbulkDrv pkgs; }
        ));
    };
}
