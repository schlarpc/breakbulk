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
#     that names what `root` accepts.
#
# Planning runs through IFD, so the first run builds the fixture's plans.
# Not a flake check: it evaluates a flake.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${WORK:-${TMPDIR:-/tmp}/breakbulk-flake-self}
rm -rf "$work"
mkdir -p "$work/flake"
cp -r "$repo/tests/fixtures/outside-reads/." "$work/flake/"
sed "s|@BREAKBULK@|path:$repo|" "$here/flake.nix" > "$work/flake/flake.nix"
chmod -R u+w "$work/flake"

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

  if "${nix[@]}" eval "${opts[@]}" "path:$work/flake#wrong" 2> "$work/wrong.log"; then
    echo "flake-self: a wrong root was accepted" >&2
    exit 1
  fi
  grep -qF '`root` must be a path (`root = ./.;`) or a flake'"'"'s `self`' "$work/wrong.log" || {
    cat "$work/wrong.log" >&2
    echo "flake-self: the error does not say what root accepts" >&2
    exit 1
  }
done
echo "flake-self: ok" >&2
