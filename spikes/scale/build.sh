#!/usr/bin/env bash
# Build every unit of a generated plan from scratch (a fresh salt makes new
# unit derivations; tools and sources are already built), timed per unit.
#
#   spikes/scale/build.sh <generated dir> <results dir> [max-jobs] [cores]
#
# NOSUBST=1 builds with no substituters (no narinfo queries for the new
# unit outputs); the tag "-nosubst" is then added to the result names.
#
# Writes <results dir>/build-<jobs>x<cores>.json (per-derivation start/stop)
# and prints a summary. Also builds `trivial` derivations of the same count
# (bash writing one file), for the bare per-derivation cost.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(realpath "$1")
res=$(realpath -m "$2")
jobs=${3:-8}
cores=${4:-1}
mkdir -p "$res"
salt=build-$(date +%s%N)
nixf=(-f "$here" --argstr dir "$dir" --argstr salt "$salt")
opts=()
tag=$jobs"x"$cores
if [ "${NOSUBST:-}" = 1 ]; then
  opts=(--option substituters "")
  tag=$tag-nosubst
fi

# Instantiate first (writes the .drv files), so the timed part is building.
drv=$(nix eval --raw "${nixf[@]}" check.drvPath)
uptime >"$res/build-$tag.load"
# Build the .drv directly, so the timing has no evaluation in it.
nix build "$drv^*" --no-link --max-jobs "$jobs" --cores "$cores" "${opts[@]}" \
  --log-format internal-json -v 2>&1 |
  python3 "$here/buildlog.py" "$res/build-$tag.json" |
  tee "$res/build-$tag.summary"
uptime >>"$res/build-$tag.load"

n=$(jq length "$res/drvPaths.json" 2>/dev/null || echo 300)
drv=$(nix eval --raw "${nixf[@]}" --argstr trivialCount "$n" trivial.drvPath)
nix build "$drv^*" --no-link --max-jobs "$jobs" --cores "$cores" "${opts[@]}" \
  --log-format internal-json -v 2>&1 |
  python3 "$here/buildlog.py" "$res/trivial-$tag.json" |
  tee "$res/trivial-$tag.summary"
