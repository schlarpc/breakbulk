#!/usr/bin/env bash
# Reproducibility: build every fixture's products and a sample of its units
# (tests/rebuild/default.nix), then build each again with
# `nix build --rebuild` and compare the bytes.
#
#   tests/rebuild/run.sh [options] [fixture ...] [-- nix options]
#   nix run .#test-rebuild -- [options] [fixture ...] [-- nix options]
#
# Options:
#   --targets REGEX   only these target triples (default: every target)
#   --every N         rebuild 1 in N units of each plan (default 4; 1: all)
#   --seed S          another deterministic sample
#   --list            print the fixture names and exit
# Without fixtures, every fixture in the catalog. Options after `--` go to
# every nix command (e.g. `-- --max-jobs 2 --cores 4`).
#
# A rebuild that differs keeps its output next to the original as
# `<path>.check` (--keep-failed; the next garbage collection removes it),
# and the report has `diffoscope` of the two (`diff -r` when diffoscope
# cannot be had). Exit status: 0 when every fixture evaluated, built and
# rebuilt bit-identically.
#
# Environment:
#   WORK        reports (default: $TMPDIR/breakbulk-rebuild); one directory
#               per fixture with build.log, rebuild.log and *.diff
#   REPO        the breakbulk checkout (default: this script's ../..)
#   DIFFOSCOPE  a diffoscope executable (default: diffoscope on PATH, else
#               DIFFOSCOPE_DRV built on the first difference)
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$(readlink -f "$here/../..")}
WORK=${WORK:-${TMPDIR:-/tmp}/breakbulk-rebuild}
export NO_COLOR=1

targets='.*'
every=4
seed=
list=
fixtures=()
nixopts=()
while [ $# -gt 0 ]; do
  case $1 in
    --targets) targets=$2; shift 2 ;;
    --every) every=$2; shift 2 ;;
    --seed) seed=$2; shift 2 ;;
    --list) list=1; shift ;;
    --) shift; nixopts=("$@"); break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) fixtures+=("$1"); shift ;;
  esac
done

catalog=("$REPO/tests/rebuild" --argstr targets "$targets" --arg every "$every" --argstr seed "$seed")
if [ ${#fixtures[@]} -eq 0 ] || [ -n "$list" ]; then
  mapfile -t all < <(nix-instantiate --eval --json "${catalog[@]}" -A names | jq -r '.[]')
  if [ -n "$list" ]; then
    printf '%s\n' "${all[@]}"
    exit 0
  fi
  fixtures=("${all[@]}")
fi

say() { printf '\n== %s\n' "$*" >&2; }

diffoscope=${DIFFOSCOPE:-$(command -v diffoscope || true)}
compare() {
  if [ -z "$diffoscope" ] && [ -n "${DIFFOSCOPE_DRV:-}" ]; then
    diffoscope=$(nix build --no-link --print-out-paths "${nixopts[@]}" "$DIFFOSCOPE_DRV^out" 2>/dev/null)/bin/diffoscope || diffoscope=
    DIFFOSCOPE_DRV=
  fi
  if [ -n "$diffoscope" ]; then
    "$diffoscope" --no-progress "$1" "$2"
  else
    diff -r "$1" "$2"
  fi
}

mkdir -p "$WORK"
summary=()
status=0
for f in "${fixtures[@]}"; do
  say "$f"
  dir=$WORK/$f
  rm -rf "$dir"
  mkdir -p "$dir"
  if ! { nix-instantiate "${catalog[@]}" -A "products.$f" "${nixopts[@]}" &&
    nix-instantiate "${catalog[@]}" -A "units.$f" "${nixopts[@]}"; } >"$dir/drvs" 2>"$dir/eval.log"; then
    tail -n 20 "$dir/eval.log" >&2
    summary+=("EVAL-FAIL $f (see $dir/eval.log)")
    status=1
    continue
  fi
  # nix-instantiate prints `<drv>!<output>` for a derivation selected by a
  # non-default output; every output is rebuilt anyway.
  mapfile -t drvs < <(sed 's/!.*//' "$dir/drvs" | sort -u)
  if [ ${#drvs[@]} -eq 0 ]; then
    summary+=("empty $f (no derivations for these targets)")
    continue
  fi
  echo "${#drvs[@]} derivations" >&2

  if ! nix build --no-link --keep-going "${nixopts[@]}" "${drvs[@]/%/^*}" 2>"$dir/build.log"; then
    grep -E '^error' "$dir/build.log" | head -n 20 >&2
    summary+=("BUILD-FAIL $f (see $dir/build.log)")
    status=1
  fi
  # Rebuild what built.
  built=()
  for d in "${drvs[@]}"; do
    mapfile -t outs < <(nix-store -q --outputs "$d")
    if nix-store --check-validity "${outs[@]}" 2>/dev/null; then
      built+=("$d")
    fi
  done
  [ ${#built[@]} -gt 0 ] || continue

  nix build --no-link --rebuild --keep-going --keep-failed "${nixopts[@]}" "${built[@]/%/^*}" 2>"$dir/rebuild.log"
  mapfile -t differs < <(sed -nE "s|.*derivation '([^']+)' may not be deterministic: output \"?(/nix/store/[^\" ]+)\"? differs.*|\1 \2|p" "$dir/rebuild.log" | sort -u)
  other=$(grep -E '^error' "$dir/rebuild.log" | grep -vE 'may not be deterministic|build of .* failed|^error: [0-9]+ dependencies of|Cannot build' || true)
  for line in "${differs[@]}"; do
    drv=${line%% *}
    out=${line#* }
    name=$(basename "$out")
    echo "DIFFERS: $drv ($out)" >&2
    compare "$out" "$out.check" >"$dir/${name#*-}.diff" 2>&1
    summary+=("DIFFERS $f $drv ($out vs $out.check; $dir/${name#*-}.diff)")
    status=1
  done
  if [ -n "$other" ]; then
    echo "$other" >&2
    summary+=("REBUILD-FAIL $f (see $dir/rebuild.log)")
    status=1
  fi
  if [ ${#differs[@]} -eq 0 ] && [ -z "$other" ]; then
    summary+=("ok $f: ${#built[@]} derivations rebuilt bit-identically")
  fi
done

say "summary (reports in $WORK)"
printf '%s\n' "${summary[@]}" >&2
exit $status
