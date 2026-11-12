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
#     so does every doctest .drv path;
#   - every product has the same bytes in both modes;
#   - every test run and doctest succeeded in both modes, with the same
#     test outcomes (libtest's `test … ok` lines, nextest's status lines
#     without timings), and both modes have the same repo.checks, all built;
#   - the test apps of test-control behave the same in both modes;
#   - gdb, given a split-debuginfo product's debug output, shows a
#     dependency's source and arguments in both modes;
#   - repo.explainSharing works in dynamic mode;
#   - with test-cutoff and test-options: a test run whose inputs' contents
#     an edit leaves unchanged is not re-run (`cutoff` in default.nix).
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
  fixtures=(
    walking-skeleton directives embed config-env doctests test-control
    test-options test-threads required-features all-required nextest out-dir-walk
    source-paths-dwo source-paths-dwp
    crate-types dev-dep-features build-dep-leak bin-exe-not-built rlib-example
    sys-native feature-unification clippy-conf test-cutoff
    multi-ws outside-reads own-view stamps missing-input test-only sources pkgid-short
    post-link source-paths trim-paths trim-paths-cc variants
    variants-coverage cargo-config benches stdpaths git-multi-workspace git-revisions
    build-std build-std-deps same-triple static-musl static-glibc
    static-pkgconfig cross-lto cross-lto-off uefi sys-native-aarch64 cross-doctests-aarch64
    static-glibc-nonpie static-glibc-nonpie-nixpkgs linker-kind-mold
    wasm-browser wasm-component wasip2 riscv64 linux-portable
    windows-gnullvm-aarch64 windows-gnu windows-dll-staged linux-portable-native
    msvc msvc-post-link
    test-home test-closure doctest-false optional-dependency exclusive-features
    cdylib-debug ui-dist build-script-outputs manifest-dir nested-cargo
  )
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
copy+=("$(sysbuild -A prereqs.tools)")
# The nixpkgs and rust-overlay the test expression imports, so that Nix
# master need not download them.
for input in nixpkgs rust-overlay; do
  copy+=("$(nix-instantiate --eval --raw -E "
    let n = (builtins.fromJSON (builtins.readFile $REPO/flake.lock)).nodes.\"$input\".locked;
    in fetchTarball { url = \"https://github.com/\${n.owner}/\${n.repo}/archive/\${n.rev}.tar.gz\"; sha256 = n.narHash; }")")
done
case $REPO in /nix/store/*) copy+=("$REPO") ;; esac
for f in "${fixtures[@]}"; do
  copy+=("$(sysbuild -A "prereqs.$f")")
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
import subprocess
# `nix derivation show` leaves out the path of a fixed output; the store
# knows it. Without them Nix master re-fetches every fixed output, and
# some (the Windows SDK) can no longer be fetched.
unnamed = []
for p, d in drvs.items():
    if not taint(p):
        for o in d.get("outputs", {}).values():
            if o.get("path"):
                print(full(o["path"]))
            elif "hash" in o:
                unnamed.append(p)
    for s in inputs(d)[1]:
        print(s)
if unnamed:
    sys.stdout.flush()
    subprocess.run(["nix-store", "-q", "--outputs", *sorted(set(unnamed))], check=True)
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

mapfile -t copy < <(printf '%s\n' "${copy[@]}" | sort -u)
say "copying ${#copy[@]} paths (and their closures) into $WORK/store"
# The system Nix reads them; Nix master writes the private store. On stdin:
# every fixture's paths together are too many for one command line.
printf '%s\n' "${copy[@]}" | "$NIX_MASTER/bin/nix" copy --no-check-sigs --to "$STORE" --stdin

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
    nixm log "$outer" | sed -n 's/^breakbulk-drv: wrote \([cr]-[^ ]*\|doctest:[^ ]*\) \(.*\)$/\1 \2/p' >"$WORK/units.dynamic"
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
  for p in "$(real "$dyn")"/products/*/*/*/*; do
    [ -L "$p" ] || continue
    name=${p#"$(real "$dyn")/products/"}
    a=$(real "$(readlink "$p")")
    if [ ! -L "$(real "$ifd")/products/$name" ] && [ -e "$a/breakbulk-no-binaries" ]; then
      # Cargo built none of its binaries; IFD mode has no
      # product for it.
      echo "$f: product $name holds only the no-binaries marker (dynamic mode)" >&2
      continue
    fi
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
  # Test runs, doctests and checks: built (so passed) in both modes, the
  # same sets.
  for what in runs doctests checks; do
    for m in dyn ifd; do
      d=$(real "${!m}")/$what
      if [ -d "$d" ]; then (cd "$d" && find . -mindepth 1 | sort); fi >"$WORK/$f-$what.$m"
    done
    # Dynamic mode's checks of a product Cargo built nothing
    # of hold the no-binaries marker; IFD mode has none for it.
    if [ "$what" = checks ]; then
      while IFS= read -r c; do
        t=$(real "$(readlink "$(real "$dyn")/checks/$c")")
        if [ -e "$t/breakbulk-no-binaries" ]; then
          echo "$f: check $c holds only the no-binaries marker (dynamic mode)" >&2
          grep -vxF "./$c" "$WORK/$f-$what.dyn" >"$WORK/$f-$what.dyn.tmp" || true
          mv "$WORK/$f-$what.dyn.tmp" "$WORK/$f-$what.dyn"
        fi
      done < <(comm -13 "$WORK/$f-$what.ifd" "$WORK/$f-$what.dyn" | sed 's|^\./||')
    fi
    if diff -u "$WORK/$f-$what.ifd" "$WORK/$f-$what.dyn"; then
      echo "$f: $(grep -c . "$WORK/$f-$what.ifd") $what entries built in both modes" >&2
    else
      echo "FAIL: $f: different $what" >&2
      status=1
    fi
  done
  # The same test outcomes: each log's result lines, timings removed.
  if ! python3 - "$WORK/store" "$(real "$ifd")" "$(real "$dyn")" <<'EOF'; then
import os, re, sys
store, ifd, dyn = sys.argv[1:]
line = re.compile(r"^(test .* \.\.\. .*|\s*(PASS|FAIL|SKIP|TRY \d+ \w+|SIGSEGV|TIMEOUT|TMT|SLOW|SIGKILL)\b.*|.*skipped: .*)$")
def resolve(p):
    # Follow symlinks inside the private store (absolute /nix/store targets).
    for _ in range(40):
        if not os.path.islink(p):
            return p
        t = os.readlink(p)
        p = store + t if t.startswith("/nix/store/") else os.path.join(os.path.dirname(p), t)
    raise SystemExit(f"symlink loop at {p}")
def outcomes(root):
    out = {}
    for sub in ("runs", "doctests", "apps"):
        top = resolve(os.path.join(root, sub))
        for dirpath, dirs, files in os.walk(top):
            for n in dirs + files:
                p = os.path.join(dirpath, n)
                rel = os.path.join(sub, os.path.relpath(p, top))
                t = resolve(p)
                for log in (t, os.path.join(t, "log"), os.path.join(t, "tests")):
                    if os.path.isfile(log):
                        with open(log, errors="replace") as fh:
                            ls = [re.sub(r"\[[^\]]*\]", "[]", l.rstrip()) for l in fh if line.match(l.rstrip())]
                        out[rel] = sorted(set(ls))
                        break
    return out
a, b = outcomes(ifd), outcomes(dyn)
bad = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
for k in bad:
    print(f"  {k}:\n    IFD     {a.get(k)}\n    dynamic {b.get(k)}", file=sys.stderr)
n = sum(len(v) for v in a.values())
print(f"{len(a)} logs, {n} test outcomes: {'identical' if not bad else 'DIFFERENT'} in both modes", file=sys.stderr)
# No log at all is a failure only when there are runs or doctests to read.
linked = any(
    os.path.islink(os.path.join(d, n))
    for sub in ("runs", "doctests")
    for d, ds, fs in os.walk(os.path.join(ifd, sub))
    for n in ds + fs
)
sys.exit(1 if bad or (linked and not a) else 0)
EOF
    echo "FAIL: $f: different test outcomes" >&2
    status=1
  fi
  # explainSharing in dynamic mode (through IFD mode's units.json).
  if [ "$(nixm eval --json -f "$REPO/tests/dynamic" --arg mode '"dynamic"' "explain.$f")" = true ]; then
    echo "$f: explainSharing works in dynamic-derivation mode" >&2
  else
    echo "FAIL: $f: explainSharing in dynamic-derivation mode" >&2
    status=1
  fi
done

# Content-addressed cutoff of test runs (`cutoff.<name>` in default.nix),
# as tests/test-cutoff and tests/test-options check it in IFD mode. The
# store is kept between runs, so the edit is new on each run: what the
# second build builds shows what the edit re-ran.
edit=$(date +%s)
for c in test-cutoff test-options; do
  case " ${fixtures[*]} " in *" $c "*) ;; *) continue ;; esac
  say "$c: test-run cutoff in dynamic-derivation mode (edit $edit)"
  cbuild() { mbuild --arg mode '"dynamic"' --argstr cutoffEdit "$edit" "$@"; }
  attrs=(kept)
  [ "$c" = test-cutoff ] && attrs+=(changed)
  ok=1
  if ! cbuild "${attrs[@]/#/cutoff.$c.before.}" >"$WORK/cutoff-before.out" 2>"$WORK/cutoff-before.log"; then
    tail -30 "$WORK/cutoff-before.log" >&2
    ok=0
  elif ! cbuild "${attrs[@]/#/cutoff.$c.after.}" >"$WORK/cutoff-after.out" 2>"$WORK/cutoff-after.log"; then
    tail -30 "$WORK/cutoff-after.log" >&2
    ok=0
  fi
  if [ $ok = 1 ]; then
    grep -o "building '[^']*'" "$WORK/cutoff-after.log" | sed 's/^building //' >"$WORK/cutoff-after.built" || true
    echo "built after the edit:" >&2
    sed 's/^/  /' "$WORK/cutoff-after.built" >&2
    drv() { nixm path-info --derivation -f "$REPO/tests/dynamic" --arg mode '"dynamic"' --argstr cutoffEdit "$edit" "cutoff.$c.$1"; }
    keptName=$(basename "$(drv before.kept)" | cut -d- -f2-)
    # Not vacuous: the edit changed the run's derivation.
    if [ "$(drv before.kept)" = "$(drv after.kept)" ]; then
      echo "the edit did not change the kept run's derivation (vacuous)" >&2
      ok=0
    fi
    if [ "$(head -1 "$WORK/cutoff-before.out")" != "$(head -1 "$WORK/cutoff-after.out")" ]; then
      echo "the kept run has a new output path" >&2
      ok=0
    fi
    if grep -qF "$keptName" "$WORK/cutoff-after.built"; then
      echo "the kept run ($keptName) was re-run" >&2
      ok=0
    fi
    case $c in
      test-cutoff)
        # beta's test runs in beta's source view, which the edit changed.
        changedName=$(basename "$(drv before.changed)" | cut -d- -f2-)
        grep -qF "$changedName" "$WORK/cutoff-after.built" || {
          echo "beta's test run was not re-run (vacuous)" >&2
          ok=0
        }
        ;;
      test-options)
        grep -q 'app-data-bin-stripped\.drv' "$WORK/cutoff-after.built" || {
          echo "the stripped copy was not rebuilt (vacuous)" >&2
          ok=0
        }
        ;;
    esac
  fi
  if [ $ok = 1 ]; then
    echo "$c: the kept test run was not re-run after the edit" >&2
  else
    echo "FAIL: $c: test-run cutoff in dynamic-derivation mode" >&2
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
