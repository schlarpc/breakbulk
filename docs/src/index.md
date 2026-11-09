# breakbulk

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo/breakbulk-lockup-dark.svg">
  <img src="logo/breakbulk-lockup.svg" alt="breakbulk" width="260">
</picture>

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

## How these docs are organized

- **[Tutorials](tutorials/first-project.md)** teach by doing. Start here if
  you have not used breakbulk before.
- **How-to guides** solve one task each, for readers who know the basics.
- **Reference** lists facts: every [module option](reference/options.md),
  the [presets](reference/presets.md), and what breakbulk
  [assumes about Cargo and rustc](reference/assumptions.md).
- **Explanation** says why breakbulk works the way it does.

breakbulk is early. Known gaps and planned work are in the
[issues](https://github.com/schlarpc/breakbulk/issues).
