# Windows through mingw-w64: {x86_64,i686}-pc-windows-gnu with
# nixpkgs' gcc mingw-w64 cross toolchains (msvcrt, the CRT Rust's own
# windows-gnu builds link: rustc_target spec/base/windows_gnu.rs passes
# -lmsvcrt), and {x86_64,aarch64}-pc-windows-gnullvm with nixpkgs'
# LLVM mingw-w64 toolchains (ucrt, clang, libunwind).
#
#   targets.x86_64-pc-windows-gnu.preset = breakbulk.presets.windows;
#
# Linker: the toolchain's C driver (rustc's windows-gnu specs link through
# a gcc-style driver), with lld of rustc's LLVM major (./linker.nix, kind
# mingw-lld; `lld` to
# replace it).
#
# crtStatic (default true): `+crt-static` links libgcc_eh and winpthread
# (gnu) or libunwind (gnullvm) statically, so the .exe needs only system
# DLLs. Without it, the .exe imports libgcc_s_seh-1.dll (or libunwind.dll)
# from the toolchain, which wine does not find.
{
  lib,
  targetPkgsFor,
  chooseLinker,
  chooseRunner,
  hostSpec,
  staticLinking,
}:
{
  pkgs,
  config,
  triple,
  traits,
  crtStatic ? true,
  linkerKind ? null,
  facts,
  lld ? null,
  wine ? pkgs.wineWow64Packages.minimal,
  ...
}:
let
  inherit (lib) mkDefault;
  # The target's package set: the default below, or the user's
  # `packageSet`.
  tp = config.packageSet;
  cc = tp.stdenv.cc;
  prefix = cc.targetPrefix;
  # The linker (./linker.nix, kind mingw-lld): the C driver with lld.
  linker = chooseLinker {
    inherit
      pkgs
      triple
      traits
      facts
      lld
      ;
    llvm = facts.llvmPackages;
    kind = linkerKind;
    packageSet = tp;
  };
in
{
  packageSet = mkDefault (targetPkgsFor pkgs traits);
  linker = mkDefault linker;
  cc = mkDefault "${cc}/bin/${prefix}cc";
  cxx = mkDefault "${cc}/bin/${prefix}c++";
  ar = mkDefault "${cc.bintools}/bin/${prefix}ar";
  rustflags =
    (staticLinking { inherit traits crtStatic; }).rustflags
    # rustc's windows-gnu spec links `-l:libpthread.a` with +crt-static;
    # nixpkgs keeps winpthreads out of the gcc toolchain.
    ++ lib.optionals (!cc.isClang) [
      "-L"
      "native=${tp.windows.pthreads}/lib"
    ];
  env = { };
  # wine for x86_64 and i686 (./runner.nix).
  runner =
    mkDefault
      (chooseRunner {
        inherit pkgs traits wine;
        canExecute = false;
      }).runner;
  testSystem = mkDefault null;
  host = hostSpec {
    inherit
      pkgs
      facts
      triple
      linkerKind
      ;
  };
}
