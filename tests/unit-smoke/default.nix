# Nix-level smoke test of breakbulk-unit: the units of plan.json as real
# derivations, built in the sandbox with breakbulk-unit as their builder.
#
#   nix-build tests/unit-smoke -A check
#
# units.json is plan.json rendered with path tokens by the smoke test in
# crates/breakbulk-unit/tests/smoke.rs (which also checks it is current).
# This file plays the part of instantiation in IFD mode: it replaces each
# token with a store path and passes the result to `derivation`.
{
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
}:
let
  inherit (pkgs) lib;
  root = ../..;

  breakbulk-unit = pkgs.rustPlatform.buildRustPackage {
    pname = "breakbulk-unit";
    version = "0.1.0";
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/Cargo.toml")
        (root + "/Cargo.lock")
        (root + "/crates")
      ];
    };
    cargoLock.lockFile = root + "/Cargo.lock";
    cargoBuildFlags = [ "-p" "breakbulk-unit" ];
    doCheck = false;
  };

  # Both packages' source views are the fixture's repository root.
  src = builtins.path {
    path = ./fixture;
    name = "unit-smoke-source";
  };

  # Stands in for the base env capture: what rustc needs to link.
  capture = pkgs.writeText "unit-smoke-env.json" (
    builtins.toJSON {
      PATH = lib.makeBinPath [
        pkgs.stdenv.cc
        pkgs.coreutils
      ];
    }
  );

  specials = {
    src = "${src}";
    rustc = "${pkgs.rustc}/bin/rustc";
    capture = "${capture}";
  };

  spec = builtins.fromJSON (builtins.readFile ./units.json);

  resolve = r: if r ? special then specials.${r.special} else "${units.${r.unit}.${r.output}}";

  units = builtins.mapAttrs (
    id: u:
    derivation {
      name = "unit-smoke-${id}";
      system = pkgs.stdenv.buildPlatform.system;
      builder = "${breakbulk-unit}/bin/breakbulk-unit";
      args = [ "unit" ];
      inherit (u) outputs;
      BREAKBULK_UNIT = builtins.replaceStrings (map (r: r.token) u.refs) (map resolve u.refs) u.unit;
    }
  ) spec;

  app = units.c-a6654c0a89d81026;
  run = units.r-smokelib-63aa584f9c6a6c6c;
in
{
  inherit
    breakbulk-unit
    units
    src
    capture
    ;

  # Runs the binary, and fails if it references its sources or the build
  # script's OUT_DIR (path remapping covers every scope here).
  check =
    pkgs.runCommand "unit-smoke-check"
      {
        disallowedReferences = [
          src
          run.out
        ];
      }
      ''
        mkdir -p $out/bin
        cp ${app}/smokeapp-b0ba845afe70cf35 $out/bin/smokeapp
        $out/bin/smokeapp | tee $out/log
        grep -qx 'smoke ok: hello-from-build 42' $out/log
        grep -q 'smoke_cfg' ${run.flags}/directives.json
      '';
}
