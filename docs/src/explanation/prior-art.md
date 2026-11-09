# Patterns and prior art

## Patterns breakbulk supports

These patterns come from a survey of working Rust-in-Nix repositories. Each
one is either wired by hand today, or breaks without a word.

| Pattern | What goes wrong today | How breakbulk handles it |
| --- | --- | --- |
| Copied cross-toolchain plumbing (msvc via xwin: linker, cc, ar, cflags, bindgen args, SDK paths) | The same 30–60 lines copied between repositories, drifting apart | One toolchain preset |
| Build stamps (git revision, `SOURCE_DATE_EPOCH`, compiled-in settings) | Set only on the final build, by hand, to avoid rebuilding all dependencies on every commit | Per-package env reaches only that package's units |
| Build scripts reading external SDKs or vendored sources through env vars | The whole env reaches every unit, so any change rebuilds everything | Per-package `inputs` and `env` |
| Native inputs missing in the sandbox | Works locally, fails in Nix with an unrelated-looking error | Captured nixpkgs environment per package; failure hints from `rerun-if-*` declarations |
| Host binary embedding another target's build (wasm UI, components, a web bundle) | Embed silently falls back to a placeholder when the input is missing | Products as inputs, across targets, passed by reference |
| Reads outside the crate directory (`include_str!`, schema or interface files, sibling assets, patches) | Source filters drop the file, or the whole tree becomes the input | Repository-root source views plus declared extras |
| Many workspaces with their own lockfiles, path-depending on shared crates | Dependencies rebuilt once per workspace | Repository object; identical units shared; a diagnostic when they are not |
| Check variants (clippy, nextest, coverage, feature powerset) | A full dependency build per variant, exhausting CI disk | Variants as plan parameters; host units and check-mode dependencies shared |
| Dev-dependency features leaking into shipped binaries | Binaries built with features plain `cargo build` would not enable | Separate build and test plans |
| Host-vs-target leakage (`crt-static`, static archives, the wrong C compiler) | Wrapper scripts strip flags; build scripts segfault; host objects end up in wasm | Spec env and linkers scoped by unit platform |
| Rustflags from env replacing `.cargo/config.toml` rustflags | Flags duplicated in two places | Spec rustflags passed with `--config` under the key the project uses, concatenated |
| Build-script link directives (`rustc-link-arg-bins`, delay-load, resource files, kernel link args) | Dropped or applied to the wrong targets | Placement observed from Cargo through sentinels |
| Post-link steps that care about order (sign without stripping, check before stripping) | Fights with the implicit fixup phase | Named stages, no implicit fixup, side-branch checks |
| Runtime-loaded libraries (GPU, windowing, audio) | Rpaths removed by rpath shrinking | `patchelfRpath` stage after fixup |
| Test binaries consumed elsewhere (VM tests, `CARGO_BIN_EXE_*`) | Tests built as packages by hand, or skipped | Test binaries and test runs as products |
| Cross tests (Windows, other architectures, wasm) | Tests disabled for cross targets | `runner` in the spec; native builders by `system` |
| `wasm-bindgen-cli` version pinning | Hand-maintained hashes, or a nixpkgs version that matches by coincidence | Version read from `Cargo.lock` |
| Workspace members used as build tools (code generators, `xtask`) | Rebuilt whenever any member changes | Per-unit graph rebuilds only what the tool depends on |
| Reproducibility gates (rebuild checks, stamped artifacts, deterministic archives) | Bolted on per repository | Deterministic helpers; `nix run .#test-rebuild` rebuilds every fixture's products and sampled units |
| Nightly-only workspaces and build-std targets next to stable ones | Separate tooling per toolchain | Toolchain per workspace |

## Lessons from prior art

What breakbulk takes from each, and what it leaves.

**cargo-dyndrv (Obsidian Systems)**

- Takes:
  - planning at build time via dynamic derivations;
  - build-script output applied late through argument files;
  - build-script compile and run as separate units;
  - `OUT_DIR` as its own output.
- Leaves:
  - rebuilding rustc flags from `--unit-graph`;
  - `-C metadata` hashed from derivation paths and absolute paths;
  - serializing every source inside the planner;
  - overrides keyed by full package ID;
  - link flags propagating through build-dependency edges.

**crane**

- Takes:
  - real-Cargo fidelity;
  - per-crate fetching from `Cargo.lock` with no IFD;
  - vendoring one directory per source with generated source replacement;
  - optional `outputHashes` for git sources;
  - a skeleton source for planning;
  - source cleaning;
  - checks as first-class outputs.
- Leaves:
  - the coarse dependencies-blob target directory.

**crate2nix, `buildRustCrate`**

- Takes:
  - per-crate sharing across projects;
  - the curated `defaultCrateOverrides` for `-sys` crates;
  - cross builds through nixpkgs splicing.
- Leaves:
  - feature resolution in Nix;
  - checked-in generated Nix;
  - reimplementing Cargo.

**Bazel `rules_rust`, Buck2**

- Takes:
  - pipelined metadata actions with identical commands;
  - platforms and toolchains as data;
  - a content-hashed action cache.
- Leaves:
  - their own reimplementation of Cargo semantics.

## Issues found in cargo-dyndrv that breakbulk avoids

- `-C metadata` is a hash of upstream derivation paths, unit-graph indices
  and absolute source paths. It defeats cutoff, changes when unrelated
  crates join the graph, and differs between sandbox and local builds.
- Link flags from build dependencies' build scripts reach target links,
  which breaks cross builds or adds host libraries to target binaries.
- `rustc-link-lib` and `rustc-link-arg` apply to every downstream compile
  instead of only the package's own targets.
- Most Cargo env vars and profile settings are missing (`panic`,
  `overflow-checks`, LTO, `codegen-units`), and some are misparsed.
- A build script killed by a signal counts as success, and a `rustc-flags`
  directive corrupts the next argument.
- Multiple crate types per unit (`["cdylib", "rlib"]`) are rejected.

The traced planner removes most of these by construction, because the
command lines and directive placement come from Cargo.
