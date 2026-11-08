# breakbulk module for kmsrsos (field trial; docs/field-trials.md).
#
# Replaces the crane wiring of its flake.nix for the Rust parts:
#   - one workspace, 1.96.1 from rust-toolchain.toml, release;
#   - the whole workspace natively (`packages.default`), its tests
#     (`checks.test`, nextest there, libtest here) and clippy
#     (`--all-targets -- --deny warnings`);
#   - the build-time policy features as a variant (`checks.policy-features`);
#   - static musl server and client (`staticEnvFor`) with the build stamp
#     on kmsrs-server only (`stampEnv`);
#   - Windows x86_64 and aarch64 (msvc via xwin) for kmsrs-server and
#     kmsrs-client, with the project's own `+crt-static` from
#     .cargo/config.toml (x86_64) and the flake's (both);
#   - the per-package feature powerset (`checks.feature-powerset`: `cargo
#     hack check --workspace --all-targets --feature-powerset`), natively.
# Not covered: the coverage gate (cargo-llvm-cov thresholds), the
# container, OS images and
# boot checks (non-Rust stages over these products), and the nightly
# `fuzz` and `panic-audit` workspaces (no toolchain pinned in the repo).
{
  lib,
  pkgs,
  root,
  breakbulk,
  ...
}:
let
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  musl = "x86_64-unknown-linux-musl";
  windows = [
    "x86_64-pc-windows-msvc"
    "aarch64-pc-windows-msvc"
  ];
  rust = pkgs.rust-bin.fromRustupToolchainFile (root + "/rust-toolchain.toml");

  # The flake's xwin SDK pin (crt 14.44.17.14, SDK 10.0.26100, both
  # arches), through breakbulk's fetcher; unfree, allowed for this package
  # only.
  sdk = breakbulk.xwinSdk {
    pkgs = import pkgs.path {
      inherit (pkgs.stdenv.hostPlatform) system;
      config.allowUnfreePredicate = p: lib.getName p == "xwin-sdk";
    };
    manifestVersion = 17;
    crt = "14.44.17.14";
    sdk = "10.0.26100";
    arches = [
      "x86_64"
      "aarch64"
    ];
    hash = "sha256-22dqk0tKSbC4bnfsnhhsG0aEJfUHb3JJNL3TnZGFVa0=";
  };
in
{
  mode = "ifd";

  workspaces.main = {
    path = ".";
    toolchain = {
      rustc = rust;
      cargo = rust;
      clippy = rust;
    };
    targets = {
      ${native} = { };
      ${musl}.packages = [
        "kmsrs-server"
        "kmsrs-client"
        "kmsrs-os"
      ];
    }
    // lib.genAttrs windows (_: {
      packages = [
        "kmsrs-server"
        "kmsrs-client"
      ];
    });
    variants = {
      default = { };
      # Both gates run natively only, as in the flake. The policy
      # variant's test runs are in repo.checks under `variant-policy/`.
      clippy = {
        mode = "clippy";
        targets = [ native ];
        clippyArgs = [
          "--deny"
          "warnings"
        ];
      };
      policy = {
        targets = [ native ];
        packages = [
          "kmsrs-policy"
          "kmsrs-server"
        ];
        features = [
          "kmsrs-policy/permissive-retail"
          "kmsrs-policy/strict-clock-skew"
        ];
      };
    }
    # cargo-hack's matrix: one `cargo check --all-targets -p <pkg>` plan
    # per package and feature set (13 for this workspace), dev profile as
    # `cargo hack check` uses; each is in repo.checks as
    # `main/<native>/variant-hack-<pkg>…/check`.
    // breakbulk.variants.packageFeaturePowerset {
      inherit root;
      mode = "check";
      profile = "dev";
      targets = [ native ];
    };
  };

  targets = {
    ${native}.preset = breakbulk.presets.linuxGnu;
    ${musl}.preset = breakbulk.presets.linuxMusl;
  }
  // lib.genAttrs windows (_: {
    # LLVM tools for the workspace's rustc (decision 70).
    preset = breakbulk.presets.msvc {
      inherit sdk;
      crtStatic = true;
    };
  });

  # The build stamp (flake.nix `stampEnv`): only kmsrs-server reads it, so
  # only its units change when the revision does. The copy has no git
  # metadata, so the flake's own fallbacks apply.
  packages.kmsrs-server.env = {
    KMSRSOS_GIT_COMMIT = "unknown";
    SOURCE_DATE_EPOCH = "0";
  };

  # Tests that read the repository (workspace and packaging invariants, the
  # docs they keep in sync, the kernel configs, the CI scripts): the
  # flake's source filter keeps these files for them.
  packages.kmsrs-server.test.sourceScope = [
    ".github"
    "Cargo.toml"
    "Cargo.lock"
    "rust-toolchain.toml"
    "flake.nix"
    "flake.lock"
    "harness"
    "crates"
    "ci"
    "deploy"
    "docs"
    "os"
    "fuzz"
  ];
  packages.kmsrs-db.test.sourceScope = [ "crates/kmsrs-dbgen" ];
  packages.kmsrs-vectors.test.sourceScope = [ "fuzz" ];
  # kmsrs-dbgen is the generator of kmsrs-db's tables; it finds its data
  # through CARGO_MANIFEST_DIR on purpose, which the default check flags.
  packages.kmsrs-dbgen.checks.noSourceReferences = null;
}
