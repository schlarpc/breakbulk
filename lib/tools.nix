# breakbulk's own binaries, built from this repository with nixpkgs'
# rustPlatform. One derivation per binary, so a planner change does not
# change `breakbulk-unit`'s store path (though they share one source: any
# edit under crates/ still rebuilds each of them).
#
#   tools = breakbulk.mkTools pkgs;
#   tools.breakbulk-plan  tools.breakbulk-shim  tools.breakbulk-unit
#   tools.breakbulk-instantiate
{ lib }:
pkgs:
let
  root = ../.;
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/Cargo.lock")
      (root + "/crates")
    ];
  };
  build =
    pname:
    pkgs.rustPlatform.buildRustPackage {
      inherit pname src;
      version = "0.1.0";
      cargoLock.lockFile = root + "/Cargo.lock";
      cargoBuildFlags = [
        "-p"
        pname
      ];
      doCheck = false;
    };
in
lib.genAttrs [
  "breakbulk-shim"
  "breakbulk-plan"
  "breakbulk-unit"
  "breakbulk-instantiate"
] build
