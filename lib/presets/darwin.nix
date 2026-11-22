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
# - `deploymentTarget`, as MACOSX_DEPLOYMENT_TARGET for rustc and C
#   compilers alike; null keeps rustc's default, which cc-rs follows.
# - the `darwin` stage preset: `adhocSign` after `install`, last.
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
#   linkerKind, rustc, llvmMajor, llvmPackages   as for the other presets
{
  lib,
  targetTraits,
  llvmVersions,
  appleSdk,
  linkers,
  chooseRunner,
  hostSpec,
}:
{
  pkgs,
  triple ? "aarch64-apple-darwin",
  traits ? targetTraits.resolve { inherit triple; },
  sdk ? null,
  sdkVersion ? null,
  deploymentTarget ? null,
  nativeBuilder ? false,
  linkerKind ? null,
  rustc ? null,
  llvmMajor ? null,
  llvmPackages ? null,
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

  llvm = llvmVersions.packagesFor {
    pkgs = bp;
    inherit rustc llvmMajor llvmPackages;
  };
  clang = llvm.clang-unwrapped;
  facts = if rustc == null then null else linkers.rustcFacts { inherit pkgs rustc; };

  kind = linkers.linkerKind {
    inherit triple traits;
    kind = linkerKind;
    rustc = facts;
  };

  # The SDK's requirements (lib/apple-sdk.nix) against the linker's LLD
  # (./linker.nix): a linker without one is an error naming the ways out,
  # never a switch to the other linker kind, whose LLVM may not match
  # rustc's.
  lld = linkers.lldOf {
    inherit kind llvm;
    rustc =
      if facts == null then
        throw "breakbulk.presets.darwin: the `rust-lld` linker's LLVM is rustc's; pass `rustc` to the preset"
      else
        facts;
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
      rustc
      llvm
      ;
    kind = linkerKind;
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

  r = chooseRunner {
    inherit pkgs traits nativeBuilder;
    canExecute = false;
    hostPlatform = lib.systems.elaborate triple;
  };
in
assert lib.assertMsg (
  traits.isApple && traits.os == "macos"
) "breakbulk.presets.darwin: `${triple}` is not a macOS target";
assert lib.assertMsg (
  !onMac
) "breakbulk.presets.darwin: Mac build machines are not supported yet (issue #13)";
assert checked;
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
  stagePreset = mkDefault "darwin";
  runner = mkDefault r.runner;
  testSystem = mkDefault r.testSystem;
  host = hostSpec {
    inherit
      pkgs
      rustc
      triple
      linkerKind
      ;
  };
}
