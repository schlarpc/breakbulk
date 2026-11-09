# Products, stages and tests

`ws.packages.<name>` gives the right artifact for its target with no configuration. Underneath it, every step is its own named derivation that can be read, replaced or removed.

## Three layers

1. **Units.** One derivation per Cargo unit. Internal, but inspectable.
2. **Stage pipelines.** A product is the raw link output passed through ordered, named stages. Each stage is its own content-addressed derivation, so every intermediate is addressable (`.stages.linked`) and cutoff applies between stages.
3. **Sugar.** `ws.packages.<name>` and `ws.target.<triple>.packages.<name>` are the raw output, run through the target preset's default stages, installed in the usual layout (`bin/`, `lib/`, `.exe` with DLLs, `pkg/` for wasm).

## Default stages per preset

What happens to debug info is a property of the target, not of a stage list: [`targets.<t>.debugInfo`](../reference/options/targets.md#targetsnamedebuginfo) is `"split"`, `"keep"` or `"strip"`, and puts the matching stage first. The units are shared by every package of the target and their remap scope and build ID depend on it, so no package can add or remove that stage.

| Preset | debugInfo (default) | Default stages |
| --- | --- | --- |
| Linux gnu / musl | split | `splitDebug` |
| Windows msvc | keep | none (PDBs are already separate; `install` puts them in the `debug` output) |
| wasm, browser | keep | `bindgen` → `wasmOpt` |
| wasm, component | keep | `wasmOpt` → `componentize` |
| Darwin (not yet, [#13](https://github.com/schlarpc/breakbulk/issues/13)) | to decide (`.dSYM` via `dsymutil`) | `dsymutil` → `strip` → `adhocSign` |

The tool never applies an implicit fixup phase. Stripping breaks some signing schemes, and some checks must see unstripped bytes, so any default stage can be removed or reordered.

## Transforms and checks

Stages that change the artifact form the chain. Checks that only inspect it (ISA level, DLL import closure, PE headers, signature verification, "no interpreter, no needed libraries") hang off a named stage instead. They see exactly the bytes they need, never block the chain, and appear under `checks` automatically.

```nix
packages.server.checks.isa = { on = "linked"; run = isaCheck; };  # sees pre-strip bytes

packages.app.target."x86_64-pc-windows-msvc".stages = {
  stageDlls = { after = "linked"; run = stageRuntimeDlls; };
  zip       = { after = "stageDlls"; run = deterministicZip; };
  strip     = lib.mkForce null;  # signing breaks if stripped
};
```

The tool provides stage helpers: `splitDebug`, `strip`, `patchelfRpath`, `bindgen`, `wasmOpt`, `componentize`, `deterministicZip`. User stages are ordinary derivations: container images, initramfs and boot images, distribution packages, catalog generation and signing, metadata stamping.

## Source paths and debug information

Source paths must not end up in shipped outputs. Every crate's source is a store path, so an embedded source path is a real store reference: Nix would treat the sources as a runtime dependency, and any edit to a package would change the bytes of every binary that embeds its paths, defeating cutoff.

Paths are remapped by scope (rustc's `--remap-path-scope`, stable since 1.95):

- **Shipped binaries and cdylibs** of a target that splits debug info (`debugInfo = "split"`, the default on Linux) remap panic locations, `file!()` and diagnostics, but keep real store paths in debug info. `splitDebug` moves DWARF to a separate `debug` output (`$debug/lib/debug/.build-id/…`, found by gdb and debuginfod). The main output has no source references; the `debug` output references exactly the sources a debugger needs, so installing it gives source-level debugging with no setup.
- **Test binaries** keep their debug info, because symbolized backtraces in test-run logs matter, and remap every scope, so a test binary's bytes do not change when unrelated files in its package change. The workspace libraries they link are compiled once, with the shipped scope, so their debug info still names their source views: an edit to any file of such a library (a README) changes the bytes of every test binary linking it. `test.stripForRun` (off by default) has the test run consume a debug-stripped copy instead, which does not change; the unstripped binary stays available for debugging.
- On a target that keeps or strips debug info, every scope is remapped.
- With rustc older than 1.95, every scope is remapped.

Remapping is breakbulk's job until Cargo can do it. Cargo's `trim-paths` profile setting (stable in Cargo 1.101; a hard error on earlier stable releases) computes the same remaps and also removes absolute paths from the identity of path crates outside the workspace root. Its default is off for every profile, `release` included. On Cargo 1.101 and later, breakbulk sets it when the project has not set it, uses Cargo's remaps instead of its own, and sets the scope per product kind as above. A setting passed with `--config` would replace the project's, and copying Cargo's profile rules to see whether the project set it is not worth it, so breakbulk reads the files instead: any `trim-paths` under `[profile]` in the workspace root's `Cargo.toml` or the project's Cargo config leaves the choice to the project, and its own scope is kept. `cargoTrimPaths` forces it on or off, and `sourcePaths = "keep"` turns all path hiding off. Under Cargo's trim-paths, breakbulk's C prefix maps use Cargo's names, so they agree with cc-rs, which reads the same remaps from `CARGO_TRIM_PATHS_REMAP`.

## Tests as products

- Every test, bench and example binary is an attribute, so VM tests and system tests can consume it.
- Each test binary gets a test-run derivation that uses the target's `runner` and any declared env and `PATH` additions (a software GPU driver, external tools). The test run consumes a content-addressed copy of the test binary, so a byte-identical test binary is not re-run.
- `CARGO_BIN_EXE_*` is wired to the right product, and nextest configuration is respected.
- Test-run derivations for another architecture set `system` to that architecture, so Nix sends them to native builders. Emulation through the runner is the fallback.
- Targets that Cargo skips because their `required-features` are not enabled still have attributes. Building such a product fails with the reason; such a test run succeeds and logs that it was skipped, as `cargo test` does.
- Tests that cannot run in the sandbox (network, a writable home, devices) are skipped with libtest's own filters, per package or per test binary. Changing a skip list re-runs only the affected test runs.
- Every test binary also has a runnable app that sets up the same working directory, environment and runner as its test run, but runs on the user's machine: the escape hatch for network tests, debuggers and single-test reruns.
- **Doctests** get one derivation per library crate, which runs `rustdoc --test` against the crate and its dependencies. Compiling and running happen in one rustdoc process, so doctests have no cutoff and re-run whenever the crate or anything below it changes.
- **Benches** come only from a bench variant (`cargo bench --no-run`, bench profile), which provides optimized bench binaries to run outside Nix. `cargo test --no-run` builds no benches, so the test plan has none. Optional smoke checks run each bench once in test mode.

## Documentation

`cargo doc` writes every crate into one shared directory and updates cross-crate indexes in place, which does not split into per-crate derivations on stable rustdoc. The docs product (not built yet, [#6](https://github.com/schlarpc/breakbulk/issues/6)) is therefore one derivation per workspace and target that replays the traced `rustdoc` commands in Cargo's order, against the check-mode `rmeta` units it shares with check and clippy variants. Per-crate documentation waits for rustdoc's mergeable cross-crate info to stabilize.
