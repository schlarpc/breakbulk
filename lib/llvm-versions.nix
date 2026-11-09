# The LLVM major version inside a rustc, for picking version-matched LLVM
# tools (lld, lld-link, clang, clang-cl, llvm-lib) from nixpkgs ("Toolchain
# presets" in docs/src/explanation/internals/toolchains.md).
#
# Only nixpkgs' own rustc names its LLVM (`rustc.llvmPackages`); rust-overlay
# and fenix toolchains do not. This table maps the Rust release to the LLVM
# major its official builds use, and is the fast path (no build at
# evaluation time). For a rustc outside the table (older than its first
# release, newer than `verifiedThrough`, or without a `version`), the major
# is read from `rustc -vV` by a tiny derivation, through
# import-from-derivation, instead of failing.
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
#   llvm.lookup "1.102.0"                        # null: not in the table
#   llvm.probe { inherit pkgs rustc; }           # from `rustc -vV` (IFD)
{
  lib,
  util,
  # lib/toolchain-facts.nix (lazily: it reads `lookup` back).
  toolchainFacts,
}:
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

  # The last Rust release (major.minor) whose LLVM major was checked. A
  # newer one may use a newer LLVM, so it is probed instead.
  verifiedThrough = "1.101";

  # "1.97.1", "1.101.0-nightly", "1.99.0-beta.3", "1.101.0-nightly-2026-11-01"
  inherit (util.rustVersion) majorMinor;

  # The table's LLVM major for a Rust version, or null outside the table.
  lookup =
    rustVersion:
    let
      mm = majorMinor rustVersion;
      matching = lib.filter (e: lib.versionAtLeast mm e.from) table;
    in
    if builtins.match "[0-9]+\\.[0-9]+([.-].*)?" rustVersion == null then
      null
    else if matching == [ ] || lib.versionOlder verifiedThrough mm then
      null
    else
      (lib.last matching).llvm;

  majorFor =
    rustVersion:
    let
      m = lookup rustVersion;
    in
    if m == null then
      throw "breakbulk.llvmVersions: Rust ${rustVersion} is outside the table (${(lib.head table).from} to ${verifiedThrough}); use `probe`, or pass llvmMajor explicitly"
    else
      m;

  # The LLVM major of `rustc`, from `rustc -vV` ("LLVM version: 23.1.5"),
  # read at evaluation time (import-from-derivation). The derivation is
  # tiny and runs on the build machine.
  # The LLVM major of a rustc, from `rustc -vV` (IFD;
  # toolchainFacts.probe).
  probe = args: (toolchainFacts.probe args).llvmMajor;

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
          (toolchainFacts.of { inherit pkgs rustc; }).llvmMajor;
      attr = "llvmPackages_${toString major}";
    in
    if llvmPackages != null then
      llvmPackages
    else if llvmMajor == null && rustc != null && rustc ? llvmPackages then
      rustc.llvmPackages
    else
      pkgs.${attr}
        or (throw "breakbulk: nixpkgs has no `${attr}` for the LLVM inside rustc; pass `llvmPackages` to the preset");
in
{
  inherit
    table
    verifiedThrough
    lookup
    majorFor
    probe
    packagesFor
    ;
}
