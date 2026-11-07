#!/usr/bin/env bash
# Producer builds the dynamic-derivation graph with a post-build-hook that runs
# `nix copy --to file://… "$DRV_PATH^*"`. A fresh consumer store then builds
# the same `linked` stage with only that cache as substituter.
#
#   cache-experiment.sh <base dir> <attr>...   (attrs of dyn.nix, e.g. linked.app)
#   DROP_BUILD_TRACE=1 removes the realisations before the consumer runs.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
base=$1; shift
attrs=("$@")
rm -rf "$base"; mkdir -p "$base/cache"
cache="file://$base/cache?compression=none"

echo "=== producer"
export SPIKE_DIR=$base/producer
mkdir -p "$SPIKE_DIR"
ln -sfn "$(readlink -f "${NIX_MASTER:-/tmp/claude-1000/-home-schlarpc-breakbulk/spike-b/w/nix-master}")" "$SPIKE_DIR/nix-master"
export HOOK_CACHE=$cache HOOK_LOG=$base/hook.log
export SPIKE_NIX_CONF="post-build-hook = $here/post-build-hook.sh"
"$here/setup.sh" >/dev/null 2>&1
(source "$here/env.sh"; export STORE NIX_MASTER
 nixm build -f "$here/dyn.nix" "${attrs[@]}" --no-link --print-out-paths 2>&1 | grep -v 'Internet access')
echo "--- hook log"; cat "$HOOK_LOG"
echo "--- cache contents"
(cd "$base/cache" && find . -type f ! -name '*.nar' | sort)
for f in "$base"/cache/*.narinfo; do
  echo "$(basename "$f"): $(grep '^StorePath:' "$f" | cut -d' ' -f2 | sed 's|/nix/store/[^-]*-||')"
done
find "$base/cache" -path '*realisations*' -type f -o -path '*build-trace*' -type f | while read -r f; do
  echo "--- $f"; cat "$f"; echo
done

if [[ ${DROP_BUILD_TRACE:-} ]]; then
  # Simulate a cache that stores no realisations (Attic, FlakeHub Cache).
  echo "=== dropping build-trace-v2 from the cache"
  rm -rf "$base/cache/build-trace-v2" "$base/cache/realisations"
fi

echo "=== consumer"
export SPIKE_DIR=$base/consumer
mkdir -p "$SPIKE_DIR"
ln -sfn "$(readlink -f "$base/producer/nix-master")" "$SPIKE_DIR/nix-master"
export SPIKE_NIX_CONF="substituters = $cache
require-sigs = false"
"$here/setup.sh" >/dev/null 2>&1
(source "$here/env.sh"
 nixm build -f "$here/dyn.nix" "${attrs[@]}" --no-link --print-out-paths -v 2>&1 |
   grep -E 'copying path|building|querying|realisation|warning|error|^/nix' | grep -v 'Internet access')
echo "--- consumer store paths (excluding tools)"
ls "$base/consumer/store/nix/store" | grep -v -E 'bash|coreutils|jq|gnused|python|nix-|readline|glibc|gcc|openssl|sqlite|curl|boehm|libs|xz|zlib|zstd|brotli|nghttp|ngtcp|onetbb|pcre|publicsuffix|s2n|aws|libarchive|lowdown|editline|ncurses|mpdecimal|expat|libffi|bzip|acl|attr|gmp|libcpuid|libgit|libssh|http-parser|keyutils|krb5|idn|psl|libunistring|libxcrypt|tzdata|mailcap|bzip2|libmd|libbsd|nlohmann|toml|blake|util-linux|systemd|libseccomp|libsodium|libyaml|lix|libblake|base|boost|llhttp|abseil|crc|gnugrep|kmod' || true
