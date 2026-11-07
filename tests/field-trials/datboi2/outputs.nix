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
  build = pkgs.linkFarm "datboi2-build" {
    datboi = repo.workspaces.host.packages.datboi;
    inherit transforms;
    emu-ds = repo.workspaces.emu-ds.target.${wasm}.packages.datboi-emu-ds;
  };
}
