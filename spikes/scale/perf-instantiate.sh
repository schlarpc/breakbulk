#!/usr/bin/env bash
# CPU profile of breakbulk-instantiate on a measured plan (after measure.sh).
#
#   spikes/scale/perf-instantiate.sh <results dir> <breakbulk-instantiate binary> [perf binary]
#
# Reuses the instantiate derivation's own arguments (instantiate-drv.json).
set -euo pipefail
res=$(realpath "$1")
bin=$2
perf=${3:-perf}
mapfile -t args < <(jq -r '.derivations[] | .args[]' "$res/instantiate-drv.json")
/run/current-system/sw/bin/time -f "wall %e s, maxrss %M KiB" "$bin" "${args[@]}" --out "$res/units-local.json"
"$perf" record -g -o "$res/perf.data" "$bin" "${args[@]}" --out "$res/units-local.json" 2>/dev/null
"$perf" report -i "$res/perf.data" --no-children --stdio --percent-limit 2 2>/dev/null |
  grep -v '^$' | grep -E '^ +[0-9]' | head -30
