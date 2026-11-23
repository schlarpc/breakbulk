# Android targets (`*-linux-android*`) with the Android NDK.
#
#   targets.aarch64-linux-android.preset = breakbulk.presets.android {
#     ndk = breakbulk.androidNdk { pkgs = unfreePkgs; version = "29.0.14206865"; };
#     apiLevel = 26;
#   };
#
# The NDK's clang compiles C and C++ and links (./linker.nix, kind `ndk`),
# for `--target=<ndkTriple><apiLevel>`: the API level picks the sysroot's
# libraries and the `__ANDROID_API__` the headers see, and is the app's
# minSdkVersion for native code. The compiler is a script named as the
# NDK's own drivers (`aarch64-linux-android26-clang`), so cc-rs passes no
# `--target` of its own, which would drop the API level; it adds the
# words of NIX_CFLAGS_COMPILE, where units put their `-ffile-prefix-map`s
# and nixpkgs' cc-wrapper reads them, so C code names no source path. The
# NDK is required: it is licensed under the Android SDK License Agreement,
# so breakbulk never fetches it on its own (lib/android-ndk.nix).
#
# Debug info: split into the `debug` output by default, as on Linux (the
# traits' `debugInfo`); `debug/lib/debug/.build-id/<xx>/<rest>.debug` is
# the `.so.dbg` Play Console takes for the library with that build ID.
#
# Tests: through adb on a device or emulator (`breakbulk.runners.adb`),
# which the Nix sandbox has none of, so `canRunTests` is false: test runs
# are not checks, and a target's test apps
# (`repo.workspaces.<ws>.target.<triple>.variants.<v>.testApps`) run them
# with a device attached.
#
# Options:
#   ndk          an NDK package (breakbulk.androidNdk, or a directory with
#                the NDK's layout and passthru `toolchain`), or a version
#                for breakbulk.androidNdk with this preset's `pkgs`.
#                Required.
#   ndkVersion   the NDK's version, for a package without `version`
#   apiLevel     the Android API level, e.g. 26; null: the NDK's oldest
#                (breakbulk.androidNdk.apiLevelsOf)
#   adb          the package with bin/adb for the runner
{
  lib,
  androidNdk,
  chooseLinker,
  chooseRunner,
  guard,
}:
{
  pkgs,
  triple,
  traits,
  ndk ? null,
  ndkVersion ? null,
  apiLevel ? null,
  adb ? pkgs.buildPackages.android-tools,
  linkerKind ? null,
  kinds,
  facts,
  ...
}:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;

  ndkPackage =
    if ndk == null then
      throw ''
        breakbulk.presets.android: building ${triple} needs the Android NDK as `ndk`: a package, or a version for breakbulk.androidNdk, e.g.
          breakbulk.presets.android { ndk = breakbulk.androidNdk { pkgs = <nixpkgs that allows it as unfree>; version = "29.0.14206865"; }; }
        The NDK is licensed under the Android Software Development Kit License Agreement (https://developer.android.com/studio/terms), so breakbulk does not fetch it by default: passing it is your own licence decision.''
    else if builtins.isString ndk then
      androidNdk {
        inherit pkgs;
        version = ndk;
      }
    else
      ndk;
  version = if ndkVersion != null then ndkVersion else androidNdk.versionOf ndkPackage;
  api =
    if apiLevel == null then
      (androidNdk.apiLevelsOf version).min
    else if builtins.isInt apiLevel then
      apiLevel
    else
      throw "breakbulk.presets.android: `apiLevel` is an integer (e.g. 26), not ${builtins.toJSON apiLevel}";
  tc = ndkPackage.toolchain or "${ndkPackage}/toolchains/llvm/prebuilt/linux-x86_64";
  target = "${traits.ndkTriple}${toString api}";

  # The compilers, named as the NDK's drivers.
  driver =
    exe:
    "${bp.writeShellScriptBin "${target}-${exe}" ''
      # shellcheck disable=SC2086
      exec ${tc}/bin/${exe} --target=${target} ''${NIX_CFLAGS_COMPILE-} "$@"
    ''}/bin/${target}-${exe}";

  linker = chooseLinker {
    inherit
      pkgs
      triple
      traits
      facts
      kinds
      ;
    kind = linkerKind;
    ndk = {
      clang = "${tc}/bin/clang";
      inherit target;
    };
  };

  r = chooseRunner {
    inherit pkgs traits adb;
    canExecute = false;
  };

  minimum = (androidNdk.apiLevelsOf version).min;
in
guard traits.isAndroid "breakbulk.presets.android: `${triple}` is not an Android target" (
  guard (api >= minimum)
    "breakbulk.presets.android: API level ${toString api} is older than NDK ${version} builds for (${toString minimum})"
    {
      packageSet = mkDefault null;
      linker = mkDefault linker;
      cc = mkDefault (driver "clang");
      cxx = mkDefault (driver "clang++");
      ar = mkDefault "${tc}/bin/llvm-ar";
      bindgen.extraClangArgs = [
        "--target=${target}"
        "--sysroot=${tc}/sysroot"
      ];
      env = lib.mapAttrs (_: mkDefault) {
        # Where build systems look for the NDK (cmake's Android toolchain
        # file, ndk-build, cargo-ndk's conventions).
        ANDROID_NDK_ROOT = "${ndkPackage}";
        ANDROID_NDK_HOME = "${ndkPackage}";
      };
      runner = mkDefault r.runner;
      # adb needs a device, which no build in the sandbox has.
      canRunTests = mkDefault false;
      testSystem = mkDefault null;
    }
)
