# Copy what we compare out of target/: build-script directives, generated
# bindings, cc-rs archives, the final binary. Run from the crate root.
#   $1  target triple
set -eu
t="target/$1/release"
mkdir -p "$out/directives" "$out/archives" "$out/bindings"
for d in "$t"/build/*/ target/release/build/*/; do
  [ -f "$d/output" ] || continue
  name=$(basename "$d"); name="${name%-*}"   # strip cargo hash
  plat=target; case "$d" in target/release/*) plat=host ;; esac
  cp "$d/output" "$out/directives/$plat-$name"
  for a in "$d"/out/*.a "$d"/out/*/*.a; do
    [ -f "$a" ] && cp "$a" "$out/archives/$plat-$name-$(basename "$a")"
  done
  for b in "$d"/out/*.rs; do
    [ -f "$b" ] && cp "$b" "$out/bindings/$plat-$name-$(basename "$b")"
  done
done
cp "$t/env-capture-fixture" "$out/"
true
