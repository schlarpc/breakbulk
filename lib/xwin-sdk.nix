# The MSVC CRT and Windows SDK for cross-compiling to *-pc-windows-msvc
# ("Windows msvc" in docs/src/explanation/targets.md and
# docs/src/explanation/internals/toolchains.md).
#
#   sdk = breakbulk.xwinSdk {
#     inherit pkgs;              # the build machine's package set
#     manifestVersion = 17;      # Visual Studio major version (xwin --manifest-version)
#     crt = "14.44.17.14";       # xwin --crt-version
#     sdk = "10.0.26100";        # xwin --sdk-version
#     arches = [ "x86_64" "aarch64" ];
#     hash = "sha256-…";
#   };
#
# A fixed-output derivation that runs `xwin download/unpack/splat` (the xwin
# in nixpkgs) and keeps xwin's splat layout, including the symlinks xwin adds
# so that case-insensitive spellings resolve (`windows.h` -> `Windows.h`,
# `kernel32.lib` -> `Kernel32.lib`, ...):
#
#   crt/include                     CRT and C++ standard library headers
#   crt/lib/<arch>                  CRT import and static libraries
#   sdk/include/{ucrt,um,shared,winrt,cppwinrt}
#   sdk/lib/{ucrt,um}/<arch>
#
# where <arch> is xwin's (LLVM-style) name: x86, x86_64, aarch, aarch64.
#
# The download is licensed by Microsoft and not redistributable, so
# meta.license is unfree: evaluating this needs `allowUnfree`, or better an
# `allowUnfreePredicate` that admits only this derivation, e.g.
#   config.allowUnfreePredicate = p: lib.getName p == "xwin-sdk";
# `--accept-license` is passed on the caller's behalf; calling this function
# is the acceptance.
#
# Pinning. xwin reads the channel manifest https://aka.ms/vs/<v>/release/channel,
# which follows Visual Studio updates, then the package manifest it names.
# --crt-version picks the CRT component by exact version; --sdk-version picks
# the first package id that ends with the given string (e.g.
# Win11SDK_10.0.26100), whose payloads Microsoft can update within the same
# 10.0.26100 line. Every payload is checked against the sha256 in the package
# manifest. If the live manifest moves on, the output hash no longer matches
# and the build fails loudly rather than drifting. For a stronger pin, pass
# `channelManifest = pkgs.fetchurl { url = "https://download.visualstudio.microsoft.com/…/VisualStudio.17.Release.chman"; hash = …; }`
# (the URL aka.ms redirects to) and xwin reads that file instead of the
# live channel; the package manifest it names is then fixed as well.
#
# passthru gives the paths a toolchain needs, per architecture:
#   sdk.includeDirs                    list of include directories
#   sdk.libDirs.<arch>                 list of library directories
#   sdk.crtIncludeDir, sdk.sdkIncludeDir, sdk.crtLibDir.<arch>, ...
# (strings with the store path in them, so they carry the dependency).
{ lib }:
let
  xwinArches = [
    "x86"
    "x86_64"
    "aarch"
    "aarch64"
  ];
in
{
  pkgs,
  manifestVersion ? 17,
  crt,
  sdk,
  arch ? "x86_64",
  arches ? [ arch ],
  # Visual Studio channel: "release" (xwin's default) or "pre".
  channel ? "release",
  # Optional pinned channel manifest file (see above). Exclusive with
  # manifestVersion/channel in xwin; when set those two are ignored.
  channelManifest ? null,
  # Extra `xwin` global flags (e.g. [ "--include-atl" ]) and `splat` flags.
  extraArgs ? [ ],
  extraSplatArgs ? [ ],
  hash,
}:
let
  bad = lib.subtractLists xwinArches arches;
  archesChecked =
    if arches == [ ] then
      throw "breakbulk.xwinSdk: `arches` is empty"
    else if bad != [ ] then
      throw "breakbulk.xwinSdk: unknown arch ${lib.concatStringsSep ", " bad}; xwin knows ${lib.concatStringsSep ", " xwinArches}"
    else
      arches;

  manifestArgs =
    if channelManifest != null then
      [
        "--manifest"
        "${channelManifest}"
      ]
    else
      [
        "--manifest-version"
        (toString manifestVersion)
        "--channel"
        channel
      ];

  args = [
    "--accept-license"
    "--log-level"
    "warn"
    "--http-retry"
    "5"
    "--timeout"
    "600s"
    "--crt-version"
    crt
    "--sdk-version"
    sdk
    "--arch"
    (lib.concatStringsSep "," archesChecked)
  ]
  ++ manifestArgs
  ++ extraArgs;

  # Paths are built from the output path so they carry the store reference.
  paths =
    out:
    let
      forArch = f: lib.genAttrs archesChecked f;
      crtIncludeDir = "${out}/crt/include";
      sdkIncludeDir = "${out}/sdk/include";
      sdkIncludeDirs = map (d: "${sdkIncludeDir}/${d}") [
        "ucrt"
        "um"
        "shared"
        "winrt"
        "cppwinrt"
      ];
      crtLibDir = forArch (a: "${out}/crt/lib/${a}");
      sdkLibDirs = forArch (a: [
        "${out}/sdk/lib/um/${a}"
        "${out}/sdk/lib/ucrt/${a}"
      ]);
    in
    {
      inherit
        crtIncludeDir
        sdkIncludeDir
        sdkIncludeDirs
        crtLibDir
        sdkLibDirs
        ;
      includeDirs = [ crtIncludeDir ] ++ sdkIncludeDirs;
      libDirs = forArch (a: [ crtLibDir.${a} ] ++ sdkLibDirs.${a});
    };
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "xwin-sdk";
  version = "${crt}-${sdk}";

  nativeBuildInputs = [
    pkgs.xwin
    pkgs.cacert
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;

  # Splat inside $TMPDIR (xwin renames unpacked files into place, which
  # fails across filesystems), then copy into the store.
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    xwin --cache-dir "$TMPDIR/xwin-cache" ${lib.escapeShellArgs args} splat \
      --output "$TMPDIR/splat" ${lib.escapeShellArgs extraSplatArgs} </dev/null
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -a "$TMPDIR/splat" "$out"
    runHook postInstall
  '';

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = hash;

  passthru = {
    inherit
      crt
      sdk
      manifestVersion
      ;
    arches = archesChecked;
  }
  // paths finalAttrs.finalPackage.outPath;

  meta = {
    description = "MSVC CRT ${crt} and Windows SDK ${sdk} (xwin splat)";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = pkgs.xwin.meta.platforms or lib.platforms.unix;
  };
})
