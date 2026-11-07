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
# Instantiation (IFD mode; no pkgs): breakbulk.instantiate { ... },
# breakbulk.predictedRoots { ... }.
# Planning and the M1 end-to-end entry:
#   breakbulk.mkTools pkgs                breakbulk's own binaries
#   breakbulk.mkPlan pkgs { ... }         the plan derivation (lib/plan.nix)
#   breakbulk.mkWorkspace pkgs { root; path; toolchain; ... }  (lib/workspace.nix)
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
in
{
  inherit
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
}
