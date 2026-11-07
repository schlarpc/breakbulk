# Replay builder: a plain `bash replay.sh` derivation, no stdenv.
# Starts from the environment Nix gives every builder (NIX_BUILD_TOP, TMPDIR,
# HOME, NIX_STORE, NIX_BUILD_CORES, PATH=/path-not-set, plus this
# derivation's attributes), exports every variable from env.json, then runs
# `$replayCommand` with bash. This is the shape breakbulk-unit will have.
#
#   envJson        path to a capture's env.json
#   jq             absolute path to jq (not on PATH)
#   replayCommand  script to run
set -eu
while IFS= read -r -d '' kv; do
  export "$kv"
done < <("$jq" -j 'to_entries[] | "\(.key)=\(.value)\u0000"' "$envJson")

# The capture drops its own -frandom-seed; add this derivation's, exactly as
# pkgs/build-support/setup-hooks/reproducible-builds.sh does in a live stdenv.
outbase="${out##*/}"
export NIX_CFLAGS_COMPILE=" -frandom-seed=${outbase:0:10}${NIX_CFLAGS_COMPILE:-}"

"$SHELL" -eu "$replayCommand" > "$out" 2>&1 || { cat "$out"; exit 1; }
