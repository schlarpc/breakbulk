# Env capture builder. Run by mkDerivation as `bash -e capture.sh`
# (we set `args` ourselves, so stdenv's setup has NOT been sourced yet).
#
# 1. Record the environment Nix gave the builder.
# 2. Source $stdenv/setup: this runs every setup hook of every input and
#    every env hook (findInputs, _activatePkgs, _addToEnv, postHook).
# 3. Record the environment again and keep what setup produced, minus
#    per-build values.
#
# `$jq` is an absolute path passed as a derivation attribute, so jq is
# never on PATH and never seen by the hooks.

"$envTool" -0 > "$NIX_BUILD_TOP/before.env"

# shellcheck disable=SC1091
source "$stdenv/setup"

"$envTool" -0 > "$NIX_BUILD_TOP/after.env"

mkdir -p "$out"

# --- Survey (spike only): state that is NOT in the exported environment ---
if [ -n "${captureSurvey:-}" ]; then
  mkdir -p "$out/survey"
  # Every shell variable, exported or not, with its attributes.
  declare -p > "$out/survey/declare-p.txt"
  # Shell variables that are set but not exported (names only).
  # (stdenv's bash has no compgen, so parse `declare -p`.)
  declare -p | grep '^declare -' | awk '$2 !~ /x/ { sub(/=.*/, "", $3); print $2, $3 }' \
    | sort -k2 > "$out/survey/unexported-vars.txt"
  # Functions defined by setup.sh and hooks.
  declare -F | sed 's/^declare -f //' | sort > "$out/survey/functions.txt"
  # Hook arrays registered by setup hooks.
  for v in envBuildBuildHooks envBuildHostHooks envBuildTargetHooks \
           envHostHostHooks envHostTargetHooks envTargetTargetHooks \
           preConfigureHooks postUnpackHooks preFixupHooks fixupOutputHooks \
           postFixupHooks unpackCmdHooks postHooks preHooks \
           pkgsBuildBuild pkgsBuildHost pkgsBuildTarget pkgsHostHost \
           pkgsHostTarget pkgsTargetTarget; do
    if declare -p "$v" >/dev/null 2>&1; then
      declare -p "$v"
    fi
  done > "$out/survey/arrays.txt"
  for p in configurePhase buildPhase installPhase checkPhase; do
    echo "$p=${!p:-<unset>}"
  done > "$out/survey/phases.txt"
  cp "$NIX_BUILD_TOP/before.env" "$out/survey/before.env"
  cp "$NIX_BUILD_TOP/after.env" "$out/survey/after.env"
fi

# --- The capture itself ---
# Keep a variable when it is exported after setup and
#  - setup created or changed it, or
#  - it is a NIX_* variable (wrapper inputs such as NIX_HARDENING_ENABLE or
#    NIX_CFLAGS_LINK can arrive as derivation attributes from mkDerivation
#    or stdenv adapters, and the hooks then leave them unchanged),
# and it is not a per-build value or capture bookkeeping.
"$jq" -n -S \
  --rawfile before "$NIX_BUILD_TOP/before.env" \
  --rawfile after "$NIX_BUILD_TOP/after.env" \
  --arg outputNames "${outputs:-out}" \
  --arg seed "-frandom-seed=$(b="${out##*/}"; echo "${b:0:10}")" \
  '
  def parse: split("\u0000")
    | map(select(length > 0) | capture("^(?<k>[^=]*)=(?<v>.*)$"; "s"))
    | map({key: .k, value: .v}) | from_entries;
  ($before | parse) as $b
  | ($after | parse) as $a
  | ([
      "NIX_BUILD_TOP", "TMPDIR", "TMP", "TEMP", "TEMPDIR", "PWD", "OLDPWD",
      "SHLVL", "_", "HOME", "TERM", "NIX_LOG_FD", "NIX_BUILD_CORES",
      "NIX_STORE", "NIX_ATTRS_JSON_FILE", "NIX_ATTRS_SH_FILE",
      "NIX_NO_SELF_RPATH", "outputs", "jq", "envTool", "captureSurvey"
    ] + ($outputNames | split(" "))) as $drop
  | $a
  | with_entries(.key as $k | .value as $v | select(
      ($k | IN($drop[]) | not)
      and ($k | startswith("BASH_FUNC_") | not)
      and (($b | has($k) | not)
           or ($b[$k] != $v)
           or ($k | startswith("NIX_")))
    ))
  # reproducible-builds.sh adds -frandom-seed=<first 10 chars of $out> to
  # NIX_CFLAGS_COMPILE (and the bindgen hook copies it). That is the
  # identity of the capture, not of the unit: remove it everywhere.
  | map_values(gsub(" ?" + $seed; ""))
  ' > "$out/env.json"
