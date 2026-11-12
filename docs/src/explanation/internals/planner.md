# The traced planner

The planner runs your real Cargo with a rustc wrapper that records each command instead of compiling. It turns those records into `plan.json`: every unit, its exact command line, and the edges between units. This page covers how Cargo is invoked, how compiles are faked, how units and paths are identified, and how trim-paths and toolchain capabilities are decided.

`breakbulk-plan` runs the user's real cargo once per (workspace, target, variant, plan kind), with a rustc wrapper that records instead of compiling. It combines the records with `cargo metadata`, which is stable, to produce `plan.json`.

Spike A tested this design on Cargo 1.95, 1.97, 1.99 and nightly 1.101. The result, with source citations and the experiments, is in [spikes/A-trace-fidelity.md](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/A-trace-fidelity.md).

## Invocation

```sh
# build plan
cargo build --frozen --offline <selection> \
  --target <triple> --profile <profile> [--features …] \
  --config <generated file: rustc, wrapper, rustdoc, directories, test runner> \
  [--config <the variant's cargoConfig file>] \
  --config <generated source-replacement file, one directory per source> \
  --config '<spec rustflags and linkers, see below>'
# test plan: the same, with `cargo test` and a test runner that does nothing
# bench variant: `cargo bench --no-run` with the bench profile
# env: RUSTC_WRAPPER=breakbulk-shim  RUSTDOC=<dir>/rustdoc (a symlink to breakbulk-shim)
#      BREAKBULK_RUSTDOC=<real rustdoc>  CARGO_TARGET_DIR=<scratch>  BREAKBULK_RECORD=<record dir>
#      BREAKBULK_METADATA=<scratch>/metadata.json
#      CARGO_CACHE_RUSTC_INFO=0
```

- `<selection>` is `--workspace`, or `-p` for each package in the target's `packages` list.
- The vendor configuration is described under [Vendoring for planning](sources.md#vendoring-for-planning).
- **The variant's `cargoConfig`** ([Cargo configuration per variant](../configuration.md#cargo-configuration-per-variant)) is a TOML file the Nix library writes, passed as `--cargo-config <file>` to the planner and as `--config <file>` to Cargo, after the generated file and before the spec's, so that the spec's rustflags follow its own. Cargo merges `--config` arguments in order over the discovered files, each with `force` (cargo `src/context/mod.rs`: `cli_args_to_config`, `merge_cli_args`; `ConfigValue::merge`): a string or number replaces, an array is appended (except the non-mergeable `target.*.runner` and a few credential keys), a table merges; a `--config` file's `include`s merge before it (`load_includes`). The planner's own reader of the project's config (`ProjectConfig::of`) loads the file last with the same rules, so the key choice for spec rustflags and the `[env]` names below see it, and the trim-paths rule counts a `trim-paths` in it as the project's. The Nix library rejects the keys the generated file, the spec and the planner's arguments own. Cargo resolves the file's relative paths against the directory above it (`Definition::root` of `Definition::Cli(Some(path))`), which is in the store.
- Before tracing, the planner writes the `cargo metadata` JSON to `$BREAKBULK_METADATA`. Stubs read it to learn their package's targets, and the planner looks up each traced compile's package in it by directory.
- `cargo metadata` runs with `--all-features`, not the variant's feature flags. It lists only the packages of the resolve for the features it is given, so without them a variant whose features turn on an optional dependency would compile a package the metadata does not have. The variant's own flags would not do: `cargo metadata` selects every workspace member, and a bare feature name applies to each selected member that has it, which differs from what it means for a `-p` selection. With `--all-features` Cargo resolves only; mutually exclusive features that would not compile together still plan.
- **Spec rustflags.** Cargo takes rustflags from exactly one source: the first of `CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`, `target.<triple>` together with `target.<cfg>`, and `build.rustflags`. Arrays concatenate only within one key. The planner therefore reads the project's `.cargo/config.toml` files (a documented format).

  If the project sets `build.rustflags` and no per-target rustflags, spec rustflags go under `build.rustflags`; otherwise under `target.<triple>.rustflags`.

  Which `target.'cfg(…)'` keys apply depends on rustflags, because Cargo asks `rustc --print=cfg` with the flags it has and then recomputes them (up to two rounds); the planner repeats those queries with the spec's flags in place, so a spec flag such as `--cfg x` or `-C target-feature=+avx2` that turns on a cfg key moves the spec's flags under the target key.

  The planner then checks in the trace that every target unit carries both the project's and the spec's flags.
- **Linkers** go under `target.<triple>.linker`. Cargo passes `-C linker` to every unit, including rlibs that never link, so a linker change changes every unit's derivation. The planner keeps Cargo's argv as it is.
- Spec env is **not** passed to Cargo. Cargo's `[env]` reaches every process, including host build scripts; spec env is added per unit by platform at instantiation.
- The user's own `.cargo/config.toml` is in the skeleton and applies as it does locally, with every file its `include`s reach (Cargo 1.93 and later; `withIncludes` in `lib/skeleton.nix`). An include outside the repository root or by absolute path is not copied. Nothing from the user's home directory or shell is visible. Cargo reads `.cargo/config.toml` from every ancestor of its working directory, whatever `CARGO_HOME` says. In the Nix sandbox no ancestor has one; local planner runs and tests must stage the project outside `$HOME` (see [Testing and conformance](testing.md)).
- `CARGO_CACHE_RUSTC_INFO=0` turns off Cargo's rustc-info cache (`<build dir>/.rustc_info.json`), so every Cargo invocation sends `rustc -vV` through the shim, whose record is Cargo's own environment, the baseline that env filtering subtracts. The planner fails when an invocation recorded no `-vV`. The variable reaches every process Cargo starts and is subtracted with the rest of the baseline.
- The planner never sets `CARGO_INCREMENTAL` and never passes it through from its own environment, because the incremental setting is part of every unit's `-C metadata`. The `-C incremental=…` argument is stripped from argv instead (see [Env filtering](#env-filtering)).
- The planner runs Cargo without `-v`. Verbosity changes argv: with `-vv`, non-local crates get `--cap-lints warn` instead of `--cap-lints allow`.
- The clippy variant adds `RUSTC_WORKSPACE_WRAPPER=clippy-driver`. Cargo then calls `breakbulk-shim clippy-driver rustc …` for workspace members only. This chain is parsed but not yet tested. clippy-driver is a rustc with its own sysroot compiled in, so before tracing, the planner checks that `clippy-driver --rustc --print sysroot` equals `rustc --print sysroot`. A clippy built for another rustc (nixpkgs' `clippy` beside a rust-overlay toolchain, even of the same release) would otherwise put that rustc's sysroot into the traced units, which instantiation rejects as an undeclared input. The error names [`workspaces.<ws>.toolchain.clippy`](../../reference/options/workspaces.md#workspacesnametoolchainclippy) (`--clippy-option`); that option defaults to `pkgs.clippy` with nixpkgs' rustc and to `rustc` itself otherwise.
- **Tests and doctests.** The test plan traces one plain `cargo test`, because rustdoc compiles doctests at run time: `cargo test --no-run` stops before them. The generated config sets `target.<triple>.runner` for the target and for the host (Cargo looks the runner up per compile kind, and proc macros' tests run for the host) to a `breakbulk-test-runner` symlink to the shim, which exits 0 without running the (empty, faked) test binary. Cargo then calls `rustdoc --test` for each library that `cargo test` doc-tests: those with `doctest` on and a `lib`, `rlib` or `proc-macro` crate type. The shim, acting as `RUSTDOC`, records each and exits successfully. Because of the runner, Cargo adds `--test-runtool <runner>` (and a `--test-runtool-arg` per argument) where `--target` ends (a proc macro's doctest, built for the host, has no `--target`: after `--test-run-directory`); the planner removes them from the recorded command, and records the doctest's platform (`host` without `--target`). At build time `breakbulk-unit` adds the runner of that platform at the same place: the target's runner for a target library, none for a proc macro, which runs on the build machine.

  `cargo test --doc` is not used: it doc-tests every doctestable library, also those with `doctest = false` (cargo `src/ops/cargo_compile/unit_generator.rs`, `create_proposals`: the `CompileFilter::Default` arm checks `doctested() && doctestable()`, the `CompileFilter::Only` arm only `doctestable()`), and those libraries' dependencies, built for them alone, add build-script runs to every doctest's `-L` list. Each doctest gets one `-L` for every search path of every build-script run in the whole `cargo test` (`run_doc_tests`, from `Compilation::native_dirs`), so every doctest depends on every run of the test plan, as test runs do.
- **Documentation.** The doc plan traces `cargo doc` (with `--no-deps` under [`docs.noDeps`](../../reference/options/workspaces.md#workspacesnamedocsnodeps)) in every variant, never with clippy-driver. The shim, as `RUSTDOC`, records each `rustdoc` command and exits successfully. The planner removes Cargo's `-o <doc dir>` (the docs derivation gives its own) and keeps which directory it was as the command's platform: Cargo documents a proc macro into `target/doc` even with `--target` (`kind.for_target` in `unit_generator.rs`, `output_dir` in `compilation_files.rs`). The commands are ordered so that each comes after the documented crates its `--extern`s name, then by crate name ([Documentation](products.md#documentation)). The rest of the trace is the check-mode units rustdoc reads, as a check variant's.
- One target per plan. A traced compile with a `--target` other than the plan's target and the host fails planning, naming the package (#39). Nightly `package.forced-target` (`per-package-target`) causes this, since it overrides `--target`. `package.default-target` is harmless, because `--target` overrides it.

## Which targets each command builds

Observed on every supported Cargo release:

| Command | Builds |
| --- | --- |
| `cargo build` | Libraries and bins. Never examples. |
| `cargo test --no-run` | Libraries, lib and bin test harnesses, integration tests, and examples (as plain bins). Bins only when the package has integration tests. **No benches.** |
| `cargo bench --no-run` | Lib and bin harnesses in bench mode, and benches. No examples or integration tests. |

Benches therefore come only from the bench variant.

## trim-paths

Cargo's `trim-paths` profile setting is stable from Cargo 1.101 (nightly 1.101 included). On earlier releases any `trim-paths` setting is a hard error, so it is always off there. Its default is `none` for every profile, `release` included. Its values are `none`, `object` and `all` (cargo `TomlTrimPaths`).

- **Detection.** A unit is under Cargo's trim-paths when its argv has `--remap-path-prefix=<build dir>=/cargo/build-dir`; user rustflags never produce that pair.

  Cargo also passes `--remap-path-scope=<value>` and one pair each for the package (`<workspace root>=.`, or `<package root>=/cargo/deps/<name>-<version>` for packages outside the workspace root, vendored registry and git crates included, since breakbulk vendors them; a local build reading a git checkout or the registry cache from `$CARGO_HOME` gets `/cargo/git/<hash>/<rev>` or `/cargo/registry/<id>` instead, so panic locations in those crates read differently, and the golden comparator treats the two forms as equal) and the sysroot (`<sysroot>/lib/rustlib/src/rust=/rustc/<commit>`)

  (cargo `src/compiler/trim_paths.rs`, `trim_paths_remap`). The plan header's `trimPaths` records the result. trim-paths on for some compile units and off for others (a per-package profile override) fails the plan, naming the packages on each side; doctests are not counted, because rustdoc gets remaps only with `all`.
- **Default** ([`workspaces.<ws>.cargoTrimPaths`](../../reference/options/workspaces.md#workspacesnamecargotrimpaths), per variant too). A profile setting from `--config` overrides the manifest's, so passing it blindly would replace the project's own choice.

  With `cargoTrimPaths = null` (the default) and the toolchain's `trimPaths` capability on (Cargo 1.101 or later, see [Toolchain capabilities](#toolchain-capabilities)), the planner passes `--config profile.<profile>.trim-paths="all"` unless the project declares `trim-paths` anywhere: under `[profile.<any>]`, its `build-override` or a `package.<spec>` override, in the workspace root's `Cargo.toml`, in a `.cargo/config.toml` (or `.cargo/config`) from the workspace directory up, or in the variant's `cargoConfig`.

  The files are read as TOML, not merged as Cargo would (`breakbulk-plan`'s `trim_paths` module), so any mention counts, whatever the profile or value, an explicit `"none"` included; a file that does not parse is a warning and counts as no mention. The planner then traces once, with `trimPathsDefault` in the plan header when it passed the setting.

  `cargoTrimPaths = true` passes it even over the project's own (an error without the capability); `false` never passes it. A nightly 1.101 from before the setting was stable rejects it; with `null` the planner then traces without it and warns.
- **`sourcePaths = "keep"`** (per workspace and variant): breakbulk neither passes trim-paths nor adds any remap of its own (Rust `--remap-path-prefix` and scope, C `-ffile-prefix-map`; `toolchains.json`'s `keepSourcePaths`), and products get no default `noSourceReferences` check. A project that sets trim-paths itself still gets Cargo's remaps, as traced.
- **Scope.** With the project's own setting, Cargo's `--remap-path-scope` stays in argv. With `trimPathsDefault`, the planner drops it, and `breakbulk-unit` adds the scope per product kind, as for its own remaps (see [Source paths at run time](../../reference/unit-builder.md#source-paths-at-run-time)): shipped units keep store paths in debug info, test binaries remap every scope. `all` is passed rather than `object` so that `rustdoc --test` gets remaps too.
- With trim-paths on, path crates outside the workspace root hash without their absolute path (cargo `src/workspace/source_id.rs`, `SourceId::stable_hash`: "not hashed at all"; c82e769), so the skeleton location no longer matters (see below).

  Build-script runs get `CARGO_TRIM_PATHS_SCOPE` and `CARGO_TRIM_PATHS_REMAP` (the same pairs, `:`-separated, built in cargo `src/compiler/custom_build.rs`; cc-rs, from 1.3.0 (`add_trim_paths_flags` in `src/lib.rs`, PR #1794; checked in 1.11.1), turns each pair into `-fmacro-prefix-map` and, for scope `object` or `all`, `-fdebug-prefix-map`).

  The plan leaves the build-directory pair out of `CARGO_TRIM_PATHS_REMAP`, because the run's `OUT_DIR` is inside its own `out`, which its derivation cannot name. Every run's `out` copies Cargo's build directory around its `OUT_DIR`, so `breakbulk-unit` puts the pair back at run time as `<own out>=/cargo/build-dir`, with the same pair for each other run's `out` the script names, in Cargo's position (before the sysroot pair).

  Cargo's one pair likewise becomes one `<run out>=/cargo/build-dir` per run a compile unit names. The golden checks compare the variable with Cargo's as is: each run's `out` resolves to Cargo's target directory there, so the pairs collapse into Cargo's one. `CARGO_TRIM_PATHS_SCOPE` stays `all` even when the planner set the scope per product kind for rustc, so C debug info is always remapped.
- **C prefix maps**. Under trim-paths, breakbulk's own `-ffile-prefix-map` flags for a run (`NIX_CFLAGS_COMPILE`, see [Environment capture](env-capture.md)) use Cargo's names, not breakbulk's: the pairs of the run's `CARGO_TRIM_PATHS_REMAP`, and Cargo's build-directory pair expanded per run `out` the run names, its own included (the run unit's `buildDirRemap` in the plan: run id to `/cargo/build-dir`, since each run's `out` copies Cargo's build directory). So C code compiled by cc-rs, which adds the same maps after the wrapper's, or by any other means reads as under Cargo: `__FILE__` of `<workspace root>/cfile/c/where.c` is `./cfile/c/where.c` (`products-trim-paths-cc`).
- The golden and differential tests give the reference `cargo build` the same `--config` when the plan has `trimPathsDefault`, and compare Cargo's one build-directory pair with the plan's expanded ones (below).

## Toolchain capabilities

What breakbulk turns on or off per toolchain is decided in one place, the Nix library's `toolchainFacts.of { pkgs; rustc; cargo; capabilities; }` (`lib/toolchain-facts.nix`), as its `capabilities`:

| Capability | Meaning | Default |
| --- | --- | --- |
| [`remapPathScope`](../../reference/options/workspaces.md#workspacesnametoolchaincapabilitiesremappathscope) | rustc takes `--remap-path-scope` | rustc 1.95 or later; for a rustc without a `version` attribute, whether `rustc --remap-path-scope=macro,diagnostics --print sysroot` succeeds |
| `trimPaths` | Cargo has the `trim-paths` profile setting | Cargo 1.101 or later (nightly 1.101 included); `cargo -V` without a `version` attribute |
| `nightly` | Cargo allows unstable features | a `-nightly` or `-dev` Cargo release |

The rustc probe is reliable because rustc parses every option before it acts on `--print`: an unknown option fails in `handle_options` (rustc_driver_impl `lib.rs`, getopts' `UnrecognizedOption`, "Did you mean `-Z remap-path-scope`?" on 1.94), and the scope list is parsed by `parse_remap_path_scope` (rustc_session `config.rs`), so a rustc that accepts the probe accepts breakbulk's scopes; checked on rust-overlay 1.94.0 (rejects), 1.95.0, 1.99.0, nightly 1.101 and nixpkgs' 1.99.0 (accept).

As for every toolchain fact, the probes run through import-from-derivation only when the toolchain has no `version`, or one that is not a Rust release (a table first, a probe only when the table cannot say). fenix is such a toolchain (fenix `5161c3b`, `lib/mk-toolchain.nix`): its combined packages (`rustc`, `toolchain`, `minimalToolchain`, `withComponents …`) have no `version`, and its component packages (`cargo`, `rustc-unwrapped`) have the channel manifest's date (`2026-10-15`), which once read as release 2026 and turned trim-paths on for Cargo 1.99.

Checked end to end with fenix's stable `rustc` and `cargo` (1.99.1), its stable `minimalToolchain` and a nightly `withComponents` (1.101): the probes give the right capabilities, and the walking-skeleton fixture plans and builds with each. The release is not readable from fenix's packages without a build: their names and versions carry only the date, and only stable component download URLs name the release.

`workspaces.<ws>.toolchain.capabilities.<name>` overrides any of them, for a forked or patched toolchain whose version says otherwise (`null` keeps the default).

The planner receives them as `--capabilities <file>` (`trimPaths`: whether Cargo can take trim-paths at all, see [trim-paths](#trim-paths); `nightly`: the plan's `nightlyFeaturesAllowed` for build-script runs) and breakbulk-instantiate as `toolchains.json`'s `capabilities` (`remapPathScope`: whether shipped units get a scope); both parse breakbulk-format's `Capabilities`, every field required. No Rust program reads a Rust or Cargo version to decide a feature. The dev shell's trim-paths export reads the same `trimPaths` (`breakbulk-plan --cargo-env-only --capabilities <file>`). `breakbulk-unit` keeps its own check of a package's `rust-version` against 1.77 (the `cargo::` syntax): that is the package's declared version, not the toolchain's.

## Target facts from rustc

The planner runs the real rustc for the target already, so it takes from rustc the target facts that matter only at plan or build time, rather than from the [target traits](toolchains.md#target-traits). It runs `rustc -Z unstable-options --print target-spec-json --target <t>` once, in the directory it runs Cargo in, so a custom target's relative `.json` path names the same file. The print is unstable, so that one command gets `RUSTC_BOOTSTRAP=1`; Cargo and the build scripts it starts do not, because the scripts would see the variable and the units would record it.

A key the spec leaves out has rustc's default: rustc writes only the options that differ from `TargetOptions::default()` (rustc_target `spec/json.rs`, `Target::to_json`). From the spec the planner takes:

- `exe-suffix`: the suffix of the name a bin or example is stored under (its target name and the suffix, as Cargo uplifts it). Cargo takes the same suffix from rustc's `--print file-names`. The planner fails when rustc's file name for the bin is not `<crate name><-C extra-filename><suffix>`.
- The plan's `targetDebuginfo` ([Plan format](../../reference/plan-format.md)): the target's default `split-debuginfo`, and the side files its links write, as rustc_codegen_ssa `back/link.rs` writes them. An MSVC-style linker (`linker-flavor` `msvc` or `msvc-lld`) always writes a `.pdb` (`back/linker.rs`, `MsvcLinker::debuginfo`). With `packed` split debuginfo, a Darwin-like target (`is-like-darwin`) gets a `.dSYM` from dsymutil, a Windows-like one nothing more, and any other a `.dwp` from thorin. With `unpacked`, a target whose `debuginfo-kind` is `dwarf` keeps a `.dwo` per object. Only the kinds in `supported-split-debuginfo` count, because stable rustc rejects the others (rustc_session `session.rs`, `SplitDebugInfoUnstablePlatform`).

So a custom target gets the right `debug` outputs from its own spec, with no `traits` declared for them. The evaluation-time choices (presets, linker, stages) still read the traits, which must not need a build to evaluate.

## Fixed skeleton location

Cargo hashes the absolute path of a path crate that lies outside the workspace root into its `-C metadata`, unless `trim-paths` is in effect. The planner therefore places the skeleton at one canonical absolute path inside the sandbox and records it in the plan header. When a workspace has path dependencies outside its root, `trim-paths` is not in effect after the planner's second trace, and the canonical path is not available (non-default `sandbox-build-dir`, an unsandboxed build, macOS), planning fails with a message naming the crates affected. Otherwise the location does not matter and no check is made.

## `breakbulk-shim` modes

The shim decides its mode from how it was started and from its arguments, checked in this order:

| Mode | Detected by | Action |
| --- | --- | --- |
| Build-script stub | `breakbulk-stub.json` in the directory of the running executable | Record argv, cwd and the full env; print sentinel directives; exit 0 |
| Test runner | The executable's file name is `breakbulk-test-runner` (the planner's symlink to the shim, set as the runner of a traced `cargo test`) | Exit 0 without running the test binary |
| Rustdoc | The executable's file name contains `rustdoc`. The planner sets `RUSTDOC` to a `rustdoc` symlink to the shim, because Cargo starts `RUSTDOC` with the same env it gives `RUSTC_WRAPPER`. | For queries, `exec` `$BREAKBULK_RUSTDOC`; otherwise record and exit 0 without output |
| Query | `-vV`, `-V`, `--version`, any `--print`, or `-` as the input; or no `--crate-name` or no input file | Record, then `exec` the real rustc unchanged |
| Compile | `--crate-name` plus an input file | Record, then fake the outputs |

As `RUSTC_WRAPPER` the shim is started as `breakbulk-shim [workspace-wrapper] rustc ARGS`. The program chain is every leading argument that is not an option; Cargo always starts rustc's arguments with an option.

The record of the `rustc -vV` query carries Cargo's own process environment. It is the baseline for [Env filtering](#env-filtering).

## Faking a compile

1. Write a record: argv (with the wrapper chain), env, cwd.
2. Ask the real rustc for output names: the same arguments plus `--print=file-names` (it does not compile, and it does not resolve `--extern` paths). Add the `.rmeta` and `.d` names that `--emit` implies. The query names every link output for every crate type, `--emit` set and `--test`, but not debuginfo side files (`.dwp`, `.dwo`; by the same logic `.pdb` and `.dSYM`, not tested). Cargo tolerates their absence during the trace.
3. Create each output as an empty file. Write the dep-info file as `<output>: <input file>`, because Cargo parses it after every compile.
4. When the arguments contain `--json=…artifacts…` and `--emit` includes `metadata`, print one `{"$message_type":"artifact","artifact":"<path>","emit":"<kind>"}` line per output on stderr, as rustc does. Cargo waits for the metadata notification before starting pipelined dependents.
5. For a build-script compile (crate name `build_script_build`), copy the shim binary to the output path and write `breakbulk-stub.json` next to it, naming the compile unit.

When Cargo runs a stub, the stub records argv, cwd and the full env Cargo gave it, including `TARGET`, `HOST`, `PROFILE`, `OPT_LEVEL`, `DEBUG`, `CARGO_CFG_*`, `CARGO_FEATURE_*`, `CARGO_ENCODED_RUSTFLAGS`, `CARGO_MANIFEST_LINKS`, `OUT_DIR` and any `DEP_*` sentinels from upstream stubs. It finds its package in the `cargo metadata` JSON (`$BREAKBULK_METADATA`, default `$BREAKBULK_RECORD/metadata.json`) by `CARGO_MANIFEST_DIR`, to learn the package's targets.

The stub writes its record to `$BREAKBULK_RECORD` as Cargo gives it when it runs the stub, not to a directory named at compile time, so a Cargo invocation over the same target directory that runs the stub without compiling it again gets the record. Cargo passes its own environment on to build scripts (it removes only `RUSTC_WORKSPACE_WRAPPER` and `RUSTFLAGS`, and sets `RUSTC_WRAPPER`), so the variable is always there under a traced Cargo; a stub started without it fails.

## Unit identity and graph edges

- **Compile units** are keyed by Cargo's `-C metadata=<hash>` value; **build-script runs** by the `<pkg>-<hash>` (or `<pkg>/<hash>`) component of their `OUT_DIR`. These hashes come from Cargo's stable unit identity. The sentinels leave every `-C metadata` and every run hash unchanged (observed on every supported release).
- **Keys are per plan.** `-C metadata` does not contain rustflags; Cargo hashes rustflags only into `-C extra-filename`. Two variants that differ only in rustflags (coverage, a `--cfg`) therefore share `-C metadata`, and units without `-C extra-filename` (cdylibs, and in the new layout bins and dylibs) also share output names. Unit keys identify a unit only within one plan. Sharing across plans is decided by derivation paths, and `explainSharing` compares argv and env, not hashes.
- **Errors name units by key and by what they are.** Nobody knows a `-C metadata` hash without Cargo's verbose log, so a planner error follows the key with the package, the crate kind (`test` for a `--test` compile), the crate name when it is not the package's, and the platform: `unit c-a99789a5b8158e0a (block-buffer 0.10.4, lib, target)`, `run r-ring-… (build script of ring 0.17.14, host)`. A cause that concerns several units is one line, listing them.
- **Edges** come from the records: a `--extern name=<path>` or `-L dependency=<dir>` path names the producing unit's output; `OUT_DIR` in a compile's env names its build-script run; the stub's path names the run's compile unit; sentinels give directive placement and metadata edges. In the new layout each compile gets one `-L dependency=<dep's out>` per dependency instead of one shared `deps` directory.
- **Platform** is read from the output location: Cargo always receives `--target`, so host units write under `<scratch>/<profile>/` and target units under `<scratch>/<triple>/<profile>/`, in both layouts.
- **`links` overrides** in config (`[target.<triple>.<links>]`) need no special case. Cargo skips the build script and passes the flags directly, so they appear in the recorded arguments.

## Path rewriting

Every recorded argument and env value is split into literal text and references. Any remaining absolute path that is not in the store is an error that names the unit and the argument.

Cargo has two build-directory layouts. Releases up to 1.99 use the classic one. Current nightly Cargo (1.101) uses a new layout by default (opt-out `__CARGO_TEMPORARY_BUILD_DIR_NEW_LAYOUT_OPT_OUT=1`), and it will reach stable unless reverted. In the new layout every unit gets `build/<pkg>/<hash>/{out,fingerprint,run}`, compile outputs go to that unit's `out`, there is no `deps/`, build scripts are `…/out/build_script_build` with no hash and no `build-script-build` copy, and bins, dylibs, cdylibs and build scripts have no `-C extra-filename`. The planner supports both. In the new layout an output path names its unit's directory directly.

| Recorded path | Becomes |
| --- | --- |
| Classic: `<scratch>/[<triple>/]<profile>/deps/<file>` | `{"out": <unit>, "output": "rmeta" or "rlib" or "bin", "file": <name>}` |
| Classic: `<scratch>/…/build/<pkg>-<hash>/out` | `{"out": <run unit>, "output": "out"}` |
| New: `<scratch>/…/build/<pkg>/<hash>/out/<file>`, where `<hash>` is a compile unit's directory | `{"out": <compile unit>, "output": "rmeta" or "rlib" or "bin", "file": <name>}` |
| New: `<scratch>/…/build/<pkg>/<hash>/out`, where `<hash>` is a run's directory | `{"out": <run unit>, "output": "out"}` |
| The stub binary path (both layouts) | `{"out": <compile unit>, "output": "bin"}` |
| A bin's uplifted copy, `<scratch>/[<triple>/]<profile>/<name><exe suffix>` (`CARGO_BIN_EXE_<name>`) | `{"out": <bin unit>, "output": "bin", "file": "<name><exe suffix>"}`: the one bin of that name, or the referring unit's package's |
| `<skeleton>/<rel>`, in a unit of a workspace package | `{"src": <the unit's package>, "rel": <rel>}`, resolved at instantiation |
| `<skeleton>/<rel>`, in a unit of a registry or git crate | `{"empty": <rel>}` |
| `<vendor dir>/<source>/<crate>/<rel>` | `{"crateSrc": <package id>, "rel": <rel>}` |
| `/nix/store/…` | Literal; the containing store path becomes an input |

A bin or example that Cargo uplifts is stored under its uplifted name, so that is its `file` in every row, not rustc's `<crate name><-C extra-filename><exe suffix>`; the plan's `uplifted` maps it to rustc's name ([Plan format](../../reference/plan-format.md)).

A path in the repository always resolves in the unit's own source view, never in the view of the package whose directory holds the path. Such paths come from three places: Cargo runs the rustc of a workspace package in the workspace root, with a source path relative to it (`path_args`, `src/util/workspace.rs`); Cargo config's `[env]` with `relative = true` names a path relative to the config's directory, and Cargo sets it on every compile and build-script run, registry crates' included; and `build.rustflags` can name any path. Every view is rooted at the repository root, so the path keeps its place in it:

- A member of a workspace whose root is also a package runs in its own view, which holds its own directory. The root package's view leaves out the members' directories.
- A unit depends only on its own view. A config path into another package's directory resolves there only when the unit's package lists that path in [`extraSources`](../../reference/options/packages.md#packagesnameextrasources), as for `include_str!("../../assets/x")`.
- A registry or git crate's unit has no view. Its repository paths point into one constant empty directory (`empty`), so the value keeps its shape, never changes with the repository, and the unit stays shared across repositories.

Two rewrites go beyond paths:

- **Same-triple linkers.** When host and target triples are equal, Cargo gives every host unit (build scripts, proc macros and host rlibs) `-C linker=<target linker>`, and every build-script run `RUSTC_LINKER=<target linker>`. When the host spec's linker differs from the target's, each host unit's `-C linker=` value, and `RUSTC_LINKER` on each host run, is replaced with the host linker. The planner first checks that the unit carries exactly one `-C linker=` equal to the configured target linker. A linker set by the user's own config is left alone, because local Cargo applies it the same way. (Nightly's `-Zhost-config` does not help: host rlibs still get the target linker.)
- **Build-directory remap.** When Cargo's `trim-paths` is in effect, Cargo emits one `--remap-path-prefix=<build dir>=/cargo/build-dir`. In breakbulk the build directory is split into one store path per `OUT_DIR`, so the planner expands it, in place, into one `--remap-path-prefix=<run's out>=/cargo/build-dir/<OUT_DIR relative to the build directory>` per run whose `OUT_DIR` the unit names (normally its own `OUT_DIR`; values with sentinels, which name search paths, do not count). Paths below it then read exactly as under Cargo, for example `/cargo/build-dir/x86_64-unknown-linux-gnu/debug/build/shared/<hash>/out/gen.rs` for `include!(concat!(env!("OUT_DIR"), …))`. A unit that names no `OUT_DIR` gets none.

## Env filtering

A unit's recorded env is the recorded env minus a baseline: the env of the shim's `rustc -vV` query record, which is Cargo's own process environment. That keeps exactly what Cargo set per process, except the project's `[env]`: Cargo applies `[env]` to the `rustc -vV` query too, so it is in the baseline. The planner therefore reads the `[env]` names and `force` flags from the project's config files, keeps those Cargo applies (forced, or not already in Cargo's environment), takes their values from the records (so `relative` paths come out as Cargo resolved them), and records them as `configEnv` so test runs can export them too. The env the planner gave Cargo is not the right baseline: Cargo sets `SSL_CERT_FILE` and `SSL_CERT_DIR` on itself at startup and, from 1.97, `CARGO`; every child inherits them, and they are machine-specific. Then:

- Drop `RUSTC_WRAPPER`, `CARGO_MAKEFLAGS` and the planner's own variables. Keep `RUSTC_WORKSPACE_WRAPPER` only in the clippy variant.
- Rewrite `RUSTDOC` to the real rustdoc. Cargo passes `RUSTC_WRAPPER` (when set) and `RUSTDOC` as configured to every build-script run, so the trace shows the shim for both.
- Strip `-C incremental=…` from argv. It does not affect `-C metadata`; `CARGO_INCREMENTAL` and `profile.*.incremental` do, which is why the planner never sets them.
- Replace `NUM_JOBS` with `$NIX_BUILD_CORES`, applied by the runner at build time.
- Never pass `RUSTC_BOOTSTRAP` to a build-script run. If it reached one, build scripts that probe for nightly would turn on nightly-only code paths. Compile units may receive it only from the pipelined split's `-Zno-codegen` backend.
