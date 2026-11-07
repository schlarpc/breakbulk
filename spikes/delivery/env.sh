# Source me. Runs a Nix master build against a private chroot store, with a
# private config, so the system daemon and /etc/nix are never touched.
#
#   SPIKE_DIR   scratch directory (store root, config, caches)
#   NIX_MASTER  a Nix master build; default: the $SPIKE_DIR/nix-master link
#               that setup.sh creates
#   SPIKE_NIX_CONF  extra nix.conf lines (substituters, post-build-hook, ...)

: "${SPIKE_DIR:=/tmp/claude-1000/-home-schlarpc-breakbulk/spike-b/w}"
: "${NIX_MASTER:=$(readlink -f "$SPIKE_DIR/nix-master")}"
export SPIKE_DIR NIX_MASTER

mkdir -p "$SPIKE_DIR/etc" "$SPIKE_DIR/cache" "$SPIKE_DIR/store"
cat > "$SPIKE_DIR/etc/nix.conf" <<EOF
experimental-features = nix-command ca-derivations dynamic-derivations
sandbox = true
substituters =
build-users-group =
max-jobs = 2
cores = 4
${SPIKE_NIX_CONF:-}
EOF
: > "$SPIKE_DIR/etc/empty.conf"

export NIX_CONF_DIR="$SPIKE_DIR/etc"
export NIX_USER_CONF_FILES="$SPIKE_DIR/etc/empty.conf"
export XDG_CACHE_HOME="$SPIKE_DIR/cache"
export STORE="local?root=$SPIKE_DIR/store"
unset NIX_REMOTE NIX_PATH

# nixm: Nix master on the private store.
nixm() { "$NIX_MASTER/bin/nix" --store "$STORE" "$@"; }
