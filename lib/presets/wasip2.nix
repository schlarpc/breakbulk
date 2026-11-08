# wasm32-wasip2 (M7): std programs and libraries linked straight to
# components by rustc's own `wasm-component-ld` (the linker rustc's target
# spec names, shipped in the toolchain's lib/rustlib/<host>/bin), with the
# version-matched nixpkgs `wasm-ld` underneath instead of rustup's rust-lld
# (./linker.nix, kind wasm-component-ld). Tests run under wasmtime.
#
#   targets.wasm32-wasip2.preset = breakbulk.presets.wasip2 { inherit rustc; withC = true; };
#
# withC = true: C code compiles against the headers of the wasi-sdk
# release whose wasi-libc the Rust toolchain bundles (decision 99): one
# wasi-libc version for std, the C code and the library linked. rustc links
# libc.a and the crt1 objects from its own "self-contained" directory as
# usual; breakbulk adds no library path and swaps no objects. The sysroot
# is a fixed-output download of that wasi-sdk release's sysroot
# (lib/wasi-sdk.nix: a table from Rust release to wasi-sdk release, checked
# byte for byte against the toolchains' libc.a). A Rust release the table
# does not know is an evaluation error; pass `wasiSdkVersion` (a release the
# table has a hash for) or `wasiSdk` (a sysroot directory) to override.
{
  lib,
  wasmCommon,
  wasiSdkLib,
  runners,
}:
{
  pkgs,
  triple ? "wasm32-wasip2",
  withC ? false,
  rustc ? null,
  wasiSdkVersion ? null,
  wasiSdk ? wasiSdkLib.sysrootFor (
    {
      inherit pkgs rustc;
    }
    // lib.optionalAttrs (wasiSdkVersion != null) { version = wasiSdkVersion; }
  ),
  wasmtime ? pkgs.buildPackages.wasmtime,
  llvmMajor ? null,
  llvmPackages ? null,
  ...
}@args:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  inc = "-isystem ${wasiSdk}/include/wasm32-wasip2";
  common = wasmCommon (args // { inherit triple; });
in
assert lib.assertMsg (
  triple == "wasm32-wasip2"
) "breakbulk.presets.wasip2: ${triple} is not wasm32-wasip2";
common
// {
  stagePreset = mkDefault null;
  runner = mkDefault (
    runners.wasmtime {
      pkgs = bp;
      inherit wasmtime;
    }
  );
}
// lib.optionalAttrs withC {
  cflags = [ inc ];
  bindgen.extraClangArgs = [
    "--target=${triple}"
    inc
  ];
}
