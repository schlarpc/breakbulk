# Your first project

In this tutorial you build a small Rust program with breakbulk, run its
tests through Nix, and open a development shell. You need Nix with flakes
enabled.

## 1. Make a Cargo project

```sh
cargo new app
cd app
cargo generate-lockfile
git init
git add .
```

breakbulk needs a `Cargo.lock`, and `cargo new` does not write one.
Nix flakes see only files that git knows about, so `git add` every new
file before you build.

## 2. Add a flake

Create `flake.nix` next to `Cargo.toml`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    breakbulk.url = "github:schlarpc/breakbulk";
  };

  outputs = { self, nixpkgs, breakbulk }:
    let
      system = "x86_64-linux";
      repo = breakbulk.lib.mkRepository {
        pkgs = nixpkgs.legacyPackages.${system};
        root = self;
      };
    in
    {
      packages.${system}.default = repo.workspaces.default.packages.app;
      checks.${system} = repo.checks;
      devShells.${system}.default = repo.workspaces.default.devShell;
    };
}
```

Change `system` if you are not on x86_64 Linux.

`mkRepository` takes the repository (`root`) and finds the Cargo workspace
at its root. That workspace is called `default`. `packages.app` is the
`app` package from `Cargo.toml`.

Run `git add flake.nix`.

## 3. Build

```sh
nix build
./result/bin/app
```

The program prints `Hello, world!`.

The first build runs Cargo once to record its plan, then builds each unit
as its own derivation. Run `nix build` again: nothing rebuilds.

## 4. Run the tests

Add a test to `src/main.rs`:

```rust
#[test]
fn adds() {
    assert_eq!(2 + 2, 4);
}
```

Then:

```sh
nix flake check
```

`repo.checks` builds every product and runs every test binary, each in its
own derivation.

## 5. Use the development shell

```sh
nix develop
cargo build
```

In the shell, plain `cargo` sees the same configuration as breakbulk's
planner. Use it for the edit-compile loop; use `nix build` for results you
keep or share.

To enter the shell automatically when you `cd` into the project, [set up
direnv](../how-to/direnv.md).

## Next steps

- Every setting is a module option. See the
  [module options](../reference/options.md).
- To build for another target, choose a [preset](../reference/presets.md).
