#!/usr/bin/env bash
# Plain `cargo build -jJ` of a generated workspace, from clean, timed.
# Run inside `nix develop` (rustc 1.99 from nixpkgs).
#
#   spikes/scale/cargo-build.sh <generated dir> [jobs]
set -euo pipefail
dir=$(realpath "$1")
jobs=${2:-8}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Keep the user's ~/.cargo/config.toml (build-dir) out.
export CARGO_HOME=$scratch/cargo-home CARGO_TARGET_DIR=$scratch/target
mkdir -p "$CARGO_HOME"
cd "$dir"
# Warm-up: resolve and write Cargo.lock, so the timed run only compiles.
cargo metadata --format-version 1 >/dev/null
start=$(date +%s.%N)
cargo build -j"$jobs" --quiet
end=$(date +%s.%N)
"$CARGO_TARGET_DIR"/debug/app
echo "cargo build -j$jobs: $(echo "$end - $start" | bc) s"
