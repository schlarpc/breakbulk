# What breakbulk needs to know about a Rust toolchain, from one function:
#
#   facts = breakbulk.toolchainFacts.of { inherit pkgs rustc cargo; };
#   facts.version        "1.99.0" (rustc.version, else `rustc -vV`'s release)
#   facts.majorMinor     "1.99"
#   facts.llvmMajor      23 (rustc.llvmPackages, else lib/llvm-versions.nix's
#                        table, else `rustc -vV`)
#   facts.llvmVersion    "23.1.1" (rustc.llvmPackages, else `rustc -vV`;
#                        the table has majors only)
#   facts.llvmPackages   nixpkgs' LLVM packages of that major, for the
#                        build machine (`pkgs`): rustc.llvmPackages for
#                        nixpkgs' rustc, else `pkgs.llvmPackages_<major>`
#   facts.wasiSdkVersion "33" (lib/wasi-sdk.nix's table)
#   facts.bundledLld     true: rustc is a rust-lang build (rustup,
#                        rust-overlay, fenix), which ships its own lld and
#                        links some Linux targets with it by default
#                        (lib/presets/linker.nix, `rustcPicksLld`); false
#                        for nixpkgs' rustc (`rustc.llvmPackages`), built
#                        with `--disable-lld` against nixpkgs' LLVM
#   facts.capabilities   { remapPathScope; trimPaths; } (below)
#
# `facts` (`workspaces.<ws>.toolchain.facts`: `llvmMajor`, `llvmPackages`,
# `bundledLld`, `wasiSdkVersion`, `capabilities`; `null` values are
# ignored) overrides any of them, for a source-built, forked or patched
# toolchain the attributes and tables misjudge. An overridden
# `llvmPackages` gives `llvmMajor` and `llvmVersion` too, an overridden
# `llvmMajor` the packages of that major.
#
# Each fact comes from the toolchain's attributes and breakbulk's tables
# when they can say, and otherwise from the toolchain itself, read by one
# tiny derivation through import-from-derivation (`probe`). Nothing is
# probed unless a fact the tables cannot give is read: nixpkgs' and
# rust-overlay's rustc and cargo carry `version` (a `version` that is not a
# Rust release, such as fenix's manifest dates, counts as none; fenix's
# toolchains are therefore probed), and the LLVM table covers
# every release up to llvmVersions.verifiedThrough. The facts are lazy, so
# a preset that never reads `llvmMajor` (no LLVM tools) probes nothing.
#
# Capabilities ("Toolchain capabilities" in
# docs/src/explanation/internals/planner.md) are the
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
#
# Whether Cargo allows unstable features is not one: the planner asks the
# cargo it runs (`cargo -Zunstable-options help`), since a version string
# does not say it (nixpkgs' cargo has no release channel, so it is a `dev`
# build).
#
# `facts.capabilities` (or `capabilities`, for callers that have only
# those) overrides any of them. `cargo` is needed only for trimPaths.
#
# `nixFeatures` (lib/nix-features.nix; default: import from derivation
# allowed) is the record the probes are checked against; `mayProbe {
# rustc; cargo; }` says whether `of` may probe that toolchain, which is
# what repo.nixFeatures counts.
#
# lib/llvm-versions.nix (`packagesFor`, `probe`) and lib/wasi-sdk.nix
# (`sysrootFor`) read their rustc through this.
{
  lib,
  util,
  llvmVersions,
  wasiSdk,
  featureGates,
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
  ];

  # A package's `version` when it is a Rust release (`1.99.0`,
  # `1.101.0-nightly`, `1.100.0-beta.3`), else null, so the toolchain is
  # asked. fenix's component packages (its `cargo`, `rustc-unwrapped`) set
  # `version` to the channel manifest's date (`2026-10-15`; fenix
  # `lib/mk-toolchain.nix`: `version = source.date or date`), which says
  # nothing about the release or the channel; its combined toolchains
  # (`rustc`, `toolchain`, `minimalToolchain`) have no `version`.
  releaseOf =
    drv:
    let
      v = drv.version or null;
    in
    if builtins.isString v && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+(-.*)?" v != null then
      v
    else
      null;

  # `rustc -vV`'s release, LLVM version and major, and whether it takes
  # `--remap-path-scope`, as { release; llvmVersion; llvmMajor;
  # remapPathScope; }.
  probe =
    {
      pkgs,
      rustc,
      nixFeatures ? featureGates.standalone { },
    }:
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
            llvmVersion=$(sed -n 's/^LLVM version: \([0-9][0-9.]*\).*/\1/p' vv)
            llvm=''${llvmVersion%%.*}
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
            printf '{"release":"%s","llvmVersion":"%s","llvmMajor":%s,"remapPathScope":%s}' "$release" "$llvmVersion" "$llvm" "$scope" > $out
          '';
    in
    builtins.fromJSON (
      featureGates.readOutput nixFeatures "probing `${rustc}/bin/rustc -vV` (lib/toolchain-facts.nix)" out
    );

  # `cargo -V`'s release, as { release; }.
  probeCargo =
    {
      pkgs,
      cargo,
      nixFeatures ? featureGates.standalone { },
    }:
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
    builtins.fromJSON (
      featureGates.readOutput nixFeatures "probing `${cargo}/bin/cargo -V` (lib/toolchain-facts.nix)" out
    );

  # Whether `of` may probe: a release from `version` and the LLVM major
  # from `llvmPackages` or the table leave nothing to ask. Lazy reads
  # count, as a preset may read `llvmMajor`.
  mayProbe =
    {
      rustc,
      cargo ? null,
    }:
    let
      release = releaseOf rustc;
    in
    release == null
    || (!(rustc ? llvmPackages) && llvmVersions.lookup release == null)
    || (cargo != null && releaseOf cargo == null);

  # The facts `of` takes as overrides.
  factNames = [
    "llvmMajor"
    "llvmPackages"
    "bundledLld"
    "wasiSdkVersion"
    "capabilities"
  ];

  of =
    {
      pkgs,
      rustc,
      cargo ? null,
      facts ? { },
      capabilities ? { },
      nixFeatures ? featureGates.standalone { },
    }:
    let
      unknownFacts = lib.subtractLists factNames (lib.attrNames facts);
      given = lib.filterAttrs (_: v: v != null) (removeAttrs facts [ "capabilities" ]);
      givenCapabilities = lib.filterAttrs (_: v: v != null) (
        (if facts.capabilities or null == null then { } else facts.capabilities) // capabilities
      );
      probed = probe { inherit pkgs rustc nixFeatures; };
      rustcRelease = releaseOf rustc;
      version = if rustcRelease != null then rustcRelease else probed.release;
      fromTable = if rustcRelease != null then llvmVersions.lookup rustcRelease else null;
      cargoVersion =
        if cargo == null then
          throw "breakbulk.toolchainFacts: the trimPaths capability needs `cargo`"
        else
          let
            r = releaseOf cargo;
          in
          if r != null then r else (probeCargo { inherit pkgs cargo nixFeatures; }).release;
      unknown = lib.subtractLists capabilityNames (lib.attrNames givenCapabilities);
      llvmMajor =
        if given ? llvmMajor then
          given.llvmMajor
        else if given ? llvmPackages then
          lib.toInt (lib.versions.major given.llvmPackages.llvm.version)
        else if rustc ? llvmPackages then
          lib.toInt (lib.versions.major rustc.llvmPackages.llvm.version)
        else if fromTable != null then
          fromTable
        else
          probed.llvmMajor;
      detected = {
        remapPathScope =
          if rustcRelease != null then
            util.rustVersion.atLeast capabilitySince.remapPathScope rustcRelease
          else
            probed.remapPathScope;
        trimPaths = util.rustVersion.atLeast capabilitySince.trimPaths cargoVersion;
      };
      result = {
        inherit version llvmMajor;
        majorMinor = util.rustVersion.majorMinor version;
        # nixpkgs' own rustc names its LLVM, which may differ from the
        # official builds' (nixpkgs' 1.99.0 used LLVM 21, rustup's 23).
        llvmVersion =
          if given ? llvmPackages then
            given.llvmPackages.llvm.version
          else if rustc ? llvmPackages then
            rustc.llvmPackages.llvm.version
          else
            probed.llvmVersion;
        llvmPackages =
          if given ? llvmPackages then
            given.llvmPackages
          else if !(given ? llvmMajor) && rustc ? llvmPackages then
            rustc.llvmPackages
          else
            llvmVersions.packagesFor {
              inherit pkgs llvmMajor;
            };
        wasiSdkVersion = given.wasiSdkVersion or (wasiSdk.versionFor version);
        bundledLld = given.bundledLld or (!(rustc ? llvmPackages));
        capabilities =
          if unknown != [ ] then
            throw "breakbulk.toolchainFacts: unknown capabilities ${lib.concatStringsSep ", " unknown}; known: ${lib.concatStringsSep ", " capabilityNames}"
          else
            detected // givenCapabilities;
      };
    in
    if unknownFacts != [ ] then
      throw "breakbulk.toolchainFacts: unknown facts ${lib.concatStringsSep ", " unknownFacts}; known: ${lib.concatStringsSep ", " factNames}"
    else
      result;

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
    mayProbe
    of
    capabilitySince
    capabilityNames
    factNames
    ;
}
