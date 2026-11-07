# Spike: per-unit overhead and graph size

Nov 7, 2026

This spike answers two rows of "Spikes and open questions" in the implementation doc, "Per-unit overhead" and "Graph size", and the worry in decision log #29: in IFD mode the Nix side substitutes named placeholders into every unit's attributes at evaluation time. Is that fast enough at about 1,000 units?

## Result

**#29: go.** Placeholder substitution is a small part of evaluation: 0.06 s of CPU at 1,225 units and 0.6 s at 3,689 units, about 3% and 6% of the evaluation. Going back to literal paths would not make evaluation faster. The cost is elsewhere.

**The real cost is that inputs grow with the transitive graph.** Every compile unit lists every transitive dependency's `rmeta`, and the `flags` of every upstream build script (Cargo passes `-L` for all of them). So the input edges of the whole graph grow with the sum of all transitive-closure sizes, which is roughly quadratic in graph size:

| Units | Input edges, all units | `.drv` bytes, all units | Evaluation CPU | First evaluation (writes the `.drv` files), wall |
| ---: | ---: | ---: | ---: | ---: |
| 381 | 12.7 k | 3.5 MB | 1.1 s | 4 s |
| 1,225 | 112 k | 25 MB | 2.4 s | 11–28 s |
| 2,036 (zed's real graph) | 250 k | 53 MB | 5.1 s | 40 s |
| 3,689 | 758 k | 154 MB | 10.4 s | 93–102 s |

Evaluation time is proportional to `.drv` bytes: about 45 µs of CPU per KB, almost all of it inside `derivation` (`derivationStrict`). The first evaluation after a plan change also writes every `.drv` file to the store. That was the slowest step: 25 ms per derivation at 3,689 units on this (loaded) machine.

**Per-unit overhead: Nix, not rustc, sets the pace for tiny crates.** On this machine, `nix build --max-jobs 8 --cores 1` of 1,225 tiny units took 160 s. `cargo build -j8` of the same workspace took 31 s. Three costs explain most of the gap. All three are paid one after another inside one `nix build`, so more build slots do not hide them:

| Cost | Measured | Where it comes from |
| --- | --- | --- |
| Per derivation | 35–50 ms | A bare `bash -c 'echo > $out'` derivation: 200 of them take as long with `--max-jobs 1` as with 8 |
| Per path in the sandbox's input closure | about 0.19 ms per path, per build | Gone with `sandbox = false`. The builder bind-mounts every input path, and the Nix process waits for the sandbox to be ready before it starts the next build |
| Per input-derivation edge | about 0.1 ms per edge, before building starts | Present with or without the sandbox; gone when the same paths arrive through one input's references |

A tiny crate's rustc run is 65–110 ms. A unit's whole build (sandbox, `breakbulk-unit`, rustc, output registration) has a median of 0.35–0.5 s. Units with more than 400 inputs take about 1.5 s.

**Recommendations, in order of payoff:**

1. Keep #29 (named placeholders). Nothing to fix in `lib/instantiate.nix`.
2. Make library units name only their **direct** dependencies. Transitive `rmeta` files and upstream link-search values would arrive through references inside the direct dependencies' outputs. Estimated effect at 3,689 units: 758 k → 32 k input edges, 154 MB → 16 MB of `.drv` files. That is 10× less evaluation, `.drv` writing and pre-build work, and the graph's size becomes linear. Command lines stay the same. Bins, tests, proc macros and build scripts link, so they keep the full list. See [Option: direct inputs](#option-direct-inputs-transitive-ones-through-references).
3. Accept that the sandbox's per-input-path cost stays. rustc needs every transitive `rmeta`, so they must be in the sandbox however they get there. At 3,000+ units this puts a floor of a few minutes under a cold build of tiny crates, whatever the core count. Real crates compile for longer, so the overhead's share is smaller, but the per-unit costs are still serial. Upstream Nix could set up sandboxes in parallel: that is the request to take upstream.
4. Small: `breakbulk-instantiate` spends about half its time in `breakbulk_format::render::crate_deps` (a breadth-first search per unit with string-keyed lookups). Memoizing per unit would roughly halve the 6–8 s it takes at 3,689 units. Not done here: it is in `breakbulk-format`, owned elsewhere, and it is not the bottleneck.

Confidence: high for the shape of the results (what grows with what, and which step dominates). Medium for absolute times: the machine was shared with other agents, with a load average of 15–30 on 8 cores during every run. Serial costs are inflated by CPU contention, so on an idle machine expect them to be maybe 1.5–2× lower. The ratios were measured back to back and are more trustworthy than the absolute times.

## Setup

Everything is in [`spikes/scale/`](../../spikes/scale/); saved numbers are in [`spikes/scale/results/`](../../spikes/scale/results/).

| File | What it does |
| --- | --- |
| `gen.py` | Generates `plan.json`, the crate sources, a Cargo workspace of the same crates, and graph statistics |
| `default.nix` | Feeds a generated plan through `breakbulk.instantiate` (IFD) and adds measurement attributes |
| `measure.sh` | Times `breakbulk-instantiate` and evaluation; summarizes the `.drv` files (`analyze.py`) |
| `build.sh`, `buildlog.py` | Builds every unit from scratch with a fresh salt; times every derivation from Nix's `internal-json` log |
| `cargo-build.sh` | Plain `cargo build -jN` of the same workspace, with a scratch `CARGO_HOME` |
| `wide.sh` | Microbenchmark: N bare derivations with K inputs each, listed directly or through one bundle, sandbox on or off |
| `profile.sh`, `folded.py` | Nix evaluation profile (`--eval-profiler flamegraph`) |
| `perf-instantiate.sh` | `perf` profile of `breakbulk-instantiate` |
| `correlate.py`, `estimate.py`, `summarize.py` | Per-unit build time against inputs; the direct-inputs estimate; the tables |

```sh
python3 spikes/scale/gen.py --n 1000 --out /tmp/g1000            # or --lock path/to/Cargo.lock
spikes/scale/measure.sh /tmp/g1000 /tmp/r1000                    # instantiate + evaluation
spikes/scale/build.sh /tmp/g1000 /tmp/r1000 8 1                  # build, --max-jobs 8 --cores 1
nix develop -c spikes/scale/cargo-build.sh /tmp/g1000 8          # the cargo comparison
spikes/scale/wide.sh /tmp/wide 200 1000 8 drvs                   # input-cost microbenchmark
python3 spikes/scale/summarize.py /tmp/g1000:/tmp/r1000
```

Nix: Determinate Nix 3.22.2 (2.35.2), sandbox on, the user's substituters (four caches), `auto-optimise-store` on. rustc 1.99 from the repository's pinned nixpkgs. 8 cores, 62 GB RAM, shared with other agents.

### The synthetic graph

`gen.py` makes N tiny library crates. Each has a `pub fn f()` and a `pub fn sum()` that calls its direct dependencies. About 12% of them get a build script that prints `rustc-check-cfg` and `rustc-cfg`. One `app` bin depends on every crate that no other crate depends on. Library crates are registry-like crate sources (`crateSrc` references, `--cap-lints allow`). `app` is a workspace package (`src` references). The arguments follow `tests/unit-smoke/plan.json`. The parts that grow with the graph follow what Cargo does:

- one `--extern name=<rmeta>` per direct dependency (`rlib` for the bin);
- one `rustc-link-search` splice for every build script of the unit's own package and of every transitive dependency, in Cargo's `to_link` order. Cargo passes `-L` for each library path that any of those scripts prints: `build_map::build` collects `to_link` transitively through linkable dependencies, and `add_native_deps` adds one `-L` per path. That is Cargo at commit `5f94df4789f005f9a352888e8355ffc645b7ed0e` (0.100.0), `src/compiler/custom_build.rs` lines 1316–1351 and `src/compiler/mod.rs` lines 552–585. Because the planner's stubs always print a link-search sentinel, a traced plan has one splice per such script;
- the transitive `rmeta`/`rlib` list (`deps` in `BREAKBULK_UNIT`) is not in the plan. `breakbulk_format::render::crate_deps` computes it from the `--extern` edges, as it does for a real plan.

The graph model was fitted to zed's `Cargo.lock` (1,787 packages; 1,655 after dropping Windows-only and wasm-only crates). Out-degrees are drawn from zed's own histogram and sorted along the build order with noise, so that leaf-like crates sit low in the graph. Each edge goes either to one of the last 30 crates (probability 0.12, which builds depth) or to an earlier crate chosen by linear preferential attachment (which gives a few crates a very large fan-in, like `libc` and `serde`). `--lock` uses a real lockfile's topology instead (cycles from dev-dependencies are broken). Lockfiles list every target's dependencies, so this over-approximates the graph a single target builds.

| Graph | Crates | Edges | Mean direct deps | Depth | Mean / median closure | Σ closure / N² | Top fan-in |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| zed `Cargo.lock` | 1,655 | 9,449 | 5.7 | 54 | 131 / 9 | 0.079 | 269, 251, 208 |
| nushell `Cargo.lock` | 962 | 3,471 | 3.6 | 37 | 38 / 5 | 0.040 | 97, 93, 73 |
| model, N = 1,655 | 1,655 | 9,823 | 5.9 | 62 | 144 / 7 | 0.087 | 168, 118, 118 |
| model, N = 100 | 100 | 714 | 7.1 | 11 | 14 / 5 | 0.14 | |
| model, N = 300 | 300 | 1,911 | 6.4 | 18 | 32 / 7.5 | 0.11 | |
| model, N = 1,000 | 1,000 | 6,154 | 6.2 | 38 | 97 / 7 | 0.097 | |
| model, N = 3,000 | 3,000 | 17,263 | 5.8 | 88 | 222 / 6 | 0.074 | |

The model matches zed on the quantity that matters here, Σ closure / N². That ratio is about 0.08, so the input edges really do grow as N². The model is deeper than zed at N = 3,000 (88 levels), which makes it a pessimistic test. zed's real topology was also run end to end ("lock 1655" below), and its numbers land where the model predicts.

Not modeled: proc macros, `links` metadata edges, features, test plans. Proc macros cut transitive propagation (`crate_deps` does not follow them), so real graphs may be somewhat smaller. Test plans add one linking unit per workspace member, and each of those lists the full closure.

## Instantiation and evaluation

`measure.sh` builds the instantiate derivation first, so the IFD is cached. It then evaluates in separate processes, each timed with GNU time and `NIX_SHOW_STATS`:

- **base:** nixpkgs and the tools only.
- **parse:** the plan text, the instantiate derivation, and reading `units.json` with `fromJSON`.
- **subst:** every unit's `BREAKBULK_UNIT` assembled from its parts exactly as `lib/instantiate.nix` does, with a fake path in place of each reference, so no derivation is computed.
- **sources:** the crate sources (`builtins.path` of each crate; a real setup uses fetch derivations instead).
- **fresh:** every unit's `.drvPath`, with a new salt, so every `.drv` is written.
- **repeat:** the same again; the `.drv` files already exist.

The salt is one env value in every unit. Only its key reaches `breakbulk-instantiate`, so a new salt does not rerun the IFD.

| Graph | Units | `plan.json` | `breakbulk-instantiate` | `units.json` | CPU: base / parse / subst / sources | CPU, repeat | Wall, repeat / fresh | Max RSS |
| --- | ---: | ---: | --- | ---: | --- | ---: | --- | ---: |
| model 100 | 117 | 0.4 MB | 0.04 s, 9 MiB | 0.5 MB | 0.9 / – / – / 0.2 | 1.0 s | 3.0 / 2.6 s | 181 MiB |
| model 300 | 381 | 1.3 MB | 0.15 s, 30 MiB | 2.1 MB | 0.8 / 0.15 / – / 0.3 | 1.1 s | 2.3 / 4.1 s | 216 MiB |
| model 1,000 | 1,225 | 4.7 MB | 1.3 s, 178 MiB | 13 MB | 0.8 / 0.3 / 0.06 / 0.5 | 2.4 s | 3.6 / 11–28 s | 388 MiB |
| zed lockfile | 2,036 | 8.3 MB | 2.6 s, 366 MiB | 28 MB | 0.8 / 0.8 / 0.23 / 0.8 | 5.1 s | 9.8 / 40 s | 584 MiB |
| model 3,000 | 3,689 | 18 MB | 5.9–8.2 s, 1.0 GiB | 78 MB | 0.7 / 1.25 / 0.61 / 1.3 | 10.4 s | 12 / 93–102 s | 1.24 GiB |

("–": below the noise between runs.)

So at 3,689 units the repeat evaluation spends about 0.7 s on nixpkgs, 1.25 s reading `units.json`, 0.6 s on placeholder substitution, about 1 s on sources and plan parsing (the spike's own driver), and **about 7 s inside `derivation`**. The evaluation profiler at 1,225 units agrees: the substitution code in `lib/instantiate.nix` (`part`, `value`, `concatMapStrings`) is a few percent on its own. Most time attributed to it is the `derivationStrict` of the dependency whose `outPath` it asks for, plus `builtins.path` copying sources (see `results/eval-profile-1000.txt`).

Nix's `derivation` cost is linear in `.drv` text: about 40–47 µs of CPU per KB at 1,225 and 3,689 units. The fresh run's extra wall time is writing the `.drv` files through the daemon. It varied by 2.5× between runs at 1,225 units (11 s and 28 s) because of the machine's load. It is paid once per changed derivation, so after a plan change (a `Cargo.lock` bump, a toolchain change) and for the downstream units of an edited path crate, not on every evaluation.

**Decision #29.** The placeholder design costs 0.06 s at 1,225 units. The original design (literal store paths in `units.json`) would not save the `derivation` cost: the `.drv` text and its inputs are the same either way. It would also need string context re-attached, because `fromJSON` refuses strings with context. Keep #29.

`passAsFile`: 85 of 1,225 units and 437 of 3,689 units have a `BREAKBULK_UNIT` over 64 KiB (largest 455 KB, the bin). The threshold works as designed.

`breakbulk-instantiate` grows as N^1.6 (0.15 s → 1.3 s → 6–8 s). This is fine for an IFD step that reruns only on plan changes. Its 1 GiB peak at 3,689 units comes from keeping the whole `units.json` in memory before writing it. `perf` puts 26% of the time in `crate_deps` itself and another 26% in `memcmp`; the release build has no frame pointers, so that is probably the same function's string-keyed `BTreeMap` lookups (`results/perf-instantiate-3000.txt`).

## Derivation size

From `nix derivation show` of every unit (`analyze.py`):

| Graph | Units | Input derivations per unit: mean / median / max | `.drv`: mean / max | `.drv`, all units |
| --- | ---: | --- | --- | ---: |
| model 100 | 117 | 18 / 9 / 111 | 6.6 KB / 27 KB | 0.8 MB |
| model 300 | 381 | 33 / 7 / 343 | 9.3 KB / 73 KB | 3.5 MB |
| model 1,000 | 1,225 | 91 / 7 / 1,115 | 20 KB / 241 KB | 25 MB |
| zed lockfile | 2,036 | 123 / 10 / 1,848 | 26 KB / 349 KB | 53 MB |
| model 3,000 | 3,689 | 206 / 6 / 3,347 | 42 KB / 735 KB | 154 MB |

Yes, it is quadratic. The median unit stays small (6–10 inputs), but the mean grows with N because units high in the graph list nearly everything below them. A least-squares fit gives 2.5 KB per derivation plus 190–240 bytes per input derivation. Each input appears twice: once in `inputDrvs` (the `.drv` path and output name) and once in `BREAKBULK_UNIT` (the output path and file name in `deps`, or a `flags` directory in a splice).

## Building

`build.sh` evaluates with a new salt (so no unit has been built), then runs `nix build <drv>^* --max-jobs 8 --cores 1` and times every derivation's `building` activity. Tools and sources were already built. The bin root's check runs the binary, so the whole graph really compiled and linked.

| Graph | Derivations | Nix wall (build span) | Median / mean per unit | Same count of bare derivations | `cargo build -j8` | `cargo build -j1` |
| --- | ---: | --- | --- | --- | ---: | ---: |
| model 300 | 382 | 31.8 s (24.0 s) | 0.35 / 0.38 s | 13.7 s | 8.6 s | 25.2 s |
| model 300, no substituters | 382 | 24.4 s (22.1 s) | 0.31 / 0.33 s | 13.7 s | | |
| model 1,000 | 1,226 | 160 s (142 s) | 0.50 / 0.64 s | 61 s | 31.0 s | 136 s |

- **Nix vs Cargo:** 3.7× (N = 300) and 5.2× (N = 1,000) Cargo's `-j8` time. Even bare derivations alone take twice Cargo's whole build.
- **Tiny-crate compile time:** `cargo build -j1` time divided by unit count is 66 ms (N = 300) and 111 ms (N = 1,000). Cargo's per-unit cost grows with dependency count too: rustc loads every transitive `rmeta`.
- **Per-unit overhead:** a unit's `building` activity has a median of 0.35–0.5 s, against 0.15–0.2 s for a bare derivation at the same time. In throughput terms, at N = 1,000 Nix finished one unit every 116 ms with 8 slots, and Cargo one every 25 ms.
- **Concurrency:** 8 slots kept only 5.5–6 builds running on average. Even bare derivations, with no dependencies between them, average 4.8.
- **Inputs:** build time per unit rises by 1.0–1.7 ms per input derivation (`results/correlate.txt`). Units with more than 400 inputs take about 1.5 s; units with fewer than 25 take 0.48 s.
- **Substituters:** every new unit output is looked up on every configured cache before building. With the user's four caches that added 7 s of wall time at N = 300 (31.8 s vs 24.4 s).

### Where the overhead goes

`wide.sh` builds N bare derivations that differ only in their inputs. Two series ran; the machine's load was about 17 in the first and about 24 in the second.

| Series | Derivations × inputs | How inputs arrive | Sandbox | Max jobs | Build span | Before the first build |
| --- | --- | --- | --- | ---: | ---: | ---: |
| 1 | 200 × 0 | | on | 8 | 7.0 s | |
| 1 | 200 × 0 | | on | 1 | 7.8 s | |
| 1 | 200 × 1,000 | listed | on | 8 | 45.8 s | |
| 1 | 200 × 1,000 | listed | on | 1 | 44.3 s | |
| 2 | 100 × 0 | | on | 8 | 14.7 s | 1.3 s |
| 2 | 100 × 1,000 | listed | on | 8 | 28.3 s | 14.4 s |
| 2 | 100 × 1,000 | one bundle whose output references them | on | 8 | 28.8 s | 5.0 s |
| 2 | 100 × 1,000 | listed | off | 8 | 6.5 s | 15.8 s |
| 2 | 100 × 0 | | off | 8 | 7.8 s | 0.4 s |

What this shows:

- `--max-jobs 8` and `--max-jobs 1` take the same time. The per-derivation work of one `nix build` is serial.
- The cost of inputs during the build is the sandbox. It goes away with `sandbox = false`, and it is the same whether inputs are listed or arrive through references. That works out to about 0.15–0.19 ms per path in the input closure, per build.
- Before building, Nix spends about 0.1 ms per input-derivation edge. This cost does not depend on the sandbox. It drops by two thirds when the same paths arrive through one input's references.

From the source (DeterminateSystems/nix-src at `60ca49f7526402a147591f1180b1e93bac0a6f5c`): `DerivationBuilderImpl::startBuilder` (`src/libstore/unix/build/derivation-builder.cc`, line 529) calls `processSandboxSetupMessages`. That function blocks on `readLine(builderOut)` until the child writes `\2` (line 1049), which the child does only after `enterChroot`. `enterChroot` bind-mounts every entry of `pathsInChroot` one at a time (`src/libstore/linux/build/linux-derivation-builder.cc`, line 845). `pathsInChroot` holds the full input closure (`chroot-derivation-builder.cc`, lines 52–55). The goals of one `nix build` run on one worker thread as coroutines (`src/libstore/build/worker.cc`). So sandbox setup, including one bind mount per input path, runs serially across all builds. A goal that finds no free build slot ends its `building` activity and retries later (`derivation-building-goal.cc`, lines 916–920); `buildlog.py` keeps the last attempt. Confidence: high that setup blocks the worker; medium on how the remaining per-derivation cost (output registration, locks, database writes) splits up.

### What it means at 3,000+ units

A rough model, using series 1's coefficients: 35 ms per derivation, plus 0.19 ms per sandbox input path (each unit's input derivations plus about 34 paths of tool closure), plus 0.11 ms per input-derivation edge. This gives a serial floor of about 85 s at 1,225 units (measured: 160 s, with the compiles and the load on top). At 3,689 units the floor is about 380 s: 130 s per derivation, 170 s sandbox, 80 s edges. That floor does not shrink with more cores. With direct inputs only (below), the 80 s of edges drops to about 4 s and the sandbox share stays.

For tiny crates this overhead dominates. A real dependency's debug compile takes from tenths of a second to tens of seconds, so the share is smaller, but the serial floor stays.

## Options

### Option: direct inputs, transitive ones through references

Today `crate_deps` puts every transitive crate file into a library unit's `deps`, and every upstream build script's `flags` into its splices. Instead:

- A library unit names only its direct dependencies' `rmeta` outputs, and only the `flags` of its own build script.
- `breakbulk-unit` writes a small manifest into the `rmeta` output, for example `nix-support/breakbulk-deps`. The manifest lists the unit's own `rmeta` file plus every path from its direct dependencies' manifests: the transitive `rmeta` files, and the expanded `-L` values of every build script in Cargo's `to_link` for that unit. Nix's reference scanner then records those paths as references of the `rmeta` output, so they are in every dependent's sandbox without being listed.
- To build `$TMPDIR/deps` and the `-L` arguments, `breakbulk-unit` reads its direct dependencies' manifests. The rustc command line is byte-identical to today's.
- Linking units (bins, tests, proc macros, build scripts) keep listing every `rlib` explicitly, as they do now. Library `rlib` outputs get no references, so fetching one library's `rmeta` from a cache still never fetches an `rlib`.
- Invalidation does not change. A unit's input-addressed hash already depends on every transitive unit through its direct inputs' hashes.

Estimated effect (`estimate.py`: the measured `.drv` sizes, minus the transitive inputs that would go away, priced with the fitted bytes per input):

| Graph | Input edges: now → direct | `.drv` bytes: now → direct |
| --- | --- | --- |
| model 300 | 12.7 k → 3.5 k | 3.5 → 1.6 MB |
| model 1,000 | 112 k → 11 k | 25 → 5.3 MB |
| zed lockfile | 250 k → 18 k | 53 → 8.8 MB |
| model 3,000 | 758 k → 32 k | 154 → 16 MB |

The bin at the top still lists everything, which is why the total is not smaller still. Evaluation CPU, the first evaluation's `.drv` writes, `units.json` size, `breakbulk-instantiate` time, and Nix's pre-build edge work all scale with these numbers. The sandbox's per-path cost does not change. This touches `breakbulk-format` (`crate_deps`, `render_unit`) and `breakbulk-unit` (`compile`), so it was not done in this spike.

### Other options considered

- **Literal paths instead of placeholders (the fallback in #29).** This would not help: the cost is in `derivation`, not in substitution.
- **Dynamic-derivation mode.** Evaluation would no longer pay for this, but the instantiate build would write the same 154 MB of `.drv` files through the daemon. Direct inputs help both modes equally.
- **Coarser units for tiny leaf crates** (several crates in one derivation). This would cut the per-derivation cost, but it breaks "one derivation per Cargo unit" and cross-project sharing. Not recommended unless the numbers on real projects demand it.
- **Upstream Nix:** set up sandboxes off the worker thread, or bind-mount input paths more cheaply. That is where the remaining per-unit cost lives.
- **Fewer substituters for unit outputs.** Every new unit output is looked up on every cache. The local store is the main cache here, so a `narinfo` miss on four remote caches per output is pure overhead. That is worth a line in the docs.

## Limits

- The machine was shared and heavily loaded (load average 15–30 on 8 cores) for every run. Absolute times are inflated and noisy, run to run by up to 2.5× for daemon-bound steps such as `.drv` writing. Ratios measured back to back are more trustworthy.
- A Nix build of N = 3,000 was not run; its numbers above are a model, checked against N = 1,000.
- The env capture is `tests/unit-smoke`'s stand-in (`PATH` only). A real base capture adds roughly 50–100 paths to every unit's sandbox closure, at about 0.19 ms each.
- Crate sources are `builtins.path` copies made during evaluation. A real setup has fetch and unpack derivations, which add one more derivation per crate to a cold build and nothing to a warm one.
- Proc macros, `links` metadata, features and test plans are not modeled (see [The synthetic graph](#the-synthetic-graph)).
