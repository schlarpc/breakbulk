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
  fixtures=(walking-skeleton directives embed config-env)
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
  # outer derivations' build logs, per workspace and plan kind. Units whose
  # names match mayDiffer (downstream of an embedded product) may differ.
  ifdUnits=$(real "$(mbuild --arg mode '"ifd"' "unitDrvs.$f")")
  mayDiffer=$(nix-instantiate --eval --raw "$REPO/tests/dynamic" --arg mode '"ifd"' -A "mayDiffer.$f" 2>/dev/null || true)
  mapfile -t keys < <(python3 -c 'import json, sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$ifdUnits")
  for key in "${keys[@]}"; do
    outer=$(nixm path-info --derivation -f "$REPO/tests/dynamic" --arg mode '"dynamic"' "outer.$f.\"$key\"")
    nixm log "$outer" | sed -n 's/^breakbulk-drv: wrote \([cr]-[^ ]*\) \(.*\)$/\1 \2/p' >"$WORK/units.dynamic"
    if ! python3 - "$ifdUnits" "$key" "$WORK/units.dynamic" "$mayDiffer" <<'EOF'; then
import json, re, sys
ifd = json.load(open(sys.argv[1]))[sys.argv[2]]
dyn = dict(l.split(" ", 1) for l in open(sys.argv[3]).read().splitlines())
may = re.compile(sys.argv[4]) if sys.argv[4] else None
def name(p):
    return p.rsplit("/", 1)[-1].split("-", 1)[1]
same, allowed, bad = 0, [], []
for k in sorted(set(ifd) | set(dyn)):
    a, b = ifd.get(k), dyn.get(k)
    if a == b:
        same += 1
    elif a and b and may and may.search(name(a)) and may.search(name(b)):
        allowed.append(name(a))
    else:
        bad.append(f"  {k}: IFD {a}\n  {' ' * len(k)}  dynamic {b}")
label = f"{sys.argv[2]}: {same} unit .drv paths identical in both modes"
if allowed:
    label += f"; {len(allowed)} downstream of an embedded product differ, as expected ({', '.join(allowed)})"
print(label, file=sys.stderr)
if same == 0 or bad:
    print("FAIL: unit .drv paths differ:\n" + "\n".join(bad), file=sys.stderr)
    sys.exit(1)
EOF
      status=1
    fi
  done

  # Products: the same bytes.
  for p in "$(real "$dyn")"/products/*/*; do
    name=${p#"$(real "$dyn")/products/"}
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

# A check variant (no roots) builds every unit through `units.drv`.
case " ${fixtures[*]} " in
  *" walking-skeleton "*)
    say "check variant (dynamic-derivation mode)"
    if c=$(mbuild --arg mode '"dynamic"' checkVariant); then
      echo "check variant: $(cat "$(real "$c")"/* 2>/dev/null | wc -l) entries" >&2
    else
      echo "FAIL: the check variant did not build" >&2
      status=1
    fi
    ;;
esac

[ $status -eq 0 ] && say "all fixtures: OK"
exit $status
