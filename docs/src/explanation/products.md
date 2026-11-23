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
| Linux (gnu, musl) | `split` | `packDwo` → `splitDebug` |
| Other ELF targets (bare metal, BSDs) | `keep` | `packDwo` |
| Windows (MSVC) | `keep` | none: PDBs are already separate files; `install` puts them in the `debug` output |
| wasm for browsers | `keep` | `wasmBindgen` → `wasmOpt` |
| wasm components | `keep` | `wasmOpt` → `wasmComponentize` → `wasmMetadata` |
| macOS | `split` | `splitDebug` (the `.dSYM` to the `debug` output, `llvm-strip -S`) → `install` → `adhocSign` |

`"strip"` inserts `strip` instead. `packDwo` packs split DWARF objects
(see [Split DWARF](#split-dwarf)); it does
nothing unless a profile sets `split-debuginfo = "unpacked"`.

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
Directories that earlier stages made are kept as they are, so `wasmBindgen`'s
`pkg/` (the JavaScript glue and its `.wasm`) and a stage's `share/` land
unchanged. Where each kind goes comes from the target's traits
(`sharedLibraryDir`), so a target you define controls it.

`install` is an ordinary stage with a default position:

| Stage | Runs | Sees |
| --- | --- | --- |
| names neither `install` nor a stage after it | before `install` | the flat link output (`app`, `libfoo.so`) |
| `after = "install"`, or after such a stage | after `install` | the installed layout (`bin/`, `lib/`, and `pkg/` after `wasmBindgen`) |

The stage helpers (`splitDebug`, `strip`, `wasmBindgen`, …) expect the flat
link output. A wrapper made before `install` would run the earlier
stage's binary, so the product would carry both copies. More in
[Wrap or package a binary](../how-to/wrap-package.md).

Typical checks: ISA level, DLL import closure, PE headers, signature
verification, "no interpreter, no needed libraries".

breakbulk ships [stage helpers](../reference/stage-helpers.md):
`packDwo`, `splitDebug`, `strip`, `patchelfRpath`, `wasmBindgen`, `wasmOpt`,
`wasmComponentize`, `deterministicZip` and more. Your own stages are
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
| Test binaries | hidden | hidden for the test's own crate, real store paths from the workspace libraries it links; with `ca`, test runs execute a copy with the debug info stripped (below) |
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
compiled as shipped libraries are, so their debug information names their
sources and holds their line tables. Editing any file of such a library,
even a README or a function the test never calls, changes the test binary.
So with [`ca`](../reference/options/repository.md#ca) on, a test run
executes a copy of the binary with its debug information and GNU build
ID stripped (the `strip` stage of
[`test.stages`](../reference/options/packages.md#packagesnameteststages)),
which does not change, and the test is not re-run. Panic messages keep
their file and line; backtraces keep function names but lose files, lines
and inlined frames. For debugging, the unstripped binary is
`tests.<pkg>.<binary>`. Without `ca` the run is not stripped: its input
changes with the binary anyway. On Apple targets the stage removes the
debug map, but the Mach-O UUID, which the linker computes over the whole
file, stays, so the cutoff holds only when the debug map did not change.

### Cargo's trim-paths

Cargo's `trim-paths` profile setting (Cargo 1.101 and later) computes the
same remaps, and also keeps absolute paths out of the identity of path
crates outside the workspace root. Cargo leaves it off by default. On
Cargo 1.101 and later breakbulk turns it on, uses Cargo's remaps instead
of its own, and keeps the per-kind scopes above, unless the project sets
`trim-paths` itself: any `trim-paths` under `[profile]` in the workspace
root's `Cargo.toml`, the project's Cargo config or the variant's
[`cargoConfig`](../reference/options/workspaces.md#workspacesnamevariantsnamecargoconfig)
leaves the choice to the project. That is
[`sourcePaths = "auto"`](../reference/options/workspaces.md#workspacesnamevariantsnamesourcepaths),
the default; the other values change it:

- `"cargo"` turns Cargo's trim-paths on even over the project's own
  setting;
- `"remap"` never turns it on and hides paths with breakbulk's own remaps;
- `"keep"` turns all path hiding off.

Under Cargo's trim-paths, breakbulk's C prefix maps use Cargo's names, so
they agree with cc-rs, which reads the same remaps from
`CARGO_TRIM_PATHS_REMAP`.

### Split DWARF

With `split-debuginfo = "unpacked"` in a Cargo profile, rustc leaves most
of the DWARF out of the objects. Each object keeps a small skeleton unit
that names a `.dwo` file holding the rest. The skeleton names the file by
rustc's absolute build path (`/build/out/…`), which does not exist after
the build. gdb opens such a name as given and nowhere else, so a loose
`.dwo` file is of no use to a debugger.

So the `packDwo` stage packs the `.dwo` files that each file of the
product names into one `<file>.dwp` (a DWARF package) in the `debug`
output, and ships no loose `.dwo` files:

| Product file | `debug` output | How gdb finds it |
| --- | --- | --- |
| `bin/app` | `bin/app.dwp` | with `split`, `splitDebug` moves it next to the separate debug file; with `keep`, it must be next to the binary, as in a profile that has both outputs |
| `lib/libfoo.so` | `lib/libfoo.so.dwp` | the same |
| `lib/libfoo.a` | `lib/libfoo.a.dwp` | it does not: see below |

To ship the loose files anyway, remove the stage:
`packages.<name>.stages.packDwo = null`.

With `debugInfo = "strip"`, the skeleton units are stripped, so nothing
names the `.dwo` files or a packed `<file>.dwp` any more, and none ship.

**A staticlib's `.dwp`.** The archive keeps its skeleton units, because
the program that links it needs them. gdb looks for a DWARF package only
under the name of the program it debugs (`<program>.dwp`, next to the
program or in `debug-file-directory`; gdb 17.2, `gdb/dwarf2/read.c`,
`open_and_init_dwp_file`), never under the archive's name. So the program
that links `libfoo.a` packs the archive's `.dwp` into its own, with its
own `.dwo` files if it has any:

```
llvm-dwp libfoo.a.dwp their/*.dwo -o their-program.dwp
```

`llvm-dwp` matches each skeleton to its unit by the DWARF ID they share,
so the `/build/out/…` names in the archive do not matter. Use `llvm-dwp`,
not binutils' `dwp`: from DWARF 5 units, binutils' `dwp` writes an empty
package and succeeds.

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

**Profile.** Tests are built in Cargo's `test` profile, as plain
`cargo test` builds them: it inherits `dev` (debug assertions on, no
optimization), with your `[profile.test]` over it. The products keep
the variant's `profile` (`release`). To build tests with the products'
profile, set the variant's
[`testProfile`](../reference/options/workspaces.md#workspacesnamevariantsnametestprofile)
(`testProfile = "release"`); the tests then share their dependencies
with the products. See [Variants](configuration.md#variants).

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

**The toolchain's libraries.** A test run finds the standard library's
shared library (`libstd-*.so`, for binaries linked with
`-C prefer-dynamic`) in a small copy, so it does not depend on the
whole toolchain. The copy has none of the compiler's own libraries, so
a `rustc` that a test starts uses its own sysroot.

- A test linked against the compiler's crates
  (`#![feature(rustc_private)]`) loads `librustc_driver` from the
  sysroot. It finds the library through its RUNPATH: nixpkgs' linker
  wrapper (the `cc` of a nixpkgs toolchain) adds the directory of every
  store library it links to the RUNPATH. Only such a test depends on the
  toolchain.
- A test binary linked without the wrapper, for example by `rust-lld`
  called directly, has no RUNPATH, and fails to load `librustc_driver`.
  Give its linker an rpath to the sysroot's
  `lib/rustlib/<triple>/lib` (`-rpath`) in the target's rustflags.

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

**Working directory and `CARGO_TARGET_TMPDIR`.** A test binary runs in
its package directory, as under `cargo test`. Integration tests and
benches can use `env!("CARGO_TARGET_TMPDIR")`, a scratch directory that
Cargo puts inside its target directory. The value is compiled into the
binary, and breakbulk has no target directory, so it compiles in the
relative path `target/tmp`. A relative path resolves wherever the binary
runs: in the sandbox, in a test app on your machine, and in a copy of the
binary that you run by hand somewhere else (create `target/tmp` there
first, as Cargo does, unless the test creates it itself).

A test run or test app whose binary contains `target/tmp` therefore runs
in a fresh directory of its own. That directory holds a symbolic link to
each entry of the package directory and a real, empty, writable
`target/tmp`. Each run gets its own, also when runs happen at the same
time or outside the sandbox. A test app removes it when it exits. A binary
without the string runs in the package directory itself. Only for
binaries that use the variable, this differs from `cargo test`:

- A relative path under it, passed as an argument to a child process
  that runs in another directory, resolves against the child's
  directory. `Command::current_dir` with a relative path is fine.
- `std::env::current_dir()` is not `CARGO_MANIFEST_DIR`, although the
  files in both are the same.
- A walk of `.` meets symbolic links. Walkers that are given a named
  directory as their root follow it.
- A checked-in `target/` directory of the package is hidden by the
  `target` entry.

If a project hits one of these, a
[test wrapper](../reference/options/packages.md#packagesnametestwrapper)
can set up the run differently.

**Test output.** A test run's output goes to the build log only: see it
with `nix log <run>` or `nix build -L`. The run's own output (`$out`) is
an empty directory. The output holds timings and, with more than one
test thread, result lines in a varying order. If it were in `$out`, a
passing run would fail `nix build --rebuild`, which compares outputs, and
`--rebuild` is how you check that a test still passes. breakbulk does not
parse the output into a stable form either: that would tie it to
libtest's and nextest's formats, and `harness = false` tests have
neither. Doctest runs work the same way.

- [`test.postRun`](../reference/options/packages.md#packagesnametestpostrun)
  (a [run setting](configuration.md#run-settings): per package, per
  binary, for doctests, for bench runs) is a shell snippet that runs
  inside the run after it passes, with the
  raw output in `$log`. Under nextest, `$nextestDir` is nextest's store,
  so `cp -r "$nextestDir/ci" "$out/junit"` keeps a profile's JUnit
  report, and `cp "$log" "$out/log"` keeps the raw output (see
  [Keep test output as an artifact](../how-to/ci.md#keep-test-output-as-an-artifact)).
  Whether the result is reproducible depends on what the snippet puts
  in `$out`.
- A coverage variant's runs keep their profiles in `$out/profraw`, named
  by content. The counters themselves can differ between runs (hash
  seeds, timing), so coverage runs are outside the `--rebuild`
  guarantee.

**Test threads.** Each test binary is its own derivation, and Nix builds
up to `max-jobs` derivations at once. Each test run starts `cores` test
threads by default: the `threads` entry of
[`test.preRun`](../reference/options/packages.md#packagesnametestprerun)
sets `RUST_TEST_THREADS` to `$NIX_BUILD_CORES`.
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
  is nextest's `test-threads`, set to `$NIX_BUILD_CORES` (the same
  `threads` entry writes it to a tool configuration). A
  `test-threads` in the project's nextest profile wins over it, and
  `NEXTEST_TEST_THREADS` in `test.env` or `test.binaries.<binary>.env`
  wins over both.
- `test.preRun.threads = null` leaves both unset: libtest and nextest
  then pick their own defaults, every CPU of the machine.

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

**Test wrappers.** Some tests find files from the test binary's own
path: they walk up from `std::env::current_exe()` to a directory named
`target` and take its parent as the repository root. Under Cargo the binary is in
`target/debug/deps/`. Under breakbulk it runs from its own store path, so
such a helper finds nothing.
[`test.wrapper`](../reference/options/packages.md#packagesnametestwrapper)
(per package, in `memberDefaults`, or per binary under
`test.binaries.<key>.wrapper`) is a program that starts the test binary,
as Cargo's `target.<triple>.runner` does. Test runs and test apps both
use it.

- It is called as `<wrapper> <binary> <args…>`, in the package
  directory (or the private directory above, when the binary uses
  `CARGO_TARGET_TMPDIR`).
- `BREAKBULK_SOURCE_ROOT` is the root of the run's source view (for a
  test app with `checkout`, the checkout).
- `BREAKBULK_NEXT` is a program that starts a binary under the target's
  runner (wine, an emulator), or directly when there is none. The
  wrapper ends with `exec "$BREAKBULK_NEXT" <binary> <args…>`, where the
  binary may be a moved copy. The wrapper itself runs on the machine that
  runs the test, outside the runner, so `current_exe()` names the copy.
- Under `test.runner = "nextest"`, nextest starts the wrapper as the
  target's runner, for the listing as well as for each test.
- Doctests do not use it: rustdoc runs them from its own temporary
  directory.

[`breakbulk.lib.wrappers.cargoTargetLayout`](../reference/presets.md#test-wrappers)
is the ready-made wrapper for the case above:

```nix
workspaces.main.memberDefaults.test.wrapper =
  breakbulk.lib.wrappers.cargoTargetLayout { profile = "debug"; };
```

**Doctests** get one derivation per library, which runs `rustdoc --test`.
rustdoc compiles and runs the examples in one process, so doctests have
no cutoff: they re-run whenever the library or anything below it changes.
`test.args` reach rustdoc too, as `--test-args`, so a doctest is skipped
by its name (`--skip "src/lib.rs - net::connect"`); per-binary
`test.binaries.<binary>.args` do not.

- [`test.doctest`](../reference/options/packages.md#packagesnametestdoctest)
  gives a package's doctest run its own `enable`, `args`, `env`, `path`
  and `postRun`, over the package's `test` settings, as
  `test.binaries.<key>` does for a binary
  ([run settings](configuration.md#run-settings)).
- rustdoc runs each example itself, so doctests have no `wrapper`,
  `runner`, `preRun` or `stages`: under `test.doctest` they are an error,
  and the package's do not apply. A doctest gets a fresh `HOME` and
  `RUST_TEST_THREADS` from breakbulk-unit, and its platform's runner
  through `--test-runtool`.
- `test.doctest.enable = false` leaves the doctest run out of
  `repo.checks` and the check groups. As there is no separate compile,
  the checks then build nothing of it; `doctests.<pkg>` still builds it.
  A project whose CI runs the doctests of a few crates only sets
  `memberDefaults.test.doctest.enable = false` and `true` for those.
  [`test.binaries.<key>.enable`](../reference/options/packages.md#packagesnametestbinariesnameenable)
  does the same for one test binary.

**Benches** come only from a bench variant (`cargo bench --no-run`, bench
profile), which gives optimized bench binaries to run outside Nix.
`cargo test --no-run` builds no benches. Each bench binary also runs
once in test mode, as a check of that variant (`<pkg>/bench-<name>`),
so that a bench that no longer runs fails CI; timed runs never happen
inside Nix. Bench runs are runs like the others, with their own layer of
run settings,
[`bench`](../reference/options/packages.md#packagesnamebench): its
`args` start with `--test` (libtest's and Criterion's test mode), and
`bench.enable = false` leaves a package's bench runs out of the checks
(`test.binaries."bench/<name>".enable = false` one of them).

## Documentation

`target.<triple>.docs` is what `cargo doc` writes: one folder with a
directory per documented crate (`base/index.html`), the shared search
index, `crates.js` and `static.files/`. Each variant has its own
(`target.<triple>.variants.<v>.docs`); `target.<triple>.docs` is the
default variant's. Open `<crate>/index.html` in it, as in Cargo's
`target/doc`.

- By default only the planned packages are documented, as with
  `cargo doc --no-deps`. With
  [`docs.noDeps = false`](../reference/options/workspaces.md#workspacesnamevariantsnamedocsnodeps)
  their dependencies are documented too, and links to a dependency's
  items go to its pages in the same folder.
- It is one derivation. rustdoc merges the cross-crate files (the search
  index, the list of crates, the implementors of each trait) into the
  folder as each crate is documented, and stable rustdoc has no way to
  merge them later. So any change to any documented crate runs every
  rustdoc again. That is why a variant's docs are in `repo.checks` only
  with
  [`docs.check = true`](../reference/options/workspaces.md#workspacesnamevariantsnamedocscheck).
  The flake-parts module puts each workspace's docs (the default target
  and variant's) in the flake's `packages` as `<ws>-docs`.
- The crates rustdoc reads are check-mode units: metadata only, no code.
  They are the same derivations as a check variant's with the same
  profile and features, so the docs and `cargo check` share them.
- Each crate is documented after the documented crates it uses. A link
  from one crate to another resolves only when the other's pages are
  already there, so every link that can resolve does. Under
  `cargo doc --no-deps`, Cargo does not order the members, and which
  links resolve can change from run to run.
- A proc macro's pages are in the same folder as the rest, as with
  `cargo doc` without `--target`. With `--target`, Cargo puts them in
  `target/doc` and the other crates in `target/<triple>/doc`.

Cargo fails `cargo doc --target <triple>` without `--no-deps` with
"document output filename collision" when a proc macro is a workspace
member, another member depends on it, and the profile's `opt-level`
differs from its `build-override`'s (`release`: 3 and 0)
([rust-lang/cargo#10368](https://github.com/rust-lang/cargo/issues/10368)).
Cargo then has two doc units for the proc macro: the member's, with the
profile, and the dependency's, with the build override. Without
`--target`, Cargo drops the second; with it, it does not. breakbulk
always passes `--target`, so the doc plan of such a workspace fails the
same way with `docs.noDeps = false`. Use `docs.noDeps = true`, or a variant
whose profile has the `opt-level` of its build override (the `dev`
profile, or `[profile.release.build-override] opt-level = 3`, which also
optimizes build scripts and proc macros).
