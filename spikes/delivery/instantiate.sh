# Builder of the dynamic-derivation-mode outer derivation (stand-in for
# breakbulk-instantiate). Runs with requiredSystemFeatures = builder-rpc-v0.
#
# For each unit, in topological order: render references, build the JSON
# derivation (format version 4) with *deferred* input-addressed outputs, add it
# with `nix derivation add` (Nix fills in the output paths), and read the
# output paths back from the written .drv. Finally submit each root .drv as the
# outer derivation's output "<root>.drv".
set -euo pipefail
export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

echo "NIX_REMOTE=$NIX_REMOTE"
if [[ -n "${out+set}" ]]; then echo "unexpected \$out in builder-rpc-v0 build"; exit 1; fi

base() { echo "${1#"$NIX_STORE"/}"; }

declare -A outpath   # "<unit>/<output>" -> store path
declare -A drvof     # "<unit>" -> .drv path
mkdir -p "$TMPDIR/drvs"  # copies of the .drv files we add

# render <segments json>: sets $rendered; records inputs in $drvdeps, $srcs.
# (Not called in a subshell, so the input bookkeeping survives.)
render() {
  local segs=$1 n i seg s=""
  n=$(jq 'length' <<<"$segs")
  for ((i = 0; i < n; i++)); do
    seg=$(jq -c ".[$i]" <<<"$segs")
    case $(jq -r 'if type == "string" then "lit" elif has("unit") then "unit" elif has("tool") then "tool" else "src" end' <<<"$seg") in
      lit) s+=$(jq -r . <<<"$seg") ;;
      unit)
        local u o f
        u=$(jq -r .unit <<<"$seg"); o=$(jq -r .output <<<"$seg"); f=$(jq -r '.file // ""' <<<"$seg")
        s+="${outpath[$u/$o]}$f"
        drvdeps=$(jq -c --arg d "$(base "${drvof[$u]}")" --arg o "$o" \
          '.[$d].outputs = ((.[$d].outputs // []) + [$o] | unique) | .[$d].dynamicOutputs = {}' <<<"$drvdeps") ;;
      tool)
        s+="$TOOLCHAIN_OUT"
        drvdeps=$(jq -c --arg d "$(base "$TOOLCHAIN_DRV")" '.[$d] = {outputs: ["out"], dynamicOutputs: {}}' <<<"$drvdeps") ;;
      src)
        s+="$SRC_a"
        srcs=$(jq -c --arg p "$(base "$SRC_a")" '. + [$p] | unique' <<<"$srcs") ;;
    esac
  done
  rendered=$s
}

# add_drv <json> <name>: add one derivation; sets $drv and $paths ({output: path}).
# ADD_METHOD selects the mechanism:
#   harmonia (default)  bb-drv: harmonia hash modulo + AddToStore with explicit
#                       references over the builder-rpc-v0 socket
#   compute             drvhash.py + `nix store add --mode text --scan`
#   derivation-add      `nix derivation add`; fails for any derivation whose
#                       inputs were added earlier in this build
add_drv() {
  local json=$1 name=$2
  printf '%s' "$json" > "$TMPDIR/unit.json"
  case ${ADD_METHOD:-harmonia} in
    harmonia)
      local r
      r=$(bb-drv add "$TMPDIR/unit.json" "$TMPDIR/drvs")
      drv=$(jq -r .drvPath <<<"$r"); paths=$(jq -c .outputs <<<"$r") ;;
    compute)
      paths=$(python3 "$DRVHASH" "$TMPDIR/unit.json" "$TMPDIR/unit.drv" "$TMPDIR/drvs")
      drv=$(nix store add --mode text --scan --name "$name.drv" "$TMPDIR/unit.drv")
      cp "$TMPDIR/unit.drv" "$TMPDIR/drvs/$(base "$drv")" ;;
    derivation-add)
      drv=$(nix derivation add <<<"$json")
      local aterm o
      aterm=$(cat "$drv")   # fails: added paths are not mounted into the sandbox
      paths='{}'
      for o in $(jq -r '.outputs | keys[]' <<<"$json"); do
        [[ $aterm =~ \(\"$o\",\"($NIX_STORE/[^\"]*)\" ]]
        paths=$(jq -c --arg o "$o" --arg p "${BASH_REMATCH[1]}" '.[$o] = $p' <<<"$paths")
      done ;;
  esac
}

submit() {
  case ${ADD_METHOD:-harmonia} in
    harmonia) bb-drv submit "$1" "$2" ;;
    *) nix store submit-output "$1" "$2" ;;
  esac
}

for id in $(jq -r '.order[]' "$UNITS"); do
  unit=$(jq -c --arg id "$id" '.units[$id]' "$UNITS")
  name=$(jq -r .name <<<"$unit")
  outputs=$(jq -r '.outputs | join(" ")' <<<"$unit")
  drvdeps='{}'
  # The builder and PATH strings carry these store paths as context in IFD mode.
  srcs=$(jq -cn --arg a "$(base "$UNIT_BASH")" --arg b "$(base "$UNIT_COREUTILS")" '[$a, $b] | unique')
  env='{}'
  for k in $(jq -r '.env | keys[]' <<<"$unit"); do
    render "$(jq -c --arg k "$k" '.env[$k]' <<<"$unit")"; v=$rendered
    env=$(jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' <<<"$env")
  done
  json=$(jq -n \
    --arg name "$name" --arg system "$UNIT_SYSTEM" --arg builder "$UNIT_BUILDER" \
    --argjson args "$UNIT_ARGS" --arg path "$UNIT_PATH" --arg outputs "$outputs" \
    --argjson env "$env" --argjson drvs "$drvdeps" --argjson srcs "$srcs" \
    --argjson outs "$(jq -c '.outputs' <<<"$unit")" '
    {
      version: 4, name: $name, system: $system, builder: $builder, args: $args,
      # Output env vars must be present and empty: Nix masks them before
      # hashing, and a missing key hashes differently (see the spike notes).
      env: ($env + {builder: $builder, name: $name, system: $system, outputs: $outputs, PATH: $path}
            + ($outs | map({key: ., value: ""}) | from_entries)),
      inputs: {drvs: $drvs, srcs: $srcs},
      outputs: ($outs | map({key: ., value: {}}) | from_entries)
    }')
  add_drv "$json" "$name"
  for o in $outputs; do outpath[$id/$o]=$(jq -r --arg o "$o" '.[$o]' <<<"$paths"); done
  drvof[$id]=$drv
  echo "added $id -> $drv"
  for o in $outputs; do echo "  $o -> ${outpath[$id/$o]}"; done
done

# Nix requires a submitted output's store path name to be
# outputPathName(<outer name>, <output>), i.e. "<outer name>-<root>.drv"
# (src/libstore/build/derivation-check.cc). The root unit's .drv has its own
# name, so each root is wrapped in a tiny input-addressed derivation with the
# required name that symlinks the root unit's output.
for root in $(jq -r '.roots | keys[]' "$UNITS"); do
  id=$(jq -r --arg r "$root" '.roots[$r]' "$UNITS")
  if [[ ${SUBMIT_UNWRAPPED:-} ]]; then
    submit "${drvof[$id]}" "$root.drv"
    continue
  fi
  wname="$OUTER_NAME-$root"
  json=$(jq -n --arg name "$wname" --arg system "$UNIT_SYSTEM" --arg sh "$UNIT_BUILDER" \
    --arg target "${outpath[$id/out]}" --arg rootdrv "$(base "${drvof[$id]}")" \
    --arg bash "$(base "$UNIT_BASH")" --arg cu "$UNIT_COREUTILS" --arg cub "$(base "$UNIT_COREUTILS")" '
    {
      version: 4, name: $name, system: $system, builder: $sh,
      args: ["-c", ($cu + "/bin/ln -s " + $target + " $out")],
      env: {builder: $sh, name: $name, system: $system, outputs: "out", out: ""},
      inputs: {drvs: {($rootdrv): {outputs: ["out"], dynamicOutputs: {}}},
               srcs: ([$bash, $cub] | unique)},
      outputs: {out: {}}
    }')
  add_drv "$json" "$wname"; wdrv=$drv
  submit "$wdrv" "$root.drv"
  echo "submitted $wdrv (wrapping ${drvof[$id]}) as $root.drv"
done
