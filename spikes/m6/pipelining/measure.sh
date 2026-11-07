#!/usr/bin/env bash
# Pipelining-gap measurement (M6 spike). For one workspace at one pinned rev:
#   1. export the rev into a build dir outside $HOME,
#   2. record Cargo's unit graph (dependency edges),
#   3. run `cargo build --timings` for the given profile at -j$JOBS,
#   4. keep cargo-timing.html and unit-graph.json for analyze.py.
# Usage: measure.sh <git-clone-dir> <rev> <name> <profile> [extra cargo args...]
# Env: OUT (results dir), WORK (scratch), JOBS (default 8).
# Run inside a shell with cargo/rustc/cc (e.g. `nix develop` of this repo).
set -euo pipefail
src=$1 rev=$2 name=$3 profile=$4
shift 4
: "${OUT:?}" "${WORK:?}"
JOBS=${JOBS:-8}
dir=$WORK/$name-$rev
if [ ! -d "$dir" ]; then
  mkdir -p "$dir"
  git -C "$src" archive "$rev" | tar -x -C "$dir"
fi
# Never let the user's ~/.cargo/config.toml (build-dir, etc.) in.
export CARGO_HOME=$WORK/cargo-home
export CARGO_TARGET_DIR=$dir/target-$profile
unset CARGO_BUILD_TARGET RUSTFLAGS CARGO_INCREMENTAL CARGO_BUILD_BUILD_DIR
export HELIX_DISABLE_AUTO_GRAMMAR_BUILD=1
cd "$dir"
cargo fetch --locked
res=$OUT/$name-$profile
mkdir -p "$res"
# --unit-graph is unstable; RUSTC_BOOTSTRAP only for this graph-only call.
RUSTC_BOOTSTRAP=1 cargo build --locked --profile "$profile" "$@" \
  -Z unstable-options --unit-graph > "$res/unit-graph.json"
rm -rf "$CARGO_TARGET_DIR"
start=$(date +%s)
cargo build --locked --profile "$profile" "$@" -j"$JOBS" --timings 2> "$res/build.log"
end=$(date +%s)
cp "$CARGO_TARGET_DIR"/cargo-timings/cargo-timing.html "$res/"
printf '{"name":"%s","rev":"%s","profile":"%s","jobs":%s,"wall":%s,"args":"%s","loadavg":"%s"}\n' \
  "$name" "$rev" "$profile" "$JOBS" "$((end - start))" "$*" "$(cut -d' ' -f1-3 /proc/loadavg)" \
  > "$res/meta.json"
rm -rf "$CARGO_TARGET_DIR"
