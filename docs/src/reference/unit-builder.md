# The unit builder

`breakbulk-unit` is the builder of every unit. It is a small Rust binary
with few dependencies and two modes:

- `compile`: one rustc call;
- `run`: one build-script run.

Test runs are not units; they belong to [products](../explanation/products.md).

## Environment contract

A unit's environment is built in layers. Later layers win, except for
list-like variables (`PATH`, `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS`), where
later layers append.

| Layer | Contents |
| --- | --- |
| 1. Fixed base | `HOME=/homeless-shelter` (doctests: `HOME=$TMPDIR/home`, a fresh, empty directory), `TMPDIR`, `NIX_BUILD_CORES`, `NIX_BUILD_TOP`, `NIX_STORE`, `LC_ALL=C`, `TZ=UTC`, `SOURCE_DATE_EPOCH=315532800` |
| 2. Env capture | The capture for the unit's package and platform, or the platform's base capture. A unit that links then adds the library search flags of the captures of the other packages it links ([Environment capture](../explanation/internals/env-capture.md)). |
| 3. Cargo's env | Cargo's recorded env, after filtering |
| 4. Toolchain spec | The spec's env for the unit's platform |
| 5. Package override | The package's `env` for the unit's platform |

Nothing from the planner's environment reaches a unit.

`HOME` does not exist in compiles and build-script runs, so a build that
writes to its home fails. Doctests are tests, so they get a writable home
as under `cargo test`. No `XDG_*` variable is set, so tools fall back to
directories under `HOME`. The package's `test.env` goes over all layers
of a doctest and can set `HOME` back to `/homeless-shelter`. Test runs
set up the same home in their own derivation
([Tests](../explanation/products.md#tests)).

## `compile`

1. Read `BREAKBULK_UNIT` and set up the environment contract. Replace
   `NUM_JOBS` with `$NIX_BUILD_CORES`.
2. Build a dependency directory (details below): `$TMPDIR/deps`, with
   symlinks to the crate files of every transitive dependency (`rmeta`
   for units that do not link, `rlib` for units that do). Pass one
   `-L dependency=$TMPDIR/deps`.
3. Expand splice points from each referenced run's `flags` output, using
   the [sentinel table](sentinels.md) and the
   [value-dependent rules](#value-dependent-rules). Set the
   dynamic-library path from the unit's dynamic-path splices (the runs of
   its host plugin dependencies).
4. Add path remapping, unless the plan already carries Cargo's own remaps
   (`trimPaths`). Map every source view, crate source and upstream
   `OUT_DIR` to a stable name, with the scope for the unit's product kind
   ([Source paths at run time](#source-paths-at-run-time)):
   - crates: `<name>-<version>`;
   - workspace members: the package's path from the repository root.

   With Cargo's remaps and `trimPathsDefault`, add only the scope.
5. Point `--out-dir` at `$TMPDIR/out` and run the recorded program.
6. Parse rustc's JSON diagnostics from stderr, print each `rendered`
   field, and drop artifact notifications. Without this, build logs are
   unreadable JSON. If rustc fails and its output names a path under one
   of the unit's `testOnly` paths (test-only paths its source view leaves
   out), add a hint naming the option that keeps the path.
7. Move outputs into place (details below): `.rmeta` to `$rmeta`, `.rlib`
   to `$rlib`, binaries and cdylibs to `$out` (a bin under the name the
   plan's `uplifted` gives it), debuginfo side files to `$debug`. Discard
   dep-info.

### The dependency directory

`$TMPDIR/deps` replaces Cargo's single shared `deps` directory (classic
layout) or its one `-L dependency=` per dependency (new layout), and keeps
argv short.

- **Libraries name only their direct dependencies.** Each library's `rmeta`
  output holds a manifest, `breakbulk-deps.json`, naming:
  - its own `.rmeta`;
  - the proc macros it names directly;
  - the `flags` directories of the build scripts whose search paths it was
    given, when no manifest below names them;
  - its direct dependencies' `rmeta` directories.

  Nix's reference scanning therefore puts everything below a unit into
  its sandbox, and `breakbulk-unit` walks the manifests to fill the
  dependency directory. Splices of runs that a manifest below names are
  written into the unit as paths without being inputs (weak references in
  `units.json`). Each manifest names only what is new at its level, so the
  graph's input edges and references grow with its edges, not with the sum
  of its closures (the [scale
  spike](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/scale.md)).
- **Units that link name every `rlib`.** Bins, tests, proc macros,
  cdylibs, build scripts and doctests still list every `rlib` as an input.
  An `rlib` output cannot carry a manifest: Nix records references only to
  paths in the builder's input closure, and a library compile has only
  `rmeta` inputs. `rlib` outputs carry no references, so fetching an
  `rmeta` never fetches an `rlib`.
- **Nightly `-Zembed-metadata=no`.** When both Cargo and rustc are nightly,
  Cargo passes `-Zembed-metadata=no`: rlibs carry no metadata, and
  dependents get both `--extern name=lib….rlib` and
  `--extern name=lib….rmeta`. Units that link then also take every
  `rmeta` below them, from the manifests.

### Debuginfo side files

`.dwp` (`split-debuginfo=packed`), `.dwo` (`unpacked`), `.pdb` and `.dSYM`
are not in the plan's output list, because `--print=file-names` does not
name them.

- They are collected by scanning `$TMPDIR/out` for `.pdb`, `.dwp` and
  `.dwo` files, and moved, under rustc's names, to the unit's `debug`
  output.
- Units without a `debug` output discard them with a warning: host units,
  libraries outside the `.dwo` case, and any unit the target's traits say
  writes none.

## `run` (build scripts)

1. Set up the environment contract, with `OUT_DIR` inside `$out`
   (details below), empty and writable.
2. For each unit in `metadataFrom`, read its `flags/metadata.json` and set
   `DEP_<LINKS>_<KEY>`, uppercased with `-` mapped to `_`, as Cargo does.
   Set the dynamic-library path from the run's dynamic-path splices (the
   runs of packages its build script depends on).
3. Run the script from its compile unit's output, with the package
   source as the working directory. The source is read-only, as in any Nix
   build.
4. Parse stdout and write `$flags` (details below).
5. Fail on a non-zero exit, on death by signal (naming the signal), and on
   any `error` directive. Print `warning` directives.
6. Check every `rerun-if-changed` path against the sandbox.
   - On failure, add a hint for each missing path, naming the package
     option to add it to, then the [failure hints](#failure-hints), and
     a hint for each test-only path the script's output names, as for
     compiles.
   - On success, warn about missing paths, or fail when
     [`strictSources`](options/repository.md#strictsources) is set.
7. Remove CMake's internal state (details below).

### Failure hints

A failed run gets hints after its stdout. The script's stdout, its
streamed stderr and the repeated stderr tail are never changed.

Some crates fail in a recognizable way when a tool or library is missing
from the sandbox. A hint is added when the script printed the crate's
error and the crate also left its fingerprint. The hint quotes the line
it matched:

| Crate | Error | Fingerprint | Hint |
| --- | --- | --- | --- |
| `pkg-config` | `The pkg-config command could not be found.` | declares `PKG_CONFIG*` or `*_NO_PKG_CONFIG` | `nativeInputs = p: [ p.pkg-config ];` |
| `pkg-config` | ``The system library `X` … was not found`` | as above | add the package that provides `X` to `inputs` |
| `cc` | `failed to find tool "X"` | declares `CC*`, `CFLAGS*` or `CXX*` | add the package that provides `X` to `nativeInputs` |
| `bindgen`, `clang-sys` | `Unable to find libclang` | declares `BINDGEN_EXTRA_CLANG_ARGS*` or `LIBCLANG_PATH`, or clang-sys's `llvm-config` warning | `nativeInputs = p: [ p.rustPlatform.bindgenHook ];` |
| `openssl-sys` | `Could not find directory of OpenSSL installation` | declares `*OPENSSL_*` | `inputs = p: [ p.openssl ];` and `nativeInputs = p: [ p.pkg-config ];` |
| `prost-build` | ``Could not find `protoc` `` | its `docs.rs/prost-build` link | `nativeInputs = p: [ p.protobuf ];` |
| `cmake` | ``is `cmake` not installed?`` | its `CMAKE… = …` lines | `nativeInputs = p: [ p.cmake ];` |

Unset `rerun-if-env-changed` variables come last:

- Those of a crate whose failure was recognized are counted, not listed
  ("17 unset variables of the `pkg-config` crate omitted"). They are
  normally left unset.
- The rest go on one line, with the `packages.<name>.env` option to set
  them.

The table is built into `breakbulk-unit` and is not configurable: a user
table would be an input of every build-script run.

### `OUT_DIR` and the target directory

`OUT_DIR` is at the path the traced Cargo gave it relative to its target
directory (`RunUnit.out_dir`):

- classic layout: `<triple>/<profile>/build/<pkg>-<hash>/out`;
- new layout: `…/build/<pkg>/<hash>/out`.

So `$out` copies Cargo's target directory around `OUT_DIR`, including
`<profile>/deps` and `<profile>/examples` in the classic layout, which
Cargo creates before running build scripts. A script that walks up from
`OUT_DIR` to the target directory (tauri-build, sdl2-sys `bundled`,
ort-sys `copy-dylibs`) then writes inside `$out` and behaves as under the
traced Cargo, failing where that Cargo fails
([#23](https://github.com/schlarpc/breakbulk/issues/23), [out-dir
spike](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/out-dir-layout.md)).

References to the run's `out` name this copy of the target directory, so
they read `<out>/<OUT_DIR relative>/…`.

### The `flags` output

| File | Written when | Contents |
| --- | --- | --- |
| `directives.json` | always | Values grouped by kind, in printed order |
| `metadata.json` | the package declares `links` | The `metadata` values, for dependents' `DEP_*` |
| `target-files.json` | the script wrote files into `$out` outside `OUT_DIR` | Their paths, relative to `$out` |

When there are such target files, `directives.json` also names the copies
of `<profile>` and `<profile>/deps` that hold them (`targetDirs`). Test
runs put those on the dynamic-library path after the search paths, as
`cargo test` does with `target/<profile>` and `deps`
(`Compilation::fill_env`), so a library a script copies next to the
binaries is found.

### CMake state

In every directory of `$out` that holds both `CMakeCache.txt` and
`CMakeFiles/` (the `cmake` crate's `$OUT_DIR/build`), `CMakeFiles` is
deleted:

- its configure log names randomly named try-compile directories, so the
  run would not be reproducible;
- nothing reads it after the script (the `cmake` crate reads its build tree
  back only within one run).

The rest of the tree stays, because crates link from it.

## Directive parsing

Build-script output is a documented, line-based format: `cargo::KEY=VALUE`,
or the older `cargo:KEY=VALUE`. Lines without the prefix are ignored.
Values are opaque strings and are never interpreted beyond the splitting
below.

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

The wrapping column is also what the planner asserts against Cargo's
placement of sentinels on every trace.

**Validations copied from Cargo:**

- `rustc-env` may not set `RUSTC_BOOTSTRAP`;
- `rustc-link-arg-bin=NAME=` must name an existing bin target;
- `rustc-flags` accepts only `-l` and `-L`.

### Value-dependent rules

Each is implemented explicitly and tested.

| Rule | Behavior |
| --- | --- |
| Search-path order | For one compile, Cargo collects the search paths of every run in dependency order, then stable-sorts them: paths inside the printing run's own `OUT_DIR` first, all others after. Search paths from `links` overrides always count as outside. At an inside splice, put R's values that lie inside R's `out`, in printed order; at an outside splice, R's other values, in printed order. |
| Link arguments | All `rustc-link-arg*` kinds of one run share one list in printed order. A link-arg splice emits the run's values whose kind is in its `kinds`, in that order. |
| Doctest search paths | A `searchPathsOf` splice emits the search paths of all listed runs, both classes, deduplicated and sorted by value. The values are the real store paths at build time, so the order is computed then, not copied from the trace. |
| Dynamic-library paths | Keep only values inside the printing run's own `out`, or inside the `out` of a run whose `DEP_*` metadata it received, decided once when the run's output is parsed (`LibraryPath::for_dylib_path`). |
| Duplicates | Duplicate values within one kind are kept in printed order, as Cargo does. |
| `rustc-flags` | Split as in the table above. |

The dynamic-library rule serves compiles, runs, test processes and
`rustdoc --test`. It stands in for Cargo's rule, which keeps paths
lexically inside the platform's artifact directory
(`target/<triple>/<profile>`, `filter_dynamic_search_path` in
`src/compiler/mod.rs`). A path into another run's `out` reached by a route
other than `DEP_*` would be missed; a survey of popular crates found none
([research](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/research-coverage-and-libpath.md)).

## Source paths at run time

Path remapping uses rustc's `--remap-path-scope` (stable since 1.95; the
toolchain's
[`remapPathScope`](options/workspaces.md#workspacesnametoolchaincapabilitiesremappathscope)
capability):

| Unit | Scope |
| --- | --- |
| Non-test target units of a target with `debugInfo = "split"` | `macro,diagnostics` (plus `coverage` in coverage variants); debug info keeps store paths |
| Test binaries, and every target unit of a target with `debugInfo = "keep"` or `"strip"` | All scopes |
| Host units (build scripts, proc macros), on every target | `macro,diagnostics`. They never ship, so `debugInfo` doesn't apply, and one build serves every target |
| Any unit, with a rustc without `--remap-path-scope` (older than 1.95, or `remapPathScope = false`) | All scopes (no scope flag) |

### `debugInfo`

What happens to debug info is one property of the target:
[`targets.<triple>.debugInfo`](options/targets.md#targetsnamedebuginfo),
`"split"`, `"keep"` or `"strip"`. By default it is the traits' `debugInfo`:
`"split"` on Linux ELF targets, `"keep"` elsewhere (msvc's `.pdb` is a
separate file already, and wasm has no splitting stage).

Three things follow from it (`products.debugInfoOf`):

| `debugInfo` | Stage first after `linked` | Remap scope of target units | `NIX_SET_BUILD_ID` on target units |
| --- | --- | --- | --- |
| `"split"` | `splitDebug` | `macro,diagnostics` (table above) | yes (the GNU build ID `splitDebug` needs) |
| `"strip"` | `strip` (`strip --strip-debug`) | all | no |
| `"keep"` | none | all | no |

- `"split"` and `"strip"` need an ELF target, or evaluation fails.
- Units are shared by every package of the target, so no `stages`
  setting, the target's or a package's, may:
  - remove the inserted stage (that would leave real source paths in the
    product), or
  - add `splitDebug` where the target does not split (its links have no
    build ID and remap every path).

  Either is an evaluation error naming `debugInfo`.
- Overriding the inserted stage's attributes (its `run`, `after`) is
  allowed, and a stage of another name (an extra
  `strip { all = true; }` after `splitDebug`) is an ordinary stage.

### Cargo's trim-paths and `sourcePaths`

- When Cargo's `trim-paths` is in effect, Cargo's own remaps are used,
  and breakbulk adds none of its own, because rustc picks one remap when
  several match.
- The scope is Cargo's when the project set trim-paths, and the table's
  when the planner did (`trimPathsDefault`).
- Build-script runs' C prefix maps then use Cargo's names
  ([trim-paths](../explanation/internals/planner.md#trim-paths)).
- With `sourcePaths = "keep"`, breakbulk remaps nothing at all.

### `CARGO_MANIFEST_DIR`

`CARGO_MANIFEST_DIR` must be the real source-view store path: crates use
it in `include_str!(concat!(env!("CARGO_MANIFEST_DIR"), …))` and in build
scripts. Remapping does not rewrite `env!` values, so a binary can still
retain a source store path. Every product therefore gets a default check
that fails when its main output references a source path. The `debug`
output is allowed to.
