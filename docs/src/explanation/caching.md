# Caching and early cutoff

## Why units are input-addressed

Nix (2.35 and current master) stores CA realisations in binary caches only for *resolved* derivations, and resolving a derivation realises the contents of all its inputs first. A fresh machine pulling a fully cached graph of CA units therefore downloads every intermediate rlib and every input, not just the requested binary. The fix is tracked as NixOS/nix#11928, with an open implementation in #14833. Caches that do not store realisations at all (Attic, FlakeHub Cache, which pushes store paths only) cannot serve CA outputs, so CA units there are always rebuilt.

Input-addressed units avoid all of this: a cache hit is a narinfo lookup, substitution never touches inputs, and every cache server works. Rust also gains less from unit-level cutoff than it seems, because most upstream edits change rustc's crate hash and cascade to dependents anyway.

## Content-addressed islands

Content addressing is used where cutoff pays off and a CA node's direct inputs are input-addressed, so resolving it downloads only those inputs:

- **Test runs** consume a CA copy of the test binary. Identical bytes, no re-run.
- **Post-link stages** are CA. Identical input, no re-run of later stages.
- **Embedded products.** In dynamic-derivation mode, products are always resolved at build time, because their first stage depends on a unit derivation that exists only after instantiation. A unit that embeds a product is therefore resolved too, and an identical product does not rebuild it. In IFD mode, products are input-addressed unless CA embedding is turned on.

Rule: no input-addressed derivation sits downstream of a CA node, except the embedding chain, whose cost is documented. On caches without realisations, islands degrade gracefully: stages and test runs re-run; units are still substituted. The embedding chain in dynamic-derivation mode is deferred (resolved at build time) rather than CA, so it is still substituted as long as the product it embeds reproduces with the same bytes.

**Full-CA units** remain a mode switch for when Nix resolves derivations from realisations without fetching input contents. Instantiation is templating, so it can emit either form.

## Where cutoff fires

| Change | Cutoff |
| --- | --- |
| rustc version bump | No: rustc writes its version into every crate's metadata, and Cargo hashes it into `-C metadata` |
| `breakbulk-unit` or wrapper change | No for units (input-addressed); possible with full-CA units |
| Recompiled build script with identical output | No for units (input-addressed); possible with full-CA units |
| Byte-identical test binary | Yes: the test run is skipped |
| Post-link stage given identical input | Yes |
| Byte-identical embedded product | Yes in dynamic-derivation mode; opt-in in IFD mode |
| Function-body edit in an upstream library | No: rustc's crate hash cascades to dependents |
| Interface change | No, correctly |

## Determinism requirements

Islands only cut off, and products only reproduce, if outputs are byte-stable.

- `-C metadata` comes from Cargo's stable unit identity, never from derivation paths or absolute paths. The planner's skeleton sits at one fixed absolute path, because Cargo hashes the absolute path of path crates outside the workspace root (until `trim-paths`).
- Source paths are remapped as described in [Source paths and debug information](products.md#source-paths-and-debug-information).
- No `-C incremental` inside unit builds. The planner strips it from argv and never sets `CARGO_INCREMENTAL`, because the incremental setting is part of every unit's `-C metadata`.
- A content-derived `--build-id`.
- CMake's internal state (`CMakeFiles`, with its configure log) is removed from build-script output after the run; the rest of the build tree is kept.
- A built-in check that rebuilds sampled units and products with `nix build --rebuild` and compares their outputs is planned ([#2](https://github.com/schlarpc/breakbulk/issues/2)); today individual fixtures check this.

## The rustc limit, and what is changing

Today a dependent rebuilds after almost any upstream edit, because rustc's crate hash (SVH) covers bodies and source positions and dependents record it. Cargo behaves the same way.

- [rust-lang/rust#154724](https://github.com/rust-lang/rust/pull/154724), merged 2026-09-26 and shipping in 1.100, computes the crate hash from the encoded metadata bytes. rmeta byte-equality and crate-hash equality become the same thing. It also makes any byte-level nondeterminism in metadata a link error between separately built rmeta and rlib.
- [Relink, Don't Rebuild](https://github.com/rust-lang/rust/issues/158844) (`-Z public-api-hash`) is not landed. Its main implementation, [#156940](https://github.com/rust-lang/rust/pull/156940), is a draft under review. The [2026 goal](https://goals.rust-lang.org/2026/roadmap-fast-builds.html) is listed as unfunded.
- A published third-party measurement on an async-heavy codebase found the public hash unchanged for 2% of non-test edits. Every `async fn` body edit changed it, because coroutine MIR is encoded in metadata.
- A public-hash design lets Cargo skip direct dependents, but a pure build system still rebuilds them, because their input bytes changed. Full cutoff at the first dependent needs a physical split: data that dependents read in one file, and spans and private data in another. That is the request to take upstream.

## Seams below the crate

- **rmeta and rlib as separate outputs.** Compile units need only transitive `rmeta` (reached through their direct dependencies' manifests); link units consume `rlib`. A machine building one crate on cached dependencies downloads only their `rmeta`; check and clippy variants consume only `rmeta`; full-CA units would cut off on `rmeta` bytes.
- **Source narrowing from dep-info** (not built yet, [#7](https://github.com/schlarpc/breakbulk/issues/7)). An optional stage would derive each crate's exact file set, so edits to files outside its module tree would change nothing. The cost is re-running macro expansion. File reads by proc macros are not tracked and must be declared.
- **Separate link derivations** need nightly `-Zno-link`/`-Zlink-only`, so linking stays inside bin and test units for now.
- **Rejected: impure caches.** Rustc incremental state or a shared compiler cache mounted into the sandbox would give reuse within a crate, but outputs would depend on build history and could not be cached or shared. That reuse belongs to local `cargo`.

## Pipelining

Cargo starts a dependent as soon as an upstream library's `rmeta` is written, while the upstream codegen continues. Nix publishes a derivation's outputs only when it finishes, so one derivation per library cannot pipeline. Cargo's own measurements put pipelining at 10–20% on clean optimized builds (up to 26%), less on debug builds, and close to nothing on few cores. That is the cost breakbulk accepts by default.

An optional **pipelined split** makes a library two derivations: one producing `rmeta`, one producing `rlib`. On stable rustc both must run the identical command, because the emit kinds are part of the crate hash; the first stops at rustc's metadata notification. Backends:

1. **Rerun and stop:** the rules\_rust approach. Stable, but runs the frontend twice.
2. **Checkpoint and restore:** the `rmeta` derivation checkpoints the rustc process with CRIU at the metadata notification; the `rlib` derivation restores it and lets codegen finish. One frontend, and both files come from one process. Linux only, needs namespace privileges inside the sandbox, and needs a compatible CPU and kernel at restore.
3. **`-Zno-codegen`:** the Buck2 approach. Needs `RUSTC_BOOTSTRAP` on the split crate's compile units only, never on build-script runs, together with an empty `-Zallow-features=` so stable-only code stays stable-only.

None of the backends is built. Measured on real workspaces, the rerun and `-Zno-codegen` backends cost 23–49% more CPU and are slower than no split at 4 cores; only CRIU keeps the gain ([#14](https://github.com/schlarpc/breakbulk/issues/14)). Every backend falls back to an unsplit compile, checks that the `rlib`'s crate hash matches the `rmeta` its dependents used, and has a per-package opt-out for crates that do not build reproducibly. Which crates are split is deterministic configuration, never a machine-local heuristic. Rejected: a metadata-only `--emit=metadata` action (no optimized MIR for dependents' codegen, and a different crate hash), and `-Zalways-encode-mir` (still a different crate hash).
