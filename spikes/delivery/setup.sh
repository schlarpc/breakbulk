#!/usr/bin/env bash
# Seed the private store with the tools the prototype builders use, and write
# $SPIKE_DIR/tools.nix pointing at them.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
NIX_REV=${NIX_REV:-94c011f5040d8c1b1e251b17b5c79ff370208663}
: "${SPIKE_DIR:=/tmp/claude-1000/-home-schlarpc-breakbulk/spike-b/w}"
mkdir -p "$SPIKE_DIR"
[ -e "$SPIKE_DIR/nix-master" ] ||
  nix build -o "$SPIKE_DIR/nix-master" "github:NixOS/nix/$NIX_REV#nix-cli"
source "$here/env.sh"

mapfile -t paths < <(nix build --no-link --print-out-paths \
  "nixpkgs#bash^out" "nixpkgs#coreutils^out" "nixpkgs#jq^bin" "nixpkgs#gnused^out" "nixpkgs#python3Minimal^out")
paths+=("$NIX_MASTER")
paths+=("$(nix build --impure --no-link --print-out-paths -f "$here/bb-drv/default.nix")")

"$NIX_MASTER/bin/nix" copy --no-check-sigs --to "$STORE" "${paths[@]}"

cat > "$SPIKE_DIR/tools.nix" <<EOF
{
  bash = builtins.storePath "${paths[0]}";
  coreutils = builtins.storePath "${paths[1]}";
  jq = builtins.storePath "${paths[2]}";
  sed = builtins.storePath "${paths[3]}";
  python = builtins.storePath "${paths[4]}";
  nix = builtins.storePath "${paths[5]}";
  bbdrv = builtins.storePath "${paths[6]}";
}
EOF
echo "wrote $SPIKE_DIR/tools.nix"
