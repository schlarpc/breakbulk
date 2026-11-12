# Products, stages and tests

`repo.workspaces.<ws>.packages.app` gives you the finished `app` for its
target, with no configuration. Underneath, every step is its own named
derivation that you can read, replace or remove.

## Three layers

| Layer | What it is | Where |
| --- | --- | --- |
| Units | one derivation per Cargo unit | internal, but inspectable |
| Stages | the linked output passed through ordered, named steps | `.stages.<name>`, e.g. `.stages.linked` |
| Packages | the last stage: by default `install`, which lays out the usual tree (`bin/`, `lib/`, see [The installed layout](#the-installed-layout)) | `packages.<pkg>`, `target.<triple>.packages.<pkg>` |

Each stage is its own derivation. With content addressing on (see
[Caching and early cutoff](caching.md)), a stage whose input did not
change does not re-run, and neither do the stages after it.

## Default stages

The target's preset picks the default stages. What happens to debug
information comes first, and is set per target with
[`targets.<triple>.debugInfo`](../reference/options/targets.md#targetsnamedebuginfo):
`"split"`, `"keep"` or `"strip"`. It is per target, not per package,
because every package of a target shares the same units, and the units'
path remapping and build ID depend on it.

| Target | `debugInfo` default | Default stages |
| --- | --- | --- |
| Linux (gnu, musl) | `split` | `splitDebug` |
| Windows (MSVC) | `keep` | none: PDBs are already separate files; `install` puts them in the `debug` output |
| wasm for browsers | `keep` | `bindgen` → `wasmOpt` |
| wasm components | `keep` | `wasmOpt` → `componentize` |
| macOS (not yet, [#13](https://github.com/schlarpc/breakbulk/issues/13)) | to decide (`.dSYM` via `dsymutil`) | `dsymutil` → `strip` → `adhocSign` |

There is no hidden fixup phase. Stripping breaks some signing schemes, and
some checks need unstripped bytes, so every default stage can be removed
or reordered.

## Your own stages and checks

A stage changes the artifact; a check only looks at it. A check hangs off
a named stage, sees exactly those bytes, never blocks the chain, and shows
up in `checks` by itself:

```nix
packages.server.checks.isa = { on = "linked"; run = isaCheck; };  # sees pre-strip bytes

packages.app.target."x86_64-pc-windows-msvc".stages = {
  stageDlls = { after = "linked"; run = stageRuntimeDlls; };
  zip       = { after = "stageDlls"; run = deterministicZip; };
  strip     = lib.mkForce null;  # signing breaks if stripped
};

packages.dev-tool.checks.noSourceReferences = null;  # null removes a check too
```

A wrapper or package belongs after `install`, where the binary is already
at `bin/app`:

```nix
packages.app.stages.wrap = {
  after = "install";
  run = { input, pkgs, ... }:
    pkgs.runCommand "app-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      cp -R ${input} $out; chmod -R u+w $out
      wrapProgram $out/bin/app --set APP_MODE prod
    '';
};
```

### The installed layout

`install` places each file the package's roots produce by what the root
is, under the name Cargo uplifts it to in `target/<profile>/`:

| Root | Goes to | Examples |
| --- | --- | --- |
| bin | `bin/` | `bin/app`, `bin/app.exe`, `bin/app.wasm` (a wasi command) |
| staticlib | `lib/` | `lib/libfoo.a`, `lib/foo.lib` |
| cdylib, dylib | `lib/`; `bin/` on Windows and Cygwin, where a DLL is found beside the executable | `lib/libfoo.so`, `lib/foo.wasm`, `bin/foo.dll` |

Other files go by suffix: libraries (an import library such as
`foo.dll.lib` too) to `lib/`, executables to `bin/`, a `.pdb` next to the
file it describes. Where a suffix does not decide (`.wasm` is both
executables' and libraries' suffix), the file stays at the top.
Directories that earlier stages made are kept as they are, so `bindgen`'s
`pkg/` (the JavaScript glue and its `.wasm`) and a stage's `share/` land
unchanged. Where each kind goes comes from the target's traits
(`sharedLibraryDir`), so a target you define controls it.

`install` is an ordinary stage with a default position:

| Stage | Runs | Sees |
| --- | --- | --- |
| names neither `install` nor a stage after it | before `install` | the flat link output (`app`, `libfoo.so`) |
| `after = "install"`, or after such a stage | after `install` | the installed layout (`bin/`, `lib/`, and `pkg/` after `bindgen`) |

The stage helpers (`splitDebug`, `strip`, `bindgen`, …) expect the flat
link output. A wrapper made before `install` would run the earlier
stage's binary, so the product would carry both copies. More in
[Wrap or package a binary](../how-to/wrap-package.md).

Typical checks: ISA level, DLL import closure, PE headers, signature
verification, "no interpreter, no needed libraries".

breakbulk ships [stage helpers](../reference/stage-helpers.md):
`splitDebug`, `strip`, `patchelfRpath`, `bindgen`, `wasmOpt`,
`componentize`, `deterministicZip` and more. Your own stages are
ordinary derivations: container images, boot images, distribution
packages, signing, metadata stamps. What a stage function gets is in
[Stage and check functions](../reference/stage-functions.md).

Details: [Products, stages and tests (internals)](internals/products.md).

## Source paths and debug information

Every crate's source is a store path. If a binary contained a source path,
Nix would see a runtime dependency on the sources, and any edit to a
package would change every binary that names its files. So breakbulk
hides source paths, by kind of output (rustc's `--remap-path-scope`,
stable since 1.95):

| Output | Panic messages, `file!()`, diagnostics | Debug information |
| --- | --- | --- |
| Binaries and cdylibs, `debugInfo = "split"` (Linux default) | hidden | real store paths, moved to a separate `debug` output |
| Staticlibs, `debugInfo = "split"` | hidden | real store paths, kept in the archive |
| Test binaries | hidden | hidden; kept in the binary for backtraces in test logs |
| Anything on a target that keeps or strips debug info | hidden | hidden |
| Anything built with rustc older than 1.95 | hidden | hidden |

With `split`, `splitDebug` moves the DWARF to the `debug` output
(`$debug/lib/debug/.build-id/…`, where gdb and debuginfod look). The main
output names no sources; the `debug` output names exactly the sources a
debugger needs, so installing it gives source-level debugging with no
setup.

A staticlib is not the end of the line: another program links it, and
that final link (and its own split or strip) decides what happens to the
debug information. So a staticlib keeps its objects' DWARF, real source
paths included, and its dependencies' objects inside the archive keep
theirs.

Every product gets the `noSourceReferences` check. It fails when the main
output references a source path or a Rust toolchain path. A source named
only by the product's staticlib archives is allowed; a source that any
other file names still fails. A toolchain
path is allowed when it holds a shared library the product loads, such as
`libstd-*.so` with `-C prefer-dynamic`. To check sources only, set
`packages.<name>.checks.noSourceReferences.run =
breakbulk.stageHelpers.noSourceReferences { toolchain = [ ]; }`. To remove
the check from a package, set `packages.<name>.checks.noSourceReferences =
null`.

Path remapping rewrites panic locations, `file!()` and debug information.
It does not rewrite `env!` values. `CARGO_MANIFEST_DIR` is the package's
source in the store, so a crate that keeps
`concat!(env!("CARGO_MANIFEST_DIR"), "/", file)` in a string puts that
source in the product's closure. This is the usual cause of a source
reference, and the check's failure says so. When the program never reads
the path, add the
[`removeSourceReferences`](../reference/stage-helpers.md#removesourcereferences)
stage to the package. It replaces the hash of every source path in the
product's files with `e`s of the same length, as nixpkgs'
`remove-references-to` does, and changes nothing else. breakbulk never
adds it by itself: a program that opens `CARGO_MANIFEST_DIR/assets/…` at
run time works only while the source is in its closure, and fails after
the scrub. Such a program keeps the reference: remove the check instead.

One catch for tests: the workspace libraries a test binary links are
compiled once, for shipping, so their debug information names their
sources. Editing any file of such a library, even a README, changes the
test binary. [`test.stripForRun`](../reference/options/packages.md#packagesnameteststripforrun)
(off by default) runs a debug-stripped copy instead, which does not
change; the unstripped binary stays available for debugging.

### Cargo's trim-paths

Cargo's `trim-paths` profile setting (Cargo 1.101 and later) computes the
same remaps, and also keeps absolute paths out of the identity of path
crates outside the workspace root. Cargo leaves it off by default. On
Cargo 1.101 and later breakbulk turns it on, uses Cargo's remaps instead
of its own, and keeps the per-kind scopes above, unless the project sets
`trim-paths` itself:

- any `trim-paths` under `[profile]` in the workspace root's `Cargo.toml`
  or the project's Cargo config leaves the choice to the project;
- [`workspaces.<ws>.cargoTrimPaths`](../reference/options/workspaces.md#workspacesnamecargotrimpaths)
  forces it on or off;
- [`sourcePaths = "keep"`](../reference/options/workspaces.md#workspacesnamesourcepaths)
  turns all path hiding off.

Under Cargo's trim-paths, breakbulk's C prefix maps use Cargo's names, so
they agree with cc-rs, which reads the same remaps from
`CARGO_TRIM_PATHS_REMAP`.

## Tests

Every test, bench and example binary is an attribute
(`target.<triple>.tests.<pkg>.<test>`), so VM tests and system tests can
use it. Each test binary also gets:

- **a test run**, a derivation that runs it with the target's `runner`
  and any declared environment and `PATH` additions (a software GPU
  driver, external tools). With content addressing on, it runs a
  content-addressed copy of the binary, so a byte-identical binary is not
  run again;
- **a test app** (`testApps`), which sets up the same working directory,
  environment and runner but runs on your machine: the way out for network
  tests, debuggers and running a single test.

More behavior:

- `CARGO_BIN_EXE_*` points at the right binaries, and nextest
  configuration is respected (`test.runner = "nextest"`).
- [`targets.<triple>.testSystem`](../reference/options/targets.md#targetsnametestsystem)
  sends a target's test runs to native builders of that system, instead
  of emulating them through the runner.
- A target that Cargo skips because its `required-features` are off
  still has an attribute. Building that product fails with the reason;
  its test run succeeds and logs that it was skipped, as `cargo test`
  does.
- Tests that cannot run in the sandbox (network, devices) are skipped
  with libtest's own filters
  ([`test.args`](../reference/options/packages.md#packagesnametestargs)),
  per package or per test binary
  ([`test.binaries.<key>`](../reference/options/packages.md#packagesnametestbinaries),
  which says how a binary's key is spelled; a key that names no test
  binary is an error). Changing a skip list re-runs only the affected
  test runs.

**Home directory.** A test run and a doctest run get a fresh, empty,
writable `HOME` inside the run's own temporary directory, as a test has a
writable home under `cargo test`. Tests that keep a cache or a config
file there work without any setting. Nothing of your own home is read,
and nothing written there outlives the run. The `XDG_*` variables stay
unset, so tools fall back to `$HOME/.cache` and the like.

- Compiles and build-script runs keep Nix's `HOME=/homeless-shelter`,
  which does not exist: a build script that writes to its home fails.
- For the same strictness in a package's tests, set
  `HOME = "/homeless-shelter"` in its
  [`test.env`](../reference/options/packages.md#packagesnametestenv).
- Test apps run on your machine with your own `HOME`.

**Test output.** A test run's output goes to the build log only: see it
with `nix log <run>` or `nix build -L`. The run's own output (`$out`) is
an empty directory. The output holds timings and, with more than one
test thread, result lines in a varying order. If it were in `$out`, a
passing run would fail `nix build --rebuild`, which compares outputs, and
`--rebuild` is how you check that a test still passes. breakbulk does not
parse the output into a stable form either: that would tie it to
libtest's and nextest's formats, and `harness = false` tests have
neither. Doctest runs work the same way.

- [`test.keepLog`](../reference/options/packages.md#packagesnametestkeeplog)
  copies the raw output to `$out/log`, for a binary cache that does not
  store build logs or a CI that keeps logs as artifacts. Such a run is
  not reproducible under `--rebuild`.
- [`test.postRun`](../reference/options/packages.md#packagesnametestpostrun)
  (per package, and per binary under `test.binaries.<binary>.postRun`)
  is a shell snippet that runs inside the run after it passes, with the
  raw output in `$log`. Under nextest, `$nextestDir` is nextest's store,
  so `cp -r "$nextestDir/ci" "$out/junit"` keeps a profile's JUnit
  report. Whether the result is reproducible depends on what the
  snippet puts in `$out`.
- A coverage variant's runs keep their profiles in `$out/profraw`, named
  by content. The counters themselves can differ between runs (hash
  seeds, timing), so coverage runs are outside the `--rebuild`
  guarantee.

**Test threads.** Each test binary is its own derivation, and Nix builds
up to `max-jobs` derivations at once. Each test run starts `cores` test
threads by default: it sets `RUST_TEST_THREADS` to `$NIX_BUILD_CORES`.
So the real parallelism is `max-jobs × cores`, next to any compiles
that run at the same time. Nix has no jobserver, so breakbulk cannot
divide the cores between runs.

- A machine that runs many checks at once should set `cores` in its Nix
  configuration, so that `max-jobs × cores` is about its CPU count.
- The default yields to a value you set. `RUST_TEST_THREADS` from the
  project's `[env]` in `.cargo/config.toml`,
  [`test.env`](../reference/options/packages.md#packagesnametestenv) or
  [`test.binaries.<binary>.env`](../reference/options/packages.md#packagesnametestbinariesnameenv)
  wins.
- A timing-sensitive test should set `RUST_TEST_THREADS` in
  `test.binaries.<binary>.env` (for example to `"1"`), or skip itself
  with `test.binaries.<binary>.args`.
- nextest does not read `RUST_TEST_THREADS`. Under nextest the default
  is nextest's `test-threads`, set to `$NIX_BUILD_CORES`. A
  `test-threads` in the project's nextest profile wins over it, and
  `NEXTEST_TEST_THREADS` in `test.env` or `test.binaries.<binary>.env`
  wins over both.

**Running a test app.** A test app is a derivation whose
`meta.mainProgram` is the app's script, so `nix run` takes it at its
attribute path, wherever a flake output puts it. Arguments after `--` go
to the test binary:

```
nix run .#<…>.testApps.<pkg>.<binary> -- --exact net::fetches --nocapture
```

`repo.apps` has every test app in the shape of a flake's `apps` output,
named as its test run's [check](../reference/outputs.md#checks)
(`<ws>/<triple>/<pkg>/test-<name>`). It includes the test binaries whose
runs are disabled, or whose tests the sandbox skips, which are the main
reason to run a test app. With `apps.${system} = repo.apps;` in the
flake (the flake-parts module adds it), `nix flake show` lists them, and:

```
nix run .#default/x86_64-unknown-linux-gnu/app/test-e2e -- --nocapture
```

`nix run` splits an attribute path at `.` only, so `/` needs no quoting.
A name with a `.` in it (from a workspace named `api.v2`, say) is
quoted: `nix run '.#"api.v2/…/test-e2e"'`.

**Doctests** get one derivation per library, which runs `rustdoc --test`.
rustdoc compiles and runs the examples in one process, so doctests have
no cutoff: they re-run whenever the library or anything below it changes.
`test.args` reach rustdoc too, as `--test-args`, so a doctest is skipped
by its name (`--skip "src/lib.rs - net::connect"`); per-binary
`test.binaries.<binary>.args` do not.

- [`test.doctest`](../reference/options/packages.md#packagesnametestdoctest)
  gives a package's doctest run its own `args`, `env` and `postRun`,
  over the package's `test.args`, `test.env` and `test.postRun`, as
  `test.binaries.<key>` does for a test binary.
- `test.doctest.enable = false` leaves the doctest run out of
  `repo.checks` and the check groups. As there is no separate compile,
  the checks then build nothing of it; `doctests.<pkg>` still builds it.
  A project whose CI runs the doctests of a few crates only sets
  `memberDefaults.test.doctest.enable = false` and `true` for those.
  [`test.binaries.<key>.enable`](../reference/options/packages.md#packagesnametestbinariesnameenable)
  does the same for one test binary.

**Benches** come only from a bench variant (`cargo bench --no-run`, bench
profile), which gives optimized bench binaries to run outside Nix.
`cargo test --no-run` builds no benches.
[`benchSmoke`](../reference/options/workspaces.md#workspacesnamebenchsmoke)
runs each bench once in test mode, as a check.

## Documentation (not built yet)

A `cargo doc` product is planned
([#6](https://github.com/schlarpc/breakbulk/issues/6)). `cargo doc` writes
every crate into one shared directory and updates cross-crate indexes in
place, so it does not split into per-crate derivations on stable rustdoc.
The plan is one derivation per workspace and target that replays the
traced `rustdoc` commands in Cargo's order, against the check-mode `rmeta`
units it shares with check and clippy variants. Per-crate documentation
waits for rustdoc's mergeable cross-crate info to stabilize.
