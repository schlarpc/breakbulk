# What breakbulk assumes about Cargo and rustc

Nov 7, 2026

breakbulk implements Cargo's documented formats (manifests, lockfiles, build-script directives, target auto-discovery) and observes everything else from Cargo. Some of what it observes, and some of what it does with the result, rests on behavior that Cargo and rustc do not document or promise. This page lists every such place: what breakbulk assumes, where the code is, where upstream establishes it, which releases it is known to hold for, which test fails if it changes, and what breaks if it does.

Use it when a new Cargo or rustc release lands, when a check fails after a toolchain bump, or before changing one of the listed places.

## How to read an entry

- **Assumption**: one sentence.
- **Where**: the breakbulk file and function that rely on it.
- **Upstream**: the source that establishes it. Cargo citations are to rust-lang/cargo at the commit each release reports: `0.100.0` is Cargo 1.99 (`5f94df478`), `3c747ea3e` is nightly 1.101 (2026-11-03); up to 1.97 the same files live under `src/cargo/core/compiler/`. Most come from [spike A](../spikes/A-trace-fidelity.md) and the code comments; the ones marked "checked for this page" were re-read in the source or re-run.
- **Holds for**: the releases it was observed or tested on. "The window" means Cargo and rustc 1.95, 1.97 and 1.99 (stable) and nightly 1.101, the releases the golden and differential checks run.
- **Pinned by**: tests that fail if the assumption changes. Flake checks (`nix flake check`, names as in `checks.<system>`) run real Cargo or rustc. Rust tests (`nix develop -c cargo test`, names as `module::tests::name`) check breakbulk's own copy of a rule against hand-written input; they do not run Cargo, so they pin the copy, not the assumption. An entry counts as pinned only when a flake check would fail.
- **If it changes**: what goes wrong, and whether anything fails loudly.

Status of the 78 entries: 72 pinned, 2 pinned for some rows only (L3, L4), 4 with no pinning test (S10, X1, X4, L5). Each of the six has an issue; see [Gaps](#gaps).

## Summary

| ID | Assumption | Pinned |
| --- | --- | --- |
| [T1](#t1-the-rustc-wrapper-calling-convention) | `RUSTC_WRAPPER` is started as `wrapper [workspace-wrapper] rustc ARGS` | yes |
| [T2](#t2-rustc--vv-goes-through-the-wrapper-once-per-fresh-build-directory) | `rustc -vV` goes through the wrapper once per fresh build directory | yes |
| [T3](#t3-the--vv-record-carries-cargos-own-environment) | The `-vV` record carries Cargo's own environment | yes |
| [T4](#t4-variables-cargo-gives-every-build-script-that-name-the-planner) | Variables Cargo gives every build script that name the planner | yes |
| [T5](#t5-env-semantics) | `[env]` semantics | yes |
| [T6](#t6-config-discovery-and-merging) | Config discovery and merging | yes, rest guarded |
| [T7](#t7-rustc-option-arity-and-output-names) | rustc option arity and output names | yes |
| [T8](#t8---printfile-names-names-every-link-output) | `--print=file-names` names every link output | yes |
| [T9](#t9-cargo-accepts-a-faked-compile) | Cargo accepts a faked compile | yes |
| [T10](#t10-build-script-compiles-and-the-stub) | Build-script compiles and the stub | yes |
| [T11](#t11-rustdoc-and-cargo-test---doc) | `RUSTDOC` and `cargo test --doc` | yes |
| [T12](#t12-verbosity-changes-argv) | Verbosity changes argv | yes |
| [T13](#t13-which-targets-each-command-builds) | Which targets each command builds | yes |
| [T14](#t14-the-clippy-chain) | The clippy chain | yes |
| [S1](#s1-sentinel-placement-and-shapes) | Sentinel placement and shapes | yes |
| [S2](#s2-sentinels-change-no-unit-identity) | Sentinels change no unit identity | yes |
| [S3](#s3-link-arg-kinds-cargo-accepts-per-package) | Link-arg kinds Cargo accepts per package | yes |
| [S4](#s4-search-path-order) | Search-path order | yes |
| [S5](#s5-link-arguments-are-one-list-per-run) | Link arguments are one list per run | yes |
| [S6](#s6-doctest-search-paths) | Doctest search paths | yes |
| [S7](#s7-dep_-metadata) | `DEP_*` metadata | yes |
| [S8](#s8-links-overrides) | `links` overrides | yes |
| [S9](#s9-directive-values) | Directive values | yes |
| [S10](#s10-directive-errors-and-warnings) | Directive errors and warnings | **no** (#33) |
| [S11](#s11-dynamic-library-paths) | Dynamic-library paths | yes |
| [S12](#s12-cargo-appends-its-own-dynamic-library-path) | Cargo appends its own dynamic-library path | yes |
| [U1](#u1-the-classic-build-directory-layout) | The classic build-directory layout | yes |
| [U2](#u2-the-new-build-directory-layout) | The new build-directory layout | yes |
| [U3](#u3-platform-from-the-output-location) | Platform from the output location | yes |
| [U4](#u4--c-metadata-identifies-a-compile-within-a-plan) | `-C metadata` identifies a compile within a plan | yes |
| [U5](#u5-what-goes-into-a-units-identity) | What goes into a unit's identity | yes |
| [U6](#u6-arguments-that-name-cargos-directories) | Arguments that name Cargo's directories | yes |
| [U7](#u7-path-crates-inside-and-outside-the-workspace-root) | Path crates inside and outside the workspace root | yes |
| [U8](#u8-uplifted-bins) | Uplifted bins | yes |
| [U9](#u9--zembed-metadatano-on-nightly) | `-Zembed-metadata=no` on nightly | yes |
| [U10](#u10-cargo_target_tmpdir) | `CARGO_TARGET_TMPDIR` | yes |
| [C1](#c1-one-rustflags-source) | One rustflags source | yes |
| [C2](#c2-cfg-rounds) | cfg rounds | yes |
| [C3](#c3---target-host-keeps-rustflags-off-host-units) | `--target <host>` keeps rustflags off host units | yes |
| [C4](#c4-linkers-on-every-unit-and-on-same-triple-host-units) | Linkers on every unit, and on same-triple host units | yes |
| [C5](#c5-cargos-environment-configuration-for-the-dev-shell) | Cargo's environment configuration for the dev shell | yes |
| [P1](#p1-trim-paths-availability-and-default) | trim-paths availability and default | yes |
| [P2](#p2-trim-paths-detection-and-remap-forms) | trim-paths detection and remap forms | yes |
| [P3](#p3-trim-paths-hashes-outside-path-crates-without-their-path) | trim-paths hashes outside path crates without their path | yes |
| [P4](#p4-a---config-profile-setting-replaces-the-projects) | A `--config` profile setting replaces the project's | yes |
| [P5](#p5-trim-paths-reaches-build-scripts-and-cc-rs) | trim-paths reaches build scripts and cc-rs | yes |
| [P6](#p6---remap-path-scope) | `--remap-path-scope` | yes |
| [P7](#p7-rustc-maps-standard-library-paths-to-rust-src) | rustc maps standard-library paths to rust-src | yes |
| [X1](#x1-rustcs-json-diagnostics) | rustc's JSON diagnostics | **no** (#34) |
| [X2](#x2-which-debuginfo-side-files-a-link-writes) | Which debuginfo side files a link writes | yes |
| [X3](#x3-names-of-uplifted-side-files) | Names of uplifted side files | yes |
| [X4](#x4-rustcs-link-temp-directory) | rustc's link temp directory | **no** (#35) |
| [X5](#x5-sysroot-layout) | Sysroot layout | yes |
| [R1](#r1-test-process-environment) | Test-process environment | yes |
| [R2](#r2-cargo_bin_exe_-for-bins-cargo-did-not-build) | `CARGO_BIN_EXE_*` for bins Cargo did not build | yes |
| [R3](#r3-the-doctest-command-line) | The doctest command line | yes |
| [L1](#l1-rustcs-self-contained-lld-arguments) | rustc's self-contained lld arguments | yes |
| [L2](#l2-wasm32-wasip2-linking) | `wasm32-wasip2` linking | yes |
| [L3](#l3-the-rust-to-wasi-sdk-table) | The Rust-to-wasi-sdk table | partly (#36) |
| [L4](#l4-the-rust-to-llvm-table-and-rustc--vv) | The Rust-to-LLVM table and `rustc -vV` | partly (#37) |
| [L5](#l5-cross-language-lto) | Cross-language LTO | **no** (#10) |
| [L6](#l6-musl-links-rusts-self-contained-crt) | musl links Rust's self-contained crt | yes |
| [L7](#l7-crt-static-glibc-is-static-pie) | `+crt-static` glibc is static-pie | yes |
| [L8](#l8-windows-gnu-link-specs) | windows-gnu link specs | yes |
| [L9](#l9-wasm32-default-target-features) | wasm32 default target features | yes |
| [L10](#l10-toolchain-capabilities-from-versions-and-probes) | Toolchain capabilities from versions and probes | yes |
| [G1](#g1-target-trait-base-fields-are-rustcs-cfg) | Target-trait base fields are rustc's cfg | yes |
| [G2](#g2-file-name-traits-are-rustcs-target-spec) | File-name traits are rustc's target spec | yes |
| [G3](#g3-the-dynamic-library-variable-per-os) | The dynamic-library variable per OS | yes (Linux) |
| [F1](#f1-cargolock-layout) | `Cargo.lock` layout | yes |
| [F2](#f2-package-id-spelling) | Package id spelling | yes |
| [F3](#f3-directory-sources-and-source-replacement) | Directory sources and source replacement | yes |
| [F4](#f4-workspace-inheritance-in-vendored-git-crates) | Workspace inheritance in vendored git crates | yes |
| [F5](#f5-the-skeleton-is-enough-for-cargo) | The skeleton is enough for Cargo | yes |
| [F6](#f6-root-prediction) | Root prediction | yes |
| [F7](#f7-build-std) | build-std | yes |
| [E1](#e1-pkg-config-rs-and-pkg_config_all_static) | pkg-config-rs and `PKG_CONFIG_ALL_STATIC` | yes |
| [E2](#e2-cc-rs-passes---targetrust-triple) | cc-rs passes `--target=<Rust triple>` | yes |

## Tracing: how Cargo runs the shim

### T1. The rustc wrapper calling convention

- **Assumption.** Cargo starts `RUSTC_WRAPPER` as `wrapper [workspace-wrapper] rustc ARGS`, and rustc's own arguments always start with an option (`--crate-name`, `-vV`, `-`, `--print…`).
- **Where.** `crates/breakbulk-shim/src/main.rs`: `split_chain`, `wrapper_mode`.
- **Upstream.** cargo `src/util/rustc.rs`, `Rustc::new` and `process` (`ProcessBuilder::wrapped`, wrapper outermost); spike A.
- **Holds for.** The window.
- **Pinned by.** Every plan check, e.g. `plan-walking-skeleton`, `plan-walking-skeleton-golden-1_95`, `plan-walking-skeleton-nightly`; the workspace-wrapper chain by `products-variants` and `products-variants-clippy-strict`. Rust: `tests::chain` (shim).
- **If it changes.** The shim takes a rustc argument for a program, or the other way round; tracing fails at the first compile.

### T2. `rustc -vV` goes through the wrapper once per fresh build directory

- **Assumption.** In a build directory without Cargo's rustc-info cache, the first `cargo build`/`test`/`bench` runs `rustc -vV` through `RUSTC_WRAPPER`; `cargo metadata`, which the planner runs first with the same config, also asks, but cannot write the cache because the build directory does not exist yet.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `Builder::new` (takes the env baseline from that record; fails with "the trace has no `rustc -vV` query record"); `trace.rs`: `run` (metadata, then the build, in a fresh scratch directory).
- **Upstream.** cargo `0.100.0` `src/util/rustc.rs`: `Rustc::new` runs `-vV` through `cache.cached_output` on the wrapped command; `Cache` reads and writes `<build-dir>/.rustc_info.json` (`src/context/mod.rs`, `load_global_rustc`) and silently drops a failed write. Checked for this page with Cargo 1.99: `cargo metadata` sent `-vV` through the wrapper and left no build directory; the following `cargo build` sent `-vV` again; a second `cargo build` in the same directory sent none.
- **Holds for.** Checked on 1.99; every plan check exercises the window.
- **Pinned by.** Every plan check (planning fails without the record), e.g. `plan-walking-skeleton`, `differential-nightly`.
- **If it changes.** If `cargo metadata` started creating the build directory, or the cache moved out of it, the build would hit the cache and planning would fail loudly. The test plan's second invocation (`cargo test --doc`) already hits the cache and records no `-vV`; the baseline comes from the first. Setting `CARGO_CACHE_RUSTC_INFO=0` for traced Cargo would remove this assumption.

### T3. The `-vV` record carries Cargo's own environment

- **Assumption.** The environment of the `rustc -vV` query is Cargo's own process environment, plus the project's `[env]` and `CARGO`, and nothing per process; Cargo's own environment holds variables it set on itself at startup (`SSL_CERT_FILE`, `SSL_CERT_DIR`; `CARGO` from 1.97), which are machine-specific and must be subtracted. Cargo sets `CARGO` to its executable with symlinks resolved.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `Builder::new` (baseline), `filter_env`, `ALWAYS_KEPT_ENV`, `rewrite_env` (`CARGO`, `same_file`).
- **Upstream.** cargo `0.100.0` `src/util/rustc.rs`, `Rustc::new`: `apply_env_config(gctx, &mut cmd)` then `cmd.env(CARGO_ENV, gctx.cargo_exe())` before `-vV` (checked for this page); spike A, surprise S6 (openssl-probe).
- **Holds for.** The window.
- **Pinned by.** `differential`, `differential-1_95`, `differential-1_97`, `differential-nightly` (env compared per unit with `-vv`); `plan-walking-skeleton-golden-1_95` and the other rust-overlay goldens (a symlink-tree toolchain, so `CARGO` resolves elsewhere).
- **If it changes.** A machine-specific path kept in a plan fails validation (not a store path); a Cargo-set variable dropped by mistake shows as an env difference in the differential checks.

### T4. Variables Cargo gives every build script that name the planner

- **Assumption.** Cargo passes `RUSTC_WRAPPER` (when set), `RUSTDOC` as configured, `CARGO_MAKEFLAGS` and, in the clippy variant, `RUSTC_WORKSPACE_WRAPPER` to build-script runs, and `NUM_JOBS` with the planning machine's job count; nothing else names the shim or the planner.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `DROPPED_ENV`, `filter_env` (drops them, rewrites `RUSTDOC` to the real rustdoc, sets `NUM_JOBS=1` for `breakbulk-unit` to replace).
- **Upstream.** cargo `src/compiler/custom_build.rs`, `build_work`; spike A, surprise S7.
- **Holds for.** The window.
- **Pinned by.** `differential*` (each run's env against `cargo -vv`); `products-variants` (clippy).
- **If it changes.** A new variable naming the shim lands in a plan as an undeclared store path and validation fails loudly; a dropped one is harmless.

### T5. `[env]` semantics

- **Assumption.** Cargo applies the project's `[env]` to every process it starts, the `rustc -vV` query included, never over a variable Cargo set itself, and over its own inherited environment only with `force`; `relative` values are resolved before they reach a process.
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `ProjectConfig::load` (`[env]` names and `force`), `ProjectConfig::applied_env`; `graph.rs`: `filter_env` (`config_env`); `lib/test-runs.nix` (order: `[env]` below Cargo's own variables).
- **Upstream.** cargo `0.100.0` `src/compiler/mod.rs`, `apply_env_config` ("never override a value that has already been set by cargo"; checked for this page); `GlobalContext::env_config`; the Cargo book's `[env]` section.
- **Holds for.** 1.99 (nixpkgs).
- **Pinned by.** `loose-ends-config-env` (a plain value, `relative`, a forced `HOME`, an unforced `PATH`; test lines compared with plain `cargo test`). Rust: `spec::tests::env_table`.
- **If it changes.** `[env]` variables are lost from units or test runs, or the wrong value wins; `loose-ends-config-env` fails.

### T6. Config discovery and merging

- **Assumption.** Cargo reads `.cargo/config.toml` (or `.cargo/config`, which wins when both exist) in every ancestor of its working directory and in `$CARGO_HOME`, whatever `CARGO_HOME` says about the others; `include`s merge before the including file; deeper files win; arrays concatenate lower-precedence first and a string replaces a string; `--config` beats every file, and an inline `--config` value holds one dotted key while a file may hold many.
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `ProjectConfig::read`, `load`, `merge_rustflags`; `trim_paths.rs`: `files`; `trace.rs`: `run` (the generated `--config` file); `lib/skeleton.nix` (copies every ancestor's config); `lib/vendor.nix` (vendor config as a file, `toml_dotted_keys`).
- **Upstream.** cargo `src/context/mod.rs`: `walk_tree`, `load_includes`, `ConfigValue::merge`; spike A, surprise S1 (ancestors, `$HOME`).
- **Holds for.** The window (single-file configs); `include` and the `config`-over-`config.toml` rule only by reading the source.
- **Pinned by.** Every plan check (the `--config` file sets rustc, wrapper, rustdoc and directories); `same-triple-build` and `loose-ends-cfg-rustflags` (project rustflags merged with the spec's). Rust: `spec::tests::config_file`, `spec::tests::key_choice`. The rest is guarded at plan time: `Prepared::apply` checks that the project's and the spec's flags reached every target unit.
- **If it changes.** The planner puts spec rustflags under the wrong key; planning fails naming the flags that did not arrive.

### T7. rustc option arity and output names

- **Assumption.** The rustc options Cargo passes that take a separate value are those in the shim's list; outputs go to `--out-dir` (or `-o`'s directory) as `lib<crate><extra-filename>.rmeta` and `<crate><extra-filename>.d`.
- **Where.** `crates/breakbulk-shim/src/args.rs`: `TAKES_VALUE`, `RustcArgs::parse`, `stem`; `compile.rs`: `outputs`; `crates/breakbulk-plan/src/graph.rs`: `input_file`.
- **Upstream.** `rustc --help`, `rustc -C help`; spike A.
- **Holds for.** The window.
- **Pinned by.** Every plan check; `plan-crate-types`. Rust: `args::tests::*`, `compile::tests::lib_pipelined_outputs` (shim).
- **If it changes.** A new value-taking option is mistaken for the input file: the stub is not installed or roots are not found, and planning fails.

### T8. `--print=file-names` names every link output

- **Assumption.** rustc given the full compile arguments plus `--print=file-names` prints every link output for every crate type, `--emit` set and `--test`, stops without compiling, and does not resolve `--extern` paths; it does not name debuginfo side files (X2).
- **Where.** `crates/breakbulk-shim/src/compile.rs`: `file_names`, `outputs`, `run`.
- **Upstream.** Spike A: 154 cases per toolchain (10 crate-type sets, 7 `--emit` sets, `--test`, with and without `-C extra-filename`) matched real rustc's files and notifications.
- **Holds for.** The window.
- **Pinned by.** Every plan check; `plan-crate-types` (`cdylib`, `staticlib`, `rlib`, proc macro); `target-traits-rustc` (names per crate type for 248 targets).
- **If it changes.** A missing name means a missing output: Cargo or a dependent unit fails to find the file.

### T9. Cargo accepts a faked compile

- **Assumption.** Cargo accepts empty output files and a one-line dep-info (`<output>: <input>`), which it parses after every compile; with `--json=…artifacts…` and `metadata` in `--emit`, it waits for (but does not require) one `{"$message_type":"artifact","artifact":<path>,"emit":<kind>}` line per output on stderr before starting pipelined dependents.
- **Where.** `crates/breakbulk-shim/src/compile.rs`: `dep_info`, `artifact_notification`, `run`.
- **Upstream.** cargo `src/compiler/job_queue/job_state.rs`, `JobState::run_to_finish` (metadata counts as produced when the job ends); spike A (pipelining, `links` overrides, split debuginfo).
- **Holds for.** The window.
- **Pinned by.** Every plan check.
- **If it changes.** Cargo rejects the trace; planning fails loudly.

### T10. Build-script compiles and the stub

- **Assumption.** A build-script compile has crate name `build_script_*` and crate type `bin`; Cargo runs that binary from its compile's output directory (classic layout: a hard link beside it; new layout: `…/out/build_script_build`) with `OUT_DIR` naming the run's hash, and gives it `CARGO_MANIFEST_DIR`, `CARGO_MANIFEST_LINKS` and `CARGO_PKG_RUST_VERSION`.
- **Where.** `crates/breakbulk-shim/src/compile.rs`: `is_build_script`; `stub.rs`: `install`, `detect` (marker beside the executable), `run_tag`, `run`.
- **Upstream.** Spike A ("The shim", surprise S5 for the new layout).
- **Holds for.** The window.
- **Pinned by.** `plan-walking-skeleton`, `plan-walking-skeleton-nightly`, `plan-directives*`. Rust: `stub::tests::tags`.
- **If it changes.** The stub does not recognize itself or finds no run tag; tracing fails.

### T11. `RUSTDOC` and `cargo test --doc`

- **Assumption.** Cargo starts `RUSTDOC` with the environment it gives `RUSTC_WRAPPER`; under `cargo test --doc` it asks rustdoc for one `rustdoc --test` per doctestable library (proc macros included) and runs nothing else when that rustdoc exits 0 without output; it fails `--doc` when no library is selected; with a runner configured it adds `--test-runtool`, so the planner configures none.
- **Where.** `crates/breakbulk-shim/src/main.rs`: `is_rustdoc_invocation`, `rustdoc_mode`; `crates/breakbulk-plan/src/trace.rs`: `run`, `has_doctests`.
- **Upstream.** Spike A (doctest row; surprise S8).
- **Holds for.** The window.
- **Pinned by.** `test-runs-doctests` (test lines equal plain `cargo test --doc`'s); `differential*` (each doctest's argv and env against `cargo test --doc -vv`).
- **If it changes.** Doctests go missing from the plan or tracing fails.

### T12. Verbosity changes argv

- **Assumption.** At the default verbosity and at `-v` Cargo passes the same argv; with `-vv` non-local crates get `--cap-lints warn` instead of `allow`, and only `-vv` prints per-process env.
- **Where.** `crates/breakbulk-plan/src/trace.rs` (no `-v`); `golden.rs` (real side at `-v`, or `-vv` for env on path crates only).
- **Upstream.** cargo `src/compiler/unit.rs`, `show_warnings`; `src/compiler/mod.rs`, `add_cap_lints`; `src/compiler/compilation.rs`, `rustc_process`; spike A, surprise S11.
- **Holds for.** The window.
- **Pinned by.** Every golden check (`plan-*-golden*`); `differential*`.
- **If it changes.** Goldens report argv differences.

### T13. Which targets each command builds

- **Assumption.** `cargo build` builds libraries and bins; `cargo test --no-run` builds libraries, lib and bin harnesses, integration tests and examples (as plain bins), bins only when the package has integration tests, and no benches; `cargo bench --no-run` builds lib and bin harnesses in bench mode and benches; an unharnessed test or bench is compiled as a plain bin; `CARGO_PRIMARY_PACKAGE=1` marks every compile of a selected member, its host copy included.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `Builder::roots`, `target_of`; `lib/roots.nix`: `roots`.
- **Upstream.** cargo `src/ops/cargo_compile/unit_generator.rs`, `UnitGenerator::filter_default_targets`, `new_units` (`0.100.0`); spike A.
- **Holds for.** The window (spike A); 1.99 (checks).
- **Pinned by.** `roots-plans` (predicted roots equal what real `cargo build`, `test --no-run` and `bench --no-run` compile); `products-benches`.
- **If it changes.** A root in the plan that was not predicted fails instantiation loudly; a predicted root Cargo stopped building becomes a "not built" stub.

### T14. The clippy chain

- **Assumption.** With `RUSTC_WORKSPACE_WRAPPER=clippy-driver`, Cargo starts `wrapper clippy-driver rustc …` for workspace members only, and passes `CLIPPY_ARGS` (each argument followed by `__CLIPPY_HACKERY__`) to every process.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `run`; `graph.rs`: `compile_unit` (keeps `CLIPPY_ARGS` on clippy-driver units only).
- **Upstream.** cargo `src/util/rustc.rs` (workspace wrapper for members); `cargo clippy`'s driver protocol.
- **Holds for.** 1.99.
- **Pinned by.** `products-variants` (dependencies shared between check and clippy, members not); `products-variants-clippy-strict` (a lint argument fails the member).
- **If it changes.** Clippy units lose their arguments or dependencies stop being shared; both checks fail.

## Sentinels and the placement of build-script output

### S1. Sentinel placement and shapes

- **Assumption.** Cargo places each sentinel directive where it would place that kind of real output, in the shapes and on the units listed in the sentinel table ("Sentinel directives" in [implementation.md](../implementation.md#sentinel-directives)): `rustc-cfg`, `rustc-check-cfg` and `rustc-env` on every compile of the package and its `rustdoc --test`; `rustc-link-lib` on the lib (or the other targets when there is no lib); search paths on the package and its same-platform dependents; each `rustc-link-arg*` kind on its targets.
- **Where.** `crates/breakbulk-shim/src/stub.rs`: `sentinels`, `line`; `crates/breakbulk-plan/src/sentinel.rs`: `parse_pair`, `env_sentinel`, `dep_sentinel`, `dylib_sentinel`; `graph.rs`: `convert_args`, `convert_env`; `crates/breakbulk-unit/src/splice.rs`: `wrap`.
- **Upstream.** cargo `src/compiler/mod.rs`: `add_native_deps`, `add_custom_flags`, `pass_l_flag`; `src/compiler/custom_build.rs`: `BuildOutput::parse`; spike A, wrapping table.
- **Holds for.** The window (identical on all four).
- **Pinned by.** `plan-directives-golden`, `plan-directives-golden-test`, `plan-directives-golden-1_95`, `-1_95-test`, `-1_97`, `-1_97-test`, `-nightly`, `-nightly-test`; `differential`, `differential-1_95`, `differential-1_97`, `differential-nightly`. Rust: `sentinel::tests::shapes`, `splice::tests::wrapping_table`.
- **If it changes.** A sentinel in an unexpected shape fails the plan, naming the Cargo version, kind and arguments; a changed reach shows as an argv difference in the goldens.

### S2. Sentinels change no unit identity

- **Assumption.** Printing sentinels instead of real values leaves every compile's `-C metadata` and every run's `OUT_DIR` hash unchanged.
- **Where.** `crates/breakbulk-plan/src/graph.rs` (unit keys are those hashes).
- **Upstream.** Spike A (32 of 32 builds).
- **Holds for.** The window.
- **Pinned by.** `differential*` (units matched by `-C metadata` and run hash, so equal unit sets show it).
- **If it changes.** Plan units would not match real Cargo's; the differential checks fail.

### S3. Link-arg kinds Cargo accepts per package

- **Assumption.** Cargo rejects `rustc-link-arg-bins`, `-bin=NAME`, `-tests`, `-examples` and `-benches` when the package has no such target; it accepts `rustc-link-arg-cdylib` without a cdylib (with a warning) and passes it to the cdylibs of dependent packages; `rustc-link-arg` reaches every compile of the package, rlibs, lib test harness, proc macros and `rustdoc --test` included.
- **Where.** `crates/breakbulk-shim/src/stub.rs`: `sentinels`; `crates/breakbulk-unit/src/directives.rs`: `parse`.
- **Upstream.** cargo `0.100.0` `src/compiler/custom_build.rs`, `BuildOutput::parse`; `src/compiler/mod.rs`, `add_native_deps` (rust-lang/cargo#9562).
- **Holds for.** The window.
- **Pinned by.** `differential*` (random cdylibs and link args). Rust: `directives::tests::link_arg_target_validation`, `directives::tests::cdylib_link_arg_both_spellings_and_warning`, `stub::tests::sentinel_set`.
- **If it changes.** A stub sentinel Cargo rejects fails tracing loudly; a reach change shows in the differential checks.

### S4. Search-path order

- **Assumption.** For one compile, Cargo collects every linked run's search paths in dependency order, then stable-sorts them: paths inside the printing run's own `OUT_DIR` first, all others after; search paths from `links` overrides always count as outside.
- **Where.** `crates/breakbulk-shim/src/stub.rs` (two sentinels per run); `crates/breakbulk-unit/src/directives.rs`: `LibraryPath::new`, `is_inside`; `splice.rs`: search-path expansion.
- **Upstream.** cargo `src/compiler/mod.rs`, `add_native_deps`; `src/compiler/custom_build.rs`, `LibraryPath::new`; `src/context/target.rs`, `parse_links_overrides` (`0.100.0`; checked for this page); spike A, surprise S2.
- **Holds for.** The window.
- **Pinned by.** `differential*`, with a negative control (no ordering by class) that must find differences; `plan-directives-golden*`. Rust: `splice::tests::link_search_expands_each_class_where_cargo_put_it`, `directives::tests::link_search_classification`.
- **If it changes.** `-L` order differs from Cargo's, which can change which library links; the differential checks fail.

### S5. Link arguments are one list per run

- **Assumption.** All `rustc-link-arg*` kinds of one run share one list in printed order, and a unit gets the ones whose kind applies to it, adjacent.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `convert_args` (one splice per run, `kinds`); `crates/breakbulk-unit/src/splice.rs`.
- **Upstream.** cargo `src/compiler/custom_build.rs`, `BuildOutput::linker_args`; spike A, surprise S3.
- **Holds for.** The window.
- **Pinned by.** `differential*`; `plan-directives-golden*`. Rust: `splice::tests::link_args_keep_printed_order_across_kinds`.
- **If it changes.** Link arguments are reordered, or the planner fails on non-adjacent sentinels.

### S6. Doctest search paths

- **Assumption.** `rustdoc --test` gets one `-L` per entry of a set of every run's search paths in the invocation (both platforms, both classes) and every `links` override's, sorted by path component and without duplicates, and no `-l`.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `doctest_native_block`, `convert_args` (`searchPathsOf`); `crates/breakbulk-unit/src/doctest.rs`: `search_paths`.
- **Upstream.** cargo `src/ops/cargo_test.rs`, `run_doc_tests`; `Compilation::native_dirs`, a `BTreeSet<PathBuf>`; spike A, surprise S8.
- **Holds for.** The window.
- **Pinned by.** `differential*` (doctest argv rebuilt with `breakbulk-unit`'s code and compared). Rust: `doctest::tests::search_paths_sort_by_component_and_dedup`.
- **If it changes.** Doctest `-L` lists differ from Cargo's; the differential checks fail.

### S7. `DEP_*` metadata

- **Assumption.** A run's `metadata` reaches only the runs of packages that depend on its package directly as a normal dependency, as `DEP_<LINKS>_<KEY>` with the key uppercased and `-` mapped to `_`.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `run_unit` (`metadataFrom`); `crates/breakbulk-unit/src/directives.rs`: `envify`, `metadata_env`.
- **Upstream.** cargo `src/compiler/custom_build.rs`, `build_work`; `src/compiler/mod.rs`, `envify`; spike A.
- **Holds for.** The window.
- **Pinned by.** `differential*`; `plan-directives` (a `links` chain). Rust: `directives::tests::envify_and_metadata_env`.
- **If it changes.** A dependent's build script reads the wrong or no metadata.

### S8. `links` overrides

- **Assumption.** For a `[target.<triple>.<links>]` override in config, Cargo compiles and runs no build script, passes the override's flags itself, gives dependents its `DEP_*` values, and still sets `OUT_DIR` on the package's compiles to a directory that does not exist (classic layout) or is empty (new layout).
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `rewrite_env` (`OVERRIDDEN_OUT_DIR`), `convert_args` (override `-L` literals in doctests).
- **Upstream.** cargo `0.100.0` `src/compiler/custom_build.rs`, `prepare` (skips `build_work`, which creates `OUT_DIR`); `src/compiler/mod.rs`, `build_base_args`; spike A.
- **Holds for.** The window.
- **Pinned by.** `differential*` (`gen.py` sometimes overrides a `links` package).
- **If it changes.** An unexpected scratch path fails the plan; a changed placement shows in the differential checks.

### S9. Directive values

- **Assumption.** Cargo 1.99's handling of valid build-script output holds across the window: `rustc-flags` splits on whitespace into `-l` and `-L` and joins those lists in printed order; `rustc-env` splits on the first `=`; in `cargo:` syntax any unreserved key is metadata; duplicates stay in printed order; `cargo::` needs `rust-version` 1.77; values are not trimmed.
- **Where.** `crates/breakbulk-unit/src/directives.rs`: `parse`, `parse_rustc_flags`, `parse_rustc_env`, `RESERVED_PREFIXES`; `crates/breakbulk-shim/src/stub.rs`: `needs_old_syntax`.
- **Upstream.** cargo `0.100.0` `src/compiler/custom_build.rs`: `BuildOutput::parse`, `parse_rustc_flags`, `parse_rustc_env`, `check_minimum_supported_rust_version_for_new_syntax`.
- **Holds for.** The window.
- **Pinned by.** `differential*` (random values of every kind, duplicates, both syntaxes); `plan-directives` (`oldsyn`, `rust-version = "1.70"`). Rust: `directives::tests::*`.
- **If it changes.** Units get other values than Cargo would give them; the differential checks fail.

### S10. Directive errors and warnings

- **Assumption.** Cargo 1.99's error paths hold across the window: an unknown `cargo::` key is an error; `rustc-env=RUSTC_BOOTSTRAP=…` is an error (a warning only when nightly features are allowed and Cargo's own `RUSTC_BOOTSTRAP` permits it); `rustc-flags` with anything but `-l`/`-L` is an error; `rustc-link-arg-bin` naming no bin is an error; `cargo::error=` fails the run with Cargo's streaming rules.
- **Where.** `crates/breakbulk-unit/src/directives.rs`: `parse`, `streamed_log_messages`; `crates/breakbulk-plan/src/graph.rs`: `run_unit` (`nightly_features_allowed`, from the `nightly` capability).
- **Upstream.** cargo `0.100.0` `src/compiler/custom_build.rs`: `BuildOutput::parse`, the `exec_with_streaming` callback in `build_work`; rust-lang/cargo#7088.
- **Holds for.** 1.99 by reading the source.
- **Pinned by.** **Nothing.** Rust: `directives::tests::new_syntax_unknown_key_is_error`, `rustc_bootstrap`, `rustc_flags_splitting`, `link_arg_target_validation`, `streaming_errors_match_cargo`, `msrv_gate` check the copy only. Issue **#33**.
- **If it changes.** A unit fails where `cargo build` succeeds, or succeeds where it fails; nothing notices.

### S11. Dynamic-library paths

- **Assumption.** Cargo sets the build machine's dynamic-library variable: on a compile, the search paths of its host plugin dependencies' runs (proc macros, build dependencies with build scripts), appended after the inherited value; on a run, those of its build dependencies' runs; on a test process, those of every run of the test's platform; on `rustdoc --test`, those of every host run, sorted, before the inherited value; build scripts also get the sysroot's library directory. It keeps only paths lexically inside the platform's artifact directory; breakbulk keeps paths inside the printing run's `out` or a `DEP_*` upstream's `out` instead.
- **Where.** `crates/breakbulk-unit/src/directives.rs`: `LibraryPath::for_dylib_path`; `splice.rs`: `expand_dylib_path`, `prepend_dylib_path`; `crates/breakbulk-plan/src/graph.rs`: `dylib_path`; `lib/test-runs.nix`: `dylibJq`; `lib/workspace.nix`: `unitTools` (`rustc-sysroot`).
- **Upstream.** cargo `0.100.0` `src/compiler/mod.rs`: `add_plugin_deps`, `filter_dynamic_search_path`; `src/compiler/compilation.rs`: `fill_env`; [research-coverage-and-libpath.md](../spikes/research-coverage-and-libpath.md) section 2 (and a survey of 1207 crates for the substitute rule).
- **Holds for.** The window.
- **Pinned by.** `differential*` (env compared); `test-runs-dylib-rule`; `test-runs-test-control`; `test-runs-test-control-stable-dylibs`. Rust: `splice::tests::dylib_paths_append_like_add_plugin_deps`.
- **If it changes.** A proc macro, build script or test cannot load a library its build script built.

### S12. Cargo appends its own dynamic-library path

- **Assumption.** Cargo appends its own process's dynamic-library path to every value it sets (or uses it alone when it already starts with the paths), so a wrapped cargo (rust-overlay's exports `LD_LIBRARY_PATH` for libsecret) puts the planner's environment into recorded processes.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `dylib_path` (drops the inherited value).
- **Upstream.** cargo `0.97.0` `src/cargo/core/compiler/compilation.rs`, `fill_env` (`search_path.extend(paths::dylib_path())`); `src/cargo/core/compiler/mod.rs`, `add_plugin_deps`.
- **Holds for.** 1.96 by source, 1.99 by check.
- **Pinned by.** `plan-inherited-dylib-path`.
- **If it changes.** If Cargo stopped appending it, nothing breaks; if it put it elsewhere, the plan names a planner path and validation fails loudly.

## Build directory and unit identity

### U1. The classic build-directory layout

- **Assumption.** Up to 1.99, compile outputs go to `<target>/[<triple>/]<profile>/deps/`, each run to `build/<pkg>-<hash>/out`, and every compile gets one `-L dependency=<deps>`.
- **Where.** `crates/breakbulk-plan/src/rewrite.rs`: `Rewriter::path` (outputs are looked up from the shim's records, not parsed); `crates/breakbulk-shim/src/stub.rs`: `run_tag`; `crates/breakbulk-plan/src/golden.rs`.
- **Upstream.** cargo `src/compiler/layout.rs`, `src/compiler/build_runner/compilation_files.rs`; spike A.
- **Holds for.** 1.95, 1.97, 1.99.
- **Pinned by.** `plan-walking-skeleton-golden`, `plan-directives-golden`, `plan-*-golden-1_95`, `plan-*-golden-1_97`; `differential`, `differential-1_95`, `differential-1_97`.
- **If it changes.** A path that is no known output or `OUT_DIR` fails the plan loudly.

### U2. The new build-directory layout

- **Assumption.** Nightly Cargo (1.101) uses a new layout by default (opt-out `__CARGO_TEMPORARY_BUILD_DIR_NEW_LAYOUT_OPT_OUT=1`): `build/<pkg>/<hash>/{out,fingerprint,run}`, compile outputs in the unit's `out`, no `deps/`, one `-L dependency=` per dependency, build scripts at `…/out/build_script_build`, and no `-C extra-filename` for bins, dylibs, cdylibs and build scripts.
- **Where.** As U1; `golden.rs` (`-L dependency=` of unit directories).
- **Upstream.** cargo `3c747ea3e` `src/workspace/features.rs` (`build_dir_new_layout`), `src/compiler/build_runner/compilation_files.rs`; spike A, surprise S5.
- **Holds for.** Nightly 1.101 (2026-11).
- **Pinned by.** `plan-walking-skeleton-golden-nightly`, `-nightly-test`, `plan-directives-golden-nightly`, `-nightly-test`, `plan-walking-skeleton-nightly`, `plan-directives-nightly`, `differential-nightly`, `git-multi-workspace-golden-nightly`.
- **If it changes.** As U1. A third layout would fail loudly the same way.

### U3. Platform from the output location

- **Assumption.** With `--target` always given, host units write under `<target>/<profile>/` and target units under `<target>/<triple>/<profile>/`, in both layouts, also when host and target are the same triple.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `platform_of`; `rewrite.rs`: `Rewriter::path`.
- **Upstream.** cargo `src/compiler/build_runner/compilation_files.rs`; spike A ("Platform is read from the output location").
- **Holds for.** The window.
- **Pinned by.** `plan-build-dep-leak` (every splice of a target unit names a target run); `same-triple-eval`, `same-triple-build-script`.
- **If it changes.** Host and target settings mix; `plan-build-dep-leak` and the same-triple checks fail.

### U4. `-C metadata` identifies a compile within a plan

- **Assumption.** Cargo passes `-C metadata=<hash>` to every compile, unique within one invocation, derived from its stable unit identity; it leaves rustflags out (they go only into `-C extra-filename`), so two variants that differ only in rustflags share it.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `compile_rec` (fails without it), `Builder::new` (fails on duplicates); keys are per plan, and `explainSharing` compares argv and env, not hashes.
- **Upstream.** cargo `src/compiler/build_runner/compilation_files.rs`, `compute_metadata`; spike A, surprise S13.
- **Holds for.** The window.
- **Pinned by.** Every plan check (a missing or repeated key fails); `products-variants` (build and coverage share no target unit). Including rustflags in the hash would be harmless: keys are per plan already.
- **If it changes.** Planning fails loudly naming the compile.

### U5. What goes into a unit's identity

- **Assumption.** A profile's settings, not its name, go into `-C metadata` (`release`, `bench` and a profile that only inherits `release` give the same units); the incremental setting (`CARGO_INCREMENTAL`, `profile.*.incremental`) goes in, while the `-C incremental=<dir>` argument does not affect it.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `command` (clears the environment, so no `CARGO_INCREMENTAL`); `graph.rs`: `convert_args` (strips `-C incremental=`); `lib/devshell.nix` (warns about `CARGO_INCREMENTAL`).
- **Upstream.** cargo `0.100.0` `src/workspace/profiles.rs`, `Profile::comparable` (leaves out `name`; includes `incremental`; checked for this page); spike A, surprises S12 and D2.
- **Holds for.** The window.
- **Pinned by.** `products-variants` (every unit shared between `release` and a custom profile inheriting it); `products-benches`; `plan-walking-skeleton-golden` (dev profile: the real build's `-C incremental` is ignored and every `-C metadata` matches); `repository-devshell` (the warning). Cargo no longer hashing the incremental setting would be harmless.
- **If it changes.** Profiles stop sharing units, or the plan's `-C metadata` differs from a local build's; the checks above fail.

### U6. Arguments that name Cargo's directories

- **Assumption.** `--out-dir`, `-L dependency=` and `-C incremental=` are the only arguments that name Cargo's shared target directory; breakbulk drops them and passes its own.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `convert_args`; `crates/breakbulk-unit/src/compile.rs`: `check_args` (rejects them).
- **Upstream.** Spike A; the golden comparator strips the same set.
- **Holds for.** The window.
- **Pinned by.** Every golden check; plan validation (`invariant 3`: no literal may name the scratch directory). Rust: `compile::tests::rejects_target_directory_arguments`, `tests::invariant_3_forbidden_literals` (format).
- **If it changes.** Another argument naming the target directory fails validation loudly.

### U7. Path crates inside and outside the workspace root

- **Assumption.** Without trim-paths, Cargo hashes a path crate inside the workspace root by its relative path and one outside by its absolute path, and a selected member differs from the same crate as a dependency only by `CARGO_PRIMARY_PACKAGE`.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `check_location` (fixed skeleton location); `lib/plan.nix` (`/build/skeleton`).
- **Upstream.** cargo `src/workspace/source_id.rs`, `SourceId::stable_hash`; spike A.
- **Holds for.** The window.
- **Pinned by.** `repository-multi-ws-sharing`; `products-trim-paths` (stable 1.99 refuses to plan at another location).
- **If it changes.** Units stop being shared between workspaces; `repository-multi-ws-sharing` fails.

### U8. Uplifted bins

- **Assumption.** `CARGO_BIN_EXE_<name>` names the bin's uplifted copy, `<artifact dir>/<name>`, and only bins of the test's own package.
- **Where.** `crates/breakbulk-plan/src/rewrite.rs`: `uplifted_bins`, `Rewriter::path`; `graph.rs`: `register_uplifted_bins`.
- **Upstream.** cargo `0.100.0` `src/compiler/artifact.rs`, `get_env` (`bin_link_for_target`, `unit.pkg.manifest().targets()`).
- **Holds for.** 1.99.
- **Pinned by.** `test-runs-test-control-bin-exe`; `loose-ends-names` (two packages with a bin of the same name). Rust: `rewrite::tests::uplifted_bin_of_the_owners_package`.
- **If it changes.** The path is no unit's output and planning fails loudly.

### U9. `-Zembed-metadata=no` on nightly

- **Assumption.** When both Cargo and rustc are nightly, Cargo passes `-Zembed-metadata=no` to libraries that benefit, so their rlibs carry no metadata, and gives dependents both `--extern name=lib….rlib` and `--extern name=lib….rmeta`.
- **Where.** `crates/breakbulk-format/src/deps.rs`: `embeds_no_metadata`, `Graph::unit_deps` (linking units then take every `rmeta` below them).
- **Upstream.** cargo `src/compiler/build_context/target_info.rs`, `should_embed_metadata` ("Enable -Zembed-metadata=no by default if both cargo and rustc are nightly"; checked for this page in a 0.102 tree; stable `0.100.0` defaults to embedding); spike A, surprise S10.
- **Holds for.** Nightly 1.101.
- **Pinned by.** `plan-walking-skeleton-nightly`, `plan-directives-nightly` (products link against metadata-free rlibs). Rust: `tests::manifests_reach_what_crate_deps_lists` (format).
- **If it changes.** If Cargo did it on stable too, links fail with missing metadata unless the flag is detected, which it is by argv, not by version.

### U10. `CARGO_TARGET_TMPDIR`

- **Assumption.** `CARGO_TARGET_TMPDIR` is compile-time env of integration tests and benches only, naming a directory inside Cargo's target directory that must be writable when the test runs.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `TARGET_TMPDIR`, `rewrite_env`; `lib/test-runs.nix` (creates it).
- **Upstream.** The Cargo book (environment variables for crates); cargo `src/compiler/mod.rs`.
- **Holds for.** The window.
- **Pinned by.** `test-runs-test-control`. Portability of the fixed path: #21.
- **If it changes.** A test that writes there fails.

## Rustflags, linkers and config

### C1. One rustflags source

- **Assumption.** Cargo takes target rustflags from exactly one source, the first of `CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`, `target.<triple>` with every matching `target.'cfg(…)'`, and `build.rustflags`, and concatenates arrays only within one key.
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `RustflagsKey::choose`, `ProjectConfig::effective`, `config_text`, `Prepared::apply` (confirms in the trace).
- **Upstream.** cargo `src/compiler/build_context/target_info.rs`, `extra_args`; spike A, surprise S14.
- **Holds for.** The window.
- **Pinned by.** `same-triple-build` (a project `[build] rustflags` plus the spec's); `loose-ends-devshell`. Rust: `spec::tests::key_choice`.
- **If it changes.** The spec's or the project's flags go missing; `Prepared::apply` fails planning naming them.

### C2. cfg rounds

- **Assumption.** Cargo computes target rustflags without `cfg(…)` keys, asks `rustc --print=cfg` with those flags, adds the matching `cfg(…)` keys, and repeats once more if that changed the flags, keeping the last query's flags; it drops `proc_macro` from the answer.
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `ProjectConfig::effective`, `cfg_flags`, `target_cfg`, `CfgExpr` (see #30).
- **Upstream.** cargo `src/compiler/build_context/target_info.rs`, `TargetInfo::new`, `not_user_specific_cfg`.
- **Holds for.** 1.99.
- **Pinned by.** `loose-ends-cfg-rustflags` (a spec flag turning on a `target.'cfg(…)'` key; product equals local `cargo run`). Rust: `spec::tests::cfg_keys_see_the_rustflags`, `spec::tests::cfg_expressions`.
- **If it changes.** Spec flags land under a key Cargo then ignores; `Prepared::apply` fails planning.

### C3. `--target <host>` keeps rustflags off host units

- **Assumption.** With `--target` given, even the host triple, `[build]` and `[target.<host>]` rustflags reach target units only; build scripts, proc macros and host rlibs get none, and host runs get `CARGO_ENCODED_RUSTFLAGS=''`.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `selection_args` (always `--target`); the static and same-triple presets.
- **Upstream.** Spike A ("Does `--target <host>` keep rustflags off host units?").
- **Holds for.** The window.
- **Pinned by.** `same-triple-build-script`, `static-glibc-build-script`, `static-musl-x86_64-build-script` (build scripts stay dynamic); `plan-build-dep-leak`.
- **If it changes.** `+crt-static` reaches build scripts, which crash; the checks fail.

### C4. Linkers on every unit, and on same-triple host units

- **Assumption.** Cargo passes `-C linker=` to every compile, rlibs included; when host and target are the same triple, it gives host units (build scripts, proc macros, host rlibs) the target's linker and every run `RUSTC_LINKER=<target linker>` (`target-applies-to-host` defaults to true, and nightly's `-Zhost-config` still gives host rlibs the target linker).
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `Prepared::apply` (checks one `-C linker` per target unit, rewrites host units' and runs'), `linker_args`.
- **Upstream.** cargo `0.100.0` `src/compiler/mod.rs`, `add_codegen_linker` (target linker unless `for_host() && !target_applies_to_host`; checked for this page); `build_context/target_info.rs`, `RustcTargetData::new`; spike A, surprise S15.
- **Holds for.** The window.
- **Pinned by.** `same-triple-eval`, `same-triple-build`, `same-triple-build-script`, `same-triple-test`; `linux-portable-glibc` (host units keep the host linker, asserted on the plan).
- **If it changes.** `Prepared::apply` fails planning naming the unit.

### C5. Cargo's environment configuration for the dev shell

- **Assumption.** `CARGO_TARGET_<TRIPLE>_<KEY>` (triple uppercased, `-` and `.` as `_`), `CARGO_BUILD_RUSTFLAGS`, `CARGO_BUILD_TARGET` and `CARGO_PROFILE_<P>_TRIM_PATHS` act as the matching `--config` keys; an environment list is split on whitespace and appended after the config files' list for the same key.
- **Where.** `crates/breakbulk-plan/src/spec.rs`: `target_env_var`, `Prepared::cargo_env`; `lib.rs`: `cargo_env`, `trim_paths_var`.
- **Upstream.** cargo `src/context/mod.rs`, `GlobalContext::get_cv_with_env` ("Lists are always merged"), `ConfigKey::as_env_key`.
- **Holds for.** 1.99; nightly 1.101 for trim-paths.
- **Pinned by.** `loose-ends-devshell` (a local build in the shell gives the plan's `-C metadata` values); `loose-ends-devshell-trim-paths`. Rust: `spec::tests::cargo_env_for_the_dev_shell`.
- **If it changes.** Local builds in the dev shell stop matching the plan; the checks fail.

## trim-paths and path remapping

### P1. trim-paths availability and default

- **Assumption.** The `trim-paths` profile setting is stable from Cargo 1.101 (nightly 1.101 included) and a hard error before; its values are `none`, `object` and `all`, and its default is `none` for every profile, `release` included.
- **Where.** `lib/toolchain-facts.nix`: `capabilitySince.trimPaths`; `crates/breakbulk-plan/src/trim_paths.rs`: `decide`; `lib.rs`: `plan_with_cargo_env` (retraces without it when Cargo's error names `trim-paths`).
- **Upstream.** cargo `3c747ea3e` `src/workspace/features.rs` (`stable, trim_paths, "1.101"`), `Profile::default_release`; cargo `TomlTrimPaths`; spike A, "trim-paths".
- **Holds for.** 1.95–1.99 (rejected), nightly 1.101.
- **Pinned by.** `products-trim-paths`, `loose-ends-devshell-trim-paths` (nightly sets it, 1.99 does not); `target-traits` (`testToolchainCapabilities`). The retrace for a nightly from before stabilization is not tested; such nightlies are leaving the window.
- **If it changes.** A stable release gaining it earlier is harmless (breakbulk keeps its own remaps); a default other than `none` would be detected in the trace (P2).

### P2. trim-paths detection and remap forms

- **Assumption.** Under trim-paths Cargo passes `--remap-path-scope=<scope>` and `--remap-path-prefix` pairs for the package (`<workspace root>=.`, `<package root>=/cargo/deps/<name>-<version>`, a `$CARGO_HOME` git checkout `=/cargo/git/<id>/<rev>`, a registry source `=/cargo/registry/<id>`), the build directory (`<build-dir>=/cargo/build-dir`, which user rustflags never produce) and the sysroot (`<sysroot>/lib/rustlib/src/rust=/rustc/<commit>`); rustc uses one remap when several match, so breakbulk adds none of its own.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `has_cargo_trim_paths`, `trace_trims_paths`, `convert_args` (expands the build-directory pair per `OUT_DIR`), `build_dir_remaps`, `trim_paths`; `golden.rs` (git and registry forms equal to the vendored form).
- **Upstream.** cargo `3c747ea3e` `src/compiler/trim_paths.rs`: `trim_paths_args`, `package_remap`, `git_checkout`, `build_dir_remap`, `sysroot_remap`; spike A.
- **Holds for.** Nightly 1.101.
- **Pinned by.** `products-trim-paths`; `git-multi-workspace-golden-nightly`. Rust: `graph::trim_tests::cargo_trim_paths_detected`, `golden::tests::trim_paths_forms`.
- **If it changes.** A new form leaves a scratch path in a plan (validation fails) or a remap Cargo applies that breakbulk does not expand; `products-trim-paths` fails on source references.

### P3. trim-paths hashes outside path crates without their path

- **Assumption.** Under trim-paths a path crate outside the workspace root is hashed without its absolute path.
- **Where.** `crates/breakbulk-plan/src/lib.rs`: `plan_with_cargo_env` (no location check when the trace trims paths).
- **Upstream.** cargo `src/workspace/source_id.rs`, `SourceId::stable_hash` ("not hashed at all"; c82e769); `compute_metadata`.
- **Holds for.** Nightly 1.101.
- **Pinned by.** `products-trim-paths` (one `-C metadata` in both workspaces and at two other skeleton locations).
- **If it changes.** The skeleton location would matter again; the check fails.

### P4. A `--config` profile setting replaces the project's

- **Assumption.** `--config profile.<p>.trim-paths=…` overrides the manifest's and config files' setting, so breakbulk passes it only when the project mentions `trim-paths` nowhere under `[profile]`; a per-package override can turn it on for some packages only.
- **Where.** `crates/breakbulk-plan/src/trim_paths.rs`: `declared`, `in_table`, `decide`; `trace.rs`: `with_trim_paths`; `graph.rs`: `Builder::trim_paths` (fails on a mix).
- **Upstream.** Cargo's config precedence; spike A ("Setting it by default").
- **Holds for.** Nightly 1.101.
- **Pinned by.** `products-trim-paths` (a workspace that sets it keeps its scope); `products-trim-paths-cc` (one package only fails planning); `repository-devshell-trim-paths-files`. Rust: `trim_paths::tests::*`.
- **If it changes.** The project's own setting would be lost or ignored; the checks fail.

### P5. trim-paths reaches build scripts and cc-rs

- **Assumption.** Under trim-paths Cargo gives build-script runs `CARGO_TRIM_PATHS_SCOPE` (on 1.101 always, `none` when off) and `CARGO_TRIM_PATHS_REMAP`, the same pairs `:`-separated, the build-directory pair included; cc-rs from 1.3.0 turns each pair into `-fmacro-prefix-map` and, for `object` or `all`, `-fdebug-prefix-map`.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `run_unit`, `without_build_dir_remap`, `TRIM_PATHS_REMAP_VAR`; `crates/breakbulk-format/src/render.rs` (the run's C prefix maps in Cargo's names).
- **Upstream.** cargo `src/compiler/custom_build.rs`; cc-rs `src/lib.rs`, `add_trim_paths_flags` (PR #1794; checked in 1.11.1).
- **Holds for.** Nightly 1.101 with cc-rs 1.11.1.
- **Pinned by.** `products-trim-paths-cc` (a C file's `__FILE__` and debug info read `./cfile/c/where.c`). Rust: `tests::run_prefix_maps_follow_cargo_under_trim_paths` (format).
- **If it changes.** C objects name source views or differ from a local build; the check fails.

### P6. `--remap-path-scope`

- **Assumption.** rustc takes `--remap-path-scope` from 1.95, and with `macro,diagnostics` it remaps panic locations, `file!()` and diagnostics but keeps real paths in debug info; a rustc without the option rejects it while parsing options, before acting on `--print`.
- **Where.** `lib/toolchain-facts.nix`: `capabilitySince.remapPathScope`, `probe`; `crates/breakbulk-instantiate` (scope per product kind); `crates/breakbulk-unit/src/compile.rs`.
- **Upstream.** rustc_driver_impl `lib.rs`, `handle_options`; rustc_session `config.rs`, `parse_remap_path_scope`; checked on rust-overlay 1.94.0 (rejects), 1.95.0, 1.99.0, nightly 1.101 and nixpkgs 1.99.0 (accept).
- **Holds for.** 1.95 to nightly 1.101.
- **Pinned by.** `target-traits` (`testToolchainCapabilities`: the probe agrees with the version table on 1.94 and 1.95); `products-source-paths`, `products-source-paths-dwp`, `products-debug-info`. Rust: `tests::shipped_remap_scope` (instantiate).
- **If it changes.** Shipped binaries keep source paths or lose debugger paths; the products checks fail.

### P7. rustc maps standard-library paths to rust-src

- **Assumption.** When the toolchain ships `rust-src`, rustc names the standard library's files by the local copy's path (`<sysroot>/lib/rustlib/src/rust/…`) instead of `/rustc/<commit-hash>/…`, and `rustc -vV` names the commit (`commit-hash:`), so remapping that copy back to `/rustc/<hash>` restores Cargo's paths.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `rust_src_remap`; plan header `rustSrcRemap`.
- **Upstream.** cargo `0.97.0` `core/compiler/mod.rs`, `sysroot_remap`; in a 0.102 tree, `src/compiler/trim_paths.rs` (trim-paths adds the same remap, and `/rustc/<version>` when rustc names no commit, where breakbulk adds none; checked for this page).
- **Holds for.** 1.99.
- **Pinned by.** `products-rust-src` (the product references no toolchain path).
- **If it changes.** Every product references the toolchain; the check fails.

## Unit execution and outputs

### X1. rustc's JSON diagnostics

- **Assumption.** With `--error-format=json`, rustc writes one JSON object per stderr line, diagnostics carry their text in `rendered`, artifact notifications have `"$message_type":"artifact"`, and future-incompatibility reports have `future_incompat_report`.
- **Where.** `crates/breakbulk-unit/src/diag.rs`: `classify`.
- **Upstream.** rustc's JSON output format (rustc book, "JSON Output"); Cargo renders the same fields.
- **Holds for.** 1.99 by reading build logs.
- **Pinned by.** **Nothing.** Rust: `diag::tests::*` check hand-written lines only. Issue **#34**.
- **If it changes.** Build logs are raw JSON again; nothing fails.

### X2. Which debuginfo side files a link writes

- **Assumption.** On `*-windows-msvc` rustc passes `/DEBUG` to the linker for every linked crate whatever `-C debuginfo` and `-C strip` say, so a `.pdb` is always written; on ELF, with debuginfo on, `-C split-debuginfo=packed` writes one `.dwp` per linked output and `unpacked` one `.dwo` per object; the last `-C debuginfo` wins and `-g` means full; Cargo passes `-C split-debuginfo` only with `-C debuginfo`, and tolerates the side files' absence during the trace. (Apple's `.dSYM` is unverified; Darwin is not supported yet, #13.)
- **Where.** `crates/breakbulk-format/src/plan.rs`: `writes_debuginfo_side_files`, `DebugArtifactWhen`; `lib/target-traits.nix`: `debugArtifacts`; `crates/breakbulk-unit/src/compile.rs`: `DEBUG_SIDE_FILES`, `collect_outputs`.
- **Upstream.** rustc_codegen_ssa `back/linker.rs`, `MsvcLinker::debuginfo` (1.95 through master); rustc_session `config.rs`, `select_debuginfo`; cargo `src/compiler/mod.rs`, `build_base_args`; spike A, surprise S9.
- **Holds for.** 1.99 (msvc, ELF); the window for the trace.
- **Pinned by.** `debug-outputs`, `msvc-debug-outputs`, `msvc-x86_64-pdb`, `products-source-paths-dwp`. Rust: `tests::debuginfo_side_files`, `tests::debug_output_only_where_side_files` (format), `compile::tests::debug_side_files_go_to_debug` (unit).
- **If it changes.** A unit without a `debug` output discards side files with a warning, or one with it has an empty output; the checks fail.

### X3. Names of uplifted side files

- **Assumption.** Cargo uplifts a bin's `.dwp` as `<bin>.dwp`, while `.pdb` and `.dwo` keep rustc's names, which the binaries record.
- **Where.** `lib/products.nix`: `mkLinked` (`debug` output); `lib/stage-helpers/default.nix`: `splitDebug`, `install`.
- **Upstream.** cargo `src/compiler/build_runner/compilation_files.rs` (uplifting); rustc's link output names.
- **Holds for.** 1.99.
- **Pinned by.** `products-source-paths-dwp` (gdb finds the `.dwp`); `msvc-x86_64-pdb` (`llvm-symbolizer` with the `.pdb` beside the `.exe`).
- **If it changes.** Debuggers do not find the side files; the checks fail.

### X4. rustc's link temp directory

- **Assumption.** rustc links from a randomly named directory `<out-dir>/rustcXXXXXX` next to the output and passes files in it (`symbols.o`, extracted objects) by absolute path; a response file holds one argument per line, quoted when needed.
- **Where.** `lib/presets/lld-link-stable.sh` (copies those inputs to a fixed path so the PDB, and so the `.exe`, are reproducible); `lib/presets/linker.nix`: `lldLinkLinker`.
- **Upstream.** rustc 1.99.1 `compiler/rustc_codegen_ssa/src/back/link.rs` (`TempDirBuilder::new().prefix("rustc")`); [spikes/msvc.md](../spikes/msvc.md), "Determinism".
- **Holds for.** 1.99.1, checked by hand with `nix build --rebuild`.
- **Pinned by.** **Nothing.** No flake check rebuilds an msvc link. Issue **#35** (related: #2).
- **If it changes.** msvc `.exe` and `.pdb` are no longer reproducible; nothing fails.

### X5. Sysroot layout

- **Assumption.** `rustc --print sysroot` names a directory with `lib/rustlib/src/rust` (when `rust-src` is installed) and the target's shared libraries in `lib/rustlib/<target>/lib`.
- **Where.** `crates/breakbulk-plan/src/trace.rs`: `rust_src_remap`, `sysroot`; `crates/breakbulk-plan/src/build_std.rs`; `lib/test-runs.nix`: `testLibs`.
- **Upstream.** rustc's sysroot layout; rustup and rust-overlay components.
- **Holds for.** 1.99, nightly 1.101.
- **Pinned by.** `products-rust-src`, `loose-ends-test-libs`, `test-runs-test-control`, `build-std`.
- **If it changes.** Test runs miss `libstd-*.so` or products reference the toolchain; the checks fail.

## Tests and doctests at run time

### R1. Test-process environment

- **Assumption.** `cargo test` gives a test process, of its recorded compile-time env, only `CARGO`, `CARGO_MANIFEST_DIR`, `CARGO_MANIFEST_PATH`, `CARGO_PKG_*` and `CARGO_BIN_EXE_*`, plus the `rustc-env` values of its package's build script and the project's `[env]` below all of these, and runs it in the package directory.
- **Where.** `crates/breakbulk-instantiate/src/runtime-env.json`; `lib/test-runs.nix`: `isRuntimeVar`; `crates/breakbulk-instantiate/src/dynamic.rs`: `is_runtime_var`.
- **Upstream.** cargo `0.97.0` `ops/cargo_test.rs` (`unit_output` env from `artifact::get_env`), `core/compiler/compilation.rs`, `fill_env`; `script_metas`.
- **Holds for.** 1.96 by source, 1.99 by check.
- **Pinned by.** `test-runs-test-control` (runtime env, cwd, `rustc-env`); `loose-ends-config-env`; `test-runs-test-control-bin-exe`. Rust: `tests::dynamic::test_spec_of_a_test_root` (instantiate).
- **If it changes.** Tests that read a variable at run time fail, or pass in breakbulk and fail under `cargo test`.

### R2. `CARGO_BIN_EXE_*` for bins Cargo did not build

- **Assumption.** Cargo sets `CARGO_BIN_EXE_<bin>` on integration tests for every bin of the package, also one whose required features are off, pointing at a file that does not exist.
- **Where.** `crates/breakbulk-plan/src/graph.rs`: `rewrite_env`, `NOT_BUILT_BIN_DIR`.
- **Upstream.** cargo `0.100.0` `src/compiler/artifact.rs`, `get_env` (filters targets on `is_bin()` only; checked for this page).
- **Holds for.** 1.99.
- **Pinned by.** `plan-bin-exe-not-built`.
- **If it changes.** If Cargo stopped setting it, the planner keeps nothing (harmless); if it set it differently, planning fails on a path that names no unit.

### R3. The doctest command line

- **Assumption.** Cargo passes a runner to rustdoc as `--test-runtool R --test-runtool-arg A …` right after `--target T`, and libtest arguments as `--test-args A` after the `-L` list.
- **Where.** `crates/breakbulk-unit/src/doctest.rs`: invocation building (`RUNNER_VAR`, `TEST_ARGS_VAR`).
- **Upstream.** cargo `src/ops/cargo_test.rs`, `run_doc_tests`; spike A, surprise S8.
- **Holds for.** 1.99.
- **Pinned by.** `test-runs-runner` (a doctest runs through the runner); `test-runs-doctests`. Rust: `doctest::tests::invocation_places_runner_search_paths_and_test_args`.
- **If it changes.** rustdoc rejects the arguments or ignores the runner; the checks fail.

## Toolchains, linkers and targets

### L1. rustc's self-contained lld arguments

- **Assumption.** From about 1.90, rustc links `x86_64-unknown-linux-gnu` with its bundled `rust-lld` by passing exactly `-B<sysroot>/lib/rustlib/<host>/bin/gcc-ld` and `-fuse-ld=lld` to the C driver (also inside an `@file`), and the stable opt-out is a rustflag (`-C linker-features=-lld`) that cannot reach build scripts.
- **Where.** `lib/presets/linker.nix`: `driverWrapper` (drops both, for mold, clang-lld, mingw-lld and zig).
- **Upstream.** `rustc --print link-args`, checked with 1.95 and 1.99.
- **Holds for.** 1.95, 1.99.
- **Pinned by.** `static-glibc-product`, `static-glibc-build-script`, `same-triple-build-script`, `static-musl-x86_64-product` (every ELF's `.comment` names mold and not LLD).
- **If it changes.** Links bypass the Nix linker wrapper (no rpaths, no hardening); the checks fail.

### L2. `wasm32-wasip2` linking

- **Assumption.** rustc's `wasm32-wasip2` target spec names `wasm-component-ld`, rustc puts its own `lib/rustlib/<host>/bin` first on the linker's `PATH`, `-flavor wasm` comes first, and the target's `crt1-command.o` is only among the self-contained objects, so self-contained linking must stay on.
- **Where.** `lib/presets/linker.nix`: `componentLinker`; `lib/presets/wasip2.nix`.
- **Upstream.** rustc_codegen_ssa `back/linker.rs`, `get_linker`; rustc_target `targets/wasm32_wasip2.rs`, `crt_objects.rs`.
- **Holds for.** 1.99.
- **Pinned by.** `wasip2-linker`, `wasip2-run`, `wasip2-test-lib`, `wasip2-test-bin`, `wasip2-test-it`.
- **If it changes.** wasip2 links fail or produce modules without `_start`; the checks fail.

### L3. The Rust-to-wasi-sdk table

- **Assumption.** Each Rust release bundles, for `wasm32-wasip2`, the wasi-libc of one wasi-sdk release: 30 for 1.95–1.96, 33 for 1.97–1.99, 34 for 1.100–1.102.
- **Where.** `lib/wasi-sdk.nix`: `table`, `versionFor`, `sysrootFor`; `lib/toolchain-facts.nix`: `wasiSdkVersion`.
- **Upstream.** rust-lang/rust `src/ci/docker/host-x86_64/dist-various-2/Dockerfile` (`WASI_SDK_PATH`), `src/bootstrap/src/lib.rs` `wasi_libdir`; `e845ed8cc9c0` (wasi-sdk 34, 2026-08-25). Checked by hand: `libc.a` byte-identical for 1.95, 1.96, 1.97, 1.99, 1.100 beta, 1.101 nightly.
- **Holds for.** 1.95 to 1.101; 1.100 and 1.102 from beta and master.
- **Pinned by.** **Partly.** `wasip2-linker` (1.99 → 33, `libc.a` compared byte for byte); `presets-per-workspace` (1.96 → 30, the lookup only). Issue **#36**.
- **If it changes.** C code compiles against headers of another wasi-libc than the one linked; nothing fails.

### L4. The Rust-to-LLVM table and `rustc -vV`

- **Assumption.** Official Rust builds use LLVM 20 for 1.90, 21 for 1.91–1.94, 22 for 1.95–1.98 and 23 for 1.99–1.101 (nixpkgs' rustc names its own in `llvmPackages`); `rustc -vV` prints `release:`, `LLVM version:`, `host:` and `commit-hash:` lines.
- **Where.** `lib/llvm-versions.nix`: `table`, `lookup`, `verifiedThrough`; `lib/toolchain-facts.nix`: `probe`; `crates/breakbulk-plan/src/trace.rs`: `run` (host), `rust_src_remap` (commit).
- **Upstream.** `rustc -vV` of every rust-overlay stable 1.90.0–1.99.1 and nightly 1.101 at the pinned rust-overlay.
- **Holds for.** 1.90 to nightly 1.101.
- **Pinned by.** **Partly.** `target-traits` (`testToolchainFacts`: 1.97's row equals the probe of the same toolchain); every plan check (`host:`). Issue **#37**.
- **If it changes.** Presets use LLVM tools of another major than rustc's; for LTO and wasm the linker may not read rustc's output.

### L5. Cross-language LTO

- **Assumption.** With `-C linker-plugin-lto`, rustc emits LLVM bitcode that clang with `lld` from the LLVM release matching rustc's links, together with C code compiled to bitcode.
- **Where.** `lib/presets/linker.nix`: `linkerKind` (`clang-lld`), `lldLinker`; `lib/presets/default.nix`: `linuxGnuWith` (`crossLanguageLto`).
- **Upstream.** The rustc book, "Linker-plugin-based LTO".
- **Holds for.** Not tested.
- **Pinned by.** **Nothing.** Existing issue **#10** (its exit criteria are a building fixture).
- **If it changes.** The preset fails to link, or links without LTO.

### L6. musl links Rust's self-contained crt

- **Assumption.** For `-musl` targets rustc links crt objects, `libc.a` and `libunwind.a` from its self-contained directory by default, and `-C link-self-contained=no` fails with nixpkgs' musl, which has no `libunwind.a`.
- **Where.** `lib/presets/default.nix`: `impl.linuxMusl`.
- **Upstream.** rustc_target `spec/base/linux_musl.rs` (self-contained linking inferred for musl); observed with the preset (field names not re-read for this page).
- **Holds for.** 1.99.
- **Pinned by.** `static-musl-x86_64-product`, `static-musl-x86_64-run`, `static-musl-x86_64-test`, `static-musl-aarch64-product`, `static-musl-aarch64-test`, `static-pkgconfig-musl-run`.
- **If it changes.** musl products fail to link or are not static; the checks fail.

### L7. `+crt-static` glibc is static-pie

- **Assumption.** On a `-gnu` target, `-C target-feature=+crt-static` with rustc's default relocation model (pic) links a static-pie executable.
- **Where.** `lib/presets/default.nix`: `impl.staticGlibc` (`relocationModel`).
- **Upstream.** rustc_target's linux-gnu specs (static-pie support); observed with the preset and mold 3.0.0 (field names not re-read for this page).
- **Holds for.** 1.99.
- **Pinned by.** `static-glibc-product` (no `INTERP`, no `NEEDED`), `static-glibc-run`, `static-glibc-test`.
- **If it changes.** Products are dynamic or crash at start; the checks fail.

### L8. windows-gnu link specs

- **Assumption.** rustc's windows-gnu specs link through a gcc-style driver with `-lmsvcrt`, ask for `-l:libpthread.a` with `+crt-static`, and pass `--dynamicbase` themselves.
- **Where.** `lib/presets/windows-gnu.nix`; `lib/presets/linker.nix`: `mingwLinker` (drops GCC's `-pie`).
- **Upstream.** rustc_target `spec/base/windows_gnu.rs`.
- **Holds for.** 1.99.
- **Pinned by.** `windows-gnu-run`, `windows-gnu-test`, `windows-gnullvm-run`, `windows-gnullvm-test`, `windows-dll-test`.
- **If it changes.** MinGW links fail or need DLLs wine does not find; the checks fail.

### L9. wasm32 default target features

- **Assumption.** Since 1.87 rustc enables `bulk-memory`, `multivalue`, `mutable-globals`, `nontrapping-float-to-int`, `reference-types` and `sign-ext` on `wasm32-unknown-unknown` by default, so `wasm-opt` must be told it may use them.
- **Where.** `lib/stage-helpers/default.nix`: `wasmOpt` (`features`).
- **Upstream.** rustc's `CARGO_CFG_TARGET_FEATURE` for the target.
- **Holds for.** 1.99.
- **Pinned by.** `stages-wasm-opt-features` (a module using `memory.copy`); `stages-wasm-web`.
- **If it changes.** A new default feature makes `wasm-opt` reject modules; the check fails if the fixture uses it.

### L10. Toolchain capabilities from versions and probes

- **Assumption.** A Cargo release allows unstable features exactly when its version string contains `-nightly` or `-dev` (the planner clears `RUSTC_BOOTSTRAP`); `remapPathScope` (P6) and `trimPaths` (P1) follow the versions given there.
- **Where.** `lib/toolchain-facts.nix`: `isNightly`, `capabilitySince`, `of`; `crates/breakbulk-format/src/capabilities.rs`.
- **Upstream.** cargo `src/version.rs` and `channel()` (release channel, `RUSTC_BOOTSTRAP=1` as `dev`).
- **Holds for.** The window.
- **Pinned by.** `target-traits` (`testToolchainCapabilities`: rust-overlay 1.94, 1.95, 1.97, 1.99 and nightly, nixpkgs 1.99, with and without versions); `differential-nightly`, `plan-directives-nightly`. Rust: `capabilities::tests::json_shape`.
- **If it changes.** A feature is turned on for a toolchain that rejects it, or left off; planning or units fail.

### G1. Target-trait base fields are rustc's cfg

- **Assumption.** For built-in targets, `target_vendor`, `target_os`, `target_env`, `target_abi` and `target_family` follow from the target name as `lib/target-traits.nix` parses it.
- **Where.** `lib/target-traits.nix`: `parse`, `resolve`.
- **Upstream.** `rustc --print cfg --target <t>` for every built-in target.
- **Holds for.** nixpkgs rustc 1.99: 248 of 321 targets known, all agreeing.
- **Pinned by.** `target-traits-rustc`; `target-traits`.
- **If it changes.** A new or renamed target parses wrongly; the check fails on the next rustc bump.

### G2. File-name traits are rustc's target spec

- **Assumption.** `executableSuffix`, `sharedLibraryPrefix`/`Suffix` and `staticLibraryPrefix`/`Suffix` equal rustc's target-spec `exe_suffix`, `dll_prefix`/`dll_suffix` and `staticlib_prefix`/`staticlib_suffix`.
- **Where.** `lib/target-traits.nix`: derived fields; used by `install`, test binary names.
- **Upstream.** `rustc --print file-names --crate-type <t> --target <t>`.
- **Holds for.** nixpkgs rustc 1.99, all 248 known targets.
- **Pinned by.** `target-traits-rustc`.
- **If it changes.** Products are installed under wrong names; the check fails.

### G3. The dynamic-library variable per OS

- **Assumption.** A process running natively on the target finds shared libraries through `LD_LIBRARY_PATH` on Linux and most Unix, `PATH` on Windows and `DYLD_FALLBACK_LIBRARY_PATH` on Apple, as Cargo's `dylib_path_envvar` says.
- **Where.** `lib/target-traits.nix`: `dylibPathVar`, `dylibPathSep`; `lib/test-runs.nix`: `dylibPathOf`.
- **Upstream.** cargo-util `paths::dylib_path_envvar`.
- **Holds for.** Linux, by check. Windows targets always run under wine, whose variable (`WINEPATH`) the runner declares; Apple is not supported yet (#13).
- **Pinned by.** `test-runs-test-control`, `test-runs-dylib-rule` (Linux); `windows-dll-test`, `windows-dll-needs-dll` (the runner's own variable).
- **If it changes.** Tests cannot load their build scripts' libraries.

## Fetching, vendoring and root prediction

### F1. `Cargo.lock` layout

- **Assumption.** `Cargo.lock` lists `[[package]]` entries with `name`, `version`, `source` (`registry+…`, `sparse+…`, `git+<url>?<ref>#<commit>`) and `checksum` (in version 1, in `[metadata]` instead).
- **Where.** `lib/lockfile.nix`; `lib/fetch.nix`.
- **Upstream.** cargo `src/ops/lockfile.rs` and the resolver's encodable format (not documented as a public format).
- **Holds for.** Lockfile versions 1 to 4.
- **Pinned by.** `lib-unit`; `vendor-collision`, `git-revisions-sharing` (real Cargo accepts `--frozen` against the vendor directory).
- **If it changes.** Fetching fails at evaluation, or Cargo rejects the vendor directory.

### F2. Package id spelling

- **Assumption.** Cargo's package id for a lockfile entry is its source (git without the locked revision, with `git+` and the reference query), then `#name@version`, or `#version` alone when the name equals the URL's last path segment.
- **Where.** `lib/workspace.nix`: `crateId`.
- **Upstream.** cargo-util-schemas `0.11.0` `core/package_id_spec.rs`, `impl Display for PackageIdSpec`.
- **Holds for.** 1.99.
- **Pinned by.** `repository-pkgid-short`, `git-revisions-package-ids`.
- **If it changes.** `crateSrc` references name no fetched source; instantiation fails.

### F3. Directory sources and source replacement

- **Assumption.** A directory source needs a `.cargo-checksum.json` per crate (`{"files":{},"package":<checksum>}` is accepted and the lockfile checksum is verified), reads only immediate subdirectories and skips dot directories; a git source is replaced by `[source."git+<url>?<ref>"]` with matching `git` and reference keys; a git package inside its repository is found as Cargo finds it.
- **Where.** `lib/vendor.nix`; `lib/fetch.nix`.
- **Upstream.** cargo `src/sources/directory.rs`, `DirectorySource::update`; `src/sources/config.rs`, `SourceConfigMap::load`; `src/ops/cargo_vendor.rs`; crane's vendoring.
- **Holds for.** 1.99; nightly 1.101 for the git-inheritance goldens.
- **Pinned by.** `vendor-collision`, `git-revisions-sharing`, `git-multi-workspace-build`, `git-multi-workspace-layout`.
- **If it changes.** Offline planning fails loudly.

### F4. Workspace inheritance in vendored git crates

- **Assumption.** `find_workspace_root` walks the lexical ancestors of a manifest path (symlinks are not resolved), and a `package.workspace` pointer makes Cargo read `[workspace]` from that file without checking membership.
- **Where.** `lib/vendor.nix` (stub one level up; `.breakbulk-workspace-<hash>` pointers).
- **Upstream.** cargo `0.100.0` `src/workspace/workspace.rs`, `find_workspace_root_with_loader`, `find_root_iter`; `src/workspace/parser/mod.rs`, `load_inheritable_fields`; [git-multi-workspace.md](../spikes/git-multi-workspace.md).
- **Holds for.** 1.95, 1.99, nightly 1.101.
- **Pinned by.** `vendor-git-inherit`, `git-multi-workspace-build`, `git-multi-workspace-golden`, `git-multi-workspace-golden-1_95`, `git-multi-workspace-golden-nightly`.
- **If it changes.** Inheriting git crates fail to load.

### F5. The skeleton is enough for Cargo

- **Assumption.** Cargo plans a workspace from its manifests, lockfile, config files and empty target files, and derives `CARGO_PKG_README` from whether a README file exists, not from its contents.
- **Where.** `lib/skeleton.nix`.
- **Upstream.** cargo `src/workspace/parser/mod.rs`, `default_readme_from_package_root`.
- **Holds for.** 1.99.
- **Pinned by.** `skeleton` (`cargo metadata` over the skeleton equals over the real tree); every plan check.
- **If it changes.** Plans differ from real builds (a golden fails) or tracing fails.

### F6. Root prediction

- **Assumption.** Cargo's target auto-discovery and per-kind defaults are as `lib/roots.nix` implements them, and `cargo test --doc` covers a member's library when `doctest` is on and a crate type is `lib`, `rlib` or `proc-macro`.
- **Where.** `lib/roots.nix`.
- **Upstream.** cargo `0.100.0` `src/workspace/parser/targets.rs` (function by function), `src/workspace/manifest.rs`, `Target::doctestable`.
- **Holds for.** 1.99.
- **Pinned by.** `roots-metadata-fixtures`, `roots-metadata-crates-io`, `roots-plans`.
- **If it changes.** An unpredicted root fails instantiation loudly.

### F7. build-std

- **Assumption.** With `[unstable] build-std`, Cargo resolves the standard library's own workspace with the project's source configuration, so its crates.io dependencies must be in the offline vendor directory; `rust-src` ships them vendored with checksums in `library/vendor`; Cargo passes its own `-Z` flags to std's units.
- **Where.** `crates/breakbulk-plan/src/build_std.rs`; `trace.rs`: `std_vendor`, `run` (std's `cargo metadata`); `rewrite.rs`: `add_std_vendor`.
- **Upstream.** cargo `src/compiler/standard_lib.rs`, `resolve_std`.
- **Holds for.** Nightly 1.101 with `rust-src`.
- **Pinned by.** `build-std`, `build-std-deps`. Rust: `build_std::tests::merged_directory`.
- **If it changes.** build-std planning fails offline.

## Build-script crates

### E1. pkg-config-rs and `PKG_CONFIG_ALL_STATIC`

- **Assumption.** With `PKG_CONFIG_ALL_STATIC=1`, pkg-config-rs passes `--static` to pkg-config and prints `rustc-link-lib=static=…` for a library whose archive lies in a non-system directory, with no rule of its own for musl.
- **Where.** `lib/presets/default.nix`: `staticLinking`; `lib/presets/linux-portable.nix`.
- **Upstream.** pkg-config `0.3.34`, `infer_static`, `is_static_available`.
- **Holds for.** pkg-config 0.3.34.
- **Pinned by.** `static-pkgconfig-musl-product`, `static-pkgconfig-musl-run`, `linux-portable-native-glibc`.
- **If it changes.** Static products link shared libraries or miss private dependencies; the checks fail.

### E2. cc-rs passes `--target=<Rust triple>`

- **Assumption.** cc-rs passes `--target=<Rust triple>` to a clang-like compiler, which `zig cc` cannot parse.
- **Where.** `lib/presets/linux-portable.nix` (the zig wrapper drops it).
- **Upstream.** cc-rs `src/lib.rs` (target flags for clang).
- **Holds for.** cc-rs as locked by the fixture.
- **Pinned by.** `linux-portable-glibc` (C compiled by a build script with `zig cc`).
- **If it changes.** Harmless if dropped; another spelling makes zig fail, and the check fails.

## Gaps

Assumptions that no flake check pins, or pins for some cases only. Each has an issue with the exit criterion "a test that fails if this assumption changes".

| Entry | Gap | Issue |
| --- | --- | --- |
| [S10](#s10-directive-errors-and-warnings) | Directive error and warning paths are checked only against breakbulk's copy of Cargo's code | #33 |
| [X1](#x1-rustcs-json-diagnostics) | No check reads a real rustc diagnostic out of a unit's log | #34 |
| [X4](#x4-rustcs-link-temp-directory) | No check rebuilds an msvc link to compare bytes | #35 |
| [L3](#l3-the-rust-to-wasi-sdk-table) | Only the 1.99 row is compared with a toolchain's `libc.a` | #36 |
| [L4](#l4-the-rust-to-llvm-table-and-rustc--vv) | Only the 1.97 row is compared with `rustc -vV` | #37 |
| [L5](#l5-cross-language-lto) | Cross-language LTO has never built | #10 (existing) |

Smaller unpinned details that are harmless if they change are noted in their entries: rustflags in `-C metadata` (U4), the incremental setting in `-C metadata` (U5), the retrace for pre-stabilization nightlies (P1), `include` and `config`-over-`config.toml` (T6, guarded at plan time), and the non-Linux rows of G3.

## Keeping this page current

- A new place in the code that relies on Cargo or rustc behavior beyond a documented format gets an entry here, with its test.
- When a new release joins the window (the rust-overlay versions in `tests/plan`, `tests/differential` and the version tables), update "Holds for".
- When an issue in [Gaps](#gaps) is closed, move the entry's test into "Pinned by".
