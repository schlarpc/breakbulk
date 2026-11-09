# The wasi-sdk sysroot matching the wasi-libc a Rust release bundles for
# its WASI targets, so C code compiles against the same
# wasi-libc headers whose libc.a and crt1 objects rustc links from its
# self-contained directory.
#
# Rust's dist builds take the self-contained wasi-libc (libc.a,
# crt1-command.o, crt1-reactor.o) from `$WASI_SDK_PATH/share/wasi-sysroot`
# (rust-lang/rust src/bootstrap/src/lib.rs `wasi_libdir`, used by
# src/bootstrap/src/core/build_steps/compile.rs
# `copy_self_contained_objects`), and WASI_SDK_PATH is pinned in
# src/ci/docker/host-x86_64/dist-various-2/Dockerfile, the builder of
# wasm32-wasip2:
#   1.95.0, 1.96.0 (tags)                      wasi-sdk-30
#   1.97.0, 1.98.0, 1.99.0 (tags)              wasi-sdk-33
#   1.100 (beta), 1.101 (master 2026-09-25 to
#   2026-11-06), 1.102 (master, 2026-11-07)    wasi-sdk-34 (since e845ed8cc9c0,
#                                              2026-08-25, "Update WASI targets
#                                              to wasi-sdk-34")
# Checked against the toolchains as well: lib/wasm32-wasip2/libc.a of each
# sysroot below is byte-identical to lib/rustlib/wasm32-wasip2/lib/
# self-contained/libc.a of rust-overlay's 1.95.0 and 1.96.0 (30), 1.97.0
# and 1.99.0 (33), 1.100.0-beta.10 and 1.101.0-nightly-2026-11-06 (34).
#
#   wasiSdk = breakbulk.wasiSdk;
#   wasiSdk.versionFor "1.99.0"                  # "33"
#   wasiSdk.sysrootFor { inherit pkgs rustc; }   # the wasi-sysroot-33.0 tree
#   wasiSdk.sysrootFor { inherit pkgs; version = "34"; }
{
  lib,
  util,
  # lib/toolchain-facts.nix (lazily: it reads `versionFor` back).
  toolchainFacts,
}:
let
  # Rust release (major.minor) to wasi-sdk release.
  table = {
    "1.95" = "30";
    "1.96" = "30";
    "1.97" = "33";
    "1.98" = "33";
    "1.99" = "33";
    "1.100" = "34";
    "1.101" = "34";
    "1.102" = "34";
  };

  # The sysroot-only release asset of each wasi-sdk release (fetchzip
  # hashes). wasi-sdk 33 names it `wasi-sysroot-33.0+m.tar.gz`.
  releases = {
    "30" = {
      asset = "wasi-sysroot-30.0.tar.gz";
      hash = "sha256-7LMfiWSQU4zmJvwiA2Mx9AeI3b3Cj7AHDwqAWhiSjG0=";
    };
    "33" = {
      asset = "wasi-sysroot-33.0%2Bm.tar.gz";
      hash = "sha256-SaTSg8DUvkRTCoKHUNpIRRXl3X4F5GqEeSQFA4k9WQw=";
    };
    "34" = {
      asset = "wasi-sysroot-34.0.tar.gz";
      hash = "sha256-opwSpwqsTrYeblqqM0IpXzPCkZ+b0jy7eVjVvaoQ5hE=";
    };
  };

  # "1.97.1", "1.101.0-nightly", "1.100.0-beta.10-2026-11-05"
  inherit (util.rustVersion) majorMinor;

  versionFor =
    rustVersion:
    let
      mm = majorMinor rustVersion;
    in
    table.${mm}
      or (throw "breakbulk.wasiSdk: no wasi-sdk version for Rust ${mm}: add the wasi-sdk version for Rust ${mm} to lib/wasi-sdk.nix (rust-lang/rust pins it in src/ci/docker/host-x86_64/dist-various-2/Dockerfile), or pass the preset `wasiSdk` or `wasiSdkVersion`");

  sysrootFor =
    {
      pkgs,
      rustc ? null,
      version ?
        if rustc != null then
          (toolchainFacts.of { inherit pkgs rustc; }).wasiSdkVersion
        else
          throw "breakbulk.wasiSdk: give `rustc` or the wasi-sdk `version`",
    }:
    let
      r =
        releases.${version}
          or (throw "breakbulk.wasiSdk: no hash for wasi-sdk ${version}; add it to `releases` in lib/wasi-sdk.nix");
    in
    pkgs.fetchzip {
      name = "wasi-sysroot-${version}";
      url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${version}/${r.asset}";
      inherit (r) hash;
    };
in
{
  inherit
    table
    releases
    versionFor
    sysrootFor
    ;
}
