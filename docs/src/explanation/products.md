# Products, stages and tests

`repo.workspaces.<ws>.packages.app` gives you the finished `app` for its
target, with no configuration. Underneath, every step is its own named
derivation that you can read, replace or remove.

## Three layers

| Layer | What it is | Where |
| --- | --- | --- |
| Units | one derivation per Cargo unit | internal, but inspectable |
| Stages | the linked output passed through ordered, named steps | `.stages.<name>`, e.g. `.stages.linked` |
| Packages | the last stage, installed in the usual layout (`bin/`, `lib/`, `.exe` with its DLLs, `pkg/` for wasm) | `packages.<pkg>`, `target.<triple>.packages.<pkg>` |

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
```

Typical checks: ISA level, DLL import closure, PE headers, signature
verification, "no interpreter, no needed libraries".

breakbulk ships stage helpers: `splitDebug`, `strip`, `patchelfRpath`,
`bindgen`, `wasmOpt`, `componentize`, `deterministicZip`. Your own stages
are ordinary derivations: container images, boot images, distribution
packages, signing, metadata stamps.

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
| Test binaries | hidden | hidden; kept in the binary for backtraces in test logs |
| Anything on a target that keeps or strips debug info | hidden | hidden |
| Anything built with rustc older than 1.95 | hidden | hidden |

With `split`, `splitDebug` moves the DWARF to the `debug` output
(`$debug/lib/debug/.build-id/…`, where gdb and debuginfod look). The main
output names no sources; the `debug` output names exactly the sources a
debugger needs, so installing it gives source-level debugging with no
setup.

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
- Tests that cannot run in the sandbox (network, a writable home,
  devices) are skipped with libtest's own filters
  ([`test.args`](../reference/options/packages.md#packagesnametestargs)),
  per package or per test binary. Changing a skip list re-runs only the
  affected test runs.

**Doctests** get one derivation per library, which runs `rustdoc --test`.
rustdoc compiles and runs the examples in one process, so doctests have
no cutoff: they re-run whenever the library or anything below it changes.

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
