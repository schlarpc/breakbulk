# The configuration model

All user-facing configuration lives in the NixOS module system; the unit graph does not. Presets, per-package overrides and stage pipelines all need to merge (preset defaults, user additions, per-target exceptions), and the module system already provides typed options, list and attrset merging, `mkBefore`/`mkAfter`/`mkForce`, and generated docs. Its evaluation cost is acceptable for configuration and would not be for thousands of units.

## Repository, workspaces, targets

A **repository** object holds any number of **workspaces**, each with its own lockfile and toolchain. Each workspace is built for a set of **targets**; each target names a toolchain preset and, optionally, the packages to select for it. Target specs are set repository-wide and may be refined per workspace, and each workspace's spec is resolved with its own toolchain, so a preset picks tools matching that workspace's rustc.

Units are shared across workspaces when Cargo produces identical commands for them. For registry crates that means the same version, features, profile, toolchain and resolved dependencies. Path crates additionally depend on where they sit relative to each workspace root: Cargo hashes a crate inside the workspace root by its relative path and a crate outside it by its absolute path, and passes source paths the same way. A shared path crate therefore deduplicates when it lies **outside every workspace root that uses it**, or when every workspace is the same workspace. A crate that is a selected member in one workspace and a plain dependency in another also differs, through `CARGO_PRIMARY_PACKAGE`. A diagnostic explains why two units expected to be shared are not. It compares the units' commands and env, not Cargo's hashes: `-C metadata` leaves out rustflags, so two units can share it and still differ.

## What is inherited from the project

The planner runs the user's Cargo over the project's own `.cargo/config.toml`, so every setting there applies as it does locally, including nightly-only settings such as `resolver.feature-unification` when the user's toolchain is nightly. Settings outside the project are not visible to the planner: `~/.cargo/config.toml`, `CARGO_*` variables exported in the user's shell, and flags in aliases or scripts. They must be moved into project config to take effect. The dev shell warns when it sees `CARGO_*` variables that the planner will not.

## Toolchain presets

A preset is a per-platform spec: `rustc`/`cargo`/std, `linker`, `cc`/`cxx`/`ar`/`cflags`, bindgen settings, SDK store paths, extra rustflags, `env`, and `runner`. The planner resolves every tool to a store path; a non-store tool path is a hard error naming the tool.

Presets are named for what they are for, not how they do it: `linux`, `linuxStatic`, `linuxPortable` (runs on other distributions), `windows`, `wasmWeb`, `wasmComponent`. The mechanism follows from the target triple: `linuxStatic` is musl for a `-musl` triple and static-pie glibc for a `-gnu` one, `windows` is msvc or MinGW by the triple's ABI, `wasmComponent` componentizes core modules on `wasm32-unknown-unknown` and links components directly on `wasm32-wasip2`.

- Spec rustflags reach Cargo through `--config`, never the `RUSTFLAGS` env var. Cargo takes rustflags from one key only (per-target rustflags win over `[build] rustflags`) and concatenates arrays only within that key. The planner therefore reads the project's config files and adds the spec's flags under `[build]` when the project uses `[build] rustflags` and no per-target rustflags, and under `target.<triple>` otherwise. The trace confirms that both sets of flags arrived.
- Host and target specs are separate, and the separation is enforced per unit, not per triple. Spec env never goes through Cargo's `[env]` table, which reaches every process Cargo starts; it is added to each unit according to the unit's platform. This matters most when host and target share a triple (static glibc, zig), where triple-keyed variables such as `CC_<triple>` or `CFLAGS_<triple>` cannot tell host from target.
- Linkers: when host and target triples differ, Cargo applies each `target.<triple>.linker` correctly. When they are the same triple, Cargo applies the target linker to host units too; if the host spec's linker differs, the planner rewrites the linker value in host units after checking it is exactly the one configured. Cargo passes `-C linker` to every unit, rlibs included, and breakbulk keeps it there, so a linker change rebuilds every unit, not only those that link.

## Per-package overrides

`packages.<name>` (optionally narrowed by version range and platform) sets `env`, `nativeInputs`, `inputs` and `extraSources` for that package's units only. `nativeInputs` are tools that run on the build machine (`pkg-config`, `cmake`, `protoc`); `inputs` are libraries for the platform being built (`openssl`). This is how build stamps (git revision, `SOURCE_DATE_EPOCH`, compiled-in settings), external SDK paths and vendored C sources are supplied, without changing the hash of any other unit. A curated set of defaults for common `-sys` crates ships with the tool, seeded from nixpkgs' `defaultCrateOverrides`. It declares the native inputs only: switches that make a crate use a system library instead of the one it bundles (`LIBSQLITE3_SYS_USE_PKG_CONFIG` and the like) change what gets built, so they are left to the project.

Inputs are turned into environment by nixpkgs itself: a small derivation per package and platform runs a real `stdenv` with those inputs and records the environment its setup hooks produce. Packages without inputs share one base capture per platform, which gives build scripts the same baseline tools and hardening flags as `buildRustPackage`.

One exception follows from how native libraries are linked: a `-sys` crate's `rustc-link-lib` is applied where the final binary links, which is a unit of another package. Every unit that links (bins, tests, cdylibs, dylibs, staticlibs, proc macros, build-script compiles, doctests) therefore also gets the library search flags (`NIX_LDFLAGS`, nothing else) of every package it links that has inputs, on its own platform only. The linker wrapper turns them into `-L` and records an rpath to each directory it links a shared library from, as `cargo build` finds the library on a system where it is installed.

## Source views

A package's source is a filtered view of the **repository root**, not its crate directory: the crate directory plus declared extras, at their original relative layout. Paths such as `../../wit`, `../shared/assets` or `../../../patches` therefore resolve unchanged, and editing an unrelated file changes no source path. Test units can declare a wider scope for tests that read repository files, and a test run can be narrowed to the files its tests read (`test.runFiles`), so that editing any other file of the package does not re-run it.

When a build script fails, or succeeds while declaring a `rerun-if-changed` path that is missing from its sandbox, the error or warning names the path and the option to add it to. Missing paths on success are warnings by default; `strictSources = true` turns them into errors.

Registry crates are fetched as one fixed-output derivation per `Cargo.lock` entry using the lockfile's checksums. Their store paths are exposed as `sources.<crate>`, so steps that need files from inside a dependency (a bundled SDK, JS glue shipped in a crate) are attribute lookups.

## Products as inputs

An override's env or inputs may reference any product, including one built for another target, for example a wasm UI bundle or a set of components embedded by a host crate. Products reach the instantiate step as references, not as dependencies, so only the embedding unit and its dependents wait for the product; the rest of the host build starts immediately.

## Variants

Profiles, feature sets (including a feature powerset), check modes (clippy, coverage instrumentation) and toolchains are plan parameters. Each variant is a separate plan, and units that come out identical are shared. What is identical follows from Cargo:

| Between | Shared | Not shared |
| --- | --- | --- |
| Build and check or clippy | Build scripts, proc macros and their dependencies | Regular library dependencies, which Cargo compiles in check mode |
| Check and clippy | All dependencies | Workspace members |
| Build and coverage | Host units | Target units, whose commands carry the instrumentation flag |
| Build and test plans | Units whose features are unaffected by dev-dependencies | Units whose features dev-dependencies change |
| Two profiles with the same settings (`release`, `bench`, a custom profile that only inherits `release`) | Everything; a unit's identity contains the profile's settings, not its name | Nothing |
| Two profiles with different settings (opt-level, debuginfo, …) | Nothing | Everything |

Check and clippy variants check every target, as `cargo check --all-targets` does, unless the variant turns that off for a gate that runs plain `cargo check`. Check and clippy variants should use the same profile as the main build variant to share host units. Cargo's own `clippy` defaults to the dev profile.
