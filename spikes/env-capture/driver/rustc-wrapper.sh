# RUSTC_WRAPPER: cargo calls `bash rustc-wrapper.sh <rustc> <args...>`
# (via the executable shim written by build.sh).
#
# - Compile units: platform = target when cargo passed --target, else host.
#   The capture for (platform, package) is overlaid, then rustc runs.
# - Build-script compiles: after rustc writes the binary, it is moved to
#   <bin>.real and replaced by a script that overlays the capture for the
#   platform the script runs for (TARGET), then execs the real binary.
#   This is the per-unit env breakbulk-unit will give a `run` unit.
set -eu
source "$BB_DRIVER/overlay.sh"

rustc="$1"; shift
platform=host crate="" outdir="" extra=""
prev=""
for a in "$@"; do
  case "$prev" in
    --target) platform=target ;;
    --crate-name) crate="$a" ;;
    --out-dir) outdir="$a" ;;
    -C) case "$a" in extra-filename=*) extra="${a#extra-filename=}" ;; esac ;;
  esac
  case "$a" in --target=*) platform=target ;; esac
  prev="$a"
done

# Queries (-vV, --print) and anything without a crate name: run unchanged.
if [ -z "$crate" ]; then exec "$rustc" "$@"; fi

(
  BB_WHAT="compile $crate"
  bb_overlay "$platform"
  exec "$rustc" "$@"
)

case "$crate" in build_script_*) is_bs=1 ;; *) is_bs= ;; esac
if [ -n "$is_bs" ]; then
  bin="$outdir/$crate$extra"
  mv "$bin" "$bin.real"
  cat > "$bin" <<EOF
#!$BB_BASH
# build-script run: pick the capture for the platform this script builds for.
source "$BB_DRIVER/overlay.sh"
if [ "\$TARGET" = "\$BB_TARGET_TRIPLE" ] && [ "\$BB_TARGET_TRIPLE" != "\$BB_HOST_TRIPLE" ]; then
  p=target
elif [ "\$BB_TARGET_TRIPLE" = "\$BB_HOST_TRIPLE" ]; then
  p=target
else
  p=host
fi
BB_WHAT="run \$CARGO_PKG_NAME TARGET=\$TARGET"
bb_overlay "\$p"
exec "$bin.real" "\$@"
EOF
  chmod +x "$bin"
fi
