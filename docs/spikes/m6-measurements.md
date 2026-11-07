# M6 measurements: pipelining gap, rmeta cutoff, nextest, CA island cost

Nov 7, 2026 · measurements for M6 (below-crate seams)

| Question | Verdict |
| --- | --- |
| Is the pipelined split worth building? | **Not now.** The gap is real (measured 5–39% on a cold `-j8` release build, simulated up to 67% on a deep chain), but the stable backends (rerun and stop, `-Zno-codegen`) run the frontend twice and are *slower* than no split at 4 cores on the wide workspaces (helix, nushell), and break even or lose at 8. Only the CRIU backend keeps the gain. Next step: the CRIU spike, then an opt-in per package. |
| Does early cutoff on rmeta bytes save rebuilds? | **No, on stable and on today's nightly.** rmeta embeds the MD5 of every source file, so any edit changes the edited crate's rmeta, and every dependent's rmeta embeds that crate's hash. `-Zpublic-api-hash` is not in nightly 2026-11-06. Replaying 31 breakbulk and 50 ripgrep commits: cutoff on rmeta would have skipped 4% and 1% of library compiles, identically on stable, nightly, and nightly with the old crate hash. |
| Can synthesized `binaries-metadata` drive nextest over store paths? | **Go, and done.** `packages.<name>.test.runner = "nextest"` runs each test binary through nextest's reuse-build mode with the project's nextest configuration. Fixture and checks pass. |
| What does a CA test run cost on a cold machine? | **A lot.** Substituting one CA test run downloaded 58 paths, 1.83 GB (rustc and LLVM among them) in 37 s from a local file cache; the input-addressed run downloaded 1 path, 440 bytes, in 0.28 s. Keep CA islands off by default for caches used by fresh machines (decision 52 already does), and drop the sysroot from test runs' inputs. |

The machine was shared with other agents throughout: load average 15–60 on
8 cores. Absolute times are inflated and noisy; ratios taken from one run
(the simulations) are more trustworthy than comparisons between runs.

## 1. Pipelining gap

### Method

Everything is in [`spikes/m6/pipelining/`](../../spikes/m6/pipelining/);
saved data in [`spikes/m6/results/pipelining/`](../../spikes/m6/results/pipelining/).

- Four workspaces at pinned revisions, exported with `git archive` into a
  scratch directory outside `$HOME`, with a scratch `CARGO_HOME`, Cargo and
  rustc 1.99 from `nix develop`: ripgrep `91f5d22` (54 units, shallow),
  helix `ba40e547` (330–380 units, wide), rust-analyzer tag `2026-11-02`
  (315–325 units, a deep chain of large crates), nushell `0.116.1`
  (800–900 units, wide and large). Each was built with the project's own
  `dev` and `release` profiles (helix and nushell use thin LTO in release).
- `measure.sh`: `cargo build --profile P -j8 --timings` from a clean target
  directory, plus `cargo build --unit-graph` (unstable; run with
  `RUSTC_BOOTSTRAP=1`, which builds nothing) for the dependency edges.
- `analyze.py`: reads `UNIT_DATA` from `cargo-timing.html` (per unit:
  duration, and the frontend section's end, which is when rustc wrote the
  rmeta). Unit indices in the timings and in the unit graph are the same:
  both number units in their sorted order (cargo `5f94df47`,
  `src/ops/cargo_compile/mod.rs` and `src/compiler/unit_graph.rs`); the
  script checks name, version and features of every unit.
- Edges follow Cargo exactly: a dependent waits only for the rmeta when
  both are `mode=build` units whose crate types are all lib/rlib
  (`BuildRunner::only_requires_rmeta`, `src/compiler/build_runner/mod.rs`);
  a unit that links waits for **every transitive** dependency to finish
  (`depend_on_deps_of_deps`, `src/compiler/job_queue/mod.rs`).
- Three schedules from the same unit durations:
  - **unsplit**: every edge waits for the end of the dependency. This is
    breakbulk today.
  - **pipelined**: Cargo's pipelining; equivalently the CRIU backend with
    free checkpoints.
  - **rerun**: the "rerun and stop" or `-Zno-codegen` split. Every library
    with an rmeta-only dependent becomes an rmeta job (frontend time) and
    an rlib job (full time); the frontend runs twice.
- Each schedule's critical path (unlimited cores), and a list-scheduling
  simulation at 4, 8 and 16 cores (one unit = one core; highest remaining
  critical path first). `--overhead 0.4` adds 0.4 s per job, Nix's median
  per-unit cost from [scale.md](scale.md).
- Paired real measurement: `no-pipelining-wrapper.sh`, a `RUSTC_WRAPPER`
  that drops rustc's `"emit":"metadata"` notification. Cargo then releases
  rmeta-only dependents only when rustc exits (`job_state.rs`: a job that
  never called `rmeta_produced` gets its Metadata finish with the All
  finish). `build.pipelining = false` no longer does anything in Cargo 1.99
  (only the schema field is left, `src/context/schema.rs`). Each release
  build ran with the wrapper and then without, back to back.

### Results

Simulated, with 0.4 s per-unit overhead (`table-overhead.txt`; without
overhead, `table.txt`, the numbers differ by a point or two). "Gap" is how
much shorter than unsplit the schedule is; negative means slower.

| Workspace | Units | CPU s | Critical path: unsplit → pipelined (gap) | 4 cores: pipelined / rerun gap | 8 cores: pipelined / rerun gap | 16 cores: pipelined / rerun gap |
| --- | ---: | ---: | --- | --- | --- | --- |
| ripgrep dev | 54 | 57 | 26.0 → 20.3 s (22%) | 4% / −33% | 21% / 21% | 22% / 22% |
| ripgrep release | 54 | 202 | 95.5 → 55.9 s (41%) | 23% / 6% | 41% / 41% | 41% / 41% |
| helix dev | 329 | 464 | 127 → 102 s (20%) | 0% / −27% | 7% / 3% | 20% / 20% |
| helix release | 382 | 1,679 | 474 → 363 s (23%) | 0% / −16% | 6% / 7% | 23% / 22% |
| rust-analyzer dev | 313 | 611 | 281 → 194 s (31%) | 26% / 1% | 31% / 31% | 31% / 31% |
| rust-analyzer release | 325 | 2,878 | 1,484 → 495 s (67%) | 45% / 37% | 66% / 67% | 67% / 67% |
| nushell dev | 796 | 2,428 | 555 → 403 s (28%) | 0% / −37% | 14% / −10% | 27% / 28% |
| nushell release | 893 | 4,036 | 825 → 666 s (19%) | 0% / −33% | 8% / −16% | 19% / 19% |

Paired real builds at `-j8` (wall seconds; Cargo pipelining off with the
wrapper vs on, back to back; load average 30–60):

| Workspace (release) | No pipelining | Pipelining | Gap |
| --- | ---: | ---: | ---: |
| ripgrep | 95 | 58 | 39% |
| helix | 491 | 464 | 5% |
| rust-analyzer | 713 | 521 | 27% |

What this says:

- **Wide workspaces gain little where cores are scarce.** At 4 cores, helix
  and nushell keep every core busy without pipelining; the gain is 0%.
  At 8 cores it is 6–14%, close to Cargo's published 10–20%.
- **Deep chains gain a lot, but less than the simulation says.**
  rust-analyzer's critical path is `syntax → … → hir-def (117 s) → hir-ty
  (172 s) → hir → ide-db → ide-assists → ide → rust-analyzer`, every link
  waiting for full codegen when unsplit (`analyze.py --explain`). The
  simulation runs each unit on one core with the durations measured in a
  busy pipelined build. Run alone, a crate's codegen uses several threads
  (rustc's codegen units share Cargo's jobserver), so the real unsplit
  build is faster than simulated: measured 27%, simulated 66%. The
  simulation is an upper bound for codegen-heavy chains.
- **The rerun backends lose where it matters.** Running the frontend twice
  adds 23–49% CPU (frontend time of every split library). At 4 cores that
  makes helix, nushell and ripgrep dev slower than not splitting at all
  (−16% to −37%); only rust-analyzer and ripgrep release still gain. At 8
  cores it is break-even on wide workspaces and loses on nushell. Only with
  16 cores, or on a deep chain, does it match pipelining.
- **Incremental builds look like the deep chain.** After an edit low in
  rust-analyzer's graph, only the chain above it rebuilds, so the critical
  path is the whole build. That is breakbulk's common case in CI, and the
  case pipelining helps most; it is also the case where an unsplit unit has
  the most free cores for its own codegen.

### Recommendation

- **Rerun and stop, `-Zno-codegen`: no-go as defaults.** They lose at 4
  cores and break even at 8 on wide workspaces. They could be an opt-in for
  a few named crates on a deep chain (rust-analyzer's `hir-*`), which is
  how `packages.<name>.pipelining` is already specified, but the gain over
  a well-parallelized unsplit build is unmeasured.
- **CRIU: worth its spike.** It is the only backend that keeps Cargo's
  gain (27–39% measured on the two chain-shaped workspaces). Do the "CRIU
  in a sandbox" spike before any implementation.
- **Before either:** make sure unsplit units use their cores for codegen.
  Inside a Nix sandbox there is no Cargo jobserver; how many codegen
  threads rustc runs per unit (and whether `NIX_BUILD_CORES` should become
  `-C codegen-units` or a jobserver) decides how much of the deep-chain gap
  exists for breakbulk at all. This was not measured here.

Confidence: high for the edge rules and the simulation's arithmetic; medium
for the simulated gaps (single-core units, durations from a loaded
machine); low-to-medium for the paired wall times (one pair each, load
30–60).

## 2. History replay: early cutoff on rmeta

### What rustc does today

- **rmeta embeds every source file's hash.** A library's `.rmeta` contains
  the MD5 of each of its source files (the encoded source map), so any byte
  change to a source file, even a comment after the last item, changes the
  rmeta. Checked with `spikes/m6/micro/rmeta-edits.sh`: each of these
  edits (a same-length private body change, a longer private body, a
  public body, a generic body, an `async` body, a line shift, a comment
  inside a line, a comment after the last item) changes the rmeta at `-O0` and `-O3`, on stable 1.99, on nightly
  2026-11-06 and on that nightly with `-Zmetadata-crate-hash=no`. For a
  trailing-comment edit the MD5 of each version of the file is found
  verbatim in its rmeta.
- **Dependents' rmeta embeds the dependency's crate hash.** On stable the
  hash covers HIR including bodies and spans; on nightly
  (rust-lang/rust#154724, the default there, `-Zmetadata-crate-hash`) it is
  computed from the metadata bytes, which include the source hashes. Either
  way, a changed upstream rmeta changes every direct dependent's rmeta.
- **`-Zpublic-api-hash` is not in nightly 2026-11-06** (`rustc -Z help`
  lists `metadata-crate-hash`, `no-codegen`, `embed-metadata`, nothing
  public-API). The "nightly with relink-don't-rebuild flags" half of M6's
  exit criterion cannot be measured yet.

So rmeta-byte cutoff can only fire when a package's files change but none
of the library's own source files do: a test, an example, a README, a
`build.rs` whose output is the same, a bin's source.

### The harness

[`tools/history-replay/replay.py`](../../tools/history-replay/replay.py).
For each commit in a range (`git rev-list --no-merges`, optionally limited
to paths), it builds the commit and its first parent with a real Cargo and
rustc (`cargo build --workspace --lib`, the release profile,
`CARGO_INCREMENTAL=0`, a scratch `CARGO_HOME`), hashes every library's
`.rmeta` and `.rlib`, and reports per edit:

- `src`: workspace packages with changed files (plus new registry
  packages);
- `rmeta`, `rlib`: libraries whose bytes changed;
- `ia_lib`, `cut_lib`: library compiles redone with input addressing
  (breakbulk today: the changed packages and every dependent) and with
  cutoff on rmeta bytes (full-CA units: a library recompiles only if its
  own package changed or a direct dependency's rmeta changed);
- `ia_link`, `cut_link`: link units (bins, test binaries, from `cargo
  metadata`) redone; with cutoff, only if their package changed or a
  transitive rlib changed.

All builds of one toolchain share one source directory and one target
directory, so paths and `-C metadata` are stable; `git checkout` gives
changed files a new mtime, so Cargo rebuilds what changed. A control
rebuilds the last commit from scratch at the same target path and compares
every hash with the replayed ones (`control_mismatch`); a mismatch means
nondeterminism or a freshness bug. Usage is in the script's header.

### Results

Two repositories, three toolchains each: stable 1.99, nightly 2026-11-06
(crate hash from metadata, the nightly default), and that nightly with
`-Zmetadata-crate-hash=no` (crate hash from HIR, as on stable). Release
profile. Full tables in
[`spikes/m6/results/history-replay/`](../../spikes/m6/results/history-replay/)
(`*.txt`; the `*.json.gz` files hold every snapshot, for
`replay.py --reanalyze`).

| Repository | Commits built | Edited libraries | …with rmeta unchanged | Library compiles, input-addressed → rmeta cutoff | Link units, input-addressed → rlib cutoff |
| --- | ---: | ---: | ---: | --- | --- |
| breakbulk `crates/` (every non-merge commit touching `crates/` or the workspace manifests, up to `5da6701`) | 31 of 41 | 58 | 4 | 78 → 75 (4%) | 167 → 159 (5%) |
| ripgrep (`91f5d22~50..91f5d22`) | 50 of 50 | 68 | 26 | 98 → 97 (1%) | 239 → 239 (0%) |

The three toolchains give identical numbers, row for row. The controls
(a clean rebuild of the last commit) matched every replayed hash. Ten
early breakbulk commits did not build (no library yet, or a stale
`Cargo.lock` on a feature branch) and are skipped.

Where the rmeta stayed the same although the package changed:

- an edit to tests only (`breakbulk-format/src/tests.rs`: 3 → 1 library
  compiles, 9 → 1 link units: the only commit where cutoff saved much);
- benches, a README, a CI file inside the package directory;
- manifest-only edits (`rust-version`, `homepage` on every ripgrep crate).
  The libraries' rmeta did not change, but every library was itself
  edited, so nothing was saved;
- version bumps of registry dependencies whose bytes stayed the same.

Every edit to a library's own source changed its rmeta, as the micro-check
predicts, and every dependent's rmeta with it.

### Recommendation

- **No-go on full-CA units for cutoff's sake** while rmeta embeds source
  hashes: they would cut off only non-source edits, which dep-info source
  narrowing (M6's other seam) also cuts off, without CA's substitution
  cost (section 4).
- The upstream request in the design ("a physical split: data that
  dependents read in one file, spans and private data in another") should
  name the source map explicitly: today the per-file source hashes alone
  defeat byte-level cutoff.
- Re-run the harness when `-Zpublic-api-hash` lands in nightly
  (`--toolchain name=BINDIR,-Zpublic-api-hash` or whatever the flag
  becomes).

## 3. nextest reuse

**Go; implemented as `packages.<name>.test.runner = "nextest"`.**

nextest's reuse-build mode reads two files: `--binaries-metadata`
(nextest-metadata's `BinaryListSummary`) and `--cargo-metadata` (a `cargo
metadata` document). Read in cargo-nextest 0.9.146 (nixpkgs' version;
nextest-rs/nextest tag `cargo-nextest-0.9.146`, `8af696dd`):

- `binary-path` is used as is when no remap applies
  (`PathMapper::remap_path`, `nextest-runner/src/reuse_build/mod.rs`), so a
  test binary can stay in its own store path.
- The test's cwd and `CARGO_MANIFEST_DIR` are the package's manifest
  directory from the cargo metadata (`RustTestArtifact::from_binary_list`,
  `nextest-runner/src/list/test_list.rs`); `CARGO_PKG_*` come from the
  package entry (`apply_package_env`, `src/test_command.rs`).
- The dynamic-library path is nextest's own entries (linked paths, base
  output directories, rustc libdirs) followed by the inherited
  `LD_LIBRARY_PATH` (`create_dylib_path`).
- nextest requires `<workspace root>/Cargo.toml` to exist and writes its
  store under `<workspace root>/target/nextest` by default.
- `package()` filtersets fail with "operator didn't match any packages"
  when the package is not in the cargo metadata
  (`nextest-filtering/src/compile.rs`).

What breakbulk does (`nextestSpec` and `nextestRun` in
[`lib/test-runs.nix`](../../lib/test-runs.nix)):

- One test run per binary, as with libtest, so a byte-identical binary
  still skips its run when CA is on.
- The run sets up the same environment as a libtest run (dylib path,
  `[env]`, `rustc-env`, `test.env`, `test.path`), then runs `cargo-nextest
  nextest run --binaries-metadata … --cargo-metadata … --profile <p>
  [--config-file …] --no-tests=warn -- <libtest args>`. nextest emulates
  libtest's `--skip`, `--exact` and `--include-ignored` after `--`.
- The cargo metadata is synthesized: every path package of the plan
  (so `package()` filters resolve), with name, version, authors,
  description, license and so on from the units' recorded `CARGO_PKG_*`.
  The tested package's manifest directory is its source view's package
  directory. The workspace root is a scratch directory made at build time
  (it needs a `Cargo.toml`, and nextest writes there).
- No base output directories, linked paths or build-script out dirs, so
  nextest adds only the sysroot's library directory (already last on
  breakbulk's path) and keeps the rest of the environment.
- The configuration file is `test.nextest.configFile`, by default the
  workspace's `.config/nextest.toml` when it exists. nextest's store
  (JUnit and the like) is copied to `$out/nextest`.

Tested by `tests/test-runs` `nextest` and `nextest-repo` (flake checks
`test-runs-nextest*`) over a new `tests/fixtures/nextest`: retries (a test
that fails once passes on try 2), a per-test `slow-timeout` with
`terminate-after` that kills a hung first attempt, a default filter that
names another package, JUnit output, the package env from the synthesized
metadata, `test.env`, and a package without a config file. Unchanged
libtest runs keep their derivations.

Limits:

- Dependency edges are not synthesized: `deps()` and `rdeps()` filtersets
  see none. The planner's `cargo metadata` could provide them, at the cost
  of every nextest run depending on every manifest.
- `test-threads` comes from the nextest config (default: all CPUs), not
  `NIX_BUILD_CORES`; setting `NEXTEST_TEST_THREADS` would override the
  project's config.
- Dynamic-derivation mode warns and runs libtest; test apps run the binary
  directly, as before.
- JUnit reports are per binary; a merged report would be a separate step.

## 4. CA island cost

**Result: a CA test run on a cold machine downloads its inputs' closures,
including the Rust toolchain.**

[`spikes/m6/ca-island/run.sh`](../../spikes/m6/ca-island/run.sh): the
`test-control` fixture's six test runs, input-addressed and
content-addressed (`ca = true`), built in a private store
(`local?root=`, own `nix.conf` with `ca-derivations`; the system daemon is
not touched) with the system Nix (Determinate Nix 3.22.2, Nix 2.35.2),
pushed to a `file://` cache, then built in fresh stores that hold only the
runs' `.drv` closure, with that cache as the only substituter and
`max-jobs = 0`.

| Runs | Kind | Time | New paths | Downloaded (NAR) |
| --- | --- | ---: | ---: | ---: |
| 6 | input-addressed | 0.26 s | 6 | 2.7 KB |
| 6 | CA | 44.3 s | 74 | 1.85 GB |
| 1 | input-addressed | 0.28 s | 1 | 440 B |
| 1 | CA | 37.4 s | 58 | 1.83 GB |

The single CA run downloaded rustc (1.11 GB), LLVM's library (577 MB),
cargo, glibc, gcc's lib, jq, bash, coreutils and the rest of the stdenv,
the build-script run's outputs and the test binary's unit. To substitute a
CA derivation, Nix resolves it, and resolving realises every input first
(Nix 2.35; NixOS/nix#11928). A test run's inputs include the stdenv, `jq`,
the sysroot (for the dynamic-library path) and the units, so their
closures come down even though the run's own output is 440 bytes. With
only the runs' outputs in the cache, the cold build fails trying to build
bash.

Two smaller findings while pushing: `nix copy --to file://… "$drv^*"` of
a CA derivation fails with "reference … is not valid" unless the closures
of its CA inputs' outputs are copied first (it uploads their realisations
but not their closures); and Nix's narinfo disk cache must be cleared when
a `file://` cache is deleted and recreated at the same URL.

Recommendations:

- Keep CA test runs and stages off (`caAuto`) for caches that serve fresh
  machines, until Nix resolves from realisations without fetching inputs.
  On a developer machine that already has the toolchain, the cost is the
  inputs it lacks, which is usually little.
- Cheap mitigation: drop the sysroot from test runs' inputs. Only the
  target library directory is needed, and only when a test loads a Rust
  dylib; a small derivation holding just that directory would cut the
  rustc and LLVM download.
- Batching realisation lookups (the spike row's question) does not help:
  the cost is input contents, not lookups.

## Reproduce

```sh
# 1. pipelining gap (clones of the four workspaces under $M/src)
nix develop -c spikes/m6/pipelining/run-all.sh $M [name|name-profile ...]
NOPIPE=1 nix develop -c spikes/m6/pipelining/run-all.sh $M rust-analyzer-release
python3 spikes/m6/pipelining/analyze.py [--overhead 0.4] [--explain] spikes/m6/results/pipelining/<ws>-<profile>
# 2. history replay
nix develop -c python3 tools/history-replay/replay.py --repo . --work $M/hr-bb --range 5da6701 \
  --range-path crates Cargo.toml Cargo.lock --toolchain stable= \
  --toolchain nightly=$NIGHTLY/bin --toolchain nightly-hirsvh=$NIGHTLY/bin,-Zmetadata-crate-hash=no \
  --out $M/hr-breakbulk.json
# 3. nextest
nix build -f tests/test-runs nextest nextest-repo
# 4. CA island cost
WORK=$M/ca spikes/m6/ca-island/run.sh
```
