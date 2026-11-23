# How a target's test binaries run ("Tests as products" in
# docs/src/explanation/products.md), from its traits: one function, called
# by the presets that have no runner of their own, as the linker choice is
# (./linker.nix). A preset that knows its runner (wasmWeb's
# wasm-bindgen-test-runner, wasm32 core modules' wasmtime, linuxPortable's
# loader) calls `breakbulk.runners` itself. `targets.<t>.runner` and
# `testSystem` override either like any preset field.
#
#   runnerKind { traits; canExecute; nativeBuilder ? false; } -> a kind name
#   chooseRunner { pkgs; traits; canExecute; … }             -> { runner; testSystem; }
#
# `runnerKind` is the decision, from the target's traits
# (lib/target-traits.nix), whether the build machine can execute the
# target's programs (`canExecute`) and whether a native builder takes the
# tests (`nativeBuilder`):
#
#   kind              when                              runs tests
#   wine              isWindows, arch x86_64 or i686    wine, prefix in $TMPDIR
#   wasmtime          isWasi                            wasmtime
#   adb               isAndroid                         on a device or emulator through
#                                                       adb, outside the sandbox only
#                                                       (presets.android sets
#                                                       canRunTests false)
#   native            canExecute                        directly
#   native-builder    nativeBuilder                     directly, on a builder of
#                                                       the target's system (testSystem)
#   qemu-user         isLinux                           qemu-user
#   none              otherwise                         nowhere: runner `false`; the
#                                                       runs fail naming the options,
#                                                       and are not in repo.checks
#
# How a test process finds shared libraries under a runner is the
# runner's (a record's `dylibPath`) or the traits' (`testRuns.dylibPathOf`).
{
  lib,
  runners,
}:
let
  runnerKind =
    {
      traits,
      canExecute,
      nativeBuilder ? false,
    }:
    if traits.isWindows then
      (
        if
          lib.elem traits.arch [
            "x86_64"
            "i686"
          ]
        then
          "wine"
        else
          "none"
      )
    else if traits.isWasm then
      (if traits.isWasi then "wasmtime" else "none")
    # Before `canExecute`: an Android program needs Android's userland
    # (its loader, bionic), which no Linux machine has.
    else if traits.isAndroid then
      "adb"
    else if canExecute then
      "native"
    else if nativeBuilder then
      "native-builder"
    else if traits.isLinux then
      "qemu-user"
    else
      "none";

  direct = {
    runner = null;
    testSystem = null;
  };

  chooseRunner =
    {
      # The preset's package set; runners run on its build platform.
      pkgs,
      traits,
      # Whether the build machine runs the target's programs directly.
      canExecute,
      nativeBuilder ? false,
      # The target's nixpkgs platform (native-builder's system).
      hostPlatform ? null,
      # wine: the wine package.
      wine ? pkgs.wineWow64Packages.minimal,
      # wasmtime: the wasmtime package.
      wasmtime ? pkgs.buildPackages.wasmtime,
      # adb: the package with bin/adb, and directories of shared
      # libraries every program gets on the device.
      adb ? pkgs.buildPackages.android-tools,
      adbLibraries ? [ ],
    }:
    let
      bp = pkgs.buildPackages;
      kind = runnerKind {
        inherit
          traits
          canExecute
          nativeBuilder
          ;
      };
    in
    {
      native = direct;
      none = direct // {
        runner = false;
      };
      native-builder = direct // {
        testSystem = hostPlatform.system;
      };
      qemu-user = direct // {
        runner = runners.qemuUser {
          pkgs = bp;
          arch = traits.qemuArch;
        };
      };
      wine = direct // {
        runner = runners.wine {
          pkgs = bp;
          inherit wine;
        };
      };
      adb = direct // {
        runner = runners.adb {
          pkgs = bp;
          inherit adb;
          libraries = adbLibraries;
        };
      };
      wasmtime = direct // {
        runner = runners.wasmtime {
          pkgs = bp;
          inherit wasmtime;
        };
      };
    }
    .${kind};
in
{
  inherit runnerKind chooseRunner;
}
