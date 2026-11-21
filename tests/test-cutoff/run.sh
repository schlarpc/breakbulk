#!/usr/bin/env bash
# Content-addressed cutoff of test runs, in a private store
# with ca-derivations. The system Nix's configuration is not touched: the
# calling user's Nix builds into `local?root=$WORK/store` with the
# `ca-derivations` feature on the command line only, substituting from the
# system store (`daemon`) what the system Nix already built.
#
#   tests/test-cutoff/run.sh
#
# Steps:
#   1. the system Nix builds the fixture's test runs input-addressed
#      (`ca` off), before and after each edit (to beta's settings, `runs`;
#      to beta's source, `source`), so the units and everything upstream
#      can be substituted;
#   2. the private store builds them with `ca = true`: before each edit,
#      then after it;
#   3. checks: alpha's test run has breakbulk-hints and not breakbulk-unit
#      among its inputs (`run-inputs`, with `ca = true`);
#      after each edit, alpha's test run is not re-run (its output path is
#      the same and no `alpha-lib-alpha-run` derivation was built), while
#      the stripped copy of its test binary was rebuilt (its input
#      changed: not vacuous), and after the settings edit so was the copy
#      of the dynamic-library path.
#
# Environment: WORK (default $TMPDIR/breakbulk-test-cutoff; its store is
# recreated on each run, and read-only: `chmod -R u+w "$WORK"` before
# deleting), REPO (default: this script's ../..).
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$(readlink -f "$here/../..")}
WORK=${WORK:-${TMPDIR:-/tmp}/breakbulk-test-cutoff}
# A fresh store each time: the check is about what the second build builds.
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
nix-build "$REPO/tests/test-cutoff" --no-out-link -A runs.before -A runs.after \
  -A source.before -A source.after > /dev/null

private() {
  nix --extra-experimental-features 'nix-command ca-derivations' \
    --store "$store" --option require-sigs false \
    --option substituters daemon --option build-dir "$WORK/builds" \
    --max-jobs 2 --cores 4 "$@"
}
# $1: runs (beta's settings) or source (beta's source); $2...: attributes
# under $1.before and $1.after, alpha's run first.
cutoff() {
  local edit=$1 b a
  shift
  for s in before after; do
    say "private store, ca = true: $edit, $s the edit"
    local attrs=("${@/#/$edit.$s.}")
    private build --no-link --print-out-paths --impure -f "$REPO/tests/test-cutoff" \
      --arg ca true "${attrs[@]}" > "$WORK/$edit.$s.out" 2> "$WORK/$edit.$s.log" || {
      tail -30 "$WORK/$edit.$s.log" >&2
      fail "building $edit, $s"
    }
  done
  mapfile -t b < "$WORK/$edit.before.out"
  mapfile -t a < "$WORK/$edit.after.out"
  printf 'before: %s\nafter:  %s\n' "${b[*]}" "${a[*]}" >&2
  grep -o "building '[^']*'" "$WORK/$edit.after.log" | sed 's/^building //' > "$WORK/$edit.after.built" || true
  echo "built after the edit:" >&2
  sed 's/^/  /' "$WORK/$edit.after.built" >&2
  [ "${b[0]}" = "${a[0]}" ] || fail "$edit: alpha's test run has a new output path"
  if grep -q 'alpha-lib-alpha-run\.drv' "$WORK/$edit.after.built"; then
    fail "$edit: alpha's test run was re-run"
  fi
  grep -q 'alpha-lib-alpha-bin-stripped\.drv' "$WORK/$edit.after.built" \
    || fail "$edit: alpha's test binary was not copied again (vacuous: beta's library changed)"
}

cutoff runs alpha beta
grep -q 'test-cutoff-test-dylibs\.drv' "$WORK/runs.after.built" \
  || fail "the dynamic-library copy was not rebuilt (vacuous: beta's run changed)"
say "ok: alpha's test run was not re-run after the settings edit"

cutoff source alpha
say "ok: alpha's test run was not re-run after the source edit"

say "private store, ca = true: the test run's inputs"
private build --no-link --impure -f "$REPO/tests/test-cutoff" --arg ca true run-inputs \
  || fail "alpha's test run's inputs (run-inputs)"
