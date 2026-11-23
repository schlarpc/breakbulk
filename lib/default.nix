# breakbulk's evaluation-time Nix library.
#
#   breakbulk = import ./lib { inherit lib; };
#
# Pure parts (no pkgs): util, lockfile, manifest, roots, sourceViews,
# skeleton.describe. Parts that create derivations take pkgs:
#   breakbulk.envCapture.forPackage { pkgs; platform; name; nativeInputs; inputs; }
#   breakbulk.mkFetch pkgs { registries; git; crateSources; }
#   breakbulk.mkVendor pkgs { fetch; entries; ... }
#   breakbulk.mkSkeleton pkgs { root; wsDir; }
#   breakbulk.xwinSdk { pkgs; crt; sdk; arches; hash; }   (unfree; FOD)
#   breakbulk.appleSdk { pkgs; version; }   (unfree; nixpkgs' FOD)
#   breakbulk.wasmBindgen.forLockfile { pkgs; lockfile; }
#   breakbulk.mkProduct { name; linked; stages; checks; target; pkgs; … }
#     (= breakbulk.stages.mkProduct; helpers in breakbulk.stageHelpers;
#     preset stage sets in breakbulk.stages.defaultStages)
# Instantiation (IFD mode; no pkgs): breakbulk.instantiate { ... },
# breakbulk.predictedRoots { ... }, breakbulk.planRoots { ... } (the
# prediction, or the `roots` option's names). Dynamic-derivation mode:
# breakbulk.dynamic.{instantiate, mkTestRuns, mkBreakbulkDrv, available}
# (lib/dynamic.nix). The Nix features each uses, and their gates:
# breakbulk.nixFeatures (lib/nix-features.nix).
# Planning and the minimal end-to-end entry:
#   breakbulk.mkTools pkgs                breakbulk's own binaries
#   breakbulk.defaultTools pkgs           the ones mkRepository uses without
#                                         `tools` (see `defaultTools` below)
#   breakbulk.mkPlan pkgs { ... }         the plan derivation (lib/plan.nix)
#   breakbulk.mkCargoEnv pkgs { ... }     the dev shell's cargo-env.json (lib/plan.nix)
#   breakbulk.mkBuildTarget pkgs { ... }  the project's build.target (lib/plan.nix)
# The module-system entry point:
#   breakbulk.mkRepository { pkgs; root; modules; }  (lib/repository.nix)
#   breakbulk.modules           the option declarations (lib/modules)
#   breakbulk.sysDefaults       the curated -sys crate settings, by name
#   breakbulk.sysDefaultsDependents  the curated settings for a crate's
#                               dependents, by the crate's name
#   breakbulk.versionReq        Cargo version requirements (matches req ver)
#   breakbulk.whenVersion req m package settings `m` for matching versions only
#   breakbulk.acceptsFeature member f  whether `cargo -p <member> --features f`
#                               takes `f` (`member`: workspaces.<ws>.members.<name>)
#   breakbulk.packageSettings   the evaluation of package settings layers
#   breakbulk.flakeModule       a flake-parts module wrapping mkRepository
# Toolchains: breakbulk.presets.<name> { pkgs; triple; … } (lib/presets),
#   breakbulk.presetHelpers (the functions presets are built from),
#   breakbulk.runners (lib/runners.nix), breakbulk.llvmVersions.
# Tests: breakbulk.testRuns.mkTestRuns { ... } (test runs and doctests),
#   breakbulk.testApps.mkTestApps { ... } (test apps, for `nix run`),
#   breakbulk.wrappers.<name> { … } (ready-made test wrappers, lib/wrappers.nix)
{
  lib,
  # breakbulk's own locked nixpkgs (the flake's `nixpkgs` input), or null
  # (`import ./lib` without a flake).
  nixpkgs ? null,
}:
let
  util = import ./util.nix { inherit lib; };
  featureGates = import ./nix-features.nix { inherit lib; };
  checkGroups = import ./check-groups.nix { inherit lib util; };
  targetTraits = import ./target-traits.nix { inherit lib; };
  lockfile = import ./lockfile.nix { inherit lib util; };
  manifest = import ./manifest.nix { inherit lib util; };
  roots = import ./roots.nix { inherit lib util manifest; };
  sourceViews = import ./source-views.nix { inherit lib util manifest; };
  envCapture = import ./env-capture.nix { inherit lib; };
  skeleton = import ./skeleton.nix {
    inherit
      lib
      util
      manifest
      roots
      ;
  };
  inherit (import ./instantiate.nix { inherit lib featureGates util; })
    instantiate
    predictedRoots
    planRoots
    ;
  wasmBindgen = import ./wasm-bindgen.nix { inherit lib lockfile; };
  stages = import ./stages.nix {
    inherit
      lib
      util
      wasmBindgen
      targetTraits
      featureGates
      ;
  };
  testRuns = import ./test-runs.nix {
    inherit
      lib
      stages
      util
      targetTraits
      runners
      featureGates
      ;
  };
  products = import ./products.nix {
    inherit
      lib
      stages
      targetTraits
      featureGates
      ;
  };
  buildScriptPaths = import ./build-script-paths.nix { inherit lib; };
  packageSettings = import ./package-settings.nix {
    inherit lib;
    inherit (stages) helpers;
  };
  versionReq = import ./modules/version-req.nix { inherit lib; };
  variants = import ./variants.nix { inherit lib manifest; };
  testApps = import ./test-apps.nix {
    inherit lib;
    testRunsLib = testRuns;
  };
  dynamic = import ./dynamic.nix {
    inherit
      lib
      instantiate
      testRuns
      stages
      runners
      util
      featureGates
      ;
    breakbulkTraits = targetTraits;
  };
  llvmVersions = import ./llvm-versions.nix { inherit lib util toolchainFacts; };
  wasiSdk = import ./wasi-sdk.nix { inherit lib util toolchainFacts; };
  toolchainFacts = import ./toolchain-facts.nix {
    inherit
      lib
      util
      llvmVersions
      wasiSdk
      featureGates
      ;
  };
  runners = import ./runners.nix { inherit lib; };
  wrappers = import ./wrappers.nix { inherit lib util; };
  presetsLib = import ./presets {
    inherit
      lib
      util
      targetTraits
      toolchainFacts
      llvmVersions
      runners
      wasmBindgen
      wasiSdk
      appleSdk
      ;
    stageHelpers = stages.helpers;
  };
  inherit (presetsLib) presets;
  appleSdk = import ./apple-sdk.nix { inherit lib; };

  mkFetch =
    pkgs:
    import ./fetch.nix {
      inherit
        lib
        pkgs
        util
        featureGates
        lockfile
        manifest
        ;
    };

  mkVendor =
    pkgs:
    (import ./vendor.nix {
      inherit
        lib
        pkgs
        util
        lockfile
        manifest
        ;
    }).mkVendor;

  mkTools = import ./tools.nix { inherit lib; };

  # The tools mkRepository uses unless given `tools` (#41):
  # built with breakbulk's own locked nixpkgs for the build platform, so
  # they are the same store paths in every project at a given breakbulk
  # version, whatever nixpkgs the project uses (and a binary cache of them
  # works for everyone). `legacyPackages` is evaluated once per system and
  # shared by every repository in the evaluation. Without a locked
  # nixpkgs (`import ./lib`), or for a system it has no packages for, the
  # tools are built with `pkgs`, as `mkTools pkgs`. A flake consumer who
  # wants their own nixpkgs sets `inputs.breakbulk.inputs.nixpkgs.follows`,
  # or passes `tools = breakbulk.mkTools pkgs`.
  defaultTools =
    pkgs:
    let
      system = pkgs.stdenv.buildPlatform.system;
    in
    if nixpkgs != null && nixpkgs ? legacyPackages.${system} then
      mkTools nixpkgs.legacyPackages.${system}
    else
      mkTools pkgs;
  inherit (import ./plan.nix { inherit lib toolchainFacts util; })
    mkPlan
    mkCargoEnv
    mkBuildTarget
    ;

  # mkRepository's per-(workspace, target, variant) function. It is not
  # exported: its arguments are mkRepository's internals, not an interface.
  # tests/lib/workspace.nix builds it from the same parts.
  mkWorkspace = import ./workspace.nix {
    inherit
      lib
      util
      lockfile
      roots
      sourceViews
      envCapture
      skeleton
      instantiate
      planRoots
      mkFetch
      mkVendor
      defaultTools
      mkPlan
      mkCargoEnv
      testRuns
      testApps
      dynamic
      toolchainFacts
      featureGates
      packageSettings
      ;
    targetTraitsLib = targetTraits;
  };

  mkRepository = import ./repository.nix {
    inherit
      lib
      util
      lockfile
      manifest
      envCapture
      mkFetch
      mkVendor
      defaultTools
      mkWorkspace
      dynamic
      products
      buildScriptPaths
      presets
      targetTraits
      toolchainFacts
      featureGates
      ;
    variantsLib = variants;
    breakbulkLib = self;
  };
  self = {
    inherit
      mkRepository
      instantiate
      predictedRoots
      planRoots
      util
      lockfile
      manifest
      roots
      sourceViews
      skeleton
      envCapture
      mkFetch
      mkVendor
      mkTools
      defaultTools
      mkPlan
      mkCargoEnv
      mkBuildTarget
      dynamic
      checkGroups
      ;
    nixFeatures = featureGates;

    mkSkeleton = skeleton.mkSkeleton;

    modules = import ./modules;
    # imports = [ breakbulk.lib.flakeModule ]; in a flake-parts flake.
    flakeModule = import ./modules/flake-parts.nix { inherit mkRepository; };
    sysDefaults = import ./sys-defaults.nix { inherit lib; };
    sysDefaultsDependents = import ./sys-defaults-dependents.nix { inherit lib; };
    inherit versionReq packageSettings;

    # `packages.<name> = breakbulk.whenVersion ">=0.42" { … }`: package
    # settings for the locked versions that match a Cargo version
    # requirement only. Any module: the condition is on its import.
    whenVersion =
      req: module:
      if !versionReq.isReq req then
        throw "breakbulk.whenVersion: `${req}` is not a Cargo version requirement"
      else
        { package, ... }: { imports = lib.optional (versionReq.matches req package.version) module; };

    inherit (manifest) acceptsFeature;

    xwinSdk = import ./xwin-sdk.nix { inherit lib; };
    inherit appleSdk;

    inherit
      wasmBindgen
      stages
      testRuns
      testApps
      wrappers
      products
      variants
      ;

    # Toolchain presets: breakbulk.presets.{linux, linuxStatic,
    # linuxPortable, windows, darwin, wasmWeb, wasmComponent, uefi}, named for their
    # purpose, the mechanism from the triple; runners; the Rust to
    # LLVM version table; the Rust to wasi-sdk table (lib/wasi-sdk.nix).
    # The functions presets are built from: `chooseLinker`, `linkerKind`,
    # `targetPkgsFor`, ….
    # Target traits (lib/target-traits.nix): `resolve { triple; traits; }`,
    # `parse`, `nativeTriple`, `rustcTargetArg`.
    presetHelpers = presetsLib.helpers;
    inherit
      targetTraits
      presets
      runners
      llvmVersions
      wasiSdk
      toolchainFacts
      ;
    inherit (stages) mkProduct;
    stageHelpers = stages.helpers;
  };
in
self
