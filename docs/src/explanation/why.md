# Why breakbulk

Rust in Nix forces a choice between fidelity and granularity, and real projects need both.

- **Fidelity tools** (`buildRustPackage`, crane, naersk) run real Cargo. Build scripts, profiles, `.cargo/config.toml`, cross builds and zigbuild-style toolchains behave exactly as they do locally. Reuse is coarse: at best a "dependencies blob" plus the workspace. One `Cargo.lock` change rebuilds every dependency, nothing is shared between projects, and every check variant (clippy, tests, coverage) carries its own full copy of the dependency build.
- **Granularity tools** (crate2nix, cargo2nix, `buildRustCrate`) build one derivation per crate and share them across projects. They reimplement Cargo in Nix and shell: feature resolution, build-script semantics, profiles and config are approximations, and every gap is a silent difference from `cargo build`. They need checked-in generated Nix or import-from-derivation (IFD).

Neither handles the patterns real repositories rely on. Examples: many workspaces with their own lockfiles sharing path crates, a host binary embedding a wasm build, per-package build stamps that must not invalidate dependencies, and ordered post-link steps that implicit stripping breaks.

**Goal.** One derivation per Cargo unit, with command lines that are exactly Cargo's, so that:

- each plan matches a named Cargo command under the same project config (for example `cargo build --workspace --target T --profile P`), across native, cross, wasm and Windows targets;
- outputs are shared across machines, workspaces and projects through an ordinary binary cache;
- nothing generated is checked in, and there is no IFD where the Nix installation supports dynamic derivations;
- a change rebuilds only the affected crates and their dependents, and re-runs only the test binaries whose bytes changed.

**Non-goals.**

- Beating Cargo's incremental edit loop on the crate being edited. That stays in plain `cargo` in the dev shell.
- Beating Cargo on a cold build of a single workspace. breakbulk optimizes for cache hits and narrow rebuilds; a cold build is expected to be somewhat slower than crane (see [Pipelining](caching.md#pipelining)). A cold build worse than about twice crane's time is a bug to investigate.
- Mutable caches inside the sandbox (rustc incremental state, shared compiler caches). They trade reproducibility for speed in a way the design refuses.
- Timed benchmark runs inside Nix. Sandbox timings on shared builders are noise, and a cached timing never re-measures. Bench binaries are built; they are run where timing means something.

## Principles

1. **Cargo plans, Nix executes.** The tool implements Cargo's public, documented formats (manifests, lockfiles, build-script instructions, target auto-discovery) and observes everything else from Cargo. It never encodes Cargo's behavior: resolution, unit selection, flag scoping or propagation. Every rustc command line is Cargo's own.
2. **The unit graph is static; build-script output binds late.** A build script can change flags, env and link arguments, but never which units exist. The whole graph is planned before any build script runs. Where each script's output goes is observed from Cargo during planning; the values are spliced in at build time.
3. **Toolchains are data.** Linker, C compiler, archiver, SDKs, rustflags and test runner come from a per-platform spec. The planner never hardcodes a tool, and host and target specs never leak into each other. The environment that native inputs need (`PATH`, `PKG_CONFIG_PATH`, wrapper flags) is captured from nixpkgs' own setup hooks, not recomputed.
4. **Configuration is scoped to the units that need it.** Env vars, inputs and extra sources attach to named packages and reach only those units, so a build stamp or a large SDK never invalidates unrelated crates.
5. **Input addressing by default; content addressing where it pays.** Units are input-addressed, so a cache hit downloads only what was asked for, on any cache server. Content addressing (CA) is used at the edges of the graph (test runs, post-link stages, embedded products), where early cutoff pays off and the cost of resolution is small. Full CA for units is a future mode, gated on Nix (see [Caching and early cutoff](caching.md)).
6. **Sugar over addressable layers.** The default package output is the sensible thing for its target. Every layer underneath (units, link outputs, post-link stages) stays addressable and overridable, so a default never becomes a trap.
7. **Stable toolchains by default.** Nothing in the default path needs nightly Rust. Nightly is something users bring, not something the tool requires. Optional optimizations may use unstable rustc flags only behind a fallback, and never in a way that reaches build scripts.
8. **Inherit what changes the build; delegate what breakbulk must decide anyway.** Cargo settings that change what gets built (feature unification, profiles, `[env]`) are inherited from project config and never turned on behind the user's back. Settings that only change something breakbulk has to decide regardless, such as how paths are spelled in outputs, are delegated to Cargo when Cargo can do it.
