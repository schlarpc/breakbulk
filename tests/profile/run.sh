#!/usr/bin/env bash
# Per-check build times of `nix flake check` (#31).
#
#   tests/profile/run.sh OUT_DIR [nix flake check options ...]
#
# Runs `nix flake check --keep-going` with a time on each log line
# (OUT_DIR/log), then writes OUT_DIR/report.md: each check's build time,
# total and exclusive (tests/profile/profile.py). Only what this run
# builds is counted: on a warm store that is nothing. To profile the
# rebuild every change to breakbulk's own programs causes, edit one of
# them first (a comment in crates/breakbulk-unit/src/main.rs is enough)
# and revert it afterwards.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
repo=$(readlink -f "$here/../..")
out=$1
shift
mkdir -p "$out"
system=$(nix eval --raw --impure --expr builtins.currentSystem)
status=0
python3 -I "$here/profile.py" record "$out/log" -- \
  nix flake check "$repo" --keep-going --log-format internal-json -v "$@" || status=$?
nix eval --json "$repo#checks.$system" --apply 'builtins.mapAttrs (_: d: d.drvPath)' >"$out/checks.json"
python3 -I "$here/profile.py" report "$out/log" "$out/checks.json" >"$out/report.md"
echo "nix flake check exited $status; report in $out/report.md" >&2
exit "$status"
