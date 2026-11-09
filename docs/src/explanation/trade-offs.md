# Trade-offs and risks

breakbulk gives up some things to get per-crate sharing with Cargo's exact
behavior. This page lists them, with the issues that track each.

## Costs

- **Per-derivation overhead.** Every unit is a Nix build: sandbox setup,
  input registration, output registration. For tiny crates this costs
  more than rustc does, so a cold build of a workspace of many small
  crates is slower than `cargo build`. Real crates compile for longer, so
  the overhead's share is smaller.
- **No pipelining.** Cargo starts a dependent as soon as an upstream
  library's `rmeta` is written; one derivation per library cannot. On real
  workspaces at 8 cores this costs 5–39% of a cold build
  ([#14](https://github.com/schlarpc/breakbulk/issues/14)).
- **Little cutoff inside Rust.** A function-body edit in a library changes
  rustc's crate hash, so its dependents rebuild, as they do under Cargo
  ([#15](https://github.com/schlarpc/breakbulk/issues/15)).
- **Test re-runs without content addressing.** A byte-identical test
  binary skips its re-run only when content-addressed derivations are on
  ([Caching and early cutoff](caching.md)).
- **Slow first evaluation in IFD mode.** Planning needs every crate, so the
  first evaluation of a large workspace takes minutes
  ([#19](https://github.com/schlarpc/breakbulk/issues/19)).

## Risks

- **Tracing depends on Cargo internals:** the artifact-notification
  protocol, how build scripts are run, the target-directory layout, where
  build-script output lands. Golden tests diff traced command lines
  against `cargo build -vv`, and differential tests check where
  build-script output lands, on several Cargo releases. Every such
  dependency is listed in [Cargo and rustc
  assumptions](../reference/assumptions.md).
- **Nix features not yet in a stable release.** Dynamic-derivation mode needs
  `builder-rpc-v0`, which is on Nix master only. IFD mode is the default
  on stable Nix.
- **Content addressing in Nix and caches.** Nix fetches all inputs of a
  content-addressed derivation before it can substitute it, and several
  cache servers store no realisations. So units are input-addressed, and
  content addressing is used only at the edges
  ([#16](https://github.com/schlarpc/breakbulk/issues/16)).
