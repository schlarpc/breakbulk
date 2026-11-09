# How a build works

```text
  your modules: presets, per-package settings, variants
        │
        │      1. Fetch         crates from Cargo.lock;
        │            │          a source view per package
        │            ▼
        ├─────▶ 2. Plan          trace real Cargo over a skeleton
        │            │          → plan.json
        │            ▼
        └─────▶ 3. Instantiate   plan.json → one .drv per unit
                     │
                     ▼
                4. Units         one derivation per Cargo unit
                     │
                     ▼
                5. Products      stages, test runs, checks
```

Cargo is consulted only when manifests, the lockfile or config change. A source edit reruns only the units whose inputs changed; in IFD mode the instantiate step does not rerun either.

## 1. Fetch

Fetch derivations are created from every lockfile at evaluation time. Registry crates are fixed-output derivations keyed by the lockfile's checksums and download at build time, only when a unit actually builds. Git sources are fetched during evaluation, because locating a crate inside a repository needs its tree. Workspace packages get filtered views of the repository root. The planner never serializes sources itself.

## 2. Plan by tracing Cargo

The planner runs the user's own Cargo for one workspace, target and variant over a skeleton: manifests, lockfile, `.cargo/config.toml` and empty target files. Each (workspace, target, variant) gets two plans with named reference commands:

- **Build plan:** `cargo build --workspace --target T --profile P [--features …]`. Products come from this plan.
- **Test plan:** `cargo test --no-run --workspace --target T --profile P [--features …]`. Test binaries come from this plan. `--no-run` skips doctests, so the test plan also traces `cargo test --doc` with a `RUSTDOC` wrapper that records each `rustdoc --test` command without running it.

They are separate because Cargo turns on dev-dependency features only when test targets are built. Tracing products with `--all-targets` would ship binaries with features that plain `cargo build` would not enable. Units whose features are the same in both plans are identical derivations and are shared. A target can narrow the selection from `--workspace` to a package list (`-p ui`), for example a wasm target that builds only the UI crate.

A `RUSTC_WRAPPER` does the following:

- Records information queries (`-vV`, `--print cfg`, file-name queries) and forwards them to the real rustc. The `-vV` record carries Cargo's own environment, the baseline for env filtering.
- For each compile invocation, records argv, env and working directory, writes placeholder outputs, and emits the artifact notification Cargo waits for when pipelining.
- For each build-script compile, writes a stub executable. When Cargo runs it, the stub records the exact environment Cargo gives build scripts and prints one tagged **sentinel** directive of each applicable kind.

Cargo places each sentinel exactly where it would place real output from that script: which units get it, at which position, and which dependent build scripts receive `DEP_*` metadata. The planner records those positions as splice points. Placement is therefore observed from Cargo; only the values are filled in at build time. A few placements depend on the values, and breakbulk applies those rules itself at build time: search paths inside the script's `OUT_DIR` come before all others, all link-argument kinds of one script form one ordered list, and doctests get every script's search paths sorted by value. [A spike](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/A-trace-fidelity.md) confirmed that the traced commands, with real build-script output filled in, equal a real `cargo build` unit for unit on Cargo 1.95 to 1.101.

The recorded invocations give the graph: `--extern` and `-L` paths name the producing unit, `OUT_DIR` ties a compile to its build-script run, the stub path ties a run to its compile, and sentinels give directive scoping and `DEP_*` edges. The unstable `--unit-graph` is not needed. Paths are then rewritten:

- Target-directory paths become placeholders for the producing unit's outputs, in both of Cargo's build-directory layouts (the classic one and the per-unit one that nightly Cargo uses by default). Whether a unit is a host unit (build script, proc macro) or a target unit is read from where Cargo put its output.
- Source paths become store paths of the source views.
- Tool paths must already be store paths, or planning fails with the tool's name.
- Recorded env is kept only where Cargo set it or the configuration declared it; the planner's own sandbox env, and what Cargo sets on its own process, are dropped.

Each target is traced on its own. Host units come out identical for every target and are shared. A multi-target Cargo invocation is avoided because its feature resolution can differ from building each target alone.

## 3. Instantiate

`breakbulk-instantiate` turns the plan and the source map into one derivation per unit. It is pure templating, so rerunning it on every edit is cheap, and unchanged units come out byte-identical. The same Rust code serves both delivery modes:

- **IFD mode:** it writes each unit's derivation attributes as JSON, which Nix imports and passes to `derivation`.
- **Dynamic-derivation mode:** it writes the same derivations into the store through Nix's `builder-rpc-v0` interface and submits each root.

Both modes produce identical unit derivation paths. The default, `mode = "auto"`, picks dynamic-derivation mode when the evaluator has the `dynamic-derivations` feature and a Nix version with `builder-rpc-v0`, and IFD otherwise. Nix implementations without dynamic derivations, such as Lix, therefore use IFD mode with no configuration. Upstream Nix and Determinate Nix are tested; others are expected to work in IFD mode but are not tested.

## 4. Units

- Units are input-addressed. A cache hit is an ordinary narinfo lookup and downloads only the requested output.
- Library units have separate `rmeta` and `rlib` outputs; compile units need every transitive `rmeta`, link units every `rlib`. A library unit lists only its direct dependencies as inputs: each `rmeta` output carries a manifest naming what lies below it, and Nix's reference scanning brings that into the sandbox, so the graph's inputs grow with its edges rather than with the square of its size. Link units list every `rlib`. With a nightly toolchain, rlibs carry no metadata, so link units also take every `rmeta`.
- A build script is two units: its compile, and its run, with outputs `out` (`OUT_DIR`) and `flags`.
- Build-script output is spliced in at the positions Cargo chose for the sentinels.
- A unit's environment is a fixed, layered contract: a fixed base, the captured nixpkgs environment for its package's inputs, Cargo's recorded env, the toolchain spec for the unit's platform, and the package's overrides.

## 5. Products

Link outputs flow through named stages into packages, test runs and checks, described below.
