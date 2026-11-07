# Environment capture ("Environment capture" in docs/implementation.md;
# spike: docs/spikes/C-env-capture.md).
#
# Runs a real nixpkgs stdenv with a package's inputs and records the
# environment its setup hooks produced, as $out/env.json: a flat JSON object
# of strings, sorted by name. breakbulk-unit replays it as layer 2 of the unit
# environment contract (`envCapture` in a rendered unit names either the
# capture's output directory or its env.json).
#
#   envCapture = breakbulk.envCapture;
#
#   # The capture for one package on one platform; the base capture when
#   # the package declares no inputs.
#   envCapture.forPackage {
#     pkgs = pkgsCross.aarch64-multiplatform;   # the target package set
#     platform = "target";                      # or "host"
#     name = "openssl-sys";
#     nativeInputs = p: [ p.pkg-config ];       # tools; p = build platform's set
#     inputs = p: [ p.openssl ];                # libraries; p = the unit's platform's set
#   }
#
#   envCapture.base { inherit pkgs; platform = "host"; }
#
# Platforms. `pkgs` is always the package set of the *target* being built
# (pkgs itself for a native build, a pkgsCross set when cross compiling):
#  - platform = "target": stdenv = pkgs.stdenv; `inputs` is called with pkgs,
#    `nativeInputs` with pkgs.buildPackages.
#  - platform = "host" (build scripts, proc macros and their dependencies,
#    which run on the build machine): stdenv = pkgs.buildPackages.stdenv;
#    `inputs` is called with pkgs.buildPackages, `nativeInputs` with
#    pkgs.buildPackages.buildPackages. Libraries stay *buildInputs* of that
#    stdenv: with strictDeps, cc-wrapper, bintools-wrapper and pkg-config
#    only add flags for dependencies at host offset 0 (their env hooks are
#    registered with `addEnvHooks "$targetOffset"`), so a library passed as a
#    native input would contribute no -isystem, -L or PKG_CONFIG_PATH.
# `inputs` and `nativeInputs` are functions of a package set, so one
# declaration serves both platforms. A plain list is accepted and used as
# given; it is then the caller's job to pick packages of the right platform.
#
# A capture's name is `breakbulk-env-<name>`, plus the platform's config when
# it is cross-compiled (mkDerivation adds it), and never says host or target:
# on a native build the host and target captures of a package are one
# derivation, and so are the base captures.
#
# What is kept (verified in spike C against nixpkgs 1d060086):
#  - every variable that is exported after `source $stdenv/setup` and that
#    setup created or changed, plus every NIX_* variable (wrapper inputs such
#    as NIX_HARDENING_ENABLE for musl, or NIX_CFLAGS_LINK from stdenv
#    adapters, arrive as derivation attributes and the hooks leave them
#    unchanged). Only exported variables can reach a build script, in a live
#    stdenv as much as here, because cargo starts it as a child process.
# What is dropped:
#  - values Nix sets per build (NIX_BUILD_TOP, TMPDIR, ..., NIX_STORE): the
#    unit's own values are the right ones, and breakbulk-unit passes them on;
#  - the capture's own identity: output names and paths, its -frandom-seed
#    (setup-hooks/reproducible-builds.sh; rust-bindgen-hook.sh copies it into
#    BINDGEN_EXTRA_CLANG_ARGS), and any variable whose value contains its own
#    $out (listed in $out/dropped-self-refs.txt; e.g. gobject-introspection's
#    NIX_GOBJECT_INTROSPECTION_DEFAULT_FALLBACK_LIBPATH);
#  - SOURCE_DATE_EPOCH, which belongs to the fixed base layer;
#  - exported shell functions (BASH_FUNC_*) and the capture's bookkeeping.
# The derivation sets strictDeps (otherwise every input's bin/ is on PATH and
# flags are doubled) and NIX_NO_SELF_RPATH (otherwise NIX_LDFLAGS carries
# "-rpath <capture>/lib", and every binary a unit links gets it).
#
# What units add themselves (breakbulk-unit, env.rs): their own
# "-frandom-seed=<first 10 chars of the unit's $out basename>" at the start of
# NIX_CFLAGS_COMPILE, as reproducible-builds.sh does, and -ffile-prefix-map
# for the source paths they remap.
#
# debug = true also writes $out/debug/: the environment before and after
# setup (NUL-separated), the shell variables setup left unexported, and the
# shell functions it defined. Useful to see why a hook's effect is missing.
{ lib }:
let
  # Never part of a capture.
  dropNames = [
    # Set by Nix for every builder, per build.
    "NIX_BUILD_TOP"
    "TMPDIR"
    "TMP"
    "TEMP"
    "TEMPDIR"
    "PWD"
    "OLDPWD"
    "SHLVL"
    "_"
    "HOME"
    "TERM"
    "NIX_LOG_FD"
    "NIX_BUILD_CORES"
    "NIX_STORE"
    "NIX_ATTRS_JSON_FILE"
    "NIX_ATTRS_SH_FILE"
    # Capture bookkeeping.
    "NIX_NO_SELF_RPATH"
    "outputs"
    "jq"
    "envTool"
    "captureDebug"
    "dropNamesFile"
    # Fixed base layer, not the capture.
    "SOURCE_DATE_EPOCH"
  ];

  dropNamesFile = builtins.toFile "breakbulk-env-capture-drop.json" (builtins.toJSON dropNames);

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

    # stdenv's seed, as setup-hooks/reproducible-builds.sh computes it.
    seedPath="''${NIX_OUTPATH_USED_AS_RANDOM_SEED:-$out}"
    seedBase="''${seedPath##*/}"
    "$jq" -n -S \
      --rawfile before "$NIX_BUILD_TOP/before.env" \
      --rawfile after "$NIX_BUILD_TOP/after.env" \
      --arg outputNames "''${outputs:-out}" \
      --arg self "$out" \
      --arg seed "-frandom-seed=''${seedBase:0:10}" \
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
      # Literal removal (no regex): the seed, with the space before it.
      | map_values(split(" " + $seed) | join("") | split($seed) | join(""))
      | { env: with_entries(select(.value | contains($self) | not)),
          selfRefs: [to_entries[] | select(.value | contains($self)) | .key] }
      ' > "$NIX_BUILD_TOP/capture.json"
    "$jq" -S .env "$NIX_BUILD_TOP/capture.json" > "$out/env.json"
    "$jq" -r '.selfRefs[]' "$NIX_BUILD_TOP/capture.json" > "$out/dropped-self-refs.txt"
  '';

  pick = set: x: if builtins.isFunction x then x set else x;

  # The package sets of a platform: `host` is the set the unit's code is
  # built for, `build` the set its tools come from.
  sets =
    pkgs: platform:
    assert lib.assertOneOf "platform" platform [
      "host"
      "target"
    ];
    let
      host = if platform == "target" then pkgs else pkgs.buildPackages;
    in
    {
      inherit host;
      build = host.buildPackages;
    };

  capture =
    {
      pkgs,
      platform ? "target",
      name ? "base",
      nativeInputs ? [ ],
      inputs ? [ ],
      debug ? false,
    }:
    let
      s = sets pkgs platform;
      inherit (s.host) stdenv;
    in
    stdenv.mkDerivation {
      name = "breakbulk-env-${name}";
      nativeBuildInputs = pick s.build nativeInputs;
      buildInputs = pick s.host inputs;
      strictDeps = true;
      NIX_NO_SELF_RPATH = 1;
      args = [
        "-e"
        builderScript
      ];
      # Absolute paths of build-platform tools, never on PATH.
      jq = "${s.build.jq}/bin/jq";
      envTool = "${s.build.coreutils}/bin/env";
      captureDebug = if debug then "1" else "";
      inherit dropNamesFile;
      preferLocalBuild = true;
      allowSubstitutes = false;
      passthru = { inherit platform; };
    };

  # The capture every package without inputs gets on a platform.
  base =
    {
      pkgs,
      platform ? "target",
      debug ? false,
    }:
    capture { inherit pkgs platform debug; };

  # The capture for one (package, platform): its own when it declares
  # inputs, the platform's base capture otherwise.
  forPackage =
    {
      pkgs,
      platform ? "target",
      name,
      nativeInputs ? [ ],
      inputs ? [ ],
      debug ? false,
    }:
    let
      s = sets pkgs platform;
      empty = l: pick s.build l == [ ];
      emptyInputs = pick s.host inputs == [ ];
    in
    if empty nativeInputs && emptyInputs then
      base { inherit pkgs platform debug; }
    else
      capture {
        inherit
          pkgs
          platform
          name
          nativeInputs
          inputs
          debug
          ;
      };
in
{
  inherit
    dropNames
    capture
    base
    forPackage
    ;
}
