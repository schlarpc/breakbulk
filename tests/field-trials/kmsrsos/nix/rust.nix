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
#     .cargo/config.toml (x86_64) and the flake's (both).
# Not covered: the coverage gate (cargo-llvm-cov thresholds), the
# per-package feature powerset (cargo-hack), the container, OS images and
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
      clippy = {
        mode = "clippy";
        clippyArgs = [
          "--deny"
          "warnings"
        ];
      };
      policy.features = [
        "kmsrs-policy/permissive-retail"
        "kmsrs-policy/strict-clock-skew"
      ];
    };
  };

  targets = {
    ${native}.preset = breakbulk.presets.linuxGnu;
    ${musl}.preset = breakbulk.presets.linuxMusl;
  }
  // lib.genAttrs windows (_: {
    preset = breakbulk.presets.msvc {
      inherit sdk;
      rustc = rust;
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
}
