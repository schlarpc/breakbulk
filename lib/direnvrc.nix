# A direnvrc for projects built with breakbulk: nix-direnv, plus
# `use breakbulk`, which is `use flake` that also reloads when a file
# breakbulk reads for the dev shell changes. `use flake` watches only
# flake.nix and flake.lock; the dev shell also depends on every Cargo
# manifest and lockfile (the packages and their env captures), the toolchain
# file, Cargo config (the shell's target, linker and rustflags) and any Nix
# file the flake imports.
#
#   # .envrc
#   source "$(nix build --inputs-from . breakbulk#direnvrc --print-out-paths --out-link .direnv/breakbulk-direnvrc)"
#   use breakbulk
#
# `--inputs-from .` takes breakbulk from the project's flake.lock, and the
# out-link keeps it from being garbage-collected. Arguments are passed to
# `use flake` (`use breakbulk .#other`).
pkgs:
pkgs.writeText "breakbulk-direnvrc" ''
  source ${pkgs.nix-direnv}/share/nix-direnv/direnvrc

  use_breakbulk() {
    local files=()
    mapfile -d "" files < <(git ls-files -z --cached --others --exclude-standard -- \
      ':(glob)**/Cargo.toml' ':(glob)**/Cargo.lock' \
      ':(glob)**/rust-toolchain' ':(glob)**/rust-toolchain.toml' \
      ':(glob)**/.cargo/config' ':(glob)**/.cargo/config.toml' \
      ':(glob)**/*.nix' 2>/dev/null)
    if (( ''${#files[@]} )); then
      watch_file "''${files[@]}"
    fi
    use flake "$@"
  }
''
