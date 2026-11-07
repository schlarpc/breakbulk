#!/usr/bin/env bash
# Regenerate docs/options.md from the module options. The flake check
# `loose-ends-options-doc-in-sync` fails while the committed file differs.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(nix build --no-link --print-out-paths ".#checks.$(nix config show system).loose-ends-options-md")
install -m 644 "$out" docs/options.md
echo "updated docs/options.md"
