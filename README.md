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

Design: [docs/design.md](docs/design.md). Implementation:
[docs/implementation.md](docs/implementation.md). Options:
[docs/options.md](docs/options.md).

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

With no configuration, the Cargo workspace at the repository root is used.
Settings go in `modules`, for example:

```nix
modules = [{
  packages.openssl-sys.inputs = p: [ p.openssl ];  # a native library for one crate
  packages.app.env.GIT_REV = self.rev or "dirty";  # reaches only `app`'s units
}];
```

With flake-parts, import `breakbulk.lib.flakeModule`.

## Configuration

Configuration is NixOS-style modules; every option is in
[docs/options.md](docs/options.md). breakbulk reads your project's own
`.cargo/config.toml`, but not `~/.cargo/config.toml` or `CARGO_*`
variables in your shell.

## Presets

A target's toolchain comes from a preset; the target triple picks the
mechanism.

| Preset | Produces | Example triples |
| --- | --- | --- |
| `linux` | a normal Linux program (the native default) | `x86_64-unknown-linux-gnu`, `aarch64-…`, `riscv64gc-…` |
| `linuxStatic` | a self-contained static Linux program | `*-linux-musl`, or the host triple with static glibc |
| `linuxPortable` | a program for any Linux with glibc at least a given version | the host triple |
| `windows` | a Windows program (MSVC or MinGW) | `*-pc-windows-msvc`, `*-pc-windows-gnu`, `*-gnullvm` |
| `wasmWeb` | wasm for browsers and Node, through wasm-bindgen | `wasm32-unknown-unknown` |
| `wasmComponent` | a WebAssembly component | `wasm32-unknown-unknown`, `wasm32-wasip2` |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree; breakbulk downloads them with `breakbulk.xwinSdk`.

## Status

Early. The default mode reads Cargo's plan at evaluation time
(import-from-derivation); a mode without it works on Nix master and turns
on by itself once Nix 2.36 ships. Known gaps and planned work are in the
[issues](https://github.com/schlarpc/breakbulk/issues).

## Development

- `nix develop -c cargo test` runs the Rust tests.
- `nix flake check` runs the test fixtures. Some download the Windows SDK,
  build cross toolchains and run wine.
- `nix run .#test-dynamic`, `.#test-cutoff`, `.#test-options` and
  `.#test-linux-portable-container` run tests that need a Nix master build
  or extra downloads.

breakbulk is MIT-licensed. See [LICENSE](LICENSE).
