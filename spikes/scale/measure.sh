#!/usr/bin/env bash
# Evaluation-side measurements for one generated plan.
#
#   spikes/scale/measure.sh <generated dir> <results dir>
#
# Writes into <results dir>:
#   instantiate.time   GNU time -v of breakbulk-instantiate run directly
#   units.json         its output
#   eval-baseline.*  evaluating nixpkgs and the tools only
#   eval-sources.*     evaluating the source map alone (warm: already copied)
#   eval-parse.*    reading units.json only
#   eval-subst.*    assembling BREAKBULK_UNIT with fake paths (no derivations)
#   eval-fresh.*       evaluating every unit .drvPath, writing new .drv files
#                      (a fresh salt; units.json already built)
#   eval-repeat.*      the same again (the .drv files exist)
#   drvPaths.json, derivations.json, drv-summary.json
# *.stats is NIX_SHOW_STATS output, *.time GNU time -v of the nix process.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(realpath "$1")
res=$(realpath -m "$2")
mkdir -p "$res"
T=/run/current-system/sw/bin/time
nixf=(-f "$here" --argstr dir "$dir")
salt=$(date +%s%N)

# Tools and the instantiate derivation (IFD) first, so evaluation timings
# below measure only evaluation.
nix build "${nixf[@]}" instantiateBin breakbulkUnit unitsJson --no-link --max-jobs 2 --cores 4
units_json=$(nix eval --raw "${nixf[@]}" unitsJson.outPath)
ls -l "$units_json" | awk '{print $5}' >"$res/units.json.bytes"

# breakbulk-instantiate on its own, with the derivation's own arguments.
drv=$(nix eval --raw "${nixf[@]}" unitsJson.drvPath)
nix derivation show "$drv" >"$res/instantiate-drv.json"
mapfile -t args < <(jq -r '.derivations[] | .args[]' "$res/instantiate-drv.json")
builder=$(jq -r '.derivations[] | .builder' "$res/instantiate-drv.json")
$T -v -o "$res/instantiate.time" "$builder" "${args[@]}" --out "$res/units.json"
cmp "$res/units.json" "$units_json"

run_eval() { # name, attr, extra args...
  local name=$1 attr=$2
  shift 2
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$res/$name.stats" \
    $T -v -o "$res/$name.time" \
    nix eval --json "${nixf[@]}" "$attr" "$@" >"$res/$name.json"
}

run_eval eval-baseline breakbulkUnit.drvPath
run_eval eval-sources sourcePaths
run_eval eval-parse parseOnly
run_eval eval-subst substOnly
run_eval eval-fresh drvPaths --argstr salt "$salt"
run_eval eval-repeat drvPaths --argstr salt "$salt"
cp "$res/eval-repeat.json" "$res/drvPaths.json"

jq -r '.[]' "$res/drvPaths.json" | xargs nix derivation show >"$res/derivations.json"
python3 "$here/analyze.py" "$res/drvPaths.json" "$res/derivations.json" >"$res/drv-summary.json"

for f in instantiate eval-baseline eval-sources eval-parse eval-subst eval-fresh eval-repeat; do
  printf '%-14s wall %8s  maxrss %8s KiB\n' "$f" \
    "$(grep 'Elapsed (wall' "$res/$f.time" | awk '{print $NF}')" \
    "$(grep 'Maximum resident' "$res/$f.time" | awk '{print $NF}')"
done
for f in eval-baseline eval-sources eval-parse eval-subst eval-fresh eval-repeat; do
  jq -c '{cpuTime, nrThunks, nrFunctionCalls, envs: .envs.bytes, list: .list.bytes, values: .values.bytes, sets: .sets.bytes, gcHeap: .gc.heapSize, gcTotal: .gc.totalBytes}' "$res/$f.stats"
done
cat "$res/drv-summary.json"
