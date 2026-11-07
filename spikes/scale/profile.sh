#!/usr/bin/env bash
# Evaluation profile (Nix's flamegraph eval profiler) of every unit .drvPath.
#
#   spikes/scale/profile.sh <generated dir> <results dir> [salt]
#
# Writes <results dir>/eval.folded (collapsed stacks; feed to flamegraph.pl
# or inferno) and prints the top frames by self and by inclusive samples.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(realpath "$1")
res=$(realpath -m "$2")
salt=${3:-0}
mkdir -p "$res"
nix eval --json -f "$here" --argstr dir "$dir" --argstr salt "$salt" drvPaths \
  --eval-profiler flamegraph --eval-profile-file "$res/eval.folded" \
  --eval-profiler-frequency 999 >/dev/null
python3 "$here/folded.py" "$res/eval.folded"
