# What breakbulk needs to know about a Rust toolchain, from one function
# (decision 41's table-then-probe rule, for every fact):
#
#   facts = breakbulk.toolchainFacts.of { inherit pkgs rustc; };
#   facts.version        "1.99.0" (rustc.version, else `rustc -vV`'s release)
#   facts.majorMinor     "1.99"
#   facts.llvmMajor      23 (rustc.llvmPackages, else lib/llvm-versions.nix's
#                        table, else `rustc -vV`)
#   facts.wasiSdkVersion "33" (lib/wasi-sdk.nix's table)
#
# Each fact comes from the toolchain's attributes and breakbulk's tables
# when they can say, and otherwise from `rustc -vV`, read by one tiny
# derivation through import-from-derivation (`probe`). Nothing is probed
# unless a fact the tables cannot give is read: nixpkgs' and rust-overlay's
# rustc carry `version`, and the LLVM table covers every release up to
# llvmVersions.verifiedThrough. The facts are lazy, so a preset that never
# reads `llvmMajor` (no LLVM tools) probes nothing.
#
# lib/llvm-versions.nix (`packagesFor`, `probe`) and lib/wasi-sdk.nix
# (`sysrootFor`) read their rustc through this.
{
  lib,
  util,
  llvmVersions,
  wasiSdk,
}:
let
  # `rustc -vV`'s release and LLVM major, as { release; llvmMajor; }.
  probe =
    { pkgs, rustc }:
    let
      out =
        pkgs.runCommand "rustc-facts"
          {
            preferLocalBuild = true;
            allowSubstitutes = false;
          }
          ''
            ${rustc}/bin/rustc -vV > vv
            release=$(sed -n 's/^release: \(.*\)$/\1/p' vv)
            llvm=$(sed -n 's/^LLVM version: \([0-9][0-9]*\)\..*/\1/p' vv)
            if [ -z "$release" ] || [ -z "$llvm" ]; then
              echo "breakbulk.toolchainFacts: \`${rustc}/bin/rustc -vV\` names no release or no LLVM version:" >&2
              cat vv >&2
              exit 1
            fi
            printf '{"release":"%s","llvmMajor":%s}' "$release" "$llvm" > $out
          '';
    in
    builtins.fromJSON (builtins.readFile out);

  of =
    { pkgs, rustc }:
    let
      probed = probe { inherit pkgs rustc; };
      version = rustc.version or probed.release;
      fromTable = if rustc ? version then llvmVersions.lookup rustc.version else null;
    in
    {
      inherit version;
      majorMinor = util.rustVersion.majorMinor version;
      # nixpkgs' own rustc names its LLVM, which may differ from the
      # official builds' (nixpkgs' 1.99.0 uses LLVM 21, rustup's 23).
      llvmMajor =
        if rustc ? llvmPackages then
          lib.toInt (lib.versions.major rustc.llvmPackages.llvm.version)
        else if fromTable != null then
          fromTable
        else
          probed.llvmMajor;
      wasiSdkVersion = wasiSdk.versionFor version;
    };
in
{
  inherit probe of;
}
