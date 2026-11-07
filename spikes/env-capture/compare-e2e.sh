#!/usr/bin/env bash
# Compare live (buildRustPackage) and replayed-capture builds of the fixture.
# Usage: spikes/env-capture/compare-e2e.sh native|cross
set -euo pipefail
cd "$(dirname "$0")"
which="${1:-native}"
live=$(nix-build -A "e2e.$which.live" --no-out-link --max-jobs 2 --cores 4)
replay=$(nix-build -A "e2e.$which.replay" --no-out-link --max-jobs 2 --cores 4)
echo "live:   $live"
echo "replay: $replay"

# Paths that legitimately differ: the build directory name and the vendor
# directory (buildRustPackage copies it into the build dir).
norm() {
  sed -E \
    -e 's#/build/(source|fixture)#/build/SRC#g' \
    -e 's#/build/cargo-vendor-dir|/build/[a-z0-9-]*-vendor(\.tar\.gz)?|/nix/store/[a-z0-9]{32}-cargo-vendor-dir#VENDOR#g' \
    -e 's#-[0-9a-f]{16}/out#-HASH/out#g'
}
# ring walks directories with read_dir, so its rerun-if-changed order follows
# the file system, not the environment. Compare those lines as a set.
normf() { norm < "$1" | awk '/rerun-if-changed=/ { r[n++] = $0; next } { print } END { asort(r); for (i = 1; i <= n; i++) print r[i] }'; }

echo; echo "## files"
diff <(cd "$live" && find . -type f | sort) <(cd "$replay" && find . -type f | sort) || true

echo; echo "## build-script directives (normalised)"
for f in "$live"/directives/*; do
  n=$(basename "$f")
  if ! diff <(normf "$f") <(normf "$replay/directives/$n") > /dev/null; then
    echo "--- $n differs:"; diff <(normf "$f") <(normf "$replay/directives/$n") || true
  else
    echo "same: $n"
  fi
done

echo; echo "## bindgen output"
for f in "$live"/bindings/*; do
  n=$(basename "$f")
  cmp -s "$f" "$replay/bindings/$n" && echo "identical: $n" || echo "DIFFERENT: $n"
done

echo; echo "## cc-rs archives (object bytes)"
for f in "$live"/archives/*; do
  n=$(basename "$f")
  cmp -s "$f" "$replay/archives/$n" && echo "identical: $n" || echo "DIFFERENT: $n"
done

echo; echo "## final binary"
r=$(nix-build -A pkgs.llvm --no-out-link 2>/dev/null)  # multi-target readelf/objcopy
for b in "$live/env-capture-fixture" "$replay/env-capture-fixture"; do
  echo "$b"
  "$r/bin/llvm-readelf" -dW "$b" | grep -E 'NEEDED|RUNPATH|FLAGS' | sed -E 's/^ *0x[0-9a-f]+ //'
done
cmp -s "$live/env-capture-fixture" "$replay/env-capture-fixture" && echo "binaries identical" || echo "binaries differ"

# The capture drops stdenv's "-rpath $out/lib" (setup.sh _addRpathPrefix) on
# purpose. Control: the same live build with NIX_NO_SELF_RPATH=1.
echo; echo "## control: live build with NIX_NO_SELF_RPATH=1"
ctl=$(nix-build -A "e2e.$which.liveNoSelfRpath" --no-out-link --max-jobs 2 --cores 4 2>/dev/null)
echo "control: $ctl"
for f in env-capture-fixture archives/* bindings/*; do
  for g in "$ctl"/$f; do
    rel="${g#"$ctl"/}"
    cmp -s "$g" "$replay/$rel" && echo "byte-identical: $rel" || echo "DIFFERENT: $rel"
  done
done
