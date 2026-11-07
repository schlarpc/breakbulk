# The LLVM major version inside a rustc, for picking version-matched LLVM
# tools (lld, lld-link, clang, clang-cl, llvm-lib) from nixpkgs (decision
# 41; "Toolchain presets" in docs/implementation.md).
#
# Only nixpkgs' own rustc names its LLVM (`rustc.llvmPackages`); rust-overlay
# and fenix toolchains do not, and asking rustc at build time would need
# import-from-derivation. So this table maps the Rust release to the LLVM
# major its official builds use.
#
# Source: `rustc -vV` ("LLVM version") of every rust-overlay stable
# toolchain 1.90.0 to 1.99.1 and nightly 1.101.0 (2026-11), at the
# repository's pinned rust-overlay:
#   1.90.0                20.1.8
#   1.91.0 - 1.94.1       21.1.2 - 21.1.8
#   1.95.0 - 1.98.1       22.1.2 - 22.1.8
#   1.99.0 - 1.101 (nightly)  23.1.1 - 23.1.5
# nixpkgs' rustc 1.99.0 is built against nixpkgs' LLVM 21 instead, which is
# why `rustc.llvmPackages` wins when present.
#
#   llvm = breakbulk.llvmVersions;
#   llvm.majorFor "1.97.1"                       # 22
#   llvm.packagesFor { inherit pkgs rustc; }     # pkgs.llvmPackages_22 (or rustc.llvmPackages)
#   llvm.packagesFor { inherit pkgs; llvmMajor = 23; }
{ lib }:
let
  # Ascending by `from` (a major.minor Rust release).
  table = [
    {
      from = "1.90";
      llvm = 20;
    }
    {
      from = "1.91";
      llvm = 21;
    }
    {
      from = "1.95";
      llvm = 22;
    }
    {
      from = "1.99";
      llvm = 23;
    }
  ];

  # "1.97.1", "1.101.0-nightly", "1.99.0-beta.3", "1.101.0-nightly-2026-11-01"
  majorMinor = v: lib.versions.majorMinor (lib.head (lib.splitString "-" v));

  majorFor =
    rustVersion:
    let
      mm = majorMinor rustVersion;
      matching = lib.filter (e: lib.versionAtLeast mm e.from) table;
    in
    if matching == [ ] then
      throw "breakbulk.llvmVersions: Rust ${rustVersion} is older than the table (${(lib.head table).from}); pass llvmMajor explicitly"
    else
      (lib.last matching).llvm;

  versionOf =
    rustc:
    rustc.version
      or (throw "breakbulk.llvmVersions: the rustc derivation `${rustc.name or "?"}` has no `version`; pass llvmMajor or llvmPackages explicitly");

  packagesFor =
    {
      pkgs,
      rustc ? null,
      llvmMajor ? null,
      llvmPackages ? null,
    }:
    let
      major =
        if llvmMajor != null then
          llvmMajor
        else if rustc == null then
          throw "breakbulk: this preset needs LLVM tools matching your rustc; pass `rustc` (your toolchain), `llvmMajor` or `llvmPackages` to the preset"
        else
          majorFor (versionOf rustc);
      attr = "llvmPackages_${toString major}";
    in
    if llvmPackages != null then
      llvmPackages
    else if llvmMajor == null && rustc != null && rustc ? llvmPackages then
      rustc.llvmPackages
    else
      pkgs.${attr} or (throw "breakbulk: nixpkgs has no `${attr}` for the LLVM inside rustc; pass `llvmPackages` to the preset");
in
{
  inherit
    table
    majorFor
    packagesFor
    ;
}
