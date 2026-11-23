# The unit builder

`breakbulk-unit` is the builder of every compile and build-script-run
unit. It is a small Rust binary with few dependencies. It takes no
arguments: it reads one rendered value from `BREAKBULK_UNIT` (or the file
`BREAKBULK_UNITPath`, when the derivation passes it with `passAsFile`) and
does what its `kind` says. Two more builders over the same library read
their value the same way, so that a change to them does not rebuild every
unit:

- `compile`: one rustc call (`breakbulk-unit`);
- `run`: one build-script run (`breakbulk-unit`);
- `doctest`: a library's doctests, one `rustdoc --test`
  (`breakbulk-doctest`);
- `docs`: a doc plan's documentation, every traced `rustdoc` command in
  turn, each as a compile with no outputs, with `-o $out` and its own
  dependency directory
  ([Documentation](../explanation/internals/products.md#documentation))
  (`breakbulk-docs`).

Everything a value carries only to explain a failure (the unit's source
view, the repository paths of a registry or git crate, a build-script
run's table of [failure hints](#failure-hints)) is under its
`hints`.

Test runs are not units; they belong to [products](../explanation/products.md).

## Environment contract

A unit's environment is built in layers. A later layer's value replaces
the earlier one, or is appended to it:

- Cargo's recorded env (layer 3) appends for the list variables of the
  table below, and replaces otherwise.
- Layers 4 and 5 say it per variable: a setting given as a string
  replaces, the env capture's value included; one given as a list is
  appended, its values joined with the variable's separator. Lists from
  every settings layer concatenate. The rendered unit carries these
  layers as they are (`envLayers`, each value with its separator, empty
  for a replacing one), and `breakbulk-unit` folds them over layer 3,
  then the result over layer 2: whether a value is a list is known only
  when instantiation's values are, since a value can be a product of the
  plan.

A string that replaces a captured value that looks like a list (it holds
`:` and `/nix/store`) gets a warning: `env.PATH = "…"` drops the capture's
tools, where `env.PATH = [ "…" ]` adds to them.

| Layer | Contents |
| --- | --- |
| 1. Fixed base | `HOME=/homeless-shelter` (doctests: `HOME=$TMPDIR/home`, a fresh, empty directory), `TMPDIR`, `NIX_BUILD_CORES`, `NIX_BUILD_TOP`, `NIX_STORE`, `LC_ALL=C`, `TZ=UTC`, `SOURCE_DATE_EPOCH=315532800` |
| 2. Env capture | The capture for the unit's package and platform, or the platform's base capture. A unit that links then adds the library search flags of the captures of the other packages it links ([Environment capture](../explanation/internals/env-capture.md)). |
| 3. Cargo's env | Cargo's recorded env, after filtering |
| 4. Toolchain spec | The spec's env for the unit's platform |
| 5. Package override | The package's `env` for the unit's platform |

Nothing from the planner's environment reaches a unit.

### List variables

The built-in separators (`crates/breakbulk-unit/src/env-separators.json`,
which the Nix library reads too). The `_FOR_BUILD` and `_FOR_TARGET` forms
setup hooks write for other platform offsets take their base name's. A
variable not in the table joins its lists with `:`; `envSeparators.<name>`
(of a package's settings, or of `targets.<triple>`) sets another, one
character.

| Variable | Separator |
| --- | --- |
| `ACLOCAL_PATH` | `:` |
| `BINDGEN_EXTRA_CLANG_ARGS` | a space |
| `CMAKE_INCLUDE_PATH` | `:` |
| `CMAKE_LIBRARY_PATH` | `:` |
| `GETTEXTDATADIRS` | `:` |
| `GI_TYPELIB_PATH` | `:` |
| `NIXPKGS_CMAKE_PREFIX_PATH` | `:` |
| `NIX_CFLAGS_COMPILE` | a space |
| `NIX_CFLAGS_COMPILE_BEFORE` | a space |
| `NIX_CFLAGS_LINK` | a space |
| `NIX_LDFLAGS` | a space |
| `NIX_LDFLAGS_AFTER` | a space |
| `NIX_LDFLAGS_BEFORE` | a space |
| `PATH` | `:` |
| `PERL5LIB` | `:` |
| `PKG_CONFIG_PATH` | `:` |
| `PYTHONPATH` | `:` |
| `XDG_DATA_DIRS` | `:` |

`HOME` does not exist in compiles and build-script runs, so a build that
writes to its home fails. Doctests are tests, so they get a writable home
as under `cargo test`. No `XDG_*` variable is set, so tools fall back to
directories under `HOME`. The package's `test.env` goes over all layers
of a doctest and can set `HOME` back to `/homeless-shelter`. Test runs
set up the same home with the `home` entry of
[`test.preRun`](options/packages.md#packagesnametestprerun)
([Tests](../explanation/products.md#tests)).

## `compile`

1. Read `BREAKBULK_UNIT` and set up the environment contract. Replace
   `NUM_JOBS` with `$NIX_BUILD_CORES`.
2. Build a dependency directory (details below): `$TMPDIR/deps`, with
   symlinks to the crate files of every transitive dependency (`rmeta`
   for units that do not link, `rlib` for units that do), and to the side
   files next to them that the unit's `beside` rules name. Pass one
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
5. Point `--out-dir` at `$TMPDIR/out` and run the recorded program in
   its [working directory](#working-directory).
6. Parse rustc's JSON diagnostics from stderr, print each `rendered`
   field, and drop artifact notifications. Without this, build logs are
   unreadable JSON. If rustc fails, add a hint for each path its output
   names that the unit's source view lacks
   ([Missing paths](#missing-paths)).
7. Move every file rustc wrote where the unit's output rules send it
   ([Output rules](#output-rules)).

### Output rules

A compile's `outputs` is an ordered list of rules, each
`{ "match": M, "into": I, "as"?: N }`. `M` is `{ "file": F }`, the file
rustc writes under the name `F`, which must exist, or `{ "suffix": S }`,
any file or directory whose name ends in `S`. `I` is `{ "output": O }`, a
derivation output; `"beside"`, next to the file of the same stem that a
`file` rule stores (into each of its outputs, under its stored stem), or
on to the next rule when there is none; or `"discard"`. `as` is the name
a `file` is stored under, when not its own. Every output a rule names is
created, even when nothing goes there.

`file` rules apply first; each other file goes by the first rule it
matches, and a file no rule matches is discarded with a warning. The
renderer writes, in order:

1. a `file` rule for each file of the plan unit's `outputs`: `.rmeta` to
   `rmeta`, `.rlib` to `rlib`, binaries and cdylibs to `out`, a bin
   uplifted under the name the plan's `uplifted` gives it (`as`);
2. dep-info (`.d`) discarded;
3. for a unit with a `debug` output, the target's debuginfo side files
   (the suffixes of the plan's `target.debuginfo`: `.pdb`, `.dwp`, `.dwo`,
   `.dSYM`) into `debug`;
4. on units a wrapper runs on, the variant's
   [`sideFiles`](options/workspaces.md#workspacesnamevariantsnamesidefiles),
   which send a file into a named output (a rule into an output the unit
   does not have is left out) or beside the output file of the same
   stem.

### Working directory

A compile (and a doctest) runs in the directory Cargo ran it in, with the
path rewritten like every other ([Path
rewriting](../explanation/internals/planner.md#path-rewriting)):

- A workspace package's unit: the workspace root, inside the unit's own
  source view (its test view for a test unit). Cargo runs rustc and
  rustdoc of a package in its workspace in the workspace root, with a
  source path relative to it: `crates/lib1/src/lib.rs` for a member in
  `crates/lib1`. Every view is rooted at the repository root, so a
  workspace in `ws/` runs in `<view>/ws`. A member of a workspace whose
  root is also a package therefore runs in its own view, not in the root
  package's.
- A path package outside its workspace's directory: its package
  directory, in its own view.
- A registry or git crate's unit: its crate source.
- Under `-Zbuild-std`, the standard library's units: their directory in
  the toolchain.

A build-script run runs in its package directory: in the package's
source view, or in the crate source.

### The dependency directory

`$TMPDIR/deps` replaces Cargo's single shared `deps` directory (classic
layout) or its one `-L dependency=` per dependency (new layout), and keeps
argv short.

rustc records a crate it loads from here under the link's path, not the
real one. So next to each crate file's link, the directory also links
each side file of the same stem that a
[`sideFiles`](options/workspaces.md#workspacesnamevariantsnamesidefiles)
rule with `into = "beside"` names, when the dependency's output has one.
A driver that looks beside a loaded crate (Verus's `.vir`) finds it.

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
- **Units that link name every `rlib`.** A unit links when it compiles
  with `--test` or has a crate type other than `lib` and `rlib`, as Cargo
  decides which dependencies need only metadata: bins, tests, examples
  built as bins, proc macros, cdylibs, dylibs, staticlibs, build scripts
  and doctests. They list every `rlib` as an input. An example built as an
  `rlib` does not link, and names only `rmeta` like a library.
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

- They are collected by scanning `$TMPDIR/out` for the suffixes of the
  plan's `target.debuginfo` artifacts (`.dwp` and `.dwo` on Linux, `.pdb`
  on msvc and UEFI, `.dSYM` directories on Apple), and moved, under
  rustc's names, to the unit's `debug` output.
- Units without a `debug` output discard them with a warning: host units,
  libraries outside the `.dwo` case, and any unit the plan's target spec says
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
     a hint for each other path the script's output names that its
     source view lacks, as for compiles ([Missing paths](#missing-paths)).
   - On success, warn about missing paths and list them in
     `missing-paths.json`. The run does not fail: the
     [`buildScriptPaths`](../explanation/configuration.md#missing-build-script-paths)
     check of its plan does.
7. Remove CMake's internal state (details below).

### Failure hints

A failed run gets hints after its stdout. The script's stdout, its
streamed stderr and the repeated stderr tail are never changed.

Some crates fail in a recognizable way when a tool or library is missing
from the sandbox. A hint is added when the script printed the crate's
error and the crate also left its fingerprint (a variable it declares, or
a line it prints). The hint quotes the line it matched, as in

```text
hint: `pkg-config` is not in the sandbox; add it with `packages.foo-sys.nativeInputs = p: [ p.pkg-config ];`
      (the build script printed: The pkg-config command could not be found.)
```

Two general rules follow, for any crate. Each quotes the line it matched:

- **A tool not found.** A line that says a program was not found
  (`os error 2`, `command not found`, and the like) and names a known
  tool gets `nativeInputs = p: [ p.<package> ];`. The tool must be
  quoted, end a path, or come before a `:`, as in
  ``failed to spawn `cmake` `` or `sh: 1: nasm: not found`. Other
  wordings, and messages that name no tool, get no hint.
- **A download.** A line that shows the script downloading
  (`Downloading http…`, `curl` or `wget` as a word, `Could not resolve
  host`, and the like) gets one hint: the sandbox has no network, so give
  the crate a local copy, usually through a variable it reads
  (`packages.<name>.env.<NAME>`, a `fetchurl` path).

The crates, tools and texts are data: the repository option
[`sysDefaults.buildScriptHints`](options/repository.md#sysdefaultsbuildscripthints),
whose curated entries are listed in
[Build-script failure hints](build-script-hints.md). Every build-script
run names the table as one file (`hints.buildScriptHints`) and reads it
only after a failure, so changing it rebuilds build-script runs but no
compile; only the matching is in `breakbulk-unit`.

Unset `rerun-if-env-changed` variables come last:

- Those of a crate whose failure was recognized are counted, not listed,
  with the patterns they match ("17 unset variables of the `pkg-config`
  crate omitted, matching `PKG_CONFIG*`, `*_NO_PKG_CONFIG`"). They are
  normally left unset.
- The rest go on one line, with the `packages.<name>.env` option to set
  them.

### Missing paths

A unit of a repository package sees only its package's source view. When
a compile, a build-script run, a doctest or a test run fails, its output
is searched for paths: absolute, relative to the working directory, or
as the remap names them (`crates/x/src/../../docs/a.md` in a rustc
diagnostic). A source location (`src/lib.rs:3:5`) is not searched: it
names a file that was read. A hint is added, naming the path relative to
the repository root, for each path that does not exist and is

- under one of the package's test-only paths, in a view that leaves it
  out: [`test.scopeTestsDir = false`](options/packages.md#packagesnametestscopetestsdir)
  for `tests/`, or a move from
  [`test.sourceScope`](options/packages.md#packagesnametestsourcescope)
  to [`extraSources`](options/packages.md#packagesnameextrasources). The
  path can come from another view: a library builds a path into its
  `tests/` from `CARGO_MANIFEST_DIR`, and its test run reads it;
- under the root of another Cargo target of the package, or under
  `examples/` or `benches/`, in the view of one target's units:
  [`scopeTargetRoots = false`](options/packages.md#packagesnamescopetargetroots);
- under what every view of the package leaves out at its top level
  (`target/`, `.git`, and the `result` and `result-*` symlinks of `nix
  build`): that cause, and the option for the unit's kind (below);
- otherwise, in a predicted view (`predictSources`), anywhere inside the
  view root, the package directory included:
  [`predictSources.keep`](options/packages.md#packagesnamepredictsourceskeep),
  saying that source prediction does not see files a proc macro or build
  script reads;
- otherwise inside the unit's view. The option is
  [`extraSources`](options/packages.md#packagesnameextrasources) for a
  library, bin or build script, and
  [`test.sourceScope`](options/packages.md#packagesnametestsourcescope)
  for a test compile, a doctest or a test run. A test run narrowed by
  [`test.runFiles`](options/packages.md#packagesnametestrunfiles) names
  that option, with the path relative to the package directory. Paths in
  the package directory count only for such a run and for a package with
  [`sources`](options/packages.md#packagesnamesources) functions: the
  built-in steps keep the whole directory otherwise, so a file missing
  there is missing from the repository too. With `sources` functions,
  breakbulk cannot tell whether a function left the path out, so the
  hint names the functions and the option for the unit's kind, which
  helps only if the functions keep what it adds.

A build-script run that succeeds without a `rerun-if-changed` path it
declared names the option the same way: `extraSources`, or, with
`sources` functions, those too; in a predicted view,
`predictSources.keep` or
[`predictSources.buildScriptRuns = false`](options/packages.md#packagesnamepredictsourcesbuildscriptruns).

The unit cannot see the repository, so the hint says "if it is in the
repository". A message without a path (`filetests: No such file or
directory`) gets no hint. At most 10 paths are named; the rest are
counted. Test runs get their hints from `breakbulk-hints`, a separate
small binary run after a failed test with the run's log; it finds the
view from the run's `CARGO_MANIFEST_DIR`. It is not part of
`breakbulk-unit`, so with `ca` on a `breakbulk-unit` change does not
re-run every test run.

### Repository paths in registry and git crates

A registry or git crate has no source view: a repository path that
Cargo config gives its units (`[env]` with `relative = true`, or
`build.rustflags`) points into an empty directory. The rendered unit
lists such paths (`hints.repositoryPaths`). When the unit fails, each gets a
hint, whatever the failure's message says:

- in a variable: set it with
  [`packages.<name>.env`](options/packages.md#packagesnameenv), which
  replaces Cargo's value (`packages.openssl-sys.env.OPENSSL_DIR =
  ./vendor/openssl;`, the path relative to the repository root). A
  variable that the package's `env` or the toolchain spec's already sets
  is not listed;
- in a rustc argument, or one in `CARGO_ENCODED_RUSTFLAGS`: the hint
  names the path and the argument (with the flag before it,
  `-L native=vendor/lib`). No option replaces an argument for one
  package.

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
| `metadata.json` | always | The package's name and version, the platform the run was for, its `links`, the `metadata` values (dependents' `DEP_*` when it has `links`) and the `OUT_DIR` path; see [Build-script runs](stage-functions.md#build-script-runs) |
| `target-files.json` | the script wrote files into `$out` outside `OUT_DIR` | Their paths, relative to `$out` |
| `missing-paths.json` | the script declared `rerun-if-changed` paths that are not in the sandbox | Each as `declared` (as printed), `path` (resolved against the package directory) and `hint` (the warning's text, naming the option to add it to) |

When there are such target files, `directives.json` also names the copies
of `<profile>` and `<profile>/deps` that hold them (`targetDirs`). Test
runs put those on the dynamic-library path after the search paths, as
`cargo test` does with `target/<profile>` and `deps`
(`Compilation::fill_env`), so a library a script copies next to the
binaries is found.

### Removal rules

After a successful run, the run spec's `outDirRemove` rules
(`packages.<name>.buildScript.outDirRemove`) apply: for each rule
`{ beside, path }`, in every directory of `$out` that holds a file named
`beside`, `path` (a file or a directory) is deleted. A deleted directory is
not searched further. They are for state a tool leaves in `OUT_DIR` that
differs between runs and that nothing reads afterwards.

The curated `sysDefaults.dependents.cmake` entry gives each direct
dependent of the `cmake` crate `{ beside = "CMakeCache.txt"; path =
"CMakeFiles"; }`:

- CMake's configure log there names randomly named try-compile
  directories, so the run would not be reproducible;
- nothing reads it after the script (the `cmake` crate reads its build tree
  back only within one run,
  [E3](assumptions.md#e3-cmake-rs-reads-nothing-from-cmakefiles-after-the-run)).

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
| Doctest search paths | A `searchPathsOf` splice (`{ "searchPathsOf": [F, …], "literals": [ … ] }`, the runs' `flags` directories) emits `-L P` for every search path of the listed runs, both classes, and each literal, deduplicated and sorted by value; a doctest's test arguments (`--test-args`) follow it. The values are the real store paths at build time, so the order is computed then, not copied from the trace. |
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
[`remapPathScope`](options/workspaces.md#workspacesnametoolchainfactscapabilitiesremappathscope)
capability):

| Unit | Scope |
| --- | --- |
| Non-test target units of a target with `debugInfo = "split"` | `macro,diagnostics,coverage`, every scope but `debuginfo`; debug info keeps store paths |
| Test binaries, and every target unit of a target with `debugInfo = "keep"` or `"strip"` | All scopes |
| Host units (build scripts, proc macros), on every target | `macro,diagnostics`. They never ship, so `debugInfo` doesn't apply, and one build serves every target |
| Any unit, with a rustc without `--remap-path-scope` (older than 1.95, or `remapPathScope = false`) | All scopes (no scope flag) |

The scopes are data: `products.remapScope` in `lib/products.nix` gives
each target's `{ host; target; test; }`, which instantiation reads from
`toolchains.json`'s `remapScope`.

### `debugInfo`

What happens to debug info is one property of the target:
[`targets.<triple>.debugInfo`](options/targets.md#targetsnamedebuginfo),
`"split"`, `"keep"` or `"strip"`. By default it is the traits' `debugInfo`:
`"split"` on Linux ELF targets, `"keep"` elsewhere (msvc's `.pdb` is a
separate file already, and wasm has no splitting stage).

Three things follow from it (`products.debugInfoOf`). The stages are
the traits' `debugStages` entry for the value; these are the ELF
target's:

| `debugInfo` | Stages first after `linked` | Remap scope of target units | `NIX_SET_BUILD_ID` on target units |
| --- | --- | --- | --- |
| `"split"` | `packDwo`, `splitDebug` | `macro,diagnostics` (table above) | yes (the GNU build ID `splitDebug` needs) |
| `"strip"` | `strip` (`strip --strip-debug`; drops `.dwo` files and packed `.dwp` files) | all | no |
| `"keep"` | `packDwo` | all | no |

- Mach-O's entries are `splitDebug`, `strip` and none. Other targets
  have a `"keep"` entry only: `"split"` and `"strip"` fail at
  evaluation unless the target's traits give the stages
  (`targets.<triple>.traits.debugStages.strip = [ { name = "wasmStrip";
  run = …; } ]`, for wasm).
- Units are shared by every package of the target, so no `stages`
  setting, the target's or a package's, may:
  - remove a stage the entry inserts (`splitDebug`, `strip`: that would
    leave real source paths in the product), or
  - add a stage only the `"split"` entry has where the target does not
    split (`splitDebug`: its links have no build ID and remap every
    path).

  Either is an evaluation error naming `debugInfo`.
- A stage the entry marks `removable` (`packDwo`: it changes no unit and
  leaves no source path in the product) is an ordinary stage: configure
  it, or remove it with `null` to ship the loose `.dwo` files.
- Overriding the inserted stages' attributes (their `run`, `after`) is
  allowed, and a stage of another name (an extra
  `strip { all = true; }` after `splitDebug`) is an ordinary stage.
- A stage with no `after` runs after the inserted stages, unless it is
  ordered before one of them. So one stage set orders the same way on
  every target, whichever stages its `debugInfo` inserts.
- `strip` has a `debug` output whenever `linked` has one (in
  dynamic-derivation mode, always). With nothing left to keep, it is
  empty.

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
