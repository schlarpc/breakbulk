# Why breakbulk

Rust in Nix has made you choose between two kinds of tool:

| | Fidelity tools | Granularity tools |
| --- | --- | --- |
| Examples | `buildRustPackage`, crane, naersk | crate2nix, cargo2nix, `buildRustCrate` |
| How | run real Cargo | one derivation per crate, Cargo reimplemented in Nix |
| Behaves like `cargo build` | yes: build scripts, profiles, `.cargo/config.toml`, cross builds | approximately; every gap is a silent difference |
| Reuse | coarse: one "dependencies" derivation per project | per crate, across projects |
| A `Cargo.lock` change | rebuilds every dependency | rebuilds what changed |
| Generated files | none | checked-in Nix, or import-from-derivation |

Real projects need both. And neither handles patterns such as:

- several workspaces, each with its own lockfile, sharing path crates;
- a binary that embeds a wasm build;
- a per-package build stamp (a git revision) that must not rebuild the
  dependencies;
- post-link steps in a fixed order, which implicit stripping breaks.

## The goal

One derivation per Cargo unit, with Cargo's exact command line. So:

- each plan matches a named Cargo command (`cargo build --workspace
  --target T --profile P`) under the project's own config, on native,
  cross, wasm and Windows targets;
- outputs are shared across machines, workspaces and projects through an
  ordinary binary cache;
- nothing generated is checked in, and there is no import-from-derivation
  where Nix supports dynamic derivations;
- a change rebuilds only the crates it affects and their dependents, and
  re-runs only the test binaries whose bytes changed.

## Not goals

- **Beating Cargo's edit loop.** For the crate you are editing, use plain
  `cargo` in the dev shell.
- **Beating Cargo on a cold build.** breakbulk aims at cache hits and
  narrow rebuilds. A cold build is expected to be somewhat slower than
  crane (see [Pipelining](caching.md#pipelining)); more than about twice
  crane's time is a bug.
- **Mutable caches in the sandbox** (rustc incremental state, shared
  compiler caches). They give up reproducibility.
- **Timing benchmarks inside Nix.** Timings on shared builders are noise,
  and a cached timing never measures again. Bench binaries are built, to
  run where timing means something.

## Principles

1. **Cargo plans, Nix executes.** breakbulk implements Cargo's documented
   formats (manifests, lockfiles, build-script output, target discovery)
   and observes everything else from Cargo. It never reimplements feature
   resolution, unit selection or flag scoping. Every rustc command line is
   Cargo's own.
2. **The unit graph is fixed before anything builds.** A build script can
   change flags, environment and link arguments, but not which units
   exist. Where its output goes is observed during planning; the values
   are filled in at build time.
3. **Toolchains are data.** Linker, C compiler, SDKs, rustflags and test
   runner come from a per-platform spec. Nothing is hard-coded, and host
   and target settings never mix. The environment native libraries need
   comes from nixpkgs' own setup hooks.
4. **Settings reach only the units that need them.** Environment, inputs
   and extra sources belong to named packages, so a build stamp or a large
   SDK does not rebuild unrelated crates.
5. **Input addressing by default; content addressing where it pays.**
   Units are input-addressed, so any cache serves them and a hit downloads
   only what you asked for. Content addressing is used at the edges (test
   runs, post-link stages, embedded products), where it saves rebuilds
   cheaply. See [Caching and early cutoff](caching.md).
6. **Good defaults over addressable layers.** The default package is the
   right thing for its target, and every layer under it (units, link
   outputs, post-link stages) can still be read or replaced.
7. **Stable Rust by default.** Nothing in the default path needs nightly.
   Optional features may use unstable rustc flags only with a fallback,
   and never for build scripts.
8. **Inherit what changes the build; delegate what breakbulk must decide
   anyway.** Settings that change what gets built (feature unification,
   profiles, `[env]`) come from the project's config and are never turned
   on behind your back. Settings breakbulk has to decide regardless, such
   as how paths are spelled in outputs, go to Cargo when Cargo can do it.
