#!/usr/bin/env bash
# `root = self` against `root = ./.` in real flake evaluation (pure).
#
#   tests/flake-self/run.sh
#
# Copies the outside-reads fixture and tests/flake-self/flake.nix into a
# scratch directory (a path flake), with `breakbulk` pointing at this
# checkout, and evaluates, once with lazy trees on and once off:
#
#   - every unit .drv path (build and test plan), plan .drv path and source
#     view store path is the same for `root = self`, `root = self.outPath`
#     and `root = ./.`;
#   - a root that is neither a path nor a flake's self fails with an error
#     that names what `root` accepts;
#   - breakbulk's flake-parts module with no `root` (flake-parts/flake.nix,
#     in a second copy of the fixture) gives the same derivations: `root`
#     defaults to the flake's `self`; its `packages` output lists the
#     products. This fetches flake-parts from GitHub (pinned revision);
#   - the flake-parts module with no configuration at all
#     (zero-config/flake.nix, around the walking-skeleton fixture): no
#     `root` and no `modules` give one workspace, `default`, whose product
#     is in `packages` and whose dev shell is `devShells.default`, and
#     whose test apps are in `apps`, named as their checks;
#   - `nix run` on a test app (apps/flake.nix, around the test-control
#     fixture): at its attribute path under the flake's `repo` output,
#     where Nix wants a derivation, and by its name in `apps`
#     (`repo.apps`), unquoted, with arguments for the test binary.
#
# Planning runs through IFD, so the first run builds the fixture's plans.
# Not a flake check: it evaluates a flake, and a check cannot call
# `nix run` (tests/test-runs `test-control-app` and
# `test-control-repo-apps` run what it would).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${WORK:-${TMPDIR:-/tmp}/breakbulk-flake-self}
rm -rf "$work"
mkdir -p "$work/flake" "$work/fp" "$work/zero" "$work/apps"
cp -r "$repo/tests/fixtures/outside-reads/." "$work/flake/"
sed "s|@BREAKBULK@|path:$repo|" "$here/flake.nix" > "$work/flake/flake.nix"
cp -r "$repo/tests/fixtures/outside-reads/." "$work/fp/"
sed "s|@BREAKBULK@|path:$repo|" "$here/flake-parts/flake.nix" > "$work/fp/flake.nix"
cp -r "$repo/tests/fixtures/walking-skeleton/." "$work/zero/"
sed "s|@BREAKBULK@|path:$repo|" "$here/zero-config/flake.nix" > "$work/zero/flake.nix"
cp -r "$repo/tests/fixtures/test-control/." "$work/apps/"
sed "s|@BREAKBULK@|path:$repo|" "$here/apps/flake.nix" > "$work/apps/flake.nix"
chmod -R u+w "$work/flake" "$work/fp" "$work/zero" "$work/apps"

nix=(nix --extra-experimental-features 'nix-command flakes')

for lazy in true false; do
  echo "lazy-trees = $lazy" >&2
  opts=(--option lazy-trees "$lazy" --no-write-lock-file)
  "${nix[@]}" eval "${opts[@]}" --json "path:$work/flake#fromSelf" > "$work/self.json"
  "${nix[@]}" eval "${opts[@]}" --json "path:$work/flake#fromPath" > "$work/path.json"
  "${nix[@]}" eval "${opts[@]}" --json "path:$work/flake#fromOutPath" > "$work/outpath.json"
  units=$(jq '.units.build + .units.test | length' "$work/path.json")
  views=$(jq '.views | length' "$work/path.json")
  if [ "$units" -eq 0 ] || [ "$views" -eq 0 ]; then
    echo "flake-self: no units ($units) or views ($views)" >&2
    exit 1
  fi
  for other in self outpath; do
    if ! cmp -s "$work/path.json" "$work/$other.json"; then
      echo "flake-self (lazy-trees $lazy): root = $other differs from root = ./." >&2
      diff <(jq -S . "$work/path.json") <(jq -S . "$work/$other.json") >&2 || true
      exit 1
    fi
  done
  echo "  $units unit derivations and $views source views identical" >&2

  "${nix[@]}" eval "${opts[@]}" --json "path:$work/fp#described" > "$work/fp.json"
  if ! cmp -s "$work/path.json" "$work/fp.json"; then
    echo "flake-self (lazy-trees $lazy): the flake-parts module's default root differs from root = ./." >&2
    diff <(jq -S . "$work/path.json") <(jq -S . "$work/fp.json") >&2 || true
    exit 1
  fi
  fpPkgs=$("${nix[@]}" eval "${opts[@]}" --json "path:$work/fp#packages.x86_64-linux" --apply builtins.attrNames)
  jq -e 'index("app")' <<< "$fpPkgs" > /dev/null || {
    echo "flake-self: flake-parts packages: $fpPkgs" >&2
    exit 1
  }
  echo "  flake-parts module, default root: identical; packages $fpPkgs" >&2

  zeroPkgs=$("${nix[@]}" eval "${opts[@]}" --json "path:$work/zero#packages.x86_64-linux" --apply builtins.attrNames)
  zeroShells=$("${nix[@]}" eval "${opts[@]}" --json "path:$work/zero#devShells.x86_64-linux" --apply builtins.attrNames)
  jq -e 'index("walking-skeleton")' <<< "$zeroPkgs" > /dev/null && jq -e 'index("default")' <<< "$zeroShells" > /dev/null || {
    echo "flake-self: zero-config packages $zeroPkgs, devShells $zeroShells" >&2
    exit 1
  }
  "${nix[@]}" build "${opts[@]}" --no-link "path:$work/zero#packages.x86_64-linux.walking-skeleton"
  zeroApps=$("${nix[@]}" eval "${opts[@]}" --json "path:$work/zero#apps.x86_64-linux" --apply builtins.attrNames)
  jq -e 'index("default/x86_64-unknown-linux-gnu/walking-skeleton/test-bin-walking-skeleton")' <<< "$zeroApps" > /dev/null || {
    echo "flake-self: zero-config apps $zeroApps" >&2
    exit 1
  }
  echo "  flake-parts module, zero configuration: packages $zeroPkgs, devShells $zeroShells, apps $zeroApps" >&2

  # `nix run` on a test app: at its attribute path (a derivation), and by
  # its name in `apps`, which needs no quoting.
  testApp="path:$work/apps#repo.workspaces.main.target.x86_64-unknown-linux-gnu.testApps.ctl.net"
  "${nix[@]}" run "${opts[@]}" "$testApp" -- --skip needs_network > "$work/run-attr.log"
  "${nix[@]}" run "${opts[@]}" "path:$work/apps#main/x86_64-unknown-linux-gnu/ctl/test-net" \
    -- --skip needs_network > "$work/run-app.log"
  for log in run-attr run-app; do
    grep -q 'test offline_ok ... ok' "$work/$log.log" || {
      cat "$work/$log.log" >&2
      echo "flake-self: nix run ($log) did not run the test" >&2
      exit 1
    }
  done
  echo "  nix run: a test app at its attribute path and by its name in apps" >&2

  if "${nix[@]}" eval "${opts[@]}" "path:$work/flake#wrong" 2> "$work/wrong.log"; then
    echo "flake-self: a wrong root was accepted" >&2
    exit 1
  fi
  grep -qF '`root` must be a path (`root = ./.;`), a flake'"'"'s `self`, or a store path' "$work/wrong.log" || {
    cat "$work/wrong.log" >&2
    echo "flake-self: the error does not say what root accepts" >&2
    exit 1
  }
done
echo "flake-self: ok" >&2
