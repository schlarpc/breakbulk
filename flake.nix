{
  description = "breakbulk: one Nix derivation per Cargo unit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The systems this flake's outputs are defined for (the nix-systems
    # pattern, decision 55/59): x86_64-linux and aarch64-linux. A consumer
    # overrides the list with `inputs.breakbulk.inputs.systems.follows` (or
    # `.url`) pointing at another nix-systems flake, e.g. its own.
    systems.url = "github:nix-systems/default-linux";
  };

  outputs = inputs@{ self, nixpkgs, rust-overlay, ... }:
    let
      systems = import inputs.systems;
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; overlays = [ rust-overlay.overlays.default ]; }));
      # The documentation site (docs/default.nix).
      docsFor = pkgs: import ./docs {
        inherit pkgs;
        optionsMd = (import ./tests/loose-ends {
          inherit pkgs;
          breakbulk = self.lib;
        }).options-md;
      };
    in
    {
      # The evaluation-time library (see lib/default.nix).
      # Its default tools are built with this flake's nixpkgs (#41).
      lib = import ./lib {
        inherit (nixpkgs) lib;
        inherit nixpkgs;
      };

      # breakbulk built by breakbulk (tests/self-host):
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
        nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "breakbulk-bb-${n}" v) selfBuilt
        # The documentation site: nix build .#docs-site
        // { docs-site = (docsFor pkgs).site; });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt pkgs.rust-analyzer ];
        };
      });

      # HEAVY and opt-in: dynamic-derivation mode against IFD mode, on
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
        # Content-addressed test cutoff (decisions 61, 17): private store
        # with ca-derivations on the command line only.
        #   nix run .#test-cutoff
        test-cutoff = {
          type = "app";
          program = toString (pkgs.writeShellScript "test-cutoff" ''
            export PATH=$PATH:${nixpkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.diffutils pkgs.findutils pkgs.gnugrep ]}
            export REPO=''${REPO:-${self}}
            exec ${pkgs.bash}/bin/bash "$REPO/tests/test-cutoff/run.sh" "$@"
          '');
        };
        # stripForRun and runFiles under content addressing (decisions 17, 61).
        #   nix run .#test-options
        test-options = {
          type = "app";
          program = toString (pkgs.writeShellScript "test-options" ''
            export PATH=$PATH:${nixpkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.diffutils pkgs.findutils pkgs.gnugrep ]}
            export REPO=''${REPO:-${self}}
            exec ${pkgs.bash}/bin/bash "$REPO/tests/test-options/run.sh" "$@"
          '');
        };
      } // nixpkgs.lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux") {
        # linuxPortable (zig) binaries in a real glibc 2.17 userland (decision 122): pulls
        # CentOS 7.9 from Docker Hub (~75 MB) and builds OpenSSL with zig
        # cc, so it is not a flake check. Arguments go to nix-store.
        #   nix run .#test-linux-portable-container [-- --max-jobs 2 --cores 4]
        test-linux-portable-container =
          let
            checks = (import ./tests/presets/extra-targets.nix {
              inherit pkgs;
              breakbulk = self.lib;
            }).containerChecks;
            # The .drv files only: the checks are built when the app runs,
            # not when it is built.
            drvs = nixpkgs.lib.mapAttrsToList (n: d: "${n}=${builtins.unsafeDiscardOutputDependency d.drvPath}") checks;
          in
          {
            type = "app";
            program = toString (pkgs.writeShellScript "test-linux-portable-container" ''
              set -euo pipefail
              status=0
              for nd in ${nixpkgs.lib.escapeShellArgs drvs}; do
                name=''${nd%%=*}
                printf '\n== %s\n' "$name" >&2
                if out=$(nix-store --realise "''${nd#*=}" "$@"); then
                  echo "ok: $name $out" >&2
                else
                  echo "FAIL: $name" >&2
                  status=1
                fi
              done
              exit $status
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
        # The systems come from the `systems` input (decision 55/59): with
        # another list in its place, the outputs follow it.
        // {
          # Every internal link and fragment of the documentation site.
          docs-site-links = (docsFor pkgs).links;

          flake-systems =
            let
              other = (import ./flake.nix).outputs (inputs // {
                self = throw "flake-systems: self is not used";
                systems = builtins.toFile "systems.nix" ''[ "riscv64-linux" ]'';
              });
              names = map (o: builtins.attrNames other.${o}) [ "packages" "devShells" "apps" "checks" ];
            in
            assert nixpkgs.lib.assertMsg (nixpkgs.lib.all (n: n == [ "riscv64-linux" ]) names)
              "flake-systems: outputs do not follow the systems input: ${builtins.toJSON names}";
            assert builtins.attrNames self.checks == import inputs.systems;
            pkgs.runCommand "flake-systems" { } "touch $out";

          # #41: without `tools`, a repository's tools come from this flake's
          # nixpkgs, so a consumer whose nixpkgs builds them differently
          # (here: another rustPlatform) gets the same tools, and its units
          # use them. `mkTools` with each consumer's nixpkgs gives different
          # tools (the check is not vacuous). Whole units still differ here:
          # nixpkgs builds mold with rustPlatform, and units link with it.
          default-tools =
            let
              inherit (nixpkgs) lib;
              other = import nixpkgs {
                inherit (pkgs.stdenv.hostPlatform) system;
                overlays = [
                  rust-overlay.overlays.default
                  (f: p: {
                    rustPlatform = p.makeRustPlatform {
                      rustc = p.rust-bin.stable."1.95.0".minimal;
                      cargo = p.rust-bin.stable."1.95.0".minimal;
                    };
                  })
                ];
              };
              paths = ts: lib.mapAttrs (_: d: d.outPath) (lib.filterAttrs (_: lib.isDerivation) ts);
              native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
              units =
                extra:
                lib.mapAttrs (_: u: u.drvPath)
                  (self.lib.mkRepository ({
                    pkgs = other;
                    root = ./tests/fixtures/walking-skeleton;
                    modules = [ { workspaces.main.variants.default.profile = "dev"; } ];
                  } // extra)).workspaces.main.instances.${native}.default.units.build;
            in
            assert lib.assertMsg (paths (self.lib.defaultTools pkgs) == paths (self.lib.defaultTools other))
              "default-tools: the default tools depend on the consumer's nixpkgs";
            assert lib.assertMsg (paths (self.lib.mkTools pkgs) != paths (self.lib.mkTools other))
              "default-tools: both nixpkgs build the same tools; the check proves nothing";
            assert lib.assertMsg (units { } == units { tools = self.lib.defaultTools pkgs; })
              "default-tools: the units do not use the default tools";
            assert lib.assertMsg (units { } != units { tools = self.lib.mkTools other; })
              "default-tools: the units do not depend on the tools; the check proves nothing";
            pkgs.runCommand "default-tools" { } "touch $out";
        }
        // import ./tests/env-capture {
          inherit pkgs;
          breakbulk = self.lib;
        }
        # Toolchain-preset building blocks. HEAVY: msvc-sdk downloads the
        # MSVC CRT and Windows SDK (unfree, ~250 MB); wasm-bindgen-build
        # compiles a wasm-bindgen-cli.
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
        # Post-link stages and helpers (stages-*). stages-wasm-web
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
          # mkRepository: sharing, invalidation and override tests.
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
          # One git source, crates from two inheriting workspaces: argv
          # and CARGO_PKG_* against real Cargo over a local repository.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "git-multi-workspace-${n}" v) (
            builtins.removeAttrs (import ./tests/git-multi-workspace {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "repo" ]
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
          # Test-run options: a debug-stripped copy (test.stripForRun,
          # decision 17) and a narrowed working directory (test.runFiles,
          # decision 61). The CA check: tests/test-options/run.sh.
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "test-options-${n}" v) (
            builtins.removeAttrs (import ./tests/test-options {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "runs" ]
          )
          # Native libraries at the link steps of the packages that link a
          # `-sys` crate (decision 107).
          // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "native-link-${n}" v) (
            builtins.removeAttrs (import ./tests/native-link {
              inherit pkgs;
              breakbulk = self.lib;
            }) [ "repo" ]
          )
          # Dynamic-derivation mode's outer-derivation builder compiles (its
          # behaviour needs Nix master: `nix run .#test-dynamic`).
          // { breakbulk-drv = self.lib.dynamic.mkBreakbulkDrv pkgs; }
        ));
    };
}
