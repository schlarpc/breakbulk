# Spike A: trace fidelity

Nov 7, 2026 · spike for M1 (traced planner)

The spike's code is on the [`spikes-archive`](https://github.com/schlarpc/breakbulk/tree/spikes-archive) tag; paths below are relative to it.

**Verdict: go.** On Cargo 1.95, 1.97, 1.99 and current nightly (1.101), Cargo
accepts empty outputs, one-line dep-info and synthetic artifact
notifications, with pipelining on and with `links` overrides in config. The
shim's sentinels leave every unit's `-C metadata` and every build-script
run's hash unchanged. After the sentinels are replaced with the real build
scripts' values, the traced argv and env equal the argv and env of a real
`cargo -vv` build, unit for unit: 32 of 32 (toolchain, command) pairs.
Placement of every sentinel kind is identical on all four toolchains.

The traced planner needs changes before M1, none of them structural:

1. **Link search paths need two sentinels per run**, not one. Cargo puts
   every run's paths inside its own `OUT_DIR` before every path outside,
   across all runs. The shim now prints both classes.
2. **Link arguments of all kinds are one ordered list.** A splice must be
   "run R's link args that apply to this unit, in printed order", not one
   splice per kind.
3. **Current nightly Cargo uses a new build-directory layout by default**,
   which the path-rewriting table does not cover yet. A nightly toolchain
   also makes rlibs without metadata, so linking units need `.rmeta` files
   too.
4. Several statements in the design and implementation docs are wrong; the
   list is at the end.

Confidence: high for everything marked "observed" (each was run on all four
toolchains unless stated) and for the source citations. Lower where marked
"source only" or "not tested".

## Setup

| Toolchain | Cargo | Cargo commit used for citations |
| --- | --- | --- |
| 1.95.0 (rust-overlay) | `1.95.0 (f2d3ce0bd 2026-03-21)` | `f2d3ce0bd7f24a49f8f72d9000448f8838c4e850` |
| 1.97.0 (rust-overlay) | `1.97.0 (c980f4866 2026-06-30)` | `c980f4866141969fab6254a680546a277789d6f0` |
| 1.99.0 (rust-overlay) | `1.99.0 (5f94df478 2026-08-27)` | `5f94df4789f005f9a352888e8355ffc645b7ed0e` |
| nightly (rust-overlay) | `1.101.0-nightly (3c747ea3e 2026-11-03)` | `3c747ea3ead23951c1b43a5edfcbdb449135ddeb` |

Citations are into [rust-lang/cargo](https://github.com/rust-lang/cargo) at
the commit each toolchain reports. File paths below are 1.99's; up to 1.97
the same files live under `src/cargo/core/compiler/` and
`src/cargo/core/`. Citations without a version hold for all four.

All code is in this repository:

- `crates/breakbulk-shim/`: the shim, written as the real M1 shim (modes
  Query, Compile, Rustdoc, Build-script stub). See "The shim" below.
- `spikes/trace-fidelity/`: fixtures, the Python driver `bbtrace.py`, one
  `exp_*.py` script per question, and their output under `results/`.
  `run.sh` resolves the toolchains and tools from the flake inputs and runs
  one script, for example `spikes/trace-fidelity/run.sh exp_directives.py`.

Fixtures are offline (path dependencies and one vendored registry crate).
Every run uses a scratch `CARGO_HOME`, `HOME` and target directory, and a
copy of the fixture outside `$HOME` (see surprise S1).

The `directives` fixture has seven workspace packages plus one vendored
crate: `a-sys` (`links = "a"`) ← `b-sys` (`links = "b"`) ← `c` (`rlib` +
`cdylib`, with an integration test, an example and a bench); `pm` (proc macro
with a build script); `hostdep` (`links`, used as a build-dependency of
`app`); `oldsyn` (`rust-version = "1.70"`, so `cargo:` syntax, `links`);
`app` (two bins); `tiny` (vendored registry crate with a build script). Every
build script prints several values of every directive kind that applies, in
a deliberately mixed order, plus link search paths both inside and outside
its `OUT_DIR`.

## Questions and answers

| Question | Answer |
| --- | --- |
| Does Cargo accept empty outputs, synthetic dep-info and the artifact notification? | Yes, on all four (observed: `build`, `build --release`, `check`, `test --no-run`, `build` without `--target`, split debuginfo, `links` overrides). |
| … with pipelining? | Yes. Libraries get `--emit=dep-info,metadata,link` and `--json=…artifacts…`; the shim writes the files, then prints one notification per output, as rustc does. The notification is optional: if it never comes, Cargo marks the metadata as produced when the job ends (`job_queue/job_state.rs`, `JobState::run_to_finish`; source). |
| … with `links` overrides in config? | Yes. Cargo skips the overridden build script (no compile, no run) and passes the values itself, including `DEP_<LINKS>_<KEY>` to dependents' runs (observed). Overrides under `target.<host>.<links>` also apply to host units when `--target <host>` is given (observed, `hostdep`). |
| Where do sentinels land, in what shapes? | See "Wrapping table". Identical on all four toolchains (`results/placement-*.txt`, compared by `diff_placement.py`). |
| Do sentinels leave `-C metadata` unchanged? | Yes. For every command, the set of (crate, `-C metadata`) pairs and the set of build-script run hashes are identical between real and traced builds (observed, 32 of 32). |
| Does `--target <host>` keep rustflags off host units? | Yes. `[build]` and `[target.<host>]` rustflags reach only target units; build scripts, proc macros and host copies of libraries get none; host build-script runs get `CARGO_ENCODED_RUSTFLAGS=''` (observed). Without `--target`, every unit gets them. |
| … and apply the target linker? | Yes, to every target unit, **and to every host unit too** (build scripts, proc macros, host rlibs), and `RUSTC_LINKER` on every build-script run is the target linker (observed). This is the same-triple case the design describes. Source: the host linker comes from `target.<host>` while `target-applies-to-host` is true, its default (`build_context/target_info.rs`, `RustcTargetData::new`). |
| Same-triple: what happens with the linker on host units? | They get `-C linker=<target linker>` (above). Cargo passes `-C linker` to every unit, including rlibs that never link (`compiler/mod.rs`, `add_codegen_linker`). On nightly, `-Zhost-config -Ztarget-applies-to-host` with `target-applies-to-host=false` and `host.linker` gives build scripts and proc macros the host linker, but host rlibs still got the target linker (observed, nightly only), because `add_codegen_linker` chooses by target type (`Target::for_host`), not by unit platform. |
| Does a path crate hash differently from two workspaces? | Yes, as the design says. Inside a workspace root its `-C metadata` uses the path relative to the root and does not change when the tree moves; outside, it uses the absolute path. `shared` (member of ws1, path dependency of ws2) has two different hashes; `common` (outside both roots) has one hash for both workspaces, which changes when the tree moves (observed, `results/multiws.txt`). Being a selected member changes only `CARGO_PRIMARY_PACKAGE`. |
| How can breakbulk tell whether the project set `trim-paths`? | From the trace (details below). It is not available on 1.95–1.99 at all: any `trim-paths` setting is a hard error on stable (observed). It is stable in 1.101 (nightly today). |
| Does `cargo test --doc` with `RUSTDOC=shim` record doctests without running anything? | Yes. One `rustdoc --test` record per library (including proc macros); no test process starts (a recording runner saw zero starts); Cargo prints `Doc-tests <crate>` and exits 0 (observed). |
| Which targets does `cargo test --no-run` build by default? | Libraries, the lib test harness, bin test harnesses, integration tests and examples (as plain bins). Bins themselves only when the package has integration tests. **Not benches.** `cargo bench --no-run` builds lib and bin harnesses in bench mode and benches, but no examples or integration tests (observed; `results/doctest.txt`, `results/identity.txt`). |
| Is the profile name part of unit identity (bench vs release)? | No. `build --release`, `bench --no-run` and `build --profile bench` give identical `-C metadata` and `-C extra-filename` for every shared unit, and so does a custom profile that only inherits `release` (observed). Source: `Profile`'s `Hash` uses `comparable()`, which leaves out `name` (`workspace/profiles.rs`). The output directory differs for a custom profile (`target/ci`), which path rewriting removes. |
| Does `--print=file-names` with the full compile arguments name every output? | For link outputs, yes: 154 cases per toolchain (10 crate-type sets × 7 `--emit` sets × `--test` × with and without `-C extra-filename`) match real rustc's file lists and artifact notifications exactly. rustc stops after printing and does not resolve `--extern` paths. It does not name split-debuginfo side files (`.dwp`, `.dwo`); see surprise S9. |
| Golden test, first version? | `exp_directives.py` compares real `cargo -vv` with the trace for every unit, after expanding sentinels with each run's real output (`results/directives.txt`). It also diffs target-directory file listings: identical names in every case except debuginfo side files. A negative control (`BB_NAIVE=1`: one splice per kind, no path ordering) produces diffs, so the comparison is not vacuous. |

## Wrapping table

Placement is identical on Cargo 1.95, 1.97, 1.99 and 1.101-nightly. One
table therefore serves the whole supported window; the golden tests should
still pin it per release.

"R's package" means the package whose build script is run R. "Platform"
means host or target: a run's values only ever reach units of the run's own
platform, except dynamic-library paths (last rows).

| Kind | Sentinel the stub prints | Shape in traced argv/env | Reaches |
| --- | --- | --- | --- |
| `rustc-cfg` | `__bb_R_cfg` | `--cfg __bb_R_cfg` | Every compile of R's package: lib, bins, examples, tests, benches, all test harnesses; and its `rustdoc --test`. Not its own build script. |
| `rustc-check-cfg` | `cfg(__bb_R_ccfg)` | `--check-cfg cfg(__bb_R_ccfg)` | Same as `rustc-cfg`. |
| `rustc-env` | `__BB_R_ENV=__bb_R_env` | env var `__BB_R_ENV` on the process | Same as `rustc-cfg`. |
| `rustc-link-search` (+ `-L` from `rustc-flags`) | `native=<OUT_DIR>/__bb_R_search` and `native=/__bb_R_search_ext` | `-L native=…/__bb_R_search`, `-L native=/__bb_R_search_ext` | Every compile of R's package and of every package that depends on it on the same platform (Cargo's `to_link`), any crate type. For a host run (build-dependency, proc macro): the compiles of its dependents' build scripts. Order rule below. |
| `rustc-link-lib` (+ `-l` from `rustc-flags`) | `__bb_R_lib` | `-l __bb_R_lib` | R's package only: its lib (every lib crate type, proc macro) and lib test harness; its bins, tests, examples and benches only when the package has no lib (`pass_l_flag` in `compiler/mod.rs`, `rustc`). Never `rustdoc --test`. |
| `rustc-link-arg` | `__bb_R_arg` | `-C link-arg=__bb_R_arg` | Every compile of R's package, **including rlib-only libs, the lib test harness, proc macros** and `rustdoc --test`. |
| `rustc-link-arg-bins` | `__bb_R_arg_bins` | `-C link-arg=…` | R's bins and their test harnesses. |
| `rustc-link-arg-bin=NAME` | `NAME=__bb_R_arg_bin_NAME` | `-C link-arg=__bb_R_arg_bin_NAME` | That bin and its test harness. |
| `rustc-link-arg-tests` | `__bb_R_arg_tests` | `-C link-arg=…` | Integration tests only (`Target::is_test`), not lib or bin harnesses. |
| `rustc-link-arg-examples` | `__bb_R_arg_examples` | `-C link-arg=…` | Examples. |
| `rustc-link-arg-benches` | `__bb_R_arg_benches` | `-C link-arg=…` | Benches (bench plan only; the test plan has none). |
| `rustc-link-arg-cdylib` | `__bb_R_arg_cdylib` | `-C link-arg=…` | R's lib when it has the `cdylib` crate type, not in test mode; also cdylibs of dependent packages (a compatibility exception, `add_native_deps` in `compiler/mod.rs`; source only, not exercised). |
| `metadata` | `__bb=R` | env `DEP_<LINKS>___BB=R` on runs | Build-script runs of packages that **directly** depend on R's package as a normal dependency. Not transitive (c's run sees `DEP_B`, not `DEP_A`); not through build-dependencies (`app`'s run does not see `DEP_HOSTDEP`). |
| link search → dynamic-library path of a compile | (the `__bb_R_search` sentinel) | `LD_LIBRARY_PATH` entry `<OUT_DIR>/__bb_R_search` on the rustc process | Compiles whose package has R's package as a host "plugin" dependency (proc macro or build-dependency with a build script): `add_plugin_deps`. Observed: `app`'s compiles carry `pm`'s path. |
| … of a build-script run | same | `LD_LIBRARY_PATH` entry on the run | Runs whose build script depends on R's package (observed: `app`'s run carries `hostdep:host`'s path). |
| … of a test process | same | `LD_LIBRARY_PATH` entries | **Every** run of the test's platform whose path lies inside the target directory, not only dependencies (`Compilation::fill_env`, from the global `native_dirs` set). Observed with a recording runner under `cargo test`. |
| … of `rustdoc --test` | same | `LD_LIBRARY_PATH` entries | Every host run's in-target-dir paths (same function, `ToolKind::Rustdoc`). |
| link search → `rustdoc --test` | both sentinels | `-L native=…` | **Every** run in the invocation, both platforms, both classes, **sorted by value** and deduplicated (`ops/cargo_test.rs`, `run_doc_tests`, from `Compilation::native_dirs`, a `BTreeSet<PathBuf>`). Not positional. |

Value-dependent rules the unit must apply (each observed and reproduced by
the comparison):

- **Search-path order.** For one compile, Cargo collects the search paths
  of every run in `to_link` order, then stable-sorts them: paths inside the
  printing run's own `OUT_DIR` first (`LibraryPath::CargoArtifact`), all
  others after (`LibraryPath::External`) (`compiler/mod.rs`,
  `add_native_deps`; `custom_build.rs`, `LibraryPath::new`). Search paths
  from `links` overrides are always `External`
  (`context/target.rs`, `parse_links_overrides`). Expansion: at
  `…/__bb_R_search` put R's values that lie inside R's `out`, in printed
  order; at `/__bb_R_search_ext` put R's other values, in printed order. A
  `-L` literal from an override sits between them as Cargo placed it.
- **Link arguments.** All `rustc-link-arg*` kinds of one run share one list
  in printed order (`BuildOutput::linker_args`). In the trace, a unit's
  link-arg sentinels from run R are adjacent; the set of kinds present is
  exactly the set that applies to the unit. Expansion: replace the whole
  adjacent group with R's link args whose kind is in that set, in printed
  order. One splice per kind would reorder them (the negative control
  shows it).
- **`-l` and `-L` from `rustc-flags`** join the `rustc-link-lib` and
  `rustc-link-search` lists in printed order (`custom_build.rs`,
  `BuildOutput::parse`).
- **Dynamic-library paths** keep only values inside the target directory
  (`filter_dynamic_search_path`). In breakbulk: inside any run's `out`.
- **`metadata`**: `DEP_<LINKS>_<KEY>` with the key uppercased and `-`
  mapped to `_`; in `cargo:` syntax any unknown key is metadata.

Shapes are the same with `cargo:` syntax (package with
`rust-version = "1.70"`); the stub picks the syntax from
`CARGO_PKG_RUST_VERSION` (`cargo::` needs 1.77, `custom_build.rs`,
`check_minimum_supported_rust_version_for_new_syntax`).

## trim-paths

- **Availability.** 1.95, 1.97, 1.99: unstable. A manifest
  `[profile.*] trim-paths` fails with "feature `trim-paths` is required"; a
  config one fails with "config profile `dev` is not valid"; `-Ztrim-paths`
  is refused on stable (observed). 1.101 nightly: stable
  (`workspace/features.rs`: `(stable, trim_paths, "1.101", …)`); no
  `cargo-features` needed (observed). The default is still `none` for every
  profile, release included (`Profile::default_release`; observed: no remap
  flags in a nightly `--release` trace).
- **What Cargo emits** (`compiler/trim_paths.rs`, `trim_paths_args`): on
  every compile, `--remap-path-scope=<scope>`, then `--remap-path-prefix`
  pairs: the package root (workspace members `=.`, path crates outside the
  root `=/cargo/deps/<name>-<version>`, registry `=/cargo/registry/<id>`,
  git `=/cargo/git/<id>/<rev>`), then `<build-dir>=/cargo/build-dir`, then
  `<sysroot>/lib/rustlib/src/rust=/rustc/<commit>`. Build-script runs get
  `CARGO_TRIM_PATHS_SCOPE` (1.101: always, `none` when off; ≤1.99: only when
  set). With trim-paths on, path crates outside the root hash without their
  absolute path (`compute_metadata`, `hash_metadata`; observed: `common` and
  `shared` keep their hash when the tree moves).
- **How to detect it.** Read it from the trace: a unit is under Cargo's
  trim-paths when its argv has `--remap-path-scope=` followed by
  `--remap-path-prefix` pairs ending in `…=/cargo/build-dir` and
  `…=/rustc/<hash>`. User rustflags never produce the `/cargo/build-dir`
  pair. On Cargo ≤ 1.99 stable the answer is always "off", because Cargo
  refuses to run otherwise.
- **Setting it by default** (design: "breakbulk sets it by default when the
  project has not set it"). Profile settings from `--config` override the
  manifest's, so passing `--config profile.<p>.trim-paths=…` blindly would
  clobber the project's own choice. Recommended: trace once; only when the
  trace shows trim-paths off and Cargo ≥ 1.101, trace again with the
  `--config`. The second trace is cheap compared with a build. (Reading
  profiles from the manifests would mean encoding Cargo's profile merging,
  which Principle 1 forbids.)

## The shim

`crates/breakbulk-shim` implements the four modes of the implementation doc,
with these details settled by the spike:

| Mode | Detected by | Action |
| --- | --- | --- |
| Build-script stub | `breakbulk-stub.json` in the directory of the running executable | Record argv, cwd, full env; print sentinels; exit 0. |
| Rustdoc | the executable's file name contains `rustdoc` (the planner sets `RUSTDOC` to a `rustdoc` symlink to the shim) | Queries `exec` `$BREAKBULK_RUSTDOC`; otherwise record and exit 0. |
| Query | `-vV`, `-V`, `--version`, any `--print`, or `-` as input; or no `--crate-name`/input | **Record** (new), then `exec` the real rustc. |
| Compile | `--crate-name` and an input file | Record; `rustc ARGS --print=file-names`; create outputs; dep-info; notifications; install the stub for `build_script_*`. |

- As `RUSTC_WRAPPER` it is started as `shim [workspace-wrapper] rustc ARGS`;
  the program chain is every leading argument that is not an option. Cargo
  always starts rustc's arguments with an option. The workspace-wrapper
  (clippy) chain is parsed but **not tested** (the minimal toolchains have
  no `clippy-driver`).
- **Query records** give the planner Cargo's own process environment, which
  is the right baseline to subtract (surprise S6).
- The stub reads `cargo metadata` JSON (`$BREAKBULK_METADATA`, default
  `$BREAKBULK_RECORD/metadata.json`) to learn the package's targets, finding
  the package by `CARGO_MANIFEST_DIR`. It needs bin names for
  `rustc-link-arg-bin=NAME`, and Cargo rejects `-bins`, `-tests`,
  `-examples`, `-benches` and `-bin=NAME` when the package has no such
  target (`custom_build.rs`, `BuildOutput::parse`). It prints
  `rustc-link-arg` always (see the wrapping table).
- The run tag R is the hash in `OUT_DIR`: `build/<pkg>-<hash>/out`
  (≤ 1.99) or `build/<pkg>/<hash>/out` (nightly).
- Unit tests cover argument parsing, output naming, dep-info, sentinel
  selection and syntax. The spike harness is the integration test for now.
- **Speed.** Tracing the 18-unit fixture took 2.1 s against 0.4 s for the
  real build (tiny crates). Most of it is one `rustc --print=file-names`
  per unit and copying a 5 MB debug shim per build script. Caching the
  file-name query per (target, crate types) the way Cargo does
  (`rustc - --crate-name ___ --print=file-names --crate-type …`) and a
  release-built shim would remove most of it. Not needed for M1.

## Surprises that change the docs

Implementation doc (`docs/implementation.md`):

- **S1. Cargo reads `.cargo/config.toml` from every ancestor of the working
  directory**, including `$HOME/.cargo/config.toml` when the project is under
  `$HOME`, whatever `CARGO_HOME` says. The first traces here silently used
  the author's `build.build-dir`. In the Nix sandbox (`/build/…`) this is
  harmless, but the golden tests, local `breakbulk-plan` runs and the dev
  shell's comparisons must stage projects outside `$HOME` or accept it.
- **S2. Two link-search sentinels** (see the wrapping table). Update the
  sentinel table (`rustc-link-search` row) and the splice rule.
- **S3. One splice for all link-arg kinds**, filtered by the kinds present at
  that position. Update "Sentinel directives" step 3 and the plan format's
  `{splice, kind}` (kind becomes a set, or the planner records the set of
  link-arg kinds per splice).
- **S4. `rustc-link-arg` is printed always**, not only "when the package has
  a linkable target": Cargo passes it to rlib, lib-test, proc-macro and
  rustdoc units too. (Confirms decision-log item from the directive parser.)
- **S5. New build-dir layout on current nightly Cargo, on by default**
  (`workspace/features.rs`: `build_dir_new_layout = !is_new_build_dir_layout_opt_out()`;
  opt-out `__CARGO_TEMPORARY_BUILD_DIR_NEW_LAYOUT_OPT_OUT=1`). It will reach
  stable unless reverted. Every unit gets `build/<pkg>/<hash>/{out,fingerprint,run}`;
  compile outputs go to that `out`; there is no `deps/`; each compile gets
  one `-L dependency=<dep's out>` per dependency instead of one shared
  directory; build scripts are `…/out/build_script_build` with no hash and
  no `build-script-build` copy; bins, dylibs, cdylibs and build scripts lose
  `-C extra-filename`. The "Path rewriting" table and "Platform is read from
  the output location" both need the second layout. The rewriting stays
  simple: an output path names its unit's directory directly.
- **S6. The env baseline must come from inside Cargo.** Cargo sets
  `SSL_CERT_FILE` and `SSL_CERT_DIR` on itself at startup (openssl-probe in
  the Cargo binary) and, from 1.97, `CARGO`; every child inherits them, and
  `cargo -vv` does not show them because Cargo did not set them per process.
  "Recorded env minus the env the planner gave Cargo" therefore keeps two
  machine-specific variables. Use the env of the shim's `rustc -vV` query
  record as the baseline (observed: it differs from the planner's env by
  exactly these variables).
- **S7. Build-script runs see the shim.** Cargo hands every build script
  `RUSTC_WRAPPER` (when set) and `RUSTDOC` as configured
  (`custom_build.rs`, `build_work`), so the trace shows the shim for both. Env filtering must drop `RUSTC_WRAPPER` (already
  planned) and rewrite `RUSTDOC` to the real rustdoc (new).
- **S8. Doctests.** `rustdoc --test` gets `-L` for every run in the
  invocation, sorted by value, not by position; and `--test-runtool` when a
  runner is configured (so the planner should not configure one while
  tracing). No `-l`. The doctest derivation must rebuild this list from all
  runs at build time.
- **S9. Debuginfo side files are not named by `--print=file-names`**
  (`.dwp` with `split-debuginfo=packed`, `.dwo` with `unpacked`; `.pdb` on
  msvc and `.dSYM` on macOS by the same logic, not tested). Cargo tolerates
  their absence during the trace (observed). `breakbulk-unit` must collect
  them from the output directory, not from the plan's output list.
- **S10. Nightly toolchains make rlibs without metadata.** When both Cargo
  and rustc are nightly, Cargo passes `-Zembed-metadata=no` and gives
  dependents `--extern name=lib….rlib --extern name=lib….rmeta`
  (`build_context/target_info.rs`, `should_embed_metadata`; observed). Units
  that link need their dependencies' `rmeta` output as well as `rlib`.
  Nightly also adds `unused-externs-silent` to `--json`.
- **S11. Verbosity changes argv.** With `-vv`, non-local crates get
  `--cap-lints warn` plus their lint flags instead of `--cap-lints allow`
  (`compiler/unit.rs`, `show_warnings`; `compiler/mod.rs`, `add_cap_lints`).
  And only `-vv` prints per-process env; `-v` prints argv alone
  (`compiler/compilation.rs`, `rustc_process`: `display_env_vars` under
  `extra_verbose`). Golden
  tests must run real and traced Cargo at the same verbosity (the spike uses
  `-vv` for both), and the planner must not use `-vv`. A recording
  passthrough mode in the shim would avoid parsing `-vv` altogether.
- **S12. `CARGO_INCREMENTAL` (and `profile.*.incremental`) is part of
  `-C metadata`** (`Profile::comparable` includes `incremental`; observed:
  every unit changes). The planner must neither inherit `CARGO_INCREMENTAL`
  from its own environment nor set it; it strips `-C incremental=…` from
  argv instead, which does not affect the hash.
- **S13. `-C metadata` does not contain rustflags.** Rustflags only go into
  `-C extra-filename` (`compute_metadata`: `unit.rustflags` is hashed into
  `unit_id` only; observed). So `-C metadata` identifies a unit within one
  plan, but two variants that differ only in rustflags (coverage, a
  `--cfg`) share `-C metadata`; units without `-C extra-filename` (cdylibs,
  and on nightly bins and dylibs) then have identical output names too. Unit
  keys must stay per plan, which is the current design; `explainSharing`
  must compare argv, not hashes.
- **S14. Config rustflags sources are exclusive.** Cargo takes rustflags
  from the first of: `CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`,
  `target.<triple>` + `target.<cfg>`, `build.rustflags`
  (`build_context/target_info.rs`, `extra_args`; observed: with both set,
  `build.rustflags` is dropped). The spec passing its rustflags as
  `--config target.<triple>.rustflags=…` therefore **silently drops a
  project's `[build] rustflags`**. Arrays concatenate only for the same key.
  Options: pass spec rustflags under the key the project uses (read with
  `cargo config get`, unstable) or under both keys; or document that
  projects must use `target.<triple>.rustflags`. (Toolchain section and
  "Invocation".)
- **S15. `-C linker` is on every unit**, rlibs included, so a linker change
  changes every unit's derivation even though it does not change
  `-C metadata`. Either accept it (the linker is part of the toolchain
  anyway) or drop `-C linker` from units that do not link, which would
  diverge from Cargo's argv.

Design doc (`docs/design.md`):

- **D1. "Benches are compiled by the test plan, like Cargo does"** is
  wrong. `cargo test --no-run` builds no benches by default. Benches come
  only from the bench variant (`cargo bench --no-run`), or from adding
  `--benches` (or `--all-targets`) to the test plan, which builds them with
  the test profile. Same correction for "Benches" under "Tests as products"
  in the implementation doc and the `benches` fixture row.
- **D2. "Any two profiles: Nothing shared; the profile is part of every
  unit's identity"** is wrong for profiles with equal settings. Identity is
  the profile's settings, not its name: `release`, `bench` and a custom
  profile that only inherits `release` give identical units. Different
  settings (opt-level, debuginfo, …) do give different units.
- **D3. trim-paths "stable in Cargo 1.101"** is confirmed on current
  nightly. Its release default is still `none`.

Confirmed as written: the `--target <host>` scoping, the same-triple linker
problem and its rewrite, path-crate hashing inside vs outside the root,
`links` overrides needing no special case, `RUSTDOC` doctest tracing, the
pipelining protocol, and placing link search sentinels inside `OUT_DIR` for
the dynamic-library rule.

## Decisions made in the spike

- The link-search sentinel outside `OUT_DIR` is spelled
  `native=/__bb_R_search_ext`, a root-level path that no real build uses and
  that the forbidden-literal check catches if a splice is missed.
- Rustdoc mode is detected by the executable name (a `rustdoc` symlink), not
  by an environment variable, because Cargo starts `RUSTDOC` directly with
  the same environment it gives `RUSTC_WRAPPER`.
- The stub learns its package's targets from a `cargo metadata` file the
  planner writes before tracing.
- Fixtures copy themselves outside `$HOME` before each run (S1).

## Not covered

- `RUSTC_WORKSPACE_WRAPPER` (clippy): not tested.
- Cross targets (the spike traced the host triple only), msvc `.pdb` and
  macOS `.dSYM` naming.
- `rustc-link-arg-cdylib` reaching dependents' cdylibs: source only.
- A differential test for `rustdoc --test` argv (the recorded commands were
  inspected; the value-sorted `-L` list was checked against source).
- Duplicate values within one directive kind: the comparison used distinct
  values; Cargo keeps duplicates in order (`Vec`s in `BuildOutput`).
