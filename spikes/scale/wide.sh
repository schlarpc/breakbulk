#!/usr/bin/env bash
# Build cost of inputs: wideCount bare derivations with wideInputs inputs
# each, built from scratch with max-jobs J and cores 1.
#
#   spikes/scale/wide.sh <results dir> <count> <inputs> [max-jobs] [drvs|refs]
#
# NOSANDBOX=1 adds --option sandbox false (tag "-nosandbox"), to separate
# the sandbox's per-input cost from the rest.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
res=$(realpath -m "$1")
count=$2
inputs=$3
jobs=${4:-8}
via=${5:-drvs}
extra=()
tag=$count-$inputs-$jobs-$via
if [ "${NOSANDBOX:-}" = 1 ]; then
  extra=(--option sandbox false)
  tag=$tag-nosandbox
fi
mkdir -p "$res"
salt=wide-$(date +%s%N)
nixf=(-f "$here" --argstr dir "$here" --argstr salt "$salt" --argstr wideCount "$count" --argstr wideInputs "$inputs" --argstr wideVia "$via")
nix build "${nixf[@]}" wide.inputs --no-link --max-jobs "$jobs" --cores 1 2>/dev/null
drv=$(nix eval --raw "${nixf[@]}" wide.all.drvPath)
# Build the .drv directly, so the timing has no evaluation in it.
nix build "$drv^*" --no-link --max-jobs "$jobs" --cores 1 --option substituters "" "${extra[@]}" \
  --log-format internal-json -v 2>&1 |
  python3 "$here/buildlog.py" "$res/wide-$tag.json" |
  tee "$res/wide-$tag.summary"
