# Enter the dev shell automatically with direnv

[direnv](https://direnv.net/) loads the dev shell when you `cd` into the
project, and [nix-direnv](https://github.com/nix-community/nix-direnv)
caches it so that this is fast. breakbulk ships a direnv library that sets
up both and reloads the shell when a file it depends on changes.

## Set it up

Create `.envrc` next to `flake.nix`:

```bash
source "$(nix build --inputs-from . breakbulk#direnvrc --print-out-paths --out-link .direnv/breakbulk-direnvrc)"
use breakbulk
```

Then run `direnv allow`, and add `.direnv/` to `.gitignore`.

- `--inputs-from .` takes breakbulk from your `flake.lock`, so the library
  always matches the breakbulk version you build with. This assumes your
  flake's input is named `breakbulk`.
- The out-link under `.direnv/` keeps the library from being
  garbage-collected.
- `use breakbulk` takes the same arguments as nix-direnv's `use flake`, for
  example `use breakbulk .#other` for another dev shell.

## What it watches

nix-direnv's `use flake` reloads when `flake.nix` or `flake.lock` changes.
`use breakbulk` also reloads when any of these change, anywhere in the
repository:

- `Cargo.toml` and `Cargo.lock`: the packages, and so the native inputs
  the shell includes;
- `rust-toolchain` and `rust-toolchain.toml`;
- `.cargo/config.toml` and `.cargo/config`: the shell's target, linker and
  rustflags;
- `*.nix`: the modules your flake imports.

It finds them with `git ls-files`, so files ignored by git are not
watched; flakes do not see those files anyway.
