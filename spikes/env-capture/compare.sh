#!/usr/bin/env bash
# Build live and replayed probes and diff them.
# Usage: spikes/env-capture/compare.sh [probe names...]
set -euo pipefail
cd "$(dirname "$0")"
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(base openssl bindgen crossBase crossOpenssl)
for n in "${names[@]}"; do
  live=$(nix-build -A "probes.$n.live" --no-out-link --max-jobs 2 --cores 4 2>/dev/null)
  replay=$(nix-build -A "probes.$n.replay" --no-out-link --max-jobs 2 --cores 4 2>/dev/null)
  echo "=== $n: $live vs $replay"
  # gcc temp file names are random per run.
  diff <(sed -E 's/cc[A-Za-z0-9]{6}\.(res|o|s)/ccTMP.\1/g' "$live") \
       <(sed -E 's/cc[A-Za-z0-9]{6}\.(res|o|s)/ccTMP.\1/g' "$replay") || true
done
