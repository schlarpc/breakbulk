# Products, stages and tests

A product is a package's linked output passed through named stages, each its own derivation, ending in an installed layout. Checks hang off stages, and test binaries become test runs. This page covers stage ordering, checks, stage helpers, debug outputs, and how tests and doctests run.

Every product starts at a fixed stage named `linked` and passes through an ordered set of named stages. Each stage is one content-addressed derivation. Checks hang off stages without joining the chain.

## The `linked` stage

`linked` is a small derivation that symlinks the root unit's output. In IFD mode it depends on the root unit like any derivation. In dynamic-derivation mode it depends on the root derivation of `lib/dynamic.nix`, which depends on `builtins.outputOf <outer drv>."<root>.drv" "out"` (the wrapper), so Nix resolves both at build time; the path goes through three symlinks (root, wrapper's `root`, unit output), which is harmless. Either way, later stages get an ordinary derivation to depend on.

## Stage ordering

```nix
stages.<name> = {
  after = "linked";   # or another stage; default: the previous stage in the preset's chain
  before = null;
  run = { input, product, target, pkgs }: <derivation>;   # input = previous stage's output
};
```

- The effective stage set is the preset's defaults merged with the target's and the package's stage modules. `lib.mkForce null` removes a stage.
- Order comes from `lib.toposort` over the `after` and `before` constraints. A cycle, or a reference to a missing stage, fails evaluation and lists every stage with its constraints.
- The last stage in the order is the product. The `install` stage normalizes the layout (`bin/`, `lib/`, `.exe` with DLLs, `pkg/`) and runs last unless removed. Its file-name globs come from the target's traits (`executableSuffix`, `sharedLibrarySuffix`, `staticLibrarySuffix`, `debugArtifacts`), so a MinGW staticlib or import library (`.a`) and an Apple `.dylib` land in `lib/`.

  Files that build scripts placed next to the binaries (Cargo's `target/<profile>`, a run's `targetDirs`; #23) are not in a product by default. The `buildScriptFiles` stage helper copies them in before `install`, and the default `buildScriptFiles` check fails when there are such files and the product holds none of that name, printing the stage with its position in that product's order, or how to remove the check.

  The files considered are those of the target-platform runs the product's roots depend on (`buildScriptRuns` of each root in `units.json`, from the plan's dependency graph), not every run of the plan as in Cargo's shared `target/<profile>`: a product is not asked for a library only another member's dependency places.

  In dynamic-derivation mode each product root's `breakbulk-root.json` lists those runs' `flags` (`buildScriptFlags`), read at build time; they are built before the root anyway. The check is on every product in both modes and passes when nothing was placed.
- Every stage and check derivation runs through a guard: its builder is wrapped so that, when its input holds the no-binaries marker (`breakbulk-no-binaries`, written by a dynamic-mode `linked` stage whose roots Cargo all skipped), it copies the marker to each of its outputs and succeeds without running the real builder. The wrap goes through `overrideAttrs` when the derivation has it (`mkDerivation`, `runCommand`); a stage or check written as a bare `derivation` call is rebuilt from its `drvAttrs` with the guard as builder and its own builder and arguments passed through, and is guarded the same way. Content addressing ([`ca`](../../reference/options/repository.md#ca)) reaches such a derivation the same way.

## Checks

```nix
checks.<name> = { on = "linked"; run = { input, product, pkgs }: <derivation>; };
```

Each check becomes `repo.checks."<ws>/<triple>/<pkg>/<name>"`. Every product gets `noSourceReferences` by default, which fails if the main output's runtime closure contains a source-view or crate-source store path, or one of the Rust toolchain's (rustc, its sysroot, cargo, a rust-overlay toolchain's components such as rust-src): a std panic location that names rust-src, or an embedded tool path, would make the toolchain a runtime dependency.

The `debug` output is exempt. One toolchain reference is allowed: a toolchain path holding a shared library the checked output itself loads, read from its files (ELF `NEEDED`, PE imports) and looked up in that path's `lib`, `bin` and `lib/rustlib/<target>/{lib,bin}`.

So a binary linked with `-C prefer-dynamic` may reference the sysroot its `libstd-*.so` comes from (nixpkgs' `rustc.unwrapped`); rustc's own component, cargo and rust-src hold no such library and are never allowed. A rust-overlay toolchain's joined sysroot carries its rustc and cargo components in its closure, so a `prefer-dynamic` binary that names it still fails. `noSourceReferences { toolchain = [ ]; }` checks sources only.

Debuginfo side files: when a root unit has a `debug` output (always in dynamic-derivation mode, where unit outputs are not known at evaluation), the `linked` stage has a second output, `debug`, with the root units' `.pdb`, `.dwp` and `.dwo` files under the names Cargo uplifts them to (a bin's `.dwp` as `<bin>.dwp`; `.pdb` and `.dwo` under rustc's names, which the binaries record), and the `.dwo` files of the libraries below each root (each product root in `units.json` lists those units as `debugUnits`; in dynamic-derivation mode the root's wrapper links all of them into its `debug` directory).

Stages see it as `product.linkedDebug`. `splitDebug` copies the files into its `debug` output.

A binary's skeleton units name their `.dwo` files by rustc's absolute build path (`/build/out/…`), which gdb opens only as given, so `splitDebug` packs the `.dwo` files each binary names into `<binary>.dwp` with binutils' `dwp` (as rustc's own `.dwp` with `packed`, gdb finds it next to the separate debug file) and drops the loose `.dwo` files; without an earlier stage that splits debug information, `install` writes them to its own `debug` output in the install layout (`$debug/bin/app.pdb` for `$out/bin/app.exe`).

`products.<pkg>.debug` is the last such output. On msvc the PDB references the sources and the rlibs it was linked from; the main output references neither.

The debug outputs are tested with debuggers, not only for presence (`products-source-paths`, `products-source-paths-dwp`, `products-source-paths-dwo`, `msvc-x86_64-pdb`): with only `$debug/lib/debug` as gdb's `debug-file-directory`, gdb stops in a dependency crate, prints a backtrace into the binary's crate with file and line, and reads the source from the source view the debug output references, also with `split-debuginfo = "packed"` and `"unpacked"` (where gdb must show the dependency's arguments, which only the DWARF objects hold, and does not without the `.dwp`); on msvc, `llvm-symbolizer` resolves the address of `main` (from the PDB's public symbols) in the `.exe` with the debug output's PDB next to it to the function and `src/main.rs:<line>` in the source view.

## Stage helpers

| Helper | Does |
| --- | --- |
| `splitDebug` | Reads the GNU build ID, writes `$debug/lib/debug/.build-id/<xx>/<rest>.debug` with `objcopy --only-keep-debug`, then strips debug info and adds a debuglink. A packed `<bin>.dwp` (`split-debuginfo = "packed"`) moves next to that file, where gdb looks for it (`<debug file's directory>/<binary name>.dwp`; gdb 17.2 `gdb/dwarf2/read.c`, `open_and_init_dwp_file`), with a symlink at its install-layout place |
| `strip` | `strip --strip-debug` (or `--strip-all` when asked) |
| `patchelfRpath { libs }` | Adds rpaths for libraries loaded at runtime, after any rpath shrinking |
| `bindgen { target ? "web" }` | Lockfile-matched `wasm-bindgen` |
| `wasmOpt { flags ? [ "-Oz" ] }` | `wasm-opt` on a core module |
| `componentize { adapter ? null; metadata ? { } }` | `wasm-tools component new`, then `wasm-tools metadata add` |
| `deterministicZip` | Sorted entries, fixed timestamps, no extra attributes |
| `install` | Final layout; the link units' debuginfo side files (`.pdb`) in a `debug` output in the same layout, when no earlier stage split debug information |
| `neededLibraries { allowed ? glibcLibraries; why ? "" }` | A check: every ELF file's `NEEDED` entries must match `allowed` (shell globs of sonames), as auditwheel checks a wheel; `linuxPortable`'s `portableLibraries` (with `gccRuntimeLibraries`, `libgcc_s.so.1` and `libstdc++.so.6`) |
| `noStorePaths { allow ? [ ]; why ? "" }` | A check: no file names a Nix store path anywhere in its bytes (`<storeDir>/<32 characters>-<name>…`, so also paths outside the closure and hashes `remove-references-to` replaced with `eee…`); `allow` takes shell globs matched against each whole path found, or store paths (matching themselves and what lies below them); `linuxPortable`'s `portableNoStorePaths` |

## Tests

- **Test binaries** are roots with `test = true` in the test plan. `tests.<pkg>.<name>` is the binary installed as `bin/<target><exe suffix>`, the suffix from the target's traits (`.exe` on Windows, `.wasm` for wasm, none on Linux), as Cargo names it; `benches.<pkg>.<name>` likewise. Test binaries are never stripped.
- **`CARGO_BIN_EXE_<name>`** is compile-time env recorded by the planner, and is rewritten to the bin root's `linked` output. The test's compile unit therefore depends on that link.
- **`CARGO_TARGET_TMPDIR`** is also compile-time env, but must be writable when the test runs. It is rewritten to a fixed path under the build directory, and the test-run derivation creates that path before running (see spikes).
- **Test runs** are one derivation per test binary. A small CA derivation copies the test binary, and the test run consumes that copy, so a byte-identical binary does not re-run.

  With `test.stripForRun` the copy is stripped of debug info and of its GNU build ID (`objcopy --strip-debug --remove-section=.note.gnu.build-id`; the linker computes the ID over the whole file), because the debug info of the workspace libraries it links names their source views; files that are not ELF are copied as they are. Without `ca` the stripped copy is input-addressed.

  With [`test.runFiles`](../../reference/options/packages.md#packagesnametestrunfiles) the working directory and the runtime `CARGO_MANIFEST_DIR` (and `CARGO_MANIFEST_PATH`, which then may not exist) are the package directory of the narrowed view; a test reading another file fails. Test apps keep the package's whole view and the unstripped binary.

  In dynamic-derivation mode both options work the same, but a test run there reads its spec from the root's wrapper, whose `breakbulk-root.json` names input-addressed paths (the source view, build-script outputs), so dynamic-mode test runs are re-run after any such edit regardless (no cutoff yet).

  The run uses the target's `runner`, with the package source view as the working directory (as Cargo does), plus Cargo's runtime env (`CARGO_MANIFEST_DIR`, `CARGO_PKG_*`), the package's [`test.env`](../../reference/options/packages.md#packagesnametestenv), and [`test.path`](../../reference/options/packages.md#packagesnametestpath) on `PATH`.

  Its `system` is the target's [`testSystem`](../../reference/options/targets.md#targetsnametestsystem) when set.

  Its dynamic-library path holds the search paths of **every** run of the test's platform in the plan that pass the dynamic-library rule (see [Directive parsing](../../reference/unit-builder.md#directive-parsing)), not only the test's dependencies, as Cargo does, then the sysroot's target library directory, from a small derivation holding only that directory's shared libraries (so a test run does not depend on the whole toolchain).

  The variable that holds it is the test process's, not the build machine's: the runner's when it declares one (wine reads `WINEPATH`, `;`-separated, and finds no DLL on the Unix `PATH` or `LD_LIBRARY_PATH`; checked with wine 11.0), else the target's traits (`dylibPathVar`: `LD_LIBRARY_PATH` on Linux, `PATH` on Windows run natively), and none for wasm.

  Cargo on a Linux host sets `LD_LIBRARY_PATH` for a Windows runner too, so a Windows test that loads a DLL its build script built fails under `cargo test` with wine and passes in breakbulk (`windows-dll-*` in `tests/presets/extra-targets.nix`).

  The variable of recorded processes (compiles and build-script runs, which always run on the build machine) is the build machine's, one constant (`breakbulk_unit::splice::DYLIB_PATH_VAR`, re-exported by breakbulk-format as `HOST_DYLIB_PATH_VAR`). It succeeds on exit 0, and its output records the log.
- **Skipped tests:** a predicted test the plan lacks gets a test-run stub that succeeds and logs the reason.
- **Test arguments:** [`test.args`](../../reference/options/packages.md#packagesnametestargs) and `test.binaries.<binary>.args` are passed to the binary; [`includeIgnored`](../../reference/options/packages.md#packagesnametestincludeignored) adds `--include-ignored`. They are part of the test-run derivation, so changing them re-runs only the affected runs. `enable = false` leaves a binary's run out of `repo.checks`. Every test run sets `RUST_TEST_THREADS=$NIX_BUILD_CORES`.
- **Test apps:** each test binary also gets a runnable app with the test run's working directory, environment and runner, run on the user's machine. It is the escape hatch for tests that need network, and the way to rerun one binary under a debugger or with a filter. Network access inside `nix flake check` (through a fixed-output test run) is a possible later addition; impure derivations are not used.
- **nextest.** Test binaries run directly (libtest) by default. With `test.runner = "nextest"`, each test run synthesizes the `binaries-metadata` file that nextest's reuse-build mode reads, so per-test retries, timeouts, test groups and default filters from the nextest config apply; each binary is still its own test run. The setting is per package ([`packages.<name>.test.runner`](../../reference/options/packages.md#packagesnametestrunner), `.nextest.{profile,configFile,package}`), with a workspace-wide default ([`workspaces.<ws>.test.runner`](../../reference/options/workspaces.md#workspacesnametestrunner) and `.test.nextest.*`) that a package's own non-null setting overrides.
- **Doctests:** one derivation per library crate, from the test plan's traced `rustdoc --test` command. Inputs are the crate's `rlib`, its dependencies with test-plan features, and the source view. Cargo gives `rustdoc --test` an `-L native=` for every run in the invocation, sorted by value, so the derivation also depends on the `flags` output of every run the `searchPathsOf` splice lists, and rebuilds that list at build time. Its dynamic-library path holds every host run's in-`out` search paths. It gets no `-l`. It runs with the target's runner and records the log; it appears in `repo.checks`. There is no cutoff, because compiling and running happen in one rustdoc process. If the toolchain cannot run doctests for a cross target, the derivation is a stub that logs why.
- **Benches:** `cargo test --no-run` builds no benches, so the test plan has none. Bench binaries come only from the bench variant (`cargo bench --no-run`, bench profile), exposed for running outside Nix. With [`benchSmoke`](../../reference/options/workspaces.md#workspacesnamebenchsmoke), each bench binary also runs once with `--test` as a check. Timed runs never happen inside Nix.

## Documentation (not built yet, [#6](https://github.com/schlarpc/breakbulk/issues/6))

One derivation per workspace and target replays the traced `rustdoc` commands in Cargo's order into a single output directory, because rustdoc updates cross-crate indexes in place. Its inputs are the check-mode `rmeta` units shared with check and clippy variants. Per-crate derivations with a final merge wait for rustdoc's mergeable cross-crate info to become stable.
