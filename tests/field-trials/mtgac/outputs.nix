# What mtgac's flake builds and checks: the mtgac binary, the wasm gate,
# the UI's wasm, the Windows binary; clippy natively.
{
  pkgs,
  lib,
  repo,
}:
let
  ws = repo.workspaces.main;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  wasm = ws.target.wasm32-unknown-unknown;
  win = ws.target.x86_64-pc-windows-msvc;
in
{
  mtgac = ws.packages.mtgac;
  ui = wasm.packages.mtgac-ui;
  wasm-check = wasm.variants.check.check;
  clippy = ws.target.${native}.variants.clippy.check;
  windows = win.packages.mtgac;
  build = pkgs.linkFarm "mtgac-build" {
    mtgac = ws.packages.mtgac;
    ui = wasm.packages.mtgac-ui;
    windows = win.packages.mtgac;
  };
}
