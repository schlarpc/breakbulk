# Environment capture (draft from spike C; see docs/spikes/C-env-capture.md).
#
# Runs a real nixpkgs stdenv with a package's inputs and records the
# environment its setup hooks produced, as $out/env.json: a flat JSON object
# of strings. breakbulk-unit replays it as layer 2 of the unit environment
# contract (fixed base < capture < Cargo's env < toolchain spec < overrides).
#
#   envCapture = import ./env-capture.nix { inherit lib; };
#   envCapture.capture {
#     pkgs = pkgsCross.aarch64-multiplatform;   # the target package set
#     platform = "target";                      # or "host"
#     nativeInputs = p: [ p.pkg-config ];       # list, or function of a package set
#     inputs = p: [ p.openssl ];
#   }
#
# platform = "target": stdenv = pkgs.stdenv; nativeInputs come from
#   pkgs.buildPackages, inputs from pkgs.
# platform = "host": stdenv = pkgs.buildPackages.stdenv; nativeInputs come
#   from pkgs.buildPackages.buildPackages, inputs from pkgs.buildPackages.
#   Libraries stay *buildInputs* of the build platform's stdenv: with
#   strictDeps, cc-wrapper, bintools-wrapper and pkg-config only add flags for
#   dependencies at host offset 0 (their env hooks are registered with
#   `addEnvHooks "$targetOffset"`), so a library passed as a native input
#   would contribute no -isystem, -L or PKG_CONFIG_PATH.
#
# What is kept (verified in spike C against nixpkgs 1d060086):
#  - every variable that is exported after `source $stdenv/setup` and that
#    setup created or changed, plus every NIX_* variable (wrapper inputs such
#    as NIX_HARDENING_ENABLE for musl or NIX_CFLAGS_LINK from stdenv adapters
#    arrive as derivation attributes and the hooks leave them unchanged).
#    Only exported variables can reach a build script, in a live stdenv as
#    much as here, because cargo starts it as a child process.
# What is dropped:
#  - values Nix sets per build (NIX_BUILD_TOP, TMPDIR, ..., NIX_STORE);
#  - the capture's own identity: output paths, its -frandom-seed, and any
#    variable whose value contains its own $out (listed in
#    $out/dropped-self-refs.txt; e.g. gobject-introspection's
#    NIX_GOBJECT_INTROSPECTION_DEFAULT_FALLBACK_LIBPATH);
#  - SOURCE_DATE_EPOCH, which belongs to the fixed base layer.
# What units must add themselves: " -frandom-seed=<first 10 chars of the
# unit's $out basename>" prepended to NIX_CFLAGS_COMPILE, as
# pkgs/build-support/setup-hooks/reproducible-builds.sh does.
{ lib }:
let
  # Never part of a capture.
  dropNames = [
    # Set by Nix for every builder, per build.
    "NIX_BUILD_TOP" "TMPDIR" "TMP" "TEMP" "TEMPDIR" "PWD" "OLDPWD" "SHLVL" "_"
    "HOME" "TERM" "NIX_LOG_FD" "NIX_BUILD_CORES" "NIX_STORE"
    "NIX_ATTRS_JSON_FILE" "NIX_ATTRS_SH_FILE"
    # Capture bookkeeping.
    "NIX_NO_SELF_RPATH" "outputs" "jq" "envTool" "captureDebug" "dropNamesFile"
    # Fixed base layer, not the capture.
    "SOURCE_DATE_EPOCH"
  ];

  builderScript = builtins.toFile "breakbulk-env-capture.sh" ''
    # Run by mkDerivation as `bash -e <this>`. stdenv's setup has not been
    # sourced yet, because the derivation sets `args` itself.
    "$envTool" -0 > "$NIX_BUILD_TOP/before.env"
    # shellcheck disable=SC1091
    source "$stdenv/setup"
    "$envTool" -0 > "$NIX_BUILD_TOP/after.env"
    mkdir -p "$out"

    if [ -n "''${captureDebug:-}" ]; then
      mkdir -p "$out/debug"
      cp "$NIX_BUILD_TOP/before.env" "$NIX_BUILD_TOP/after.env" "$out/debug/"
      declare -p | grep '^declare -' | awk '$2 !~ /x/ { sub(/=.*/, "", $3); print $2, $3 }' \
        > "$out/debug/unexported-vars.txt"
      declare -F | sed 's/^declare -f //' | sort > "$out/debug/functions.txt"
    fi

    outbase="''${out##*/}"
    "$jq" -n -S \
      --rawfile before "$NIX_BUILD_TOP/before.env" \
      --rawfile after "$NIX_BUILD_TOP/after.env" \
      --arg outputNames "''${outputs:-out}" \
      --arg self "$out" \
      --arg seed "-frandom-seed=''${outbase:0:10}" \
      --slurpfile dropNames "$dropNamesFile" \
      '
      def parse: split("\u0000")
        | map(select(length > 0) | capture("^(?<k>[^=]*)=(?<v>.*)$"; "s"))
        | map({key: .k, value: .v}) | from_entries;
      ($before | parse) as $b
      | ($dropNames[0] + ($outputNames | split(" "))) as $drop
      | ($after | parse)
      | with_entries(.key as $k | .value as $v | select(
          ($k | IN($drop[]) | not)
          and ($k | startswith("BASH_FUNC_") | not)
          and (($b | has($k) | not) or ($b[$k] != $v) or ($k | startswith("NIX_")))))
      | map_values(gsub(" ?" + $seed; ""))
      | { env: with_entries(select(.value | contains($self) | not)),
          selfRefs: [to_entries[] | select(.value | contains($self)) | .key] }
      ' > "$NIX_BUILD_TOP/capture.json"
    "$jq" -S .env "$NIX_BUILD_TOP/capture.json" > "$out/env.json"
    "$jq" -r '.selfRefs[]' "$NIX_BUILD_TOP/capture.json" > "$out/dropped-self-refs.txt"
  '';

  pick = set: x: if builtins.isFunction x then x set else x;
in
rec {
  inherit dropNames;

  capture =
    { pkgs
    , platform ? "target"
    , name ? "base"
    , nativeInputs ? [ ]
    , inputs ? [ ]
    , debug ? false
    }:
    assert lib.assertOneOf "platform" platform [ "host" "target" ];
    let
      hostSet = if platform == "target" then pkgs else pkgs.buildPackages;
      buildSet = hostSet.buildPackages;
      stdenv = hostSet.stdenv;
    in
    stdenv.mkDerivation {
      name = "breakbulk-env-${platform}-${name}";
      nativeBuildInputs = pick buildSet nativeInputs;
      buildInputs = pick hostSet inputs;
      # buildRustPackage's setting, and the cross default. Without it every
      # input's bin/ lands on PATH and env hooks run for every offset.
      strictDeps = true;
      # setup.sh would add "-rpath $out/lib" of the capture to NIX_LDFLAGS.
      NIX_NO_SELF_RPATH = 1;
      args = [ "-e" builderScript ];
      # Absolute paths of build-platform tools, never on PATH.
      jq = "${buildSet.jq}/bin/jq";
      envTool = "${buildSet.coreutils}/bin/env";
      captureDebug = if debug then "1" else "";
      dropNamesFile = builtins.toFile "breakbulk-env-capture-drop.json" (builtins.toJSON dropNames);
      preferLocalBuild = true;
      allowSubstitutes = false;
    };
}
