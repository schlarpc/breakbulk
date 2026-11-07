# Decision log

Decisions made while implementing, for the author to review. Each item says
what was decided, why, and what to do if you disagree. Newest last.

Status: **FYI** (already done, tell me if you object) · **ASK** (your call;
work continues on the stated default until you answer).

## 1. FYI: breakbulk's own code needs Rust 1.95 or newer

breakbulk itself is written with the 2024 edition of Rust and declares
Rust 1.95 as its minimum. That matches the oldest Cargo in the support window
(about six months of stable releases), so nothing here limits which projects
breakbulk can build. If you want breakbulk's own binaries to build on an
older compiler, say which one.

## 2. FYI: test toolchains come from rust-overlay

The flake pins `nixos-unstable` for nixpkgs and adds `oxalica/rust-overlay`
so tests can run against several Cargo releases (1.95, 1.97, 1.99 and
nightly). rust-overlay is used only for breakbulk's own tests and dev shell;
users still bring their own toolchain. If you prefer fenix, it is a small
swap.

## 3. FYI: how the work is being split

The three risk spikes from the implementation plan (tracing Cargo, Nix
dynamic-derivation delivery, environment capture) run in parallel with two
pieces that do not depend on them: the build-script output parser plus the
`plan.json` data types, and the Nix code that reads lockfiles, fetches
crates, builds the planning skeleton and predicts output names. Each runs on
its own branch and is merged after review. Spike write-ups land in
`docs/spikes/`.

