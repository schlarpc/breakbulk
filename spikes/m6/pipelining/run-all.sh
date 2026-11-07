#!/usr/bin/env bash
# Runs measure.sh over the pinned corpus. Usage (from the repo root):
#   nix develop -c spikes/m6/pipelining/run-all.sh <scratch-dir> [name...]
# <scratch-dir>/src/<name> must be a git clone of each workspace.
set -euo pipefail
M=$1
shift
here=$(cd "$(dirname "$0")" && pwd)
export OUT=$M/results WORK=$M/work
# name rev profile [extra cargo args]
corpus=(
  "ripgrep 91f5d22 dev"
  "ripgrep 91f5d22 release"
  "helix ba40e547 dev"
  "helix ba40e547 release"
  "rust-analyzer 2026-11-02 dev"
  "rust-analyzer 2026-11-02 release"
  "nushell 0.116.1 dev"
  "nushell 0.116.1 release"
)
for line in "${corpus[@]}"; do
  read -r name rev profile extra <<<"$line"
  if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx -- "$name\|$name-$profile"; then continue; fi
  echo "== $name $rev $profile" >&2
  "$here/measure.sh" "$M/src/$name" "$rev" "$name" "$profile" $extra
done
