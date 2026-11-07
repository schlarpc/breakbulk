# What datboi2's own flake builds as packages: the datboi binary (with
# every embed), the stamped components, and the emu core.
{
  pkgs,
  lib,
  repo,
}:
let
  wasm = "wasm32-unknown-unknown";
  components = [
    "datboi-xf-cso"
    "datboi-xf-ecm"
    "datboi-xf-preflate"
    "datboi-xf-reference"
    "datboi-xf-reference-stream"
    "datboi-xf-xgd1-prng"
    "datboi-ex-unrar"
    "datboi-ex-7z"
  ];
  transforms = pkgs.symlinkJoin {
    name = "datboi-transforms";
    paths = map (c: repo.workspaces.${c}.target.${wasm}.packages.${c}) components;
  };
in
{
  inherit transforms;
  datboi = repo.workspaces.host.packages.datboi;
  emu-ds = repo.workspaces.emu-ds.target.${wasm}.packages.datboi-emu-ds;
  # What the flake's checks run, from repo.checks: the host workspace's
  # products, tests and clippy, and the components' native unit tests
  # (nextest there, so no doctests; doctests are in `doctests`). Left out:
  # the components' wasm32 test runs and doctests, which repo.checks has
  # because every target of a workspace gets test plans.
  ci =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      keep =
        n:
        !(lib.hasSuffix "/doctest" n)
        && (lib.hasPrefix "host/" n || (lib.hasInfix "/${native}/" n && lib.hasInfix "/test-" n));
    in
    pkgs.linkFarm "datboi2-ci" (
      lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) (
        lib.filterAttrs (n: _: keep n) repo.checks
      )
      // {
        inherit transforms;
        emu-ds = repo.workspaces.emu-ds.target.${wasm}.packages.datboi-emu-ds;
      }
    );
  doctests = pkgs.linkFarm "datboi2-doctests" (
    lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) (
      lib.filterAttrs (n: _: lib.hasPrefix "host/" n && lib.hasSuffix "/doctest" n) repo.checks
    )
  );
  build = pkgs.linkFarm "datboi2-build" {
    datboi = repo.workspaces.host.packages.datboi;
    inherit transforms;
    emu-ds = repo.workspaces.emu-ds.target.${wasm}.packages.datboi-emu-ds;
  };
}
