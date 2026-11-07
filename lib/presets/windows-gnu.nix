# Windows through mingw-w64 (M7): {x86_64,i686}-pc-windows-gnu with
# nixpkgs' gcc mingw-w64 cross toolchains (msvcrt, the CRT Rust's own
# windows-gnu builds link: rustc_target spec/base/windows_gnu.rs passes
# -lmsvcrt), and {x86_64,aarch64}-pc-windows-gnullvm with nixpkgs'
# LLVM mingw-w64 toolchains (ucrt, clang, libunwind).
#
#   targets.x86_64-pc-windows-gnu.preset = breakbulk.presets.windowsGnu;
#
# Linker: the toolchain's C driver (rustc's windows-gnu specs link through
# a gcc-style driver), with `-fuse-ld=lld`; lld's GNU driver switches to
# its MinGW driver for PE emulations (lld/tools/lld/lld.cpp). The driver
# finds `ld.lld` through `-B`. `--no-insert-timestamp` keeps the PE header's
# time stamp at 0: lld's MinGW driver leaves it to lld-link, which stamps
# the current time (lld/MinGW/Driver.cpp, OPT_no_insert_timestamp).
#
# crtStatic (default true): `+crt-static` links libgcc_eh and winpthread
# (gnu) or libunwind (gnullvm) statically, so the .exe needs only system
# DLLs. Without it, the .exe imports libgcc_s_seh-1.dll (or libunwind.dll)
# from the toolchain, which wine does not find.
{
  lib,
  driverWrapper,
  hostSpec,
  runners,
}:
let
  # nixpkgs' cross package set for each Rust triple.
  packageSetFor =
    pkgs: triple:
    {
      "x86_64-pc-windows-gnu" = pkgs.pkgsCross.mingwW64;
      "i686-pc-windows-gnu" = pkgs.pkgsCross.mingw32;
      "aarch64-pc-windows-gnullvm" = pkgs.pkgsCross.ucrtAarch64;
      "x86_64-pc-windows-gnullvm" = import pkgs.path {
        localSystem = pkgs.stdenv.buildPlatform;
        crossSystem = lib.systems.examples.mingw-ucrt-x86_64-llvm;
        inherit (pkgs) overlays config;
      };
    }
    .${triple}
      or (throw "breakbulk.presets.windowsGnu: `${triple}` is not a windows-gnu or windows-gnullvm triple");
in
{
  pkgs,
  triple ? "x86_64-pc-windows-gnu",
  packageSet ? packageSetFor pkgs triple,
  crtStatic ? true,
  lld ? pkgs.buildPackages.lld,
  wine ? pkgs.wineWow64Packages.minimal,
  ...
}:
let
  inherit (lib) mkDefault;
  tp = packageSet;
  cc = tp.stdenv.cc;
  prefix = cc.targetPrefix;
  arch = lib.head (lib.splitString "-" triple);
  driver = if cc.isClang then "clang" else "gcc";
  # `ld.lld` for the driver's -B: GCC 15+ is configured with default PIE and
  # passes `-pie` to the linker for executables (its link spec:
  # `%{static|shared|r:;!no-pie:-pie}`); GNU ld takes it for PE as
  # --dynamicbase, lld's MinGW driver rejects it. lld's MinGW driver uses
  # --dynamicbase by default, and rustc passes it too, so it is dropped.
  ldLld = pkgs.buildPackages.writeShellScriptBin "ld.lld" ''
    args=()
    for a in "$@"; do
      [[ $a == -pie ]] || args+=("$a")
    done
    exec ${lld}/bin/ld.lld "''${args[@]}"
  '';
  linker = driverWrapper tp "${prefix}${driver}-lld" "${cc}/bin/${prefix}cc" (
    lib.concatStringsSep " " [
      "-fuse-ld=lld"
      "-B${ldLld}/bin"
      "-Wl,--no-insert-timestamp"
    ]
  );
in
{
  packageSet = mkDefault tp;
  linker = mkDefault linker;
  cc = mkDefault "${cc}/bin/${prefix}cc";
  cxx = mkDefault "${cc}/bin/${prefix}c++";
  ar = mkDefault "${cc.bintools}/bin/${prefix}ar";
  rustflags =
    lib.optionals crtStatic [
      "-C"
      "target-feature=+crt-static"
    ]
    # rustc's windows-gnu spec links `-l:libpthread.a` with +crt-static;
    # nixpkgs keeps winpthreads out of the gcc toolchain.
    ++ lib.optionals (!cc.isClang) [
      "-L"
      "native=${tp.windows.pthreads}/lib"
    ];
  env = { };
  runner = mkDefault (
    if
      lib.elem arch [
        "x86_64"
        "i686"
      ]
    then
      runners.wine {
        pkgs = pkgs.buildPackages;
        inherit wine;
      }
    else
      null
  );
  testSystem = mkDefault null;
  host = hostSpec pkgs;
  stagePreset = mkDefault null;
}
