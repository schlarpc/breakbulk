<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/breakbulk-lockup-dark.svg">
    <img src="docs/logo/breakbulk-lockup.svg" alt="breakbulk" width="260">
  </picture>
</h1>

[![Documentation](https://img.shields.io/badge/docs-schlarpc.github.io%2Fbreakbulk-blue)](https://schlarpc.github.io/breakbulk/)
[![CI](https://github.com/schlarpc/breakbulk/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/schlarpc/breakbulk/actions/workflows/ci.yml)

breakbulk builds Rust projects with Nix, one derivation per Cargo unit.
**[Read the documentation](https://schlarpc.github.io/breakbulk/)**, or
start with the [tutorial](https://schlarpc.github.io/breakbulk/tutorials/first-project.html).

A Cargo unit is one rustc call (a library, a binary, a test harness) or one
build-script run. breakbulk runs your own Cargo once to record what it would
do. It then turns each recorded step into its own Nix derivation, with
Cargo's exact command line. So:

- builds behave like `cargo build`, including build scripts, profiles,
  `.cargo/config.toml`, cross targets, wasm and Windows;
- each crate is a separate store path, shared across workspaces, projects
  and machines through an ordinary binary cache;
- a change rebuilds only the crates it affects and their dependents;
- nothing generated is checked in.

The name: [break-bulk cargo](https://en.wikipedia.org/wiki/Breakbulk_cargo) is loaded piece by piece, not in containers.

## Quickstart

```nix
# flake.nix
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
      apps.${system} = repo.apps;
      devShells.${system}.default = repo.workspaces.default.devShell;
    };
}
```

- `nix build` builds the `app` package.
- `nix flake check` builds every product and runs every test.
- `nix run .#default/x86_64-unknown-linux-gnu/app/test-bin-app` runs one
  test binary on your machine, outside the sandbox.
- `nix develop` gives a shell where plain `cargo` behaves like breakbulk's
  planner.

## Status

**Early, mostly feature complete.** Linux (glibc, musl, static, portable),
Windows (MSVC and MinGW), wasm (browser, components, WASI) and riscv64
targets build and test, with build scripts, doctests, `cargo doc`,
variants and post-link stages. It has been used on the author's own
repositories; options may still change.

Not yet: macOS targets ([#13](https://github.com/schlarpc/breakbulk/issues/13)). Until Nix 2.36 ships, breakbulk reads Cargo's plan at
evaluation time (import-from-derivation), and the first evaluation of a
large workspace takes minutes ([#19](https://github.com/schlarpc/breakbulk/issues/19)). Everything planned is in
the [issues](https://github.com/schlarpc/breakbulk/issues).

## Development

- `nix develop -c cargo test` runs the Rust tests.
- `nix flake check` runs every check, the test fixtures included.

More, including what CI runs: [How breakbulk is tested](https://schlarpc.github.io/breakbulk/explanation/internals/testing.html).

breakbulk is MIT-licensed. See [LICENSE](LICENSE).
