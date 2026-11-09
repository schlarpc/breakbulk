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
#      (`ca` off), before and after the edit to beta, so the units and
#      everything upstream can be substituted;
#   2. the private store builds them with `ca = true`: before the edit,
#      then after it;
#   3. checks: alpha's test run is not re-run after the edit (its output
#      path is the same and no `alpha-lib-alpha-run` derivation was built),
#      beta's is (it runs in beta's source view, which changed: not
#      vacuous), and the dynamic-library copy was rebuilt (its inputs
#      changed).
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
nix-build "$REPO/tests/test-cutoff" --no-out-link -A runs.before -A runs.after > /dev/null

private() {
  nix --extra-experimental-features 'nix-command ca-derivations' \
    --store "$store" --option require-sigs false \
    --option substituters daemon --option build-dir "$WORK/builds" \
    --max-jobs 2 --cores 4 "$@"
}
build() {
  # $1: before|after; prints the build log to $WORK/$1.log
  private build --no-link --print-out-paths --impure -f "$REPO/tests/test-cutoff" \
    --arg ca true "runs.$1.alpha" "runs.$1.beta" 2> "$WORK/$1.log"
}

for s in before after; do
  say "private store, ca = true: $s the edit"
  build $s > "$WORK/$s.out" || {
    tail -30 "$WORK/$s.log" >&2
    fail "building $s"
  }
done
mapfile -t b < "$WORK/before.out"
mapfile -t a < "$WORK/after.out"
printf 'before: %s\nafter:  %s\n' "${b[*]}" "${a[*]}" >&2

grep -o "building '[^']*'" "$WORK/after.log" | sed 's/^building //' > "$WORK/after.built" || true
echo "built after the edit:" >&2
sed 's/^/  /' "$WORK/after.built" >&2

[ "${b[0]}" = "${a[0]}" ] || fail "alpha's test run has a new output path"
if grep -q 'alpha-lib-alpha-run\.drv' "$WORK/after.built"; then
  fail "alpha's test run was re-run"
fi
# beta's test runs in beta's source view, which the edit changed, so it
# is re-run (its log, the output, is the same bytes).
grep -q 'beta-lib-beta-run\.drv' "$WORK/after.built" \
  || fail "beta's test run was not re-run (vacuous: its working directory changed)"
grep -q 'test-cutoff-test-dylibs\.drv' "$WORK/after.built" \
  || fail "the dynamic-library copy was not rebuilt (vacuous: beta's run changed)"
say "ok: alpha's test run was not re-run; beta's was"
