#!/usr/bin/env bash
# Dynamic-derivation mode against IFD mode, on Nix master in a private store.
#
#   tests/dynamic/run.sh [fixture ...]        (default: every fixture)
#   nix run .#test-dynamic -- [fixture ...]
#
# The system Nix (any version) builds each fixture in IFD mode first, so
# that everything upstream of the units (toolchains, crate sources, env
# captures, plans, breakbulk's tools) is in the system store. Those paths,
# and nothing downstream of a unit, are copied into a private chroot store.
# Nix master (pinned below) then builds, in that store:
#
#   1. the fixture in dynamic-derivation mode: the outer derivations write
#      and build every unit, then products and test runs;
#   2. the fixture in IFD mode: units.json is imported, and every unit is
#      already valid.
#
# and checks that
#
#   - every unit .drv path the outer derivations wrote equals IFD mode's,
#     for the build and the test plan, and both modes have the same units;
#   - every product has the same bytes in both modes;
#   - every test run succeeded in both modes.
#
# The system daemon's configuration and /etc/nix are not touched: Nix master
# runs as the calling user against `local?root=$WORK/store` with its own
# nix.conf (NIX_CONF_DIR), no substituters, `sandbox = true`.
#
# Environment:
#   WORK        scratch directory (default: $TMPDIR/breakbulk-dynamic);
#               kept between runs, so later runs are incremental. Its store
#               is read-only: `chmod -R u+w "$WORK"` before deleting it.
#   NIX_MASTER  a Nix master build (its bin/nix); default: built from
#               github:NixOS/nix at NIX_REV with the system Nix
#   NIX_REV     default 94c011f5040d8c1b1e251b17b5c79ff370208663 (the
#               commit spike B used, 2026-11-06)
#   REPO        the breakbulk checkout (default: this script's ../..)
#   JOBS        max-jobs for Nix master (default 2; cores 4)
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$(readlink -f "$here/../..")}
WORK=${WORK:-${TMPDIR:-/tmp}/breakbulk-dynamic}
NIX_REV=${NIX_REV:-94c011f5040d8c1b1e251b17b5c79ff370208663}
JOBS=${JOBS:-2}
if [ $# -gt 0 ]; then
  fixtures=("$@")
else
  fixtures=(walking-skeleton directives)
fi

say() { printf '\n== %s\n' "$*" >&2; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$WORK"
if [ -z "${NIX_MASTER:-}" ]; then
  say "building Nix master $NIX_REV with the system Nix"
  NIX_MASTER=$(nix build --no-link --print-out-paths "github:NixOS/nix/$NIX_REV#nix-cli")
fi
"$NIX_MASTER/bin/nix" --version

# --- the system side -------------------------------------------------------

sysbuild() { nix-build "$REPO/tests/dynamic" --no-out-link --arg mode '"ifd"' "$@"; }

say "building the fixtures in IFD mode with the system Nix"
copy=()
prereqs=$(sysbuild -A prereqs)
copy+=("$prereqs")
# The nixpkgs the test expression imports, so that Nix master need not
# download it.
nixpkgs=$(nix-instantiate --eval --raw -E "
  let n = (builtins.fromJSON (builtins.readFile $REPO/flake.lock)).nodes.nixpkgs.locked;
  in fetchTarball { url = \"https://github.com/\${n.owner}/\${n.repo}/archive/\${n.rev}.tar.gz\"; sha256 = n.narHash; }")
copy+=("$nixpkgs")
case $REPO in /nix/store/*) copy+=("$REPO") ;; esac
for f in "${fixtures[@]}"; do
  out=$(sysbuild -A "build.$f")
  echo "$f (system, IFD): $out" >&2
  drv=$(nix-store -q --deriver "$out")
  units=$(sysbuild -A "unitDrvs.$f")
  # Everything the fixture's build depends on that is not a unit and not
  # downstream of one.
  mapfile -t up < <(
    nix derivation show -r "$drv" | python3 -c '
import json, sys
drvs = json.load(sys.stdin)
drvs = drvs.get("derivations", drvs)
units = json.load(open(sys.argv[1]))
def full(p):
    return p if p.startswith("/") else "/nix/store/" + p
drvs = {full(k): v for k, v in drvs.items()}
unit = {p for kind in units.values() for p in kind.values()}
def inputs(d):
    i = d.get("inputs")
    if isinstance(i, dict) and "drvs" in i:
        return [full(x) for x in i["drvs"]], [full(x) for x in i.get("srcs", [])]
    return [full(x) for x in d.get("inputDrvs", {})], [full(x) for x in d.get("inputSrcs", [])]
tainted = {}
def taint(p):
    if p not in tainted:
        tainted[p] = True  # cycles cannot happen; guard anyway
        tainted[p] = p in unit or any(taint(q) for q in inputs(drvs[p])[0] if q in drvs)
    return tainted[p]
for p, d in drvs.items():
    if not taint(p):
        for o in d.get("outputs", {}).values():
            if o.get("path"):
                print(full(o["path"]))
    for s in inputs(d)[1]:
        print(s)
' "$units" | sort -u
  )
  for p in "${up[@]}"; do
    [ -e "$p" ] && copy+=("$p")
  done
done

# --- the private store ------------------------------------------------------

mkdir -p "$WORK/etc" "$WORK/cache" "$WORK/store"
cat >"$WORK/etc/nix.conf" <<EOF
experimental-features = nix-command ca-derivations dynamic-derivations
sandbox = true
substituters =
build-users-group =
max-jobs = $JOBS
cores = 4
EOF
: >"$WORK/etc/empty.conf"
export NIX_CONF_DIR="$WORK/etc" NIX_USER_CONF_FILES="$WORK/etc/empty.conf" XDG_CACHE_HOME="$WORK/cache"
unset NIX_REMOTE NIX_PATH
STORE="local?root=$WORK/store"
nixm() { "$NIX_MASTER/bin/nix" --store "$STORE" "$@"; }

say "copying ${#copy[@]} paths (and their closures) into $WORK/store"
# The system Nix reads them; Nix master writes the private store.
"$NIX_MASTER/bin/nix" copy --no-check-sigs --to "$STORE" "${copy[@]}"

mbuild() { nixm build -f "$REPO/tests/dynamic" --no-link --print-out-paths "$@"; }
real() { printf '%s%s' "$WORK/store" "$1"; }

status=0
for f in "${fixtures[@]}"; do
  say "$f: dynamic-derivation mode (Nix master)"
  dyn=$(mbuild --arg mode '"dynamic"' -L "build.$f")
  say "$f: IFD mode (Nix master)"
  ifd=$(mbuild --arg mode '"ifd"' "build.$f")

  # Unit .drv paths: IFD mode's from units.json, dynamic mode's from the
  # outer derivations' build logs.
  ifdUnits=$(real "$(mbuild --arg mode '"ifd"' "unitDrvs.$f")")
  for kind in build test; do
    outer=$(nixm path-info --derivation -f "$REPO/tests/dynamic" --arg mode '"dynamic"' "outer.$f.$kind")
    nixm log "$outer" | sed -n 's/^breakbulk-drv: wrote \([cr]-[^ ]*\) \(.*\)$/\1 \2/p' | sort >"$WORK/$f-$kind.dynamic"
    python3 -c '
import json, sys
units = json.load(open(sys.argv[1]))[sys.argv[2]]
for k in sorted(units): print(k, units[k])
' "$ifdUnits" "$kind" | sort >"$WORK/$f-$kind.ifd"
    n=$(wc -l <"$WORK/$f-$kind.ifd")
    if [ "$n" -eq 0 ]; then
      fail "$f/$kind: IFD mode has no units"
    elif diff -u "$WORK/$f-$kind.ifd" "$WORK/$f-$kind.dynamic"; then
      echo "$f/$kind: $n unit .drv paths identical in both modes" >&2
    else
      echo "FAIL: $f/$kind: unit .drv paths differ (- IFD, + dynamic)" >&2
      status=1
    fi
  done

  # Products: the same bytes.
  for p in "$(real "$dyn")"/products/*; do
    name=$(basename "$p")
    a=$(real "$(readlink "$p")")
    b=$(real "$(readlink "$(real "$ifd")/products/$name")")
    ha=$(nix hash path "$a")
    hb=$(nix hash path "$b")
    if [ "$ha" = "$hb" ]; then
      echo "$f: product $name identical in both modes ($ha)" >&2
    else
      echo "FAIL: $f: product $name differs: $a ($ha) vs $b ($hb)" >&2
      diff -r "$a" "$b" || true
      status=1
    fi
  done
  # Test runs: built (so passed) in both modes, the same set.
  (cd "$(real "$dyn")/runs" && find . -mindepth 1 | sort) >"$WORK/$f-runs.dynamic"
  (cd "$(real "$ifd")/runs" && find . -mindepth 1 | sort) >"$WORK/$f-runs.ifd"
  if diff -u "$WORK/$f-runs.ifd" "$WORK/$f-runs.dynamic"; then
    echo "$f: $(grep -c . "$WORK/$f-runs.ifd") test-run entries passed in both modes" >&2
  else
    echo "FAIL: $f: different test runs" >&2
    status=1
  fi
done
[ $status -eq 0 ] && say "all fixtures: OK"
exit $status
