# breakbulk's evaluation-time Nix library.
#
#   breakbulk = import ./lib { inherit lib; };
#
# Pure parts (no pkgs): util, lockfile, manifest, roots, sourceViews,
# skeleton.describe. Parts that create derivations take pkgs:
#   breakbulk.envCapture.forPackage { pkgs; platform; name; nativeInputs; inputs; }
#   breakbulk.mkFetch pkgs { registries; gitHashes; ... }
#   breakbulk.mkVendor pkgs { fetch; entries; ... }
#   breakbulk.mkSkeleton pkgs { root; wsDir; }
#   breakbulk.xwinSdk { pkgs; crt; sdk; arches; hash; }   (unfree; FOD)
#   breakbulk.wasmBindgen.forLockfile { pkgs; lockfile; }
#   breakbulk.mkProduct { name; linked; stages; checks; target; pkgs; … }
#     (= breakbulk.stages.mkProduct; helpers in breakbulk.stageHelpers;
#     preset stage sets in breakbulk.stages.defaultStages)
# Instantiation (IFD mode; no pkgs): breakbulk.instantiate { ... },
# breakbulk.predictedRoots { ... }. Dynamic-derivation mode:
# breakbulk.dynamic.{instantiate, mkTestRuns, mkBreakbulkDrv, available}
# (lib/dynamic.nix).
# Planning and the minimal end-to-end entry:
#   breakbulk.mkTools pkgs                breakbulk's own binaries
#   breakbulk.defaultTools pkgs           the ones mkRepository uses without
#                                         `tools` (see `defaultTools` below)
#   breakbulk.mkPlan pkgs { ... }         the plan derivation (lib/plan.nix)
#   breakbulk.mkCargoEnv pkgs { ... }     the dev shell's cargo-env.json (lib/plan.nix)
#   breakbulk.mkBuildTarget pkgs { ... }  the project's build.target (lib/plan.nix)
#   breakbulk.mkWorkspace pkgs { root; path; toolchain; ... }  (lib/workspace.nix)
# The module-system entry point:
#   breakbulk.mkRepository { pkgs; root; modules; }  (lib/repository.nix)
#   breakbulk.modules           the option declarations (lib/modules)
#   breakbulk.sysDefaults       the curated -sys crate settings, by name
#   breakbulk.versionReq        Cargo version requirements (matches req ver)
#   breakbulk.flakeModule       a flake-parts module wrapping mkRepository
# Toolchains: breakbulk.presets.<name> { pkgs; triple; … } (lib/presets),
#   breakbulk.runners (lib/runners.nix), breakbulk.llvmVersions.
# Tests: breakbulk.testRuns.mkTestRuns { ... } (test runs and doctests),
#   breakbulk.testApps.mkTestApps { ... } (test apps, for `nix run`)
{
  lib,
  # breakbulk's own locked nixpkgs (the flake's `nixpkgs` input), or null
  # (`import ./lib` without a flake).
  nixpkgs ? null,
}:
let
  util = import ./util.nix { inherit lib; };
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
  inherit (import ./instantiate.nix { inherit lib; }) instantiate predictedRoots;
  wasmBindgen = import ./wasm-bindgen.nix { inherit lib lockfile; };
  stages = import ./stages.nix { inherit lib wasmBindgen targetTraits; };
  testRuns = import ./test-runs.nix {
    inherit
      lib
      stages
      util
      targetTraits
      runners
      ;
  };
  products = import ./products.nix { inherit lib stages targetTraits; };
  variants = import ./variants.nix { inherit lib util manifest; };
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
      ;
  };
  runners = import ./runners.nix { inherit lib; };
  presets = import ./presets {
    inherit
      lib
      targetTraits
      llvmVersions
      runners
      wasmBindgen
      wasiSdk
      ;
    stageHelpers = stages.helpers;
  };

  mkFetch =
    pkgs:
    import ./fetch.nix {
      inherit
        lib
        pkgs
        util
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

  # The tools mkRepository and mkWorkspace use unless given `tools` (#41):
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
  inherit (import ./plan.nix { inherit lib toolchainFacts; }) mkPlan mkCargoEnv mkBuildTarget;

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
      predictedRoots
      mkFetch
      mkVendor
      defaultTools
      mkPlan
      mkCargoEnv
      testRuns
      testApps
      dynamic
      toolchainFacts
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
      defaultTools
      mkWorkspace
      dynamic
      products
      presets
      targetTraits
      ;
    variantsLib = variants;
    breakbulkLib = self;
  };
  self = {
    inherit
      mkRepository
      instantiate
      predictedRoots
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
      mkWorkspace
      dynamic
      checkGroups
      ;

    mkSkeleton = skeleton.mkSkeleton;

    modules = import ./modules;
    # imports = [ breakbulk.lib.flakeModule ]; in a flake-parts flake.
    flakeModule = import ./modules/flake-parts.nix { inherit mkRepository; };
    sysDefaults = import ./sys-defaults.nix { inherit lib; };
    versionReq = import ./modules/version-req.nix { inherit lib; };

    xwinSdk = import ./xwin-sdk.nix { inherit lib; };

    inherit
      wasmBindgen
      stages
      testRuns
      testApps
      products
      variants
      ;

    # Toolchain presets: breakbulk.presets.{linux, linuxStatic,
    # linuxPortable, windows, wasmWeb, wasmComponent}, named for their
    # purpose, the mechanism from the triple; runners; the Rust to
    # LLVM version table; the Rust to wasi-sdk table (lib/wasi-sdk.nix).
    # Target traits (lib/target-traits.nix): `resolve { triple; traits; }`,
    # `parse`, `nativeTriple`.
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
