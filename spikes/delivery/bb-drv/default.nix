{ pkgs ? import (builtins.getFlake (toString ../../..)).inputs.nixpkgs { } }:
pkgs.rustPlatform.buildRustPackage {
  pname = "bb-drv";
  version = "0";
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ];
  };
  cargoLock = {
    lockFile = ./Cargo.lock;
    allowBuiltinFetchGit = true;
  };
}
