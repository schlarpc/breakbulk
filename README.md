<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/breakbulk-lockup-dark.svg">
    <img src="docs/logo/breakbulk-lockup.svg" alt="breakbulk" width="260">
  </picture>
</h1>

breakbulk builds Rust projects with Nix, one derivation per Cargo unit.

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
      devShells.${system}.default = repo.workspaces.default.devShell;
    };
}
```

- `nix build` builds the `app` package.
- `nix flake check` builds every product and runs every test.
- `nix develop` gives a shell where plain `cargo` behaves like breakbulk's
  planner.

The [tutorial](https://schlarpc.github.io/breakbulk/tutorials/first-project.html) walks through this
step by step.

## Documentation

<https://schlarpc.github.io/breakbulk/>

- How-to guides: [native libraries](https://schlarpc.github.io/breakbulk/how-to/native-library.html),
  [other targets](https://schlarpc.github.io/breakbulk/how-to/targets.html) (musl, aarch64, Windows,
  wasm), [narrowing sources](https://schlarpc.github.io/breakbulk/how-to/filter-source.html),
  [treefmt](https://schlarpc.github.io/breakbulk/how-to/treefmt.html),
  [binary caches](https://schlarpc.github.io/breakbulk/how-to/binary-cache.html).
- Reference: [module options](https://schlarpc.github.io/breakbulk/reference/options.html),
  [presets](https://schlarpc.github.io/breakbulk/reference/presets.html),
  [outputs](https://schlarpc.github.io/breakbulk/reference/outputs.html).
- Explanation: [why breakbulk](https://schlarpc.github.io/breakbulk/explanation/why.html),
  [how a build works](https://schlarpc.github.io/breakbulk/explanation/architecture.html),
  [trade-offs](https://schlarpc.github.io/breakbulk/explanation/trade-offs.html).

## Status

Early. The default mode reads Cargo's plan at evaluation time
(import-from-derivation); a mode without it works on Nix master and turns
on by itself once Nix 2.36 ships. Known gaps and planned work are in the
[issues](https://github.com/schlarpc/breakbulk/issues).

## Development

- `nix develop -c cargo test` runs the Rust tests.
- `nix flake check` runs the test fixtures. Some download the Windows SDK,
  build cross toolchains and run wine.
- CI (`.github/workflows/ci.yml`) runs on every push to `main` and every
  pull request: `cargo fmt --check`, `cargo clippy -D warnings` and
  `cargo test` in both Cargo workspaces, and the flake checks listed in
  [`.github/fast-checks`](.github/fast-checks). The other flake checks and the
  `nix run .#test-*` scripts are too heavy for hosted runners and run
  locally.
- `nix run .#test-dynamic`, `.#test-cutoff`, `.#test-options` and
  `.#test-linux-portable-container` run tests that need a Nix master build
  or extra downloads.

breakbulk is MIT-licensed. See [LICENSE](LICENSE).
