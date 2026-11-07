#!/usr/bin/env bash
# CA island cost (M6 spike, "CA island cost" in docs/implementation.md):
# how long does substituting a content-addressed test run take from a cold
# store, and what does it download, compared with an input-addressed one?
#
#   spikes/m6/ca-island/run.sh            (WORK defaults to $TMPDIR/bb-ca-island)
#
# 1. The system Nix builds the fixture's input-addressed runs (units, plans,
#    toolchain all land in the system store).
# 2. Their closure (derivations and outputs) is copied into private store A
#    (`local?root=`, own nix.conf with ca-derivations; the system daemon is
#    not touched). The system nix CLI evaluates and builds the CA runs there.
# 3. Both kinds of runs are pushed from A to a file:// cache with
#    `nix copy "$drv^*"` (which uploads realisations for CA outputs).
# 4. For each kind, a fresh empty store gets only the runs' .drv closure;
#    `nix build "$drv^*"` with that cache as the only substituter and
#    max-jobs = 0 (no local builds) substitutes them. Time and the new valid
#    paths (count, NAR size) are recorded.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
WORK=${WORK:-${TMPDIR:-/tmp}/bb-ca-island}
mkdir -p "$WORK/etc"
say() { printf '\n== %s\n' "$*" >&2; }

say "1. system Nix: input-addressed runs"
ia_out=$(nix-build "$here" -A all --arg ca false --no-out-link)
ifd_out=$(nix-build "$here" -A ifd --arg ca false --no-out-link)
mapfile -t ia_runs < <(nix-store -q --references "$ia_out" | grep -- '-run$')
mapfile -t ia_drvs < <(for p in "${ia_runs[@]}"; do nix-store -q --deriver "$p"; done)
closure=$(nix-store -qR --include-outputs "${ia_drvs[@]}" | wc -l)
echo "${#ia_runs[@]} runs; closure with outputs: $closure paths" >&2

cat > "$WORK/etc/nix.conf" <<EOF
experimental-features = nix-command ca-derivations
sandbox = true
substituters =
build-users-group =
max-jobs = 2
cores = 4
require-sigs = false
EOF
: > "$WORK/etc/empty.conf"
export NIX_CONF_DIR="$WORK/etc" NIX_USER_CONF_FILES="$WORK/etc/empty.conf" XDG_CACHE_HOME="$WORK/xdg"
unset NIX_REMOTE
A="local?root=$WORK/a"
say "2. copy into store A"
# shellcheck disable=SC2046
nix copy --no-check-sigs --to "$A" $(nix-store -qR --include-outputs "${ia_drvs[@]}") "$ifd_out"
# The runtime closure of every output too (e.g. gcc's lib output, which a
# test binary references but whose deriver differs).
# shellcheck disable=SC2046
nix copy --no-check-sigs --to "$A" $(nix-store -qR $(nix-store -qR --include-outputs "${ia_drvs[@]}" | grep -v '\.drv$'))
# The nixpkgs the expression imports.
nixpkgs=$(nix-instantiate --eval --raw -E "
  let n = (builtins.fromJSON (builtins.readFile $here/../../../flake.lock)).nodes.nixpkgs.locked;
  in fetchTarball { url = \"https://github.com/\${n.owner}/\${n.repo}/archive/\${n.rev}.tar.gz\"; sha256 = n.narHash; }")
nix copy --no-check-sigs --to "$A" "$nixpkgs"
pkgsArg=(--arg pkgs "import $nixpkgs {}")

say "2b. store A: build the CA runs"
mapfile -t ca_drvs < <(nix --store "$A" eval --raw -f "$here" "${pkgsArg[@]}" --arg ca true runs \
  --apply 'rs: builtins.concatStringsSep "\n" (map (r: r.drvPath) (builtins.attrValues rs))')
nix --store "$A" build --no-link "${ca_drvs[@]/%/^*}" 2>&1 | tail -3
CACHE="file://$WORK/cache"
# Nix caches narinfo lookups per cache URL: drop that too, or a path
# uploaded by an earlier run (since deleted) counts as present.
rm -rf "$WORK/cache" "$WORK/xdg"
say "3. push both kinds to $CACHE"
# Output closures first: copying "$drv^*" of a CA derivation alone fails
# with "reference … is not valid" (the binary cache gets the CA bin copy
# before the gcc lib it references; observed with Determinate Nix 3.22).
# (`path-info "$drv^*"` does not resolve CA derivations; `build` does.)
# The CA runs' input CA derivations (the binary copies) too: `nix copy`
# uploads their realisations as dependencies but not their closures.
mapfile -t ca_inputs < <(nix --store "$A" derivation show "${ca_drvs[@]}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d.get("derivations", d)
for v in d.values():
    i = v.get("inputs", {}).get("drvs") or v.get("inputDrvs", {})
    for p in i:
        if p.endswith("-bin.drv"):
            print(p if p.startswith("/") else "/nix/store/" + p)
' | sort -u)
# Resolving a CA derivation realises every direct input first (bash, jq,
# the stdenv, the units, the run units' flags…), so a cache that is to serve
# CA runs on a cold machine needs those too, as a CI cache that pushed
# everything (and cache.nixos.org for the stdenv) would have them. Without
# them the cold build fails trying to build bash.
mapfile -t direct < <(nix --store "$A" derivation show "${ca_drvs[@]}" "${ca_inputs[@]}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d.get("derivations", d)
for v in d.values():
    i = v.get("inputs", {}).get("drvs") or v.get("inputDrvs", {})
    for p in i:
        print(p if p.startswith("/") else "/nix/store/" + p)
' | sort -u)
mapfile -t outs < <(nix --store "$A" build --no-link --print-out-paths "${ia_drvs[@]/%/^*}" "${ca_drvs[@]/%/^*}" "${ca_inputs[@]/%/^*}" "${direct[@]/%/^*}")
# shellcheck disable=SC2046
nix --store "$A" copy --to "$CACHE" $(nix --store "$A" path-info -r "${outs[@]}")
nix --store "$A" copy --to "$CACHE" "${ia_drvs[@]/%/^*}" "${ca_drvs[@]/%/^*}"
du -sh "$WORK/cache" >&2
ls "$WORK/cache" >&2

cold() { # name, drvs...
  local name=$1
  shift
  local S="local?root=$WORK/cold-$name"
  chmod -R u+w "$WORK/cold-$name" 2> /dev/null || true
  rm -rf "$WORK/cold-$name"
  nix --store "$A" copy --derivation --to "$S" "$@"
  local before
  before=$(nix --store "$S" path-info --all | sort)
  local t0 t1
  t0=$(date +%s.%N)
  nix --store "$S" build --no-link --max-jobs 0 --substituters "$CACHE" "${@/%/^*}" 2> "$WORK/cold-$name.log" || {
    tail -20 "$WORK/cold-$name.log" >&2
    return 1
  }
  t1=$(date +%s.%N)
  comm -13 <(echo "$before") <(nix --store "$S" path-info --all | sort) > "$WORK/cold-$name.new"
  local n size
  n=$(wc -l < "$WORK/cold-$name.new")
  size=$(xargs nix --store "$S" path-info --size < "$WORK/cold-$name.new" | awk '{s+=$2} END {print s}')
  printf '%s: %d runs, %.2f s, %d new paths, %d bytes (NAR)\n' "$name" "$#" "$(echo "$t1 - $t0" | bc)" "$n" "$size"
  sed 's|^/nix/store/[a-z0-9]*-|  |' "$WORK/cold-$name.new" | sort | uniq -c | sort -rn | head -40
}
say "4. cold substitution"
cold ia "${ia_drvs[@]}"
cold ca "${ca_drvs[@]}"
# One run each: the `ignored` integration test.
pick() { printf '%s\n' "$@" | grep -- '-ignored-run.drv$'; }
cold ia1 "$(pick "${ia_drvs[@]}")"
cold ca1 "$(pick "${ca_drvs[@]}")"
