# What breakbulk needs to know about a Rust toolchain, from one function
# (decision 41's table-then-probe rule, for every fact):
#
#   facts = breakbulk.toolchainFacts.of { inherit pkgs rustc cargo; };
#   facts.version        "1.99.0" (rustc.version, else `rustc -vV`'s release)
#   facts.majorMinor     "1.99"
#   facts.llvmMajor      23 (rustc.llvmPackages, else lib/llvm-versions.nix's
#                        table, else `rustc -vV`)
#   facts.wasiSdkVersion "33" (lib/wasi-sdk.nix's table)
#   facts.capabilities   { remapPathScope; trimPaths; nightly; } (below)
#
# Each fact comes from the toolchain's attributes and breakbulk's tables
# when they can say, and otherwise from the toolchain itself, read by one
# tiny derivation through import-from-derivation (`probe`). Nothing is
# probed unless a fact the tables cannot give is read: nixpkgs' and
# rust-overlay's rustc and cargo carry `version`, and the LLVM table covers
# every release up to llvmVersions.verifiedThrough. The facts are lazy, so
# a preset that never reads `llvmMajor` (no LLVM tools) probes nothing.
#
# Capabilities ("Toolchain capabilities" in docs/implementation.md) are the
# features breakbulk turns on or off per toolchain. They are decided here
# only: the planner gets them as `--capabilities`, breakbulk-instantiate
# in `toolchains.json` (breakbulk-format's `Capabilities`), and no Rust
# program reads a version to decide one.
#
#   remapPathScope  rustc takes `--remap-path-scope` (stable since 1.95).
#                   From rustc's version; without one, the probe runs
#                   `rustc --remap-path-scope=macro,diagnostics --print
#                   sysroot`, which rustc rejects at option parsing when it
#                   lacks the option (rustc_driver_impl `handle_options`).
#   trimPaths       Cargo has the `trim-paths` profile setting (stable from
#                   Cargo 1.101, nightly 1.101 included). From cargo's
#                   version, else `cargo -V`.
#   nightly         Cargo allows unstable features: a `-nightly` or `-dev`
#                   release (Cargo's own channel rule). From cargo's
#                   version, else `cargo -V`.
#
# `capabilities` (an attribute set; `null` values are ignored) overrides
# any of them, for a forked or patched toolchain whose version says
# otherwise: `workspaces.<ws>.toolchain.capabilities`. `cargo` is needed
# only for trimPaths and nightly.
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
  # The first release with each version-decided capability.
  capabilitySince = {
    remapPathScope = "1.95";
    trimPaths = "1.101";
  };
  capabilityNames = [
    "remapPathScope"
    "trimPaths"
    "nightly"
  ];

  # Whether a rustc or cargo release is a nightly or development build.
  isNightly = v: lib.hasInfix "-nightly" v || lib.hasInfix "-dev" v;

  # `rustc -vV`'s release and LLVM major, and whether it takes
  # `--remap-path-scope`, as { release; llvmMajor; remapPathScope; }.
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
            if ${rustc}/bin/rustc --remap-path-scope=macro,diagnostics --print sysroot > /dev/null 2> scope.err; then
              scope=true
            else
              scope=false
            fi
            printf '{"release":"%s","llvmMajor":%s,"remapPathScope":%s}' "$release" "$llvm" "$scope" > $out
          '';
    in
    builtins.fromJSON (builtins.readFile out);

  # `cargo -V`'s release, as { release; }.
  probeCargo =
    { pkgs, cargo }:
    let
      out =
        pkgs.runCommand "cargo-facts"
          {
            preferLocalBuild = true;
            allowSubstitutes = false;
          }
          ''
            export HOME=$TMPDIR CARGO_HOME=$TMPDIR/cargo-home
            release=$(${cargo}/bin/cargo -V | sed -n 's/^cargo \([^ ]*\).*$/\1/p')
            if [ -z "$release" ]; then
              echo "breakbulk.toolchainFacts: \`${cargo}/bin/cargo -V\` names no release" >&2
              exit 1
            fi
            printf '{"release":"%s"}' "$release" > $out
          '';
    in
    builtins.fromJSON (builtins.readFile out);

  of =
    {
      pkgs,
      rustc,
      cargo ? null,
      capabilities ? { },
    }:
    let
      probed = probe { inherit pkgs rustc; };
      version = rustc.version or probed.release;
      fromTable = if rustc ? version then llvmVersions.lookup rustc.version else null;
      cargoVersion =
        if cargo == null then
          throw "breakbulk.toolchainFacts: the trimPaths and nightly capabilities need `cargo`"
        else
          cargo.version or (probeCargo { inherit pkgs cargo; }).release;
      unknown = lib.subtractLists capabilityNames (lib.attrNames capabilities);
      detected = {
        remapPathScope =
          if rustc ? version then
            util.rustVersion.atLeast capabilitySince.remapPathScope rustc.version
          else
            probed.remapPathScope;
        trimPaths = util.rustVersion.atLeast capabilitySince.trimPaths cargoVersion;
        nightly = isNightly cargoVersion;
      };
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
      capabilities =
        if unknown != [ ] then
          throw "breakbulk.toolchainFacts: unknown capabilities ${lib.concatStringsSep ", " unknown}; known: ${lib.concatStringsSep ", " capabilityNames}"
        else
          detected // lib.filterAttrs (_: v: v != null) capabilities;
    };

  # The capabilities as the planner's `--capabilities` file (every field, a
  # boolean; breakbulk-format `Capabilities`).
  capabilitiesFile =
    caps:
    builtins.toFile "capabilities.json" (
      builtins.toJSON (
        lib.genAttrs capabilityNames (
          n:
          if builtins.isBool (caps.${n} or null) then
            caps.${n}
          else
            throw "breakbulk: capability `${n}` must be true or false"
        )
      )
    );
in
{
  inherit
    capabilitiesFile
    probe
    probeCargo
    of
    capabilitySince
    capabilityNames
    ;
}
