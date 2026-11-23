# mkWorkspace (lib/workspace.nix), the function mkRepository calls once per
# workspace, triple and variant, for tests that drive it directly:
#
#   mkWorkspace = import ../lib/workspace.nix { inherit lib breakbulk; };
#   ws = mkWorkspace pkgs { root; tools; name; ... };
#
# It is not part of breakbulk's library. It is built from the parts of
# `breakbulk` that lib/default.nix builds it from, not from a second import
# of lib/, so its derivations are the ones mkRepository's instances get.
#
# `packages.<name>` is a settings module here, as `packages.<name>` of
# mkRepository is, evaluated alone (lib/package-settings.nix): mkWorkspace
# takes the evaluated settings, with their runs'.
{ lib, breakbulk }:
let
  mkWorkspace = import ../../lib/workspace.nix {
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
      packageSettings
      cargoCommands
      ;
    featureGates = breakbulk.nixFeatures;
    targetTraitsLib = breakbulk.targetTraits;
  };
  inherit (breakbulk) packageSettings;
in
pkgs: args:
mkWorkspace pkgs (
  args
  // lib.optionalAttrs (args ? packages) {
    packages = lib.mapAttrs (
      name: module:
      let
        e = packageSettings.evaluate {
          layers = [ { inherit module; } ];
          defaults = packageSettings.contextDefaults {
            ca = args.ca or breakbulk.nixFeatures.defaultCa;
          };
          specialArgs.package = {
            inherit name;
            version = "0.0.0";
          };
        };
      in
      e.config // { inherit (e) runs; }
    ) args.packages;
  }
)
