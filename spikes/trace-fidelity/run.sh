#!/usr/bin/env bash
# Runs a spike experiment script with toolchains and tools resolved from the
# repository's flake inputs (nixpkgs, rust-overlay). Offline after the first
# run; CARGO_HOME is always a scratch directory (see bbtrace.py).
#
#   spikes/trace-fidelity/run.sh exp_directives.py [args…]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo"

pkgs="let f = builtins.getFlake (toString $repo); in import f.inputs.nixpkgs { system = \"x86_64-linux\"; overlays = [ f.inputs.rust-overlay.overlays.default ]; }"
build() { nix build --max-jobs 2 --cores 4 --impure --no-link --print-out-paths --expr "$1"; }

export BB_TC_1_95_0=$(build "($pkgs).rust-bin.stable.\"1.95.0\".minimal")
export BB_TC_1_97_0=$(build "($pkgs).rust-bin.stable.\"1.97.0\".minimal")
export BB_TC_1_99_0=$(build "($pkgs).rust-bin.stable.\"1.99.0\".minimal")
export BB_TC_nightly=$(build "($pkgs).rust-bin.nightly.latest.minimal")
tools=$(build "with ($pkgs); buildEnv { name = \"bb-spike-tools\"; paths = [ stdenv.cc coreutils bash gnugrep gnused findutils ]; }")
python=$(build "($pkgs).python3")
export BB_TOOLS_PATH="$tools/bin"

CARGO_BUILD_JOBS=4 nix develop -c cargo build -q -p breakbulk-shim
export BB_SHIM="$repo/target/debug/breakbulk-shim"
export BB_SCRATCH=${BB_SCRATCH:-/tmp/claude-1000/-home-schlarpc-breakbulk/spike-a/runs}

exec "$python/bin/python3" "$here/$1" "${@:2}"
