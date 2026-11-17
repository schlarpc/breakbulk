# The macOS SDK for Apple targets ("Apple targets" in
# docs/src/explanation/internals/toolchains.md).
#
#   sdk = breakbulk.appleSdk { inherit pkgs; version = "14.4"; };
#   breakbulk.appleSdk.versionOf sdk          # "14.4"
#   breakbulk.appleSdk.requirementsOf "27.0"  # [ { feature = "arm64e.x1"; … } ]
#
# `appleSdk { pkgs; version; }` is nixpkgs' own fixed-output fetch of
# Apple's Command Line Tools SDK package (pkgs/by-name/ap/apple-sdk:
# common/fetch-sdk.nix, metadata/versions.json), the same store path
# nixpkgs' Darwin stdenv builds its `apple-sdk` from, with
# `meta.license` set to unfree: nixpkgs sets none. Apple's "Xcode and
# Apple SDKs Agreement" authorizes the SDK only on Apple-branded computers
# (https://www.apple.com/legal/sla/docs/xcode.pdf, §2.2.A, §2.5, §2.7), so
# evaluating it needs `allowUnfree`, or an `allowUnfreePredicate` that
# admits it:
#   config.allowUnfreePredicate = p: lib.getName p == "macOS-SDK";
# Calling this function on a machine that is not a Mac is the caller's own
# licence decision; breakbulk never calls it on its own there.
#
# `version` is one nixpkgs pins (metadata/versions.json, by major: 14.4,
# 15.5, 26.5, 27.0 at the time of writing); a different minor of a pinned
# major is an error rather than a silent substitute.
#
# The SDK table (`requirements`): what an SDK version asks of its linker,
# one row per requirement Apple introduced, from the first SDK version
# that has it. The linker side, which linker meets which requirement, is
# lib/presets/linker.nix's `linkerFeatures`.
{ lib }:
let
  requirements = [
    {
      # The SDK's `.tbd` stub files list `arm64e.x1-macos` and
      # `arm64e.x1-maccatalyst` targets, a CPU subtype an older LLD rejects
      # ("could not load TAPI file … unknown target").
      since = "27.0";
      feature = "arm64e.x1";
    }
  ];

  requirementsOf = version: lib.filter (r: lib.versionAtLeast version r.since) requirements;

  # The SDK version of an SDK package: its `version` (nixpkgs' fetch and
  # `apple-sdk` both have one), or `sdkVersion` given with it.
  versionOf =
    sdk:
    if builtins.isString (sdk.version or null) then
      sdk.version
    else
      throw "breakbulk: the macOS SDK `${toString sdk}` has no `version`; pass `sdkVersion` (e.g. \"14.4\") to the preset with it";

  fetch =
    {
      pkgs,
      version,
    }:
    let
      dir = "${pkgs.path}/pkgs/by-name/ap/apple-sdk";
      pinned = builtins.fromJSON (builtins.readFile "${dir}/metadata/versions.json");
      major = lib.versions.major version;
      info =
        pinned.${major}
          or (throw "breakbulk.appleSdk: nixpkgs pins no macOS SDK ${major}; it pins ${
            lib.concatMapStringsSep ", " (m: pinned.${m}.version) (lib.attrNames pinned)
          }");
      fetchSdk = pkgs.callPackage "${dir}/common/fetch-sdk.nix" { };
    in
    if info.version != version then
      throw "breakbulk.appleSdk: nixpkgs pins macOS SDK ${info.version}, not ${version}"
    else
      (fetchSdk info).overrideAttrs (old: {
        meta = (old.meta or { }) // {
          description = "Apple's macOS SDK ${version} (Command Line Tools)";
          license = lib.licenses.unfree;
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };
      });
in
{
  __functor = _: fetch;
  __functionArgs = lib.functionArgs fetch;
  inherit
    requirements
    requirementsOf
    versionOf
    ;
}
