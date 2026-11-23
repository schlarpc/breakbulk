# wasm32-wasip2: std programs and libraries linked straight to
# components by rustc's own `wasm-component-ld` (the linker rustc's target
# spec names, shipped in the toolchain's lib/rustlib/<host>/bin), with the
# version-matched nixpkgs `wasm-ld` underneath instead of rustup's rust-lld
# (./linker.nix, kind wasm-component-ld). Tests run under wasmtime.
#
#   targets.wasm32-wasip2.preset = breakbulk.presets.wasmComponent { withC = true; };
#
# withC = true: C code compiles against the headers of the wasi-sdk
# release whose wasi-libc the Rust toolchain bundles: one
# wasi-libc version for std, the C code and the library linked. rustc links
# libc.a and the crt1 objects from its own "self-contained" directory as
# usual; breakbulk adds no library path and swaps no objects. The sysroot
# is a fixed-output download of that wasi-sdk release's sysroot
# (lib/wasi-sdk.nix: a table from Rust release to wasi-sdk release, checked
# byte for byte against the toolchains' libc.a). A Rust release the table
# does not know is an evaluation error; set the workspace's
# `toolchain.facts.wasiSdkVersion` (a release the table has a hash for),
# or pass `wasiSdk` (a sysroot directory) to override.
{
  lib,
  wasmCommon,
  wasiSdkLib,
  chooseRunner,
  guard,
}:
{
  pkgs,
  triple,
  traits,
  withC ? false,
  facts,
  wasiSdk ? wasiSdkLib.sysrootFor {
    inherit pkgs;
    version = facts.wasiSdkVersion;
  },
  wasmtime ? pkgs.buildPackages.wasmtime,
  ...
}@args:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  inc = "-isystem ${wasiSdk}/include/${triple}";
  common = wasmCommon args;
in
guard traits.linksComponents
  "breakbulk.presets.wasmComponent: ${triple} does not link wasm components"
  (
    common
    // {
      runner =
        mkDefault
          (chooseRunner {
            inherit pkgs wasmtime;
            inherit traits;
            canExecute = false;
            flavor = "wasmtime";
          }).runner;
    }
    // lib.optionalAttrs withC {
      cflags = [ inc ];
      cxxflags = [ inc ];
      bindgen.extraClangArgs = [
        "--target=${triple}"
        inc
      ];
    }
  )
