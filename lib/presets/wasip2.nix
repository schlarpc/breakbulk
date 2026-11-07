# wasm32-wasip2 (M7): std programs and libraries linked straight to
# components by rustc's own `wasm-component-ld` (the linker rustc's target
# spec names, shipped in the toolchain's lib/rustlib/<host>/bin), with the
# version-matched nixpkgs `wasm-ld` underneath instead of rustup's rust-lld.
# Tests run under wasmtime.
#
#   targets.wasm32-wasip2.preset = breakbulk.presets.wasip2 { inherit rustc; withC = true; };
#
# withC = true: C code compiles against nixpkgs' wasi-libc built for
# wasm32-wasip2 (`wasilibc`), and the link uses that same build's libc.a
# and crt1 objects, so C headers and library match. rustc's toolchain
# bundles its own wasi-libc (wasi-sdk 33 for Rust 1.99, nixpkgs has 32),
# found through rustc's "self-contained" directory. `-C
# link-self-contained=no` is NOT the way to turn it off on this target: it
# also drops the crt1-command.o rustc adds to executables (wasm32-wasip2's
# spec only lists it under the self-contained objects), and the link fails
# with "entry symbol not defined: _start". Instead:
#   - `-L native=<wasilibc>/lib/wasm32-wasip2` comes before rustc's
#     self-contained directory on the search path (rustc_codegen_ssa
#     link.rs, walk_native_lib_search_dirs: user `-L` first, the
#     self-contained fallback last), so `-lc` (and libm, …) resolve to
#     nixpkgs' archives;
#   - the linker wrapper swaps rustc's self-contained crt1-command.o and
#     crt1-reactor.o for wasilibc's.
# Only libunwind.a (panic=unwind with exception handling, which needs
# build-std) still comes from rustc's directory.
{
  lib,
  wasmCommon,
  runners,
}:
let
  # nixpkgs' wasi-libc (pkgsCross.wasi32 builds it for wasm32-wasip1) built
  # for wasm32-wasip2: static archives only, since shared ones would need
  # clang to link with wasm-component-ld.
  wasilibcFor =
    pkgs:
    pkgs.pkgsCross.wasi32.wasilibc.overrideAttrs (o: {
      pname = "wasilibc-wasip2";
      cmakeFlags =
        map (
          f: if lib.hasPrefix "-DTARGET_TRIPLE" f then "-DTARGET_TRIPLE:STRING=wasm32-wasip2" else f
        ) o.cmakeFlags
        ++ [ "-DBUILD_SHARED=OFF" ];
    });
in
{
  pkgs,
  triple ? "wasm32-wasip2",
  withC ? false,
  wasilibc ? wasilibcFor pkgs,
  wasmtime ? pkgs.buildPackages.wasmtime,
  rustc ? null,
  llvmMajor ? null,
  llvmPackages ? null,
  ...
}@args:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  libDir = "${wasilibc}/lib/wasm32-wasip2";
  inc = "-isystem ${lib.getDev wasilibc}/include/wasm32-wasip2";
  # The linker (./linker.nix, kind wasm-component-ld): rustc's
  # wasm-component-ld over the version-matched wasm-ld.
  common = wasmCommon (
    args
    // {
      inherit triple;
      linkerArgs = lib.optionalAttrs withC { wasip2CrtDir = libDir; };
    }
  );
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
  rustflags = [
    "-L"
    "native=${libDir}"
  ];
  cflags = [ inc ];
  bindgen.extraClangArgs = [
    "--target=${triple}"
    inc
  ];
}
