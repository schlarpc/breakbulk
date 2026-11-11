# How a target's test binaries run ("Tests as products" in
# docs/src/explanation/products.md):
# one function, called by every preset, as the linker choice is
# (./linker.nix). `targets.<t>.runner` and `testSystem` override it like
# any preset field.
#
#   runnerKind { traits; canExecute; nativeBuilder ? false; flavor ? null; }
#                                                 -> a kind name
#   chooseRunner { pkgs; traits; canExecute; … }   -> { runner; testSystem; }
#
# `runnerKind` is the decision, from the target's traits
# (lib/target-traits.nix), whether the build machine can execute the
# target's programs (`canExecute`), whether a native builder takes the
# tests (`nativeBuilder`) and the preset's flavor:
#
#   kind              when                              runs tests
#   ld-so             flavor zig, canExecute            through the build machine's ld.so
#   wasm-bindgen      flavor wasm-bindgen               wasm-bindgen-test-runner (Node)
#   wasmtime          flavor wasmtime, or isWasi        wasmtime
#   wine              isWindows, arch x86_64 or i686    wine, prefix in $TMPDIR
#   native            canExecute                        directly
#   native-builder    nativeBuilder                     directly, on a builder of
#                                                       the target's system (testSystem)
#   qemu-user         isLinux                           qemu-user
#   none              otherwise                         nowhere: runners.none, which
#                                                       fails naming the options; the
#                                                       runs are not in repo.checks
#
# How a test process finds shared libraries under a runner is the runner's
# (`breakbulkDylibPath`, lib/runners.nix) or the traits'
# (`testRuns.dylibPathOf`).
{
  lib,
  runners,
  wasmBindgen,
}:
let
  runnerKind =
    {
      traits,
      canExecute,
      nativeBuilder ? false,
      flavor ? null,
    }:
    if flavor == "zig" then
      (if canExecute then "ld-so" else "none")
    else if flavor == "wasm-bindgen" || flavor == "wasmtime" then
      flavor
    else if flavor != null then
      throw "breakbulk.presets.chooseRunner: unknown runner flavor `${flavor}`"
    else if traits.isWindows then
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
    else if canExecute then
      "native"
    else if nativeBuilder then
      "native-builder"
    else if traits.isLinux then
      "qemu-user"
    else
      "none";

  none = {
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
      flavor ? null,
      # The target's nixpkgs platform (qemu-user's CPU, native-builder's
      # system).
      hostPlatform ? null,
      # wine: the wine package.
      wine ? pkgs.wineWow64Packages.minimal,
      # wasmtime: the wasmtime package.
      wasmtime ? pkgs.buildPackages.wasmtime,
      # wasm-bindgen: "node", "chromium" or "firefox".
      browser ? "node",
    }:
    let
      bp = pkgs.buildPackages;
      kind = runnerKind {
        inherit
          traits
          canExecute
          nativeBuilder
          flavor
          ;
      };
    in
    {
      native = none;
      none = none // {
        runner = runners.none {
          pkgs = bp;
          inherit (traits) triple;
        };
      };
      native-builder = none // {
        testSystem = hostPlatform.system;
      };
      qemu-user = none // {
        runner = runners.qemuUser {
          pkgs = bp;
          arch = hostPlatform.qemuArch;
        };
      };
      wine = none // {
        runner = runners.wine {
          pkgs = bp;
          inherit wine;
        };
      };
      # zig links the FHS loader path (/lib64/ld-linux-x86-64.so.2), as a
      # program for other distributions should; the Nix sandbox has none,
      # so tests run through the build machine's glibc loader, which also
      # finds its own libc.so.6.
      ld-so = none // {
        runner = bp.writeShellScript "breakbulk-runner-ld-so" ''
          exec ${pkgs.stdenv.cc.bintools.dynamicLinker} "$@"
        '';
      };
      wasmtime = none // {
        runner = runners.wasmtime {
          pkgs = bp;
          inherit wasmtime;
        };
      };
      # A function of the workspace's lockfile: the runner must be the
      # exact wasm-bindgen version.
      wasm-bindgen = none // {
        runner =
          { lockfile, ... }:
          runners.wasmBindgenTest {
            pkgs = bp;
            inherit browser;
            wasmBindgen = wasmBindgen.forLockfile {
              pkgs = bp;
              inherit lockfile;
            };
          };
      };
    }
    .${kind};
in
{
  inherit runnerKind chooseRunner;
}
