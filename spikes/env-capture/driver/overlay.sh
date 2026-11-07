# Sourced by rustc-wrapper.sh and by build-script wrappers.
# Emulates breakbulk's per-unit environment layering inside one cargo run:
#
#   base (the outer, plain derivation env) < capture(platform, package)
#   < cargo's own env for the unit (CARGO_*, OUT_DIR, TARGET, ...)
#
# Cargo's own variables are already in the environment and no capture sets
# them, so overlaying the capture on top keeps them.
#
#   $1  platform: host | target
#
# BB_CAPTURES is a JSON object {"host": {"*": env.json, "<pkg>": env.json},
# "target": {...}}; BB_JQ is jq's absolute path; BB_SEED the random seed.
bb_overlay() {
  local platform="$1" pkg="${CARGO_PKG_NAME:-}" file kv
  file=$("$BB_JQ" -r --arg p "$platform" --arg n "$pkg" \
    '.[$p][$n] // .[$p]["*"]' <<<"$BB_CAPTURES")
  # Keep the toolchain reachable: PATH is merged, not replaced.
  local outerPath="$PATH"
  while IFS= read -r -d '' kv; do
    export "$kv"
  done < <("$BB_JQ" -j 'to_entries[] | "\(.key)=\(.value)\u0000"' "$file")
  export PATH="$PATH:$outerPath"
  # Same position as reproducible-builds.sh in a live stdenv.
  export NIX_CFLAGS_COMPILE=" -frandom-seed=$BB_SEED${NIX_CFLAGS_COMPILE:-}"
  export BB_APPLIED_CAPTURE="$platform:$pkg:$file"
  if [ -n "${BB_LOG:-}" ]; then
    echo "$BB_APPLIED_CAPTURE ${BB_WHAT:-}" >> "$BB_LOG"
  fi
}
