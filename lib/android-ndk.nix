# The Android NDK for Android targets ("Android" in
# docs/src/explanation/internals/toolchains.md).
#
#   ndk = breakbulk.androidNdk { inherit pkgs; version = "29.0.14206865"; };
#   breakbulk.androidNdk.versionOf ndk            # "29.0.14206865"
#   breakbulk.androidNdk.apiLevelsOf "29.0.14206865"  # { min = 21; }
#   ndk.toolchain   ndk.clang   ndk.sysroot
#
# `androidNdk { pkgs; version; }` is the NDK archive nixpkgs' androidenv
# pins (pkgs/development/mobile/androidenv/repo.json, `packages.ndk`, by
# its full version), unpacked, with its prebuilt LLVM toolchain patched to
# run on NixOS (autoPatchelf, as androidenv's ndk-bundle does). Only the
# NDK: not androidenv's ndk-bundle, which wraps ndk-build with a JDK and
# Python and depends on platform-tools, so admitting it as unfree takes four
# package names rather than one. The NDK runs on x86_64 Linux build machines
# (Google ships no other Linux build).
#
# The NDK is licensed under the Android Software Development Kit License
# Agreement (https://developer.android.com/studio/terms), so meta.license is
# unfree: evaluating this needs `allowUnfree`, or an `allowUnfreePredicate`
# that admits it:
#   config.allowUnfreePredicate = p: lib.getName p == "android-ndk";
# nixpkgs' androidenv asks for `config.android_sdk.accept_license` only to
# assemble a whole SDK (`androidsdk`); calling this function is the
# acceptance of the NDK's licence, as for breakbulk.xwinSdk.
#
# The version table (`apiLevels`): the oldest Android API level each NDK
# release builds for, from the release that set it (the NDK's own
# meta/platforms.json `min`). presets.android defaults its `apiLevel` to it.
{ lib }:
let
  apiLevels = [
    {
      since = "0";
      min = 16;
    }
    {
      since = "24";
      min = 19;
    }
    {
      since = "26";
      min = 21;
    }
  ];

  # { min; } for an NDK version: the last row whose `since` it reaches.
  apiLevelsOf =
    version:
    let
      rows = lib.filter (r: lib.versionAtLeast version r.since) apiLevels;
    in
    {
      inherit (lib.last rows) min;
    };

  versionOf =
    ndk:
    if builtins.isString (ndk.version or null) then
      ndk.version
    else
      throw "breakbulk: the Android NDK `${toString ndk}` has no `version`; pass `ndkVersion` (e.g. \"29.0.14206865\") to the preset with it";

  # The NDK's prebuilt toolchain directory for a build machine.
  hostTag =
    pkgs:
    let
      p = pkgs.stdenv.buildPlatform;
    in
    if p.isLinux && p.isx86_64 then
      "linux-x86_64"
    else
      throw "breakbulk.androidNdk: Google ships the NDK for x86_64 Linux build machines (and macOS and Windows), not for ${p.system}";

  fetch =
    {
      pkgs,
      version,
    }:
    let
      repo = lib.importJSON "${pkgs.path}/pkgs/development/mobile/androidenv/repo.json";
      pinned = repo.packages.ndk;
      info =
        pinned.${version}
          or (throw "breakbulk.androidNdk: nixpkgs' androidenv pins no NDK ${version}; it pins ${
            lib.concatStringsSep ", " (lib.filter (v: !lib.hasInfix "-rc" v) (lib.attrNames pinned))
          }");
      archive = lib.findFirst (
        a: a.os == "linux"
      ) (throw "breakbulk.androidNdk: NDK ${version} has no Linux archive") info.archives;
      tag = hostTag pkgs;
      bp = pkgs.buildPackages;
    in
    bp.stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "android-ndk";
      inherit version;
      # Not androidenv's fetch: it carries androidenv's unfree meta, a
      # second package name to admit.
      src = bp.fetchurl { inherit (archive) url sha1; };
      nativeBuildInputs = [
        bp.unzip
        bp.autoPatchelfHook
      ];
      buildInputs = [
        bp.zlib
        bp.libxml2
        bp.ncurses
        (lib.getLib bp.stdenv.cc.cc)
      ];
      # The toolchain's own libraries are found next to it (below); lldb's
      # Python and the like are not needed to compile and link.
      autoPatchelfIgnoreMissingDeps = [ "*" ];
      dontConfigure = true;
      dontBuild = true;
      dontStrip = true;
      dontPatchELF = true;
      # autoPatchelf runs on the host tools only (postFixup): the target
      # libraries in the sysroot are Android's and must stay as they are.
      dontAutoPatchelf = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -a ./. $out/
        rm -rf $out/tests $out/simpleperf $out/prebuilt/*/bin/gdb* $out/python-packages
        runHook postInstall
      '';
      postFixup = ''
        tc=$out/toolchains/llvm/prebuilt/${tag}
        addAutoPatchelfSearchPath $tc/lib $tc/lib64
        autoPatchelf $tc/bin $tc/lib $tc/lib64 $tc/libexec
        patchShebangs $tc/bin
      '';
      passthru = rec {
        toolchain = "${finalAttrs.finalPackage}/toolchains/llvm/prebuilt/${tag}";
        clang = "${toolchain}/bin/clang";
        sysroot = "${toolchain}/sysroot";
        apiLevels = apiLevelsOf version;
      };
      meta = {
        description = "Android NDK ${version}";
        homepage = "https://developer.android.com/ndk";
        license = lib.licenses.unfree;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = [ "x86_64-linux" ];
      };
    });
in
{
  __functor = _: fetch;
  __functionArgs = lib.functionArgs fetch;
  inherit
    apiLevels
    apiLevelsOf
    versionOf
    ;
}
