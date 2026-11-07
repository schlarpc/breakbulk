#!/usr/bin/env bash
# Micro-check: which edits keep a library's rmeta bytes, per toolchain.
set -euo pipefail

NIGHTLY=${NIGHTLY:?the bin directory of a nightly toolchain}
D=${WORK:-$(mktemp -d)}
here=$(dirname "$(readlink -f "$0")")
cd "$D"
variant() { # name, then source on stdin
  mkdir -p "src-$1"; cat > "src-$1/lib.rs"
}
variant base <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant private-body <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 3 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant private-body-big <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { let mut s = x; for i in 0..x { s = s.wrapping_mul(31).wrapping_add(i); if s % 7 == 3 { s ^= 0x55; } } s }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant public-body <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 2 }
fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant generic-body <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { let u = t.clone(); u }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant async-body <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 2 }
pub fn tail() -> u32 { 7 }
EOF
variant line-shift <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }

fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant comment <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 2 } // a comment
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
variant trailing <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 2 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
// trailing comment
EOF
variant same-len <<'EOF'
pub fn public(x: u32) -> u32 { private(x) + 1 }
fn private(x: u32) -> u32 { x * 3 }
pub fn generic<T: Clone>(t: &T) -> T { t.clone() }
pub async fn asy(x: u32) -> u32 { x + 1 }
pub fn tail() -> u32 { 7 }
EOF
printf '%-16s %-8s' edit opt
for tc in stable nightly nightly-hirsvh; do printf ' %-15s' "$tc"; done
echo
for opt in 0 3; do
  for v in trailing same-len private-body private-body-big public-body generic-body async-body line-shift comment; do
    printf '%-16s %-8s' "$v" "O$opt"
    for tc in stable nightly nightly-hirsvh; do
      case $tc in
        stable) rc=rustc; extra=() ;;
        nightly) rc=$NIGHTLY/rustc; extra=() ;;
        nightly-hirsvh) rc=$NIGHTLY/rustc; extra=(-Zmetadata-crate-hash=no) ;;
      esac
      h=()
      for s in base "$v"; do
        # Same path for both versions: copy into a fixed file name.
        cp "src-$s/lib.rs" lib.rs
        rm -rf out && mkdir out
        $rc --edition 2021 --crate-type lib --crate-name m --emit=metadata,link -C opt-level=$opt \
          -C metadata=fixed "${extra[@]}" lib.rs --out-dir out
        h+=("$(sha256sum out/libm.rmeta | cut -c1-12)")
      done
      if [ "${h[0]}" = "${h[1]}" ]; then r=same; else r=changed; fi
      printf ' %-15s' "$r"
    done
    echo
  done
done
# Where a trailing-comment edit shows up: the source file's MD5.
for tc in stable nightly; do
  rc=rustc
  [ $tc = nightly ] && rc=$NIGHTLY/rustc
  for s in base trailing; do
    cp "src-$s/lib.rs" lib.rs
    rm -rf "o-$tc-$s" && mkdir "o-$tc-$s"
    $rc --edition 2021 --crate-type lib --crate-name m --emit=metadata -C metadata=fixed lib.rs --out-dir "o-$tc-$s"
  done
done
python3 "$here/source-hash.py" "$D"
