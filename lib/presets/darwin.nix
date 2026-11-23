# macOS targets: {aarch64,x86_64}-apple-darwin. One preset for both kinds
# of build machine; the build machine picks the toolchain.
#
#   targets.aarch64-apple-darwin.preset = breakbulk.presets.darwin {
#     sdk = breakbulk.appleSdk { pkgs = unfreePkgs; version = "14.4"; };
#   };
#
# A Linux build machine: rustc links directly with an ld64.lld
# (./linker.nix, kinds `rust-lld` and `ld64.lld`) against the macOS SDK,
# which rustc passes as `-syslibroot` from `SDKROOT`; C code compiles with
# unwrapped clang of rustc's LLVM, against the SDK (`-isysroot`). The SDK
# is required: Apple's agreement authorizes it only on Apple-branded
# computers, so breakbulk never fetches it there by default (see
# lib/apple-sdk.nix). A Mac build machine (nixpkgs' Darwin stdenv and its
# `darwinSdkVersion` SDK) is issue #13.
#
# Shared by both:
# - `-C split-debuginfo=packed`: rustc runs dsymutil at the link and the
#   unit's `debug` output keeps the `.dSYM`. Cargo's default on Apple
#   targets is `unpacked` whenever debuginfo is on (cargo
#   core/profiles.rs), which leaves the DWARF in the object files of the
#   build directory, and in the binary only a debug map naming them.
# - MACOSX_DEPLOYMENT_TARGET for rustc and C compilers alike (cc-rs,
#   CMake, autotools): `deploymentTarget`, else rustc's own default for
#   the triple, which the target's env capture reads at build time.
# - the `adhocSign` stage after `install`, last: signing hashes the bytes
#   every earlier stage wrote, and a stage after `install` that changes
#   them must order itself before it.
# - tests: no runner unless `nativeBuilder`, which sends them to a Mac
#   (`testSystem`).
#
# Options:
#   sdk               a macOS SDK package (breakbulk.appleSdk, or any
#                     directory with the SDK's layout), or a version for
#                     breakbulk.appleSdk with this preset's `pkgs`.
#                     Required on a build machine that is not a Mac.
#   sdkVersion        the SDK's version, for a package without `version`
#   deploymentTarget  e.g. "11.0"; null: rustc's default
#   nativeBuilder     tests run on a Mac builder (testSystem)
{
  lib,
  targetTraits,
  appleSdk,
  linkers,
  chooseRunner,
  hostSpec,
  guard,
  stageHelpers,
}:
{
  pkgs,
  triple,
  traits,
  sdk ? null,
  sdkVersion ? null,
  deploymentTarget ? null,
  nativeBuilder ? false,
  linkerKind ? null,
  kinds,
  toolchain,
  facts,
  ...
}:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  onMac = pkgs.stdenv.buildPlatform.isDarwin;

  sdkPackage =
    if sdk == null then
      (
        if onMac then
          throw "breakbulk.presets.darwin: Mac build machines are not supported yet (issue #13)"
        else
          throw ''
            breakbulk.presets.darwin: building ${triple} on ${pkgs.stdenv.buildPlatform.system} needs the macOS SDK as `sdk`: a package, or a version for breakbulk.appleSdk, e.g.
              breakbulk.presets.darwin { sdk = breakbulk.appleSdk { pkgs = <nixpkgs that allows it as unfree>; version = "14.4"; }; }
            Apple's Xcode and Apple SDKs Agreement (https://www.apple.com/legal/sla/docs/xcode.pdf) authorizes the SDK only on Apple-branded computers, so breakbulk does not fetch it on another machine by default: passing it is your own licence decision.''
      )
    else if builtins.isString sdk then
      appleSdk {
        inherit pkgs;
        version = sdk;
      }
    else
      sdk;
  version = if sdkVersion != null then sdkVersion else appleSdk.versionOf sdkPackage;

  llvm = facts.llvmPackages;
  clang = llvm.clang-unwrapped;
  rustcFacts = linkers.rustcFacts { inherit pkgs facts; };

  kind = linkers.linkerKind {
    inherit triple traits;
    kind = linkerKind;
    inherit kinds;
    rustc = rustcFacts;
  };

  # The SDK's requirements (lib/apple-sdk.nix) against the linker's LLD
  # (./linker.nix): a linker without one is an error naming the ways out,
  # never a switch to the other linker kind, whose LLVM may not match
  # rustc's.
  lld = linkers.lldOf {
    inherit kind kinds llvm;
    rustc = rustcFacts;
  };
  missing = lib.filter (r: !(linkers.lldHas lld r.feature)) (appleSdk.requirementsOf version);
  checked =
    if missing == [ ] then
      true
    else
      let
        r = lib.head missing;
        f = linkers.linkerFeatures.${r.feature};
        other = if kind == "rust-lld" then "ld64.lld" else "rust-lld";
      in
      throw ''
        breakbulk.presets.darwin: the macOS SDK ${version} for ${triple} needs a linker that reads ${f.what}, which LLD reads from ${f.lld}. The linker is ${lld.name}, LLD ${lld.version}. Ways out:
          - an older SDK (before ${r.since});
          - a Rust toolchain whose LLVM is ${f.lld} or newer;
          - `targets.${triple}.linkerKind = "${other}"`, if that linker reads it.'';

  linker = linkers.chooseLinker {
    inherit
      pkgs
      triple
      traits
      facts
      llvm
      ;
    kind = linkerKind;
    inherit kinds;
  };

  # dsymutil for rustc's `.dSYM` (split-debuginfo=packed); rust-objcopy,
  # which rustc runs for `-C strip` on Apple targets (Cargo's release
  # profile strips debuginfo when it has none), from the toolchain's own
  # lib/rustlib/<host>/bin when it ships one, which rustc searches first.
  # nixpkgs' rustc ships none.
  tools = bp.runCommand "darwin-link-tools" { } ''
    mkdir -p $out/bin
    ln -s ${llvm.llvm}/bin/dsymutil $out/bin/dsymutil
    ln -s ${llvm.llvm}/bin/llvm-objcopy $out/bin/rust-objcopy
  '';

  sysrootFlags = [
    "--target=${triple}"
    "-isysroot"
    "${sdkPackage}"
  ];

  # rustc's default deployment target, exported in the target's env
  # capture (layer 2 of every target unit's environment): rustc prints
  # `MACOSX_DEPLOYMENT_TARGET=<version>`, from that variable when it is
  # set, else from its own table (rustc 1.99). Read at build time rather
  # than copied into breakbulk, where the table would drift from rustc's.
  captureStdenv = pkgs.stdenvAdapters.addAttrsToDerivation {
    preHook = ''
      MACOSX_DEPLOYMENT_TARGET=$(${toolchain.rustc}/bin/rustc --print deployment-target --target ${triple})
      export MACOSX_DEPLOYMENT_TARGET=''${MACOSX_DEPLOYMENT_TARGET#MACOSX_DEPLOYMENT_TARGET=}
    '';
  } pkgs.stdenv;

  r = chooseRunner {
    inherit pkgs traits nativeBuilder;
    canExecute = false;
    hostPlatform = targetTraits.nixpkgsPlatform traits;
  };
in
guard (traits.isApple && traits.os == "macos")
  "breakbulk.presets.darwin: `${triple}` is not a macOS target"
  (
    guard (!onMac) "breakbulk.presets.darwin: Mac build machines are not supported yet (issue #13)" (
      guard checked "" (
        {
          packageSet = mkDefault null;
          linker = mkDefault linker;
          # Unwrapped: nixpkgs has no Linux-to-Darwin cross C toolchain (its
          # cctools does not evaluate for a Linux host), and a wrapped clang
          # would add the build machine's own flags.
          cc = mkDefault "${clang}/bin/clang";
          cxx = mkDefault "${clang}/bin/clang++";
          ar = mkDefault "${llvm.llvm}/bin/llvm-ar";
          cflags = sysrootFlags;
          cxxflags = sysrootFlags;
          bindgen.extraClangArgs = sysrootFlags;
          rustflags = [
            "-C"
            "split-debuginfo=packed"
          ];
          env = lib.mapAttrs (_: mkDefault) (
            {
              SDKROOT = "${sdkPackage}";
              LIBCLANG_PATH = "${lib.getLib llvm.libclang}/lib";
              PATH = "${tools}/bin";
            }
            // lib.optionalAttrs (deploymentTarget != null) {
              MACOSX_DEPLOYMENT_TARGET = deploymentTarget;
            }
          );
          stages.adhocSign = {
            after = mkDefault "install";
            run = mkDefault stageHelpers.adhocSign;
          };
          runner = mkDefault r.runner;
          testSystem = mkDefault r.testSystem;
          host = hostSpec {
            inherit
              pkgs
              facts
              triple
              linkerKind
              kinds
              ;
          };
        }
        # The capture's stdenv is the build machine's: the target has no package
        # set.
        // lib.optionalAttrs (deploymentTarget == null) {
          stdenv = mkDefault captureStdenv;
        }
      )
    )
  )
