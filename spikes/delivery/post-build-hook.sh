#!/usr/bin/env bash
# post-build-hook: upload "$DRV_PATH^*" to $HOOK_CACHE, logging what was asked.
set -euo pipefail
{
  echo "hook DRV_PATH=$DRV_PATH"
  echo "     OUT_PATHS=$OUT_PATHS"
} >> "$HOOK_LOG"
"$NIX_MASTER/bin/nix" --store "$STORE" copy --to "$HOOK_CACHE" "$DRV_PATH^*" >> "$HOOK_LOG" 2>&1
