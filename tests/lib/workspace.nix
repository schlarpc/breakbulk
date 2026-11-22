# mkWorkspace (lib/workspace.nix), the function mkRepository calls once per
# workspace, triple and variant, for tests that drive it directly:
#
#   mkWorkspace = import ../lib/workspace.nix { inherit lib breakbulk; };
#   ws = mkWorkspace pkgs { root; tools; name; ... };
#
# It is not part of breakbulk's library. It is built from the parts of
# `breakbulk` that lib/default.nix builds it from, not from a second import
# of lib/, so its derivations are the ones mkRepository's instances get.
{ lib, breakbulk }:
import ../../lib/workspace.nix {
  inherit lib;
  inherit (breakbulk)
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
    ;
  featureGates = breakbulk.nixFeatures;
  targetTraitsLib = breakbulk.targetTraits;
}
