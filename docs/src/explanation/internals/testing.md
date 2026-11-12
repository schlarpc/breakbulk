# How breakbulk is tested

breakbulk's promise is that a build behaves like `cargo build` and that an edit rebuilds only what it should. The test suite checks both: golden tests compare traced commands against real Cargo, and invalidation and sharing tests compare derivation sets. This page lists the kinds of tests, the fixtures, and how to run them.

Trace golden tests and directive differential tests guard against Cargo changes; invalidation and sharing tests guard the main promise, that an edit rebuilds only what it should. Every place breakbulk relies on Cargo or rustc behavior beyond a documented format, with the upstream source, the releases it holds for and the check that pins it, is listed in [reference/assumptions.md](../../reference/assumptions.md).

1. **Rust unit tests** for the directive parser (both syntaxes, every directive, malformed input), path rewriting, env filtering, splice expansion, plan canonicalization and unit ordering.
2. **Trace golden tests.** For each fixture, run real `cargo build -vv` and the traced planner on the same skeleton, render the plan back to concrete argv and env with the same scratch layout, and diff per unit after normalizing paths. Both sides run at the same verbosity, because verbosity changes argv (`--cap-lints`) and only `-vv` prints per-process env. The comparison also diffs target-directory file listings, which differ only in debuginfo side files. A negative control (one splice per kind, no search-path ordering) must produce diffs, so the comparison is not vacuous. Fixtures are copied outside `$HOME` before each run, because Cargo reads `.cargo/config.toml` from every ancestor directory. This runs against the oldest release in the supported window (about six months of stable), the latest stable and the latest nightly. `tests/plan` runs it (`breakbulk-plan-golden`).
3. **Directive differential tests.** Generate dependency graphs and build-script outputs (several values per kind, duplicates, paths inside and outside the build directory, mixed order). Let stubs replay them so Cargo applies them, and separately expand the sentinel plan with `breakbulk-unit`'s splicing. The two argv and env sets must be identical. The same harness checks that sentinels do not change any unit's `-C metadata`. Its error counterpart runs build scripts printing outputs Cargo rejects or warns about through real `cargo build` and through `breakbulk-unit`; the outcome and the messages must be the same (`differential-errors*`).
4. **Root prediction tests.** Compare the Nix prediction with `cargo metadata` targets over a corpus of real workspaces. The target sets must be identical, with `required-features` as the only allowed difference in what is built.
5. **Fixture builds.** Each fixture builds and tests on its targets in IFD mode, and in dynamic-derivation mode on a Nix with `builder-rpc-v0`. Unit derivation paths must be identical in both modes, and product bytes identical. `nix run .#test-dynamic` (`tests/dynamic/run.sh`) does this on Nix master in a private chroot store: the system Nix builds each fixture in IFD mode, everything upstream of the units is copied into the private store, and Nix master builds the fixture in dynamic-derivation mode (so the outer derivations write and build every unit) and then in IFD mode, and compares every unit and doctest `.drv` path of every plan, the product bytes, the test runs', bench runs' and doctests' outcomes, the `repo.checks` sets, the test apps, `explainSharing`, and, for split-debuginfo products (`packed` and `unpacked`), that gdb shows a dependency's source and arguments through the product's `debug` output. It covers every workspace, target and variant of each fixture, with the configuration the IFD-mode tests build it with (`tests/dynamic` reuses their repositories), cross targets and presets included. With `test-cutoff` and `test-options` it also checks test-run cutoff in dynamic-derivation mode, as `.#test-cutoff` and `.#test-options` do in IFD mode: after an edit that changes nothing a test run reads, the run is not re-run. With `run-files-ca-off` (narrowed `"run"` views, `ca = false`) it compares each test run's input closure: the same paths in both modes, and, for the stripped libtest runs, without the package's whole source view. It is opt-in, because `nix flake check` on a stable Nix cannot run it.
6. **Invalidation tests.** Instantiate a fixture, apply a scripted edit, instantiate again, and compare the sets of unit `.drv` paths. Each test states which units may change. For example: changing a build stamp on the top package changes only that package's units.
7. **Sharing tests.** For fixtures with several workspaces or variants, assert the exact set of shared unit derivations, using the same comparison as `explainSharing`.

## Fixtures

One small workspace per pattern in [Patterns and prior art](../prior-art.md), under `tests/fixtures/`.

| Fixture | Pattern | Targets | Asserts |
| --- | --- | --- | --- |
| `directives` | Every build-script directive, `links` chains, `DEP_*` | linux-gnu | Placement matches Cargo; signal death fails |
| `build-dep-leak` | A build dependency emitting `rustc-link-lib` | linux-gnu → aarch64 | Target link args contain no host libs |
| `sys-native` | pkg-config, cmake and bindgen `-sys` crates with `nativeInputs` and `inputs` | linux-gnu, aarch64 | Builds; captured env reaches only that package |
| `native-link` (`tests/native-link`) | A `-sys` crate printing only `rustc-link-lib=foo`, against a C shared library from `inputs`; a bin, tests and a doctest in other packages | linux-gnu | The bin links and runs with an empty environment (rpath), with GNU ld (nixpkgs' rustc) and with nixpkgs' lld (rust-overlay's rustc, `runs-lld`); only linking units get the library search flags; a change to the input touches no unrelated package |
| `build-script-outputs` | A `links` package publishing a header directory in `OUT_DIR` as metadata `include`; a package without `links` writing a data file; a bin depending on both | linux-gnu | The bin's product installs the header and the data file with `buildScriptPath`, in both delivery modes; the runs' `metadata.json` name their packages (`products-build-script-outputs`) |
| `missing-input` | A `-sys` crate with an undeclared input | linux-gnu | Failure names the variable or path and the option to set |
| `view-hints` | A library, a build script, an integration test, a test and a doctest that each read a file outside their package; a library that hands its test a path into its own `tests/`; a library reading a file a `sources` function left out | linux-gnu | Each fails naming the path and `extraSources`, `test.sourceScope` or `test.scopeTestsDir`; with those set, each builds or passes (`repository-view-hints`) |
| `crate-types` | `["cdylib", "rlib"]`, `staticlib`, proc macro | linux-gnu, wasm | All outputs present |
| `rlib-example` | An example with `crate-type = ["rlib"]` and a bin example, over a chain of two libraries | linux-gnu | The rlib example's inputs are its dependencies' `rmeta` outputs; the bin example's are every `rlib` (`plan-rlib-example`) |
| `outside-reads` | `include_str!` of `../`, a proc macro reading a sibling directory | linux-gnu | Builds; editing an unrelated sibling changes nothing |
| `multi-ws` | Three workspaces sharing a path crate and registry crates; one workspace contains the path crate | linux-gnu | Registry units shared; path crate shared only outside every root; `explainSharing` names the reason otherwise |
| `git-revisions` | Four workspaces depending on one local git repository: the same branch locked at two commits, the same commit by `branch` and by `rev` | linux-gnu | Each workspace gets its own revision; git units shared only between workspaces locking the same source at the same commit; package ids equal real Cargo's |
| `vendor-collision` | A crates.io crate and a git fork with the same name and version | linux-gnu | Each consumer gets its own source |
| `dev-dep-features` | A dev-dependency enabling extra features on a normal dependency | linux-gnu | The build plan's product lacks the feature; the test plan's binaries have it |
| `required-features` | Bins and tests with `required-features` | linux-gnu | Stubs fail or skip with the reason; enabled variants build them |
| `feature-unification` | `resolver.feature-unification = "package"` (and `[unstable] feature-unification`) in project config; two bins enabling different features of a shared member, which has a doctest | linux-gnu, nightly | The plan contains one unit per feature set of the shared dependency (one per package, as Cargo builds them); golden on both plans; each bin sees its own set; the shared member's doctest is traced although the bins have no library (`plan-feature-unification`) |
| `embed` | A host crate embedding a wasm product via env | linux-gnu + wasm | Host instantiation does not depend on the product; only the embedding chain references it; identical wasm bytes do not rebuild the host (dynamic-derivation mode) |
| `ui-dist` | The first example of [The configuration model](../configuration.md): `app` embeds the wasm-bindgen product of `ui`, a member of the same workspace | linux-gnu + wasm | `app` builds and carries the wasm and its JS glue (`products-ui-dist`) |
| `same-workspace-products` | `app`'s build script runs `tool` from `nativeInputs`, `app` links `shared` from `inputs` and embeds `tool` through `env`; all three are products of one plan | linux-gnu | `app` builds and runs (`products-same-workspace-products`); with every value-carrying setting of `app` throwing, the other members' products evaluate to the same derivations (`repository-poisoned-settings`) |
| `stamps` | Git revision and `SOURCE_DATE_EPOCH` per package | linux-gnu | Only the stamped package's units change |
| `msvc` | C code, a resource via `rustc-link-arg-bins`, bindgen | x86\_64 msvc, aarch64 msvc | Builds; tests pass under wine |
| `wasm-browser` | wasm-bindgen, `ring`, getrandom backend cfg from config | wasm | Bindgen version matched; tests pass in Node, headless Chromium and headless Firefox |
| `wasm-component` | C via `wasilibc`, componentize, metadata stamp; `description`, `repository` and a workspace-inherited `license` in the manifest | wasm | Component has no imports; with no metadata set, the product's component has the manifest's name, description, licenses, source and version (`wasm-component-metadata`) |
| `static` | musl and static-glibc products, static-glibc non-PIE (`relocationModel = "static"`) | musl x2, host | No `INTERP` or `NEEDED`; build scripts dynamic; `.comment` names the linker rustc picks (lld for `-gnu`, GNU ld for musl), never rustc's own `rust-lld`; non-PIE runs with lld and GNU ld |
| `linker-kind-mold` | `targets.<host>.linkerKind = "mold"` | host | The product and the build script are linked by mold |
| `same-triple` | Target spec with a marker linker and marker env on the host triple | host | No host unit (build-script compile, proc macro, host run) sees either marker; target-platform build-script runs do see spec env |
| `variants` | Feature powerset, clippy, coverage, a custom profile that only inherits `release`, `testProfile`, a test that needs debug assertions | linux-gnu | Host units shared between build and clippy at the same profile; dependencies shared between check and clippy; no target units shared between build and coverage; all units shared between `release` and the custom profile; the test passes in the default `test` profile; build and test plans share their common units with `testProfile = "release"` and no dependency without |
| `cargo-config` | A variant's `cargoConfig`: `profile.release.panic = "abort"`, an `[env]` variable, `build.rustflags`, beside the target's own rustflags | linux-gnu | `-C panic=abort` on the variant's build-plan target units only, and its product aborts; the variable and both rustflags reach the product and its test run; keys breakbulk sets are refused |
| `post-link` | Custom stages, `mkForce null` on `strip`, a check on `linked` | linux-gnu, msvc | Stage order; check sees unstripped bytes |
| `source-paths` | Panics in dependencies, `splitDebug`, test binaries | linux-gnu | No source references in main outputs; `debug` references sources; editing a README in a package does not change its test binary |
| `manifest-dir` | A bin that keeps `env!("CARGO_MANIFEST_DIR")` in a string | linux-gnu | `noSourceReferences` fails naming the cause and `removeSourceReferences`; with that stage only hash bytes change, the check passes and the bin runs (`products-manifest-dir`) |
| `cdylib-debug` | A bin whose dependency is also a cdylib (`crate-type = ["lib", "cdylib"]`), `split-debuginfo = "packed"` and `"unpacked"` | linux-gnu | The bin's `linked` debug output holds its own `app.dwp` only (packed), or the `.dwo` files of the bin and the dependency (unpacked); the dependency's own `.dwp` stays in its product |
| `trim-paths` | `trim-paths = "all"` in the profile; a second workspace without the setting; a path crate outside both roots with generated code in `OUT_DIR` | linux-gnu, Cargo ≥ 1.101 (nightly) | Cargo's remaps used, none added; path crates outside the root hashed without absolute paths (one `-C metadata` in both workspaces and at two other skeleton locations; stable 1.99 refuses those locations); the project's setting and scope kept; the second workspace planned with trim-paths on (the planner reads that the project declares none) and scoped per product kind; `OUT_DIR` paths read `/cargo/build-dir/…`; products have no source references; the second workspace's debug output works in gdb; tests pass (`products-trim-paths`) |
| `doctests` | Doctests using a dev-dependency, one `should_panic`, an edition-2024 crate | linux-gnu, aarch64 | Doctests run; cross doctests run under the runner or skip with a reason |
| `doctest-off` | A library whose doctest fails; one whose doctests pass only with their own arguments and environment; both with a `smoke` integration test | linux-gnu | `test.doctest.enable = false` (from `memberDefaults`) leaves the failing doctest out of `repo.checks` and keeps the check groups; a package's `true` wins over it; `test.doctest` `args`, `env` and `postRun` reach the doctest run (`test-runs-doctest-settings`); `test.binaries.smoke.enable` the same way for one test binary (`test-runs-binary-enable`) |
| `doctest-false` | A proc macro with `test = false` and `doctest = false` and a dev-dependency on a library with a build script and a doctest; a proc macro with a test and a doctest | linux-gnu, aarch64 (plan only) | No doctest for the `doctest = false` library and nothing built for it; the other doctests' `-L` list names only the runs `cargo test` has; the proc macro's test and doctest run for the host (`test-runs-doctest-false`) |
| `cross-doctests` | A proc macro with a doctest and a unit test; a proc macro whose unit test runs under nextest; a library whose doctest and integration test use the first | aarch64 (qemu-user runner) | The proc macros' doctest and unit tests are the host's (no `--target`) and pass on the build machine without the runner, the unit test also as a test app; the library's doctest and integration test pass under qemu (`cross-doctests-aarch64`) |
| `test-control` | Tests that need network, `#[ignore]` tests, a skip list per binary | linux-gnu | Skipped tests do not run; changing a skip list re-runs only that test run; the test app runs the network test outside the sandbox |
| `test-threads` | A test that fails unless `RUST_TEST_THREADS` is 1; a second workspace whose `[env]` sets it | linux-gnu | The test passes with the value from `test.env`, `test.binaries.<bin>.env` and `[env]`, under libtest and nextest, in IFD and dynamic mode; with nothing set, the default is `$NIX_BUILD_CORES`; a nextest profile's `test-threads` wins over the default (`test-runs-test-threads`) |
| `test-closure` | A bin-only package whose build script builds a shared library that its bin loads by name, with a test that starts the bin; a library without build-script dependencies | linux-gnu | The bin's test passes (the library is on its dynamic-library path); nothing of the other package is in the closure of the library's test run or doctest (`test-runs-test-closure`) |
| `test-home` | A test and a doctest that write under `$HOME` and the user cache directory | linux-gnu | Both pass with no setting, in a fresh, empty home in `$TMPDIR` with `XDG_CACHE_HOME` unset; with `test.env.HOME = "/homeless-shelter"` both fail (`test-runs-home`) |
| `benches` | A libtest bench and a Criterion bench | linux-gnu | Bench binaries come from the bench variant only, built with the bench profile; the test plan has none; smoke checks pass with `--test` |

## Determinism and dogfooding

- `nix run .#test-rebuild` (`tests/rebuild`) checks that builds are bit-identical. For every fixture it builds the products, their stages and a sample of the units, then builds each again with `nix build --rebuild` and compares the bytes. See [Rebuild check](#rebuild-check).
- breakbulk builds itself (`tests/self-host`): its own binaries, built crate by crate through breakbulk, behave the same as the bootstrap build.

## Running the tests

- `nix develop -c cargo test` runs the Rust tests.
- `nix flake check` runs every flake check, the fixtures included. Some download the Windows SDK, build cross toolchains and run wine.
- `nix run .#test-dynamic`, `.#test-cutoff`, `.#test-options` and `.#test-linux-portable-container` run tests that need a Nix master build or extra downloads, so they are not flake checks.
- `nix run .#test-rebuild` runs the rebuild check. It builds every fixture twice, so it is not a flake check.

### Rebuild check

```sh
nix run .#test-rebuild                                    # every fixture, every target
nix run .#test-rebuild -- --list                          # the fixture names
nix run .#test-rebuild -- --targets x86_64-unknown-linux-gnu walking-skeleton directives
nix run .#test-rebuild -- --every 1 -- --max-jobs 2 --cores 4
```

| Option | Meaning |
| --- | --- |
| `--targets REGEX` | Only instances whose target triple matches. Default: every target. |
| `--every N` | Rebuild 1 in N units of each plan (default 4; 1 rebuilds all). |
| `--seed S` | Pick another sample. The sample is deterministic: the units with the lowest sha256 of seed, plan and unit id. |
| `-- …` | Options for every `nix` command. |

The catalog (`tests/rebuild/default.nix`) reuses the repositories the other tests configure for each fixture. A fixture that fails by design, or that builds nothing through breakbulk, is in `skipped` with the reason. The `rebuild-catalog` flake check fails when a fixture directory is in neither list.

The script exits non-zero when a fixture fails to evaluate or build, or when a rebuild differs. Reports go to `$WORK` (default `$TMPDIR/breakbulk-rebuild`), one directory per fixture. A differing output is kept as `<path>.check` next to the original, and `<name>.diff` holds `diffoscope` of the two (`diff -r` when diffoscope cannot be built). The next garbage collection removes the `.check` copies.

## CI environment

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and every pull request: `cargo fmt --check`, `cargo clippy -D warnings` and `cargo test` in both Cargo workspaces, and the flake checks listed in `.github/fast-checks`, on x86_64-linux with Determinate Nix and the FlakeHub cache. The other flake checks and the `nix run .#test-*` scripts are too heavy for hosted runners and run locally. The full suite needs:

- A stable Nix for IFD mode, and Nix master (until a release ships `builder-rpc-v0`) with `dynamic-derivations` and `ca-derivations` enabled for dynamic-derivation mode.
- A binary cache that stores realisations, for the CA island and embed tests.
- An aarch64 builder for native test runs. Without one, qemu-user through binfmt.
- wine, headless Chromium and headless Firefox for runners.
- `allowUnfree` scoped to the xwin SDK, for the msvc fixtures.

### Nix settings

The checks run with the evaluating Nix's settings. One setting changes what the tests see: `lazy-trees`. With `lazy-trees = true`, `builtins.fetchGit` returns a virtual store path. Most fixtures point git sources at local directories (`gitTrees`), which are never virtual. `git-multi-workspace-fetched` and `git-multi-workspace-fetched-reference` fetch their git source with `builtins.fetchGit`, so they cover this setting. To check both values, build them twice:

```sh
nix build .#checks.x86_64-linux.git-multi-workspace-fetched{,-reference}
nix build .#checks.x86_64-linux.git-multi-workspace-fetched{,-reference} --option lazy-trees false
```

CI covers both values. Its `lazy-trees` job builds `git-multi-workspace-fetched`, `git-multi-workspace-fetched-reference` and `products-source-paths` once with `lazy-trees = true` and once with `false`, and fails if a check's derivation path differs between the two. Its `lix` job evaluates and builds the two git checks with Lix, which has no lazy trees, and fails if Lix evaluates a different derivation from Determinate Nix. Every other CI check runs with the runner's default settings.
