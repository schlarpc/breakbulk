# breakbulk module for mtgac (field trial; docs/field-trials.md).
#
# Replaces the crane wiring of its flake.nix for the Rust parts:
#   - one workspace (crates/* and xtask), 1.96.1 from rust-toolchain.toml;
#   - `packages.default` (`-p mtgac`, release), the tests and clippy
#     (`--all-targets -- --deny warnings`; the flake runs both in the dev
#     profile);
#   - the wasm gate (`cargo check-wasm`: every member but mtgac and xtask
#     checks for wasm32-unknown-unknown, ring's C through unwrapped clang);
#   - the Leptos UI (mtgac-ui) as a browser wasm product (the flake runs
#     trunk over it);
#   - Windows x86_64 (msvc via xwin) for mtgac.
# Not covered: the asset extraction pipeline (nix/assets.nix, fixed-output
# downloads of the game client), cargo-deny, coverage, trunk's HTML
# processing.
{
  lib,
  pkgs,
  root,
  breakbulk,
  ...
}:
let
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  wasm = "wasm32-unknown-unknown";
  windows = "x86_64-pc-windows-msvc";
  rust = pkgs.rust-bin.fromRustupToolchainFile (root + "/rust-toolchain.toml");

  members = builtins.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir (root + "/crates"))
  );
  memberName =
    d: (builtins.fromTOML (builtins.readFile (root + "/crates/${d}/Cargo.toml"))).package.name;

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
    # Tests run natively only, as in the flake.
    targets = {
      ${native} = { };
      # `cargo check-wasm`: --workspace --exclude mtgac --exclude xtask.
      ${wasm} = {
        packages = lib.filter (n: n != "mtgac") (map memberName members);
        tests = false;
      };
      ${windows} = {
        packages = [ "mtgac" ];
        tests = false;
      };
    };
    variants = {
      default = { };
      # The wasm gate is plain `cargo check` (decision 108), for wasm only.
      check = {
        mode = "check";
        allTargets = false;
        targets = [ wasm ];
      };
      clippy = {
        mode = "clippy";
        targets = [ native ];
        profile = "dev";
        clippyArgs = [
          "--deny"
          "warnings"
        ];
      };
    };
  };

  targets = {
    ${native}.preset = breakbulk.presets.linux;
    # LLVM tools for the workspace's rustc (decision 70).
    ${wasm}.preset = breakbulk.presets.wasmWeb;
    ${windows}.preset = breakbulk.presets.windows { inherit sdk; };
  };
}
