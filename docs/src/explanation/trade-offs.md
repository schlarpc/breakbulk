# Trade-offs and risks

breakbulk gives up some things to get per-crate sharing with Cargo's exact
behavior. This page lists them, with the issues that track each.

## Cargo with `--target`

breakbulk always plans with `--target`, also for the build machine's own
triple ([C3](../reference/assumptions.md#c3---target-host-keeps-rustflags-off-host-units)).
The static presets need this: their flags must not reach build scripts.
A project that you develop with plain `cargo build`, `cargo test` and
`cargo clippy` then sees three differences:

- **The project's rustflags reach target units only.** `build.rustflags`
  and `target.<triple>.rustflags` (and `targets.<triple>.rustflags`) do
  not reach build scripts, proc macros or their dependencies. Plain Cargo
  and crane's defaults give these flags to them too. nixpkgs'
  `buildRustPackage` also passes `--target`, so it behaves as breakbulk
  does.
- **A crate that is both a normal dependency and a build-dependency
  compiles twice**, once for each [side](configuration.md#host-and-target-sides).
  The host copy has no project rustflags, so it does not see a `--cfg`
  that the project sets.
- **A clippy variant lints such a workspace member twice.** The host copy
  is linted without the project's `--cfg` flags. Code that only the cfg
  uses then gives warnings, such as an unused variable, and with
  `-D warnings` the clippy check fails where `cargo clippy` passes.

The [dev shell](configuration.md#the-dev-shell) sets
`CARGO_BUILD_TARGET`, so `cargo clippy` in the shell shows the same
failure.

To lint the host copy with other clippy arguments, set `CLIPPY_ARGS`
for its host units in the clippy variant only. Clippy reads its
arguments from this variable, each one followed by `__CLIPPY_HACKERY__`:

```nix
packages.runtime.variant.clippy.forHost.env.CLIPPY_ARGS =
  lib.concatMapStrings (a: a + "__CLIPPY_HACKERY__") [
    "-D" "warnings"
    "-A" "unused_variables"
  ];
```

This value replaces the variant's
[`clippyArgs`](../reference/options/workspaces.md#workspacesnamevariantsnameclippyargs)
for the package's host units only: its host library and, if it has
one, its build script's compile. The target copy and the other
variants' units do not change.

Do not add the project's `--cfg` to the clippy arguments instead.
Clippy arguments reach workspace members only, so the host copy's
dependencies still compile without the cfg, and code that needs the cfg
on both sides can fail to compile.

Nothing gives a host unit a rustc flag, such as the project's `--cfg`
([#110](https://github.com/schlarpc/breakbulk/issues/110)). A build
script, or a crate it depends on, that does not compile without such a
flag builds under plain Cargo and fails under breakbulk.

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
- **Nix features not yet in a stable release.** Dynamic-derivation mode
  needs `builder-rpc-v0`, which is on Nix master only. IFD mode is the
  default on stable Nix.
- **Content addressing in Nix and caches.** Nix fetches all inputs of a
  content-addressed derivation before it can substitute it, and several
  cache servers store no realisations. So units are input-addressed, and
  content addressing is used only at the edges
  ([#16](https://github.com/schlarpc/breakbulk/issues/16)).
