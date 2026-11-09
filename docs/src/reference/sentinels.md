# Sentinel directives

Each stub prints one tagged directive of every kind that applies to its package. The tag `R` is the run's hash from its `OUT_DIR`: `build/<pkg>-<hash>/out`, or `build/<pkg>/<hash>/out` in the new build-directory layout. This table is the authoritative list of sentinels, their shapes and where Cargo places them. Placement is identical on every Cargo release tested (1.95 to 1.101); the evidence and source citations are in [spike A's wrapping table](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/A-trace-fidelity.md#wrapping-table).

"R's package" is the package whose build script is run R. A run's values reach only units of the run's own platform (host or target), except the dynamic-library paths in the last rows.

| Kind | Sentinel printed | Printed when | Shape in traced argv or env | Reaches |
| --- | --- | --- | --- | --- |
| `rustc-cfg` | `__bb_R_cfg` | Always | `--cfg __bb_R_cfg` | Every compile of R's package (lib, bins, examples, tests, benches, all test harnesses) and its `rustdoc --test`. Not its own build script. |
| `rustc-check-cfg` | `cfg(__bb_R_ccfg)` | Always | `--check-cfg cfg(__bb_R_ccfg)` | Same as `rustc-cfg`. |
| `rustc-env` | `__BB_R_ENV=__bb_R_env` (`R` uppercased in the name) | Always | Env var `__BB_R_ENV` on the process | Same as `rustc-cfg`. |
| `rustc-link-search`, inside `OUT_DIR` | `native=<OUT_DIR>/__bb_R_search` | Always | `-L native=<OUT_DIR>/__bb_R_search` | Every compile of R's package and of every package that depends on it on the same platform, any crate type. For a host run (build dependency, proc macro): the compiles of its dependents' build scripts. |
| `rustc-link-search`, outside `OUT_DIR` | `native=/__bb_R_search_ext` | Always | `-L native=/__bb_R_search_ext` | Same as above. |
| `rustc-link-lib` | `__bb_R_lib` | Always | `-l __bb_R_lib` | R's package only: its lib (every lib crate type, proc macro included) and lib test harness; its bins, tests, examples and benches only when the package has no lib. Never `rustdoc --test`. |
| `rustc-link-arg` | `__bb_R_arg` | Always | `-C link-arg=__bb_R_arg` | Every compile of R's package, including rlib-only libs, the lib test harness, proc macros, and its `rustdoc --test`. |
| `rustc-link-arg-bins` | `__bb_R_arg_bins` | The package has a bin | `-C link-arg=__bb_R_arg_bins` | R's bins and their test harnesses. |
| `rustc-link-arg-bin` | `NAME=__bb_R_arg_bin_NAME` | For each bin | `-C link-arg=__bb_R_arg_bin_NAME` | That bin and its test harness. |
| `rustc-link-arg-tests` | `__bb_R_arg_tests` | The package has an integration test | `-C link-arg=__bb_R_arg_tests` | Integration tests only, not lib or bin harnesses. |
| `rustc-link-arg-examples` | `__bb_R_arg_examples` | The package has an example | `-C link-arg=__bb_R_arg_examples` | Examples. |
| `rustc-link-arg-benches` | `__bb_R_arg_benches` | The package has a bench | `-C link-arg=__bb_R_arg_benches` | Benches (bench variant only). |
| `rustc-link-arg-cdylib` | `__bb_R_arg_cdylib` | Always | `-C link-arg=__bb_R_arg_cdylib` | R's lib when built as a cdylib, not in test mode; also the cdylibs of packages that depend on R's package, a compatibility exception Cargo keeps (rust-lang/cargo#9562; `add_native_deps` in `src/compiler/mod.rs`), which the directive differential test exercises. Printed even when R's package has no cdylib, for those dependents. |
| `metadata` | `__bb=R` | The package declares `links` | Env var `DEP_<LINKS>___BB=R` on runs | Build-script runs of packages that **directly** depend on R's package as a normal dependency. Not transitive, and not through build dependencies. |
| Dynamic-library path of a compile | (the inside search sentinel) | — | `LD_LIBRARY_PATH` entry `<OUT_DIR>/__bb_R_search` on the rustc process | Compiles whose package has R's package as a host plugin dependency (a proc macro, or a build dependency with a build script). |
| Dynamic-library path of a run | (same) | — | `LD_LIBRARY_PATH` entry on the run | Runs whose build script depends on R's package. |
| Dynamic-library path of a test process | (same) | — | `LD_LIBRARY_PATH` entries | **Every** run of the test's platform, not only dependencies. |
| Dynamic-library path of `rustdoc --test` | (same) | — | `LD_LIBRARY_PATH` entries | Every host run. |
| Search paths of `rustdoc --test` | both search sentinels | — | `-L native=…` | **Every** run in the invocation, both platforms, both sentinels, **sorted by value** and deduplicated. Not positional. |

Cargo rejects `rustc-link-arg-bins`, `-bin=NAME`, `-tests`, `-examples` and `-benches` when the package has no such target, so the stub prints them only when the target exists. `rustc-link-arg` is printed always, because Cargo passes it to every compile of the package; so is `rustc-link-arg-cdylib`, which Cargo accepts without a cdylib target (with a warning) and passes to dependents' cdylibs. The outside search sentinel is a root-level path that no real build uses, so the forbidden-literal check catches a missed splice. Stubs use the `cargo:` single-colon syntax when the package's `rust-version` predates the `cargo::` syntax (1.77). Shapes are the same in both syntaxes.

The planner then:

1. Finds every sentinel token in recorded argv and env.
2. Checks that each appears in the exact shape the table expects (for example `-l`, `__bb_R_lib`). Any other shape fails the plan, naming the Cargo version, the kind and the arguments seen.
3. Replaces sentinels with splice points in the plan:
   - `rustc-cfg`, `rustc-check-cfg`, `rustc-link-lib` and `rustc-env`: one splice per sentinel, "run R's values of kind K go here".
   - `rustc-link-search`: one splice per sentinel, "run R's search paths inside R's `out` go here" for the inside sentinel and "R's other search paths go here" for the outside one. A literal `-L` from a `links` override stays where Cargo put it, between them.
   - Link arguments: in a unit's argv, all of run R's link-arg sentinels are adjacent. The planner replaces the whole group with one splice that records the set of link-arg kinds present. That set is exactly the set of kinds that apply to the unit.
   - In `rustdoc --test`, the planner replaces the whole set of sentinel `-L native=` arguments with one splice that lists every run in the invocation.
4. Turns `DEP_<LINKS>___BB=R` in a dependent stub's env into a metadata edge from run R.
5. Turns sentinel search paths found in dynamic-library path variables of compiles, runs, tests and `rustdoc --test` into dynamic-path splice points.
6. Fails the plan if any sentinel token is left unconverted.

The expected shapes are pinned by golden tests per Cargo release.
