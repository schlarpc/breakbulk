# breakbulk's evaluation-time Nix library.
#
#   breakbulk = import ./lib { inherit lib; };
#
# Pure parts (no pkgs): util, lockfile, manifest, roots, sourceViews,
# skeleton.describe. Parts that create derivations take pkgs:
#   breakbulk.mkFetch pkgs { registries; gitHashes; ... }
#   breakbulk.mkVendor pkgs { fetch; entries; ... }
#   breakbulk.mkSkeleton pkgs { root; wsDir; }
{ lib }:
let
  util = import ./util.nix { inherit lib; };
  lockfile = import ./lockfile.nix { inherit lib util; };
  manifest = import ./manifest.nix { inherit lib util; };
  roots = import ./roots.nix { inherit lib util manifest; };
  sourceViews = import ./source-views.nix { inherit lib util manifest; };
  skeleton = import ./skeleton.nix {
    inherit
      lib
      util
      manifest
      roots
      ;
  };
in
{
  inherit
    util
    lockfile
    manifest
    roots
    sourceViews
    skeleton
    ;

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

  mkSkeleton = skeleton.mkSkeleton;
}
