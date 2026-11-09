# The unit builder

`breakbulk-unit` is the builder of every unit. It is a small, dependency-light Rust binary with two modes: `compile` and `run`. Test runs belong to products.

## Environment contract

A unit's environment is built in layers; later layers win, except for list-like variables (`PATH`, `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS`), where later layers append:

1. A fixed base: `HOME=/homeless-shelter`, `TMPDIR`, `NIX_BUILD_CORES`, `LC_ALL=C`, `TZ=UTC`.
2. The env capture for the unit's package and platform, or the base capture for the platform; for a unit that links, followed by the library search flags of the captures of the other packages it links (see [Environment capture](../explanation/internals/env-capture.md)).
3. Cargo's recorded env, after filtering.
4. The toolchain spec's env for the unit's platform.
5. The package override's env for the unit's platform.

Nothing from the planner's environment reaches a unit.

## `compile`

1. Read `BREAKBULK_UNIT` and set up the environment contract. Replace `NUM_JOBS` with `$NIX_BUILD_CORES`.
2. Build a dependency directory: `$TMPDIR/deps` with symlinks to the crate files of every transitive dependency (`rmeta` for units that do not link, `rlib` for units that do). Pass one `-L dependency=$TMPDIR/deps`. This replaces Cargo's single shared `deps` directory (classic layout) or its one `-L dependency=` per dependency (new layout), and keeps argv short.
  - A library unit's derivation names only its **direct** dependencies. Each library's `rmeta` output holds a manifest, `breakbulk-deps.json`: its own `.rmeta`, the proc macros it names directly, the `flags` directories of the build scripts whose search paths it was given that no manifest below names, and its direct dependencies' `rmeta` directories. Nix's reference scanning therefore puts everything below a unit into its sandbox, and `breakbulk-unit` walks the manifests to fill the dependency directory. Splices of runs a manifest below names are written into the unit as paths without being inputs (weak references in `units.json`). Each manifest names only what is new at its level, so the graph's input edges and references grow with its edges, not with the sum of its closures (see `docs/spikes/scale.md`).
  - Units that link (bins, tests, proc macros, cdylibs, build scripts) and doctests still name every `rlib` as an input. An `rlib` output cannot carry such a manifest: Nix records references only to paths in the builder's input closure, and a library compile has only `rmeta` inputs. `rlib` outputs carry no references, so fetching an `rmeta` never fetches an `rlib`.
  - When both Cargo and rustc are nightly, Cargo passes `-Zembed-metadata=no`: rlibs carry no metadata, and dependents get both `--extern name=lib….rlib` and `--extern name=lib….rmeta`. Units that link then also take every `rmeta` below them from the manifests.
3. Expand splice points from each referenced run's `flags` output, using the sentinel table and the value-dependent rules below. Set the dynamic-library path from the unit's dynamic-path splices (the host plugin dependencies' runs).
4. Add path remapping, unless the plan already carries Cargo's own remaps (`trimPaths`): map every source view, crate source and upstream `OUT_DIR` to a stable name (`<name>-<version>` for crates, the package's path from the repository root for workspace members), with the scope for the unit's product kind (see below). With Cargo's remaps and `trimPathsDefault`, add only the scope.
5. Point `--out-dir` at `$TMPDIR/out` and run the recorded program.
6. Parse rustc's JSON diagnostics from stderr, print each `rendered` field, and drop artifact notifications. Without this, build logs are unreadable JSON.
7. Move outputs into place: `.rmeta` to `$rmeta`, `.rlib` to `$rlib`, binaries and cdylibs to `$out`. Discard dep-info. Debuginfo side files (`.dwp` with `split-debuginfo=packed`, `.dwo` with `unpacked`, and `.pdb` and `.dSYM` on other platforms) are not in the plan's output list, because `--print=file-names` does not name them. They are collected by scanning `$TMPDIR/out` for `.pdb`, `.dwp` and `.dwo` files and moved, under rustc's names, to the unit's `debug` output; units without one (host units, libraries outside the `.dwo` case, and any unit the rule above says writes none) discard them with a warning.

## `run` (build scripts)

1. Set up the environment contract. `OUT_DIR` is inside `$out`, at the path the traced Cargo gave it relative to its target directory (`RunUnit.out_dir`: `<triple>/<profile>/build/<pkg>-<hash>/out`, or `…/build/<pkg>/<hash>/out` in the new layout), empty and writable. The `out` thus copies Cargo's target directory around `OUT_DIR`, with `<profile>/deps` and `<profile>/examples` in the classic layout, where Cargo creates them before running build scripts. A script that walks up from `OUT_DIR` to the target directory (tauri-build, sdl2-sys `bundled`, ort-sys `copy-dylibs`) then writes inside `$out` and behaves as under the traced Cargo, failing where that Cargo fails (#23, [spike](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/out-dir-layout.md)). References to the run's `out` name this copy of the target directory, so they read `<out>/<OUT_DIR relative>/…`.
2. For each unit in `metadataFrom`, read its `flags/metadata.json` and set `DEP_<LINKS>_<KEY>`, uppercased with `-` mapped to `_`, as Cargo does. Set the dynamic-library path from the run's dynamic-path splices (the runs of packages its build script depends on).
3. Execute the script from its compile unit's output, with the package source as the working directory. The source is read-only, as it is in any Nix build.
4. Parse stdout. Write `$flags/directives.json` (values grouped by kind, in printed order), `$flags/metadata.json` when the package declares `links`, and `$flags/target-files.json` when the script wrote files into `$out` outside `OUT_DIR` (their paths relative to `$out`). `directives.json` then also names the copies of `<profile>` and `<profile>/deps` that hold such files (`targetDirs`), and test runs put them on the dynamic-library path after the search paths, as `cargo test` does with `target/<profile>` and `deps` (`Compilation::fill_env`), so a library a script copies next to the binaries is found.
5. Fail on a non-zero exit, on death by signal (with the signal named), and on any `error` directive. Print `warning` directives.
6. Check every `rerun-if-changed` path against the sandbox. On failure, add a hint for each missing path naming the package option to add it to; likewise for `rerun-if-env-changed` variables that are unset. On success, warn about missing paths, or fail when `strictSources` is set.
7. Remove CMake's internal state: in every directory of `$out` that holds both `CMakeCache.txt` and `CMakeFiles/` (the `cmake` crate's `$OUT_DIR/build`), delete `CMakeFiles`. Its configure log names randomly named try-compile directories, so the run would not be reproducible, and nothing reads it after the script (the `cmake` crate reads its build tree back only within one run). The rest of the tree stays, because crates link from it.

## Directive parsing

Build-script output is a documented, line-based format: `cargo::KEY=VALUE`, or the older `cargo:KEY=VALUE`. Lines without the prefix are ignored. Values are opaque strings and are never interpreted beyond the splitting below.

| Key | Parsing | Wrapping |
| --- | --- | --- |
| `rustc-cfg` | Value as is | `--cfg <value>` |
| `rustc-check-cfg` | Value as is | `--check-cfg <value>` |
| `rustc-env` | Split on the first `=` | Env var on the compile |
| `rustc-link-lib` | Value as is | `-l <value>` |
| `rustc-link-search` | Value as is | `-L <value>` |
| `rustc-link-arg` and its target-specific forms | Value as is; `-bin=` splits `NAME=ARG` | `-C link-arg=<value>` |
| `rustc-flags` | Split on whitespace into `-l` and `-L` parts; anything else is an error | Joins the `rustc-link-lib` and `rustc-link-search` lists in printed order |
| `metadata` | Split on the first `=` | `DEP_<LINKS>_<KEY>` for dependents' runs |
| Unknown key, `cargo:` syntax | Treated as `metadata` | As `metadata` |
| Unknown key, `cargo::` syntax | Error | — |
| `warning`, `error` | Message | Printed; `error` fails the run |
| `rerun-if-changed`, `rerun-if-env-changed` | Path or variable | Used only by the sandbox check |

The wrapping column is also what the planner asserts against Cargo's placement of sentinels on every trace.

**Validations copied from Cargo:** `rustc-env` may not set `RUSTC_BOOTSTRAP`; `rustc-link-arg-bin=NAME=` must name an existing bin target; `rustc-flags` accepts only `-l` and `-L`.

**Value-dependent rules**, each implemented explicitly and tested:

- **Search-path order.** For one compile, Cargo collects the search paths of every run in dependency order, then stable-sorts them: paths inside the printing run's own `OUT_DIR` first, all others after. Search paths from `links` overrides always count as outside. At an inside splice, put R's values that lie inside R's `out`, in printed order; at an outside splice, R's other values, in printed order.
- **Link arguments.** All `rustc-link-arg*` kinds of one run share one list in printed order. A link-arg splice emits the run's values whose kind is in its `kinds`, in that order.
- **Doctest search paths.** A `searchPathsOf` splice emits the search paths of all listed runs, both classes, deduplicated and sorted by value. The values are the real store paths at build time, so the order is computed then, not copied from the trace.
- **Dynamic-library paths** keep only values inside the printing run's own `out` or inside the `out` of a run whose `DEP_*` metadata it received, decided once when the run's output is parsed (`LibraryPath::for_dylib_path`). The same rule serves compiles, runs, test processes and `rustdoc --test`. It stands in for Cargo's rule, which keeps paths lexically inside the artifact directory of the platform (`target/<triple>/<profile>`, `filter_dynamic_search_path` in `src/compiler/mod.rs`). A path into another run's `out` reached by a route other than `DEP_*` would be missed; a survey of popular crates found none ([research](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/research-coverage-and-libpath.md)).
- Duplicate values within one kind are kept in printed order, as Cargo does.
- `rustc-flags` splitting, as above.

## Source paths at run time

Path remapping uses rustc's `--remap-path-scope` (stable since 1.95; the toolchain's `remapPathScope` capability):

| Unit | Scope |
| --- | --- |
| Non-test units of a target with `debugInfo = "split"` | `macro,diagnostics` (plus `coverage` in coverage variants); debug info keeps store paths |
| Test binaries, and every unit of a target with `debugInfo = "keep"` or `"strip"` | All scopes |
| Any unit, with a rustc without `--remap-path-scope` (older than 1.95, or `remapPathScope = false`) | All scopes (no scope flag) |

What happens to debug info is one property of the target: `targets.<triple>.debugInfo`, `"split"`, `"keep"` or `"strip"`, by default the traits' `debugInfo` (`"split"` on Linux ELF targets, `"keep"` elsewhere: msvc's `.pdb` is a separate file already, and wasm has no splitting stage). Three things follow from it (`products.debugInfoOf`): the stage it puts first after `linked` in every product of the target (`splitDebug` for `"split"`, `strip`, that is `strip --strip-debug`, for `"strip"`, none for `"keep"`), the scope above, and `NIX_SET_BUILD_ID` on target units (the GNU build ID splitDebug needs, only for `"split"`). `"split"` and `"strip"` need an ELF target, or evaluation fails. Units are shared by every package of the target, so no `stages` setting, the target's or a package's, may remove the inserted stage (that would leave real source paths in the product) or add `splitDebug` where the target does not split (its links have no build ID and remap every path): either is an evaluation error naming `debugInfo`. Overriding the inserted stage's attributes (its `run`, `after`) is allowed, and a stage of another name (an extra `strip { all = true; }` after `splitDebug`) is an ordinary stage. 

When Cargo's `trim-paths` is in effect, Cargo's own remaps are used instead, and breakbulk adds none of its own, because rustc picks one remap when several match. The scope is Cargo's when the project set trim-paths, and the table's when the planner did (`trimPathsDefault`). Build-script runs' C prefix maps then use Cargo's names ([trim-paths](../explanation/internals/planner.md#trim-paths)). With `sourcePaths = "keep"` nothing is remapped by breakbulk at all.

`CARGO_MANIFEST_DIR` must be the real source-view store path: crates use it in `include_str!(concat!(env!("CARGO_MANIFEST_DIR"), …))` and in build scripts. Remapping does not rewrite `env!` values, so a binary can still retain a source store path. Every product therefore gets a default check that fails when its main output references a source path. The `debug` output is allowed to.
