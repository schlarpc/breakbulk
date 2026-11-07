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
# breakbulk.predictedRoots { ... }.
# Planning and the M1 end-to-end entry:
#   breakbulk.mkTools pkgs                breakbulk's own binaries
#   breakbulk.mkPlan pkgs { ... }         the plan derivation (lib/plan.nix)
#   breakbulk.mkWorkspace pkgs { root; path; toolchain; ... }  (lib/workspace.nix)
# The module-system entry point (M2):
#   breakbulk.mkRepository { pkgs; root; modules; }  (lib/repository.nix)
#   breakbulk.modules           the option declarations (lib/modules)
#   breakbulk.sysDefaults       the curated -sys crate module
#   breakbulk.versionReq        Cargo version requirements (matches req ver)
#   breakbulk.flakeModule       a flake-parts module wrapping mkRepository
{ lib }:
let
  util = import ./util.nix { inherit lib; };
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
  stages = import ./stages.nix { inherit lib wasmBindgen; };

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
  inherit (import ./plan.nix { inherit lib; }) mkPlan;

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
      mkTools
      mkPlan
      ;
  };

  mkRepository = import ./repository.nix {
    inherit
      lib
      util
      lockfile
      manifest
      envCapture
      mkFetch
      mkTools
      mkWorkspace
      ;
  };
in
{
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
    mkPlan
    mkWorkspace
    ;

  mkSkeleton = skeleton.mkSkeleton;

  modules = import ./modules;
  # imports = [ breakbulk.lib.flakeModule ]; in a flake-parts flake.
  flakeModule = import ./modules/flake-parts.nix { inherit mkRepository; };
  sysDefaults = ./sys-defaults.nix;
  versionReq = import ./modules/version-req.nix { inherit lib; };

  xwinSdk = import ./xwin-sdk.nix { inherit lib; };

  inherit wasmBindgen stages;
  inherit (stages) mkProduct;
  stageHelpers = stages.helpers;
}
