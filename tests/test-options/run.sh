#!/usr/bin/env bash
# Content-addressed cutoff with `test.stripForRun` and `test.runFiles`
# (decisions 17 and 61), in a private store with ca-derivations, as
# tests/test-cutoff/run.sh does it. The system Nix's configuration is not
# touched.
#
#   tests/test-options/run.sh
#
# app's `data` test run, with both options, is built with `ca = true`
# before and after an edit to util's README (in util's debug info, so the
# test binary's bytes change) and to app's notes.md (in app's source view,
# not in runFiles). Checks: the test run is not re-run (same output path, no
# `app-data-run` derivation built), while the stripped copy of app's test
# binary was rebuilt, its input having changed (not vacuous; the flake
# check test-options-strip-for-run shows the unstripped bytes differ).
#
# Environment: WORK (default $TMPDIR/breakbulk-test-options; its store is
# recreated on each run, and read-only: `chmod -R u+w "$WORK"` before
# deleting), REPO (default: this script's ../..).
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$(readlink -f "$here/../..")}
WORK=${WORK:-${TMPDIR:-/tmp}/breakbulk-test-options}
if [ -e "$WORK/store" ]; then
  chmod -R u+w "$WORK/store"
  rm -rf "$WORK/store"
fi
mkdir -p "$WORK/builds"
store="local?root=$WORK/store"

say() { printf '\n== %s\n' "$*" >&2; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

say "system store: input-addressed test runs (prerequisites)"
nix-build "$REPO/tests/test-options" --no-out-link -A runs.before -A runs.after > /dev/null

private() {
  nix --extra-experimental-features 'nix-command ca-derivations' \
    --store "$store" --option require-sigs false \
    --option substituters daemon --option build-dir "$WORK/builds" \
    --max-jobs 2 --cores 4 "$@"
}

for s in before after; do
  say "private store, ca = true: $s the edits"
  private build --no-link --print-out-paths --impure -f "$REPO/tests/test-options" \
    --arg ca true "runs.$s" > "$WORK/$s.out" 2> "$WORK/$s.log" || {
    tail -30 "$WORK/$s.log" >&2
    fail "building $s"
  }
done
b=$(cat "$WORK/before.out")
a=$(cat "$WORK/after.out")
printf 'before: %s\nafter:  %s\n' "$b" "$a" >&2

grep -o "building '[^']*'" "$WORK/after.log" | sed 's/^building //' > "$WORK/after.built" || true
echo "built after the edits:" >&2
sed 's/^/  /' "$WORK/after.built" >&2

[ "$b" = "$a" ] || fail "the test run has a new output path"
if grep -q 'app-data-run\.drv' "$WORK/after.built"; then
  fail "the test run was re-run"
fi
# The units come from the system store (substituted, not built here); the
# stripped copy is rebuilt because its input, app's test binary, changed.
grep -q 'app-data-bin-stripped\.drv' "$WORK/after.built" \
  || fail "the stripped copy was not rebuilt (vacuous)"
say "ok: the test run was not re-run"
