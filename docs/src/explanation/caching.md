# Caching and early cutoff

*Early cutoff* means: when a derivation's output comes out byte-identical
to last time, the derivations after it do not rebuild. Nix can only do this
for content-addressed (CA) derivations. This page explains where breakbulk
uses them, where it does not, and why.

## Units are input-addressed

Every unit is an ordinary input-addressed derivation. A cache hit is a
plain narinfo lookup, downloads only the output you asked for, and works
on any binary cache.

CA units would cost too much today:

- To substitute a CA derivation, Nix first *resolves* it, which fetches
  the contents of all its inputs. A fresh machine pulling a cached graph
  of CA units would download every intermediate `rlib`, not just the
  binary it asked for. The fix is
  [NixOS/nix#11928](https://github.com/NixOS/nix/issues/11928), with an
  open implementation in
  [#14833](https://github.com/NixOS/nix/pull/14833).
- Caches that store paths only, without realisations (Attic, FlakeHub
  Cache), cannot serve CA outputs at all.
- Rust gains less from unit-level cutoff than it seems: most upstream edits
  change rustc's crate hash, which every dependent records, so they
  rebuild anyway (see [The rustc limit](#the-rustc-limit)).

Full-CA units remain a mode switch for when Nix can resolve without
fetching ([#16](https://github.com/schlarpc/breakbulk/issues/16)):
instantiation is templating, so it can write either form.

## Content addressing at the edges

CA is used where cutoff pays off and a CA derivation's direct inputs are
input-addressed, so resolving it downloads only those inputs:

- **Test runs** run a CA copy of the test binary: identical bytes, no
  re-run.
- **Post-link stages and checks**: identical input, no re-run of what
  follows.
- **Embedded products**, in dynamic-derivation mode: a unit that embeds
  another workspace's product is resolved at build time (whatever `ca`
  says), so an identical product does not rebuild it.

Test runs, stages and checks are content-addressed when
[`ca`](../reference/options/repository.md#ca) is on. By default it is on
exactly when the evaluator has dynamic derivations (which need Nix's
`ca-derivations` feature too), because Nix code cannot tell whether
`ca-derivations` is on. Without CA, stages and test runs
simply re-run when their input's derivation changes.

On a cache without realisations this degrades gracefully: units are still
substituted; stages and test runs re-run.

## Where cutoff fires

| Change | Cutoff? |
| --- | --- |
| rustc version bump | No: rustc writes its version into every crate's metadata, and Cargo hashes it into `-C metadata` |
| `breakbulk-unit` or wrapper change | No for units (input-addressed); possible with full-CA units |
| Build script recompiled with identical output | No for units; possible with full-CA units |
| Byte-identical test binary | Yes: the test run is skipped |
| Post-link stage given identical input | Yes |
| Byte-identical embedded product | Yes, in dynamic-derivation mode |
| Function-body edit in an upstream library | No: rustc's crate hash changes, and dependents rebuild |
| Interface change | No, correctly |

## Test-only paths

Some edits should not reach a unit at all. A package's `tests/` directory
is in the source of its test units only, so editing a fixture there
changes only those units:

| Edit | Rebuilds |
| --- | --- |
| a fixture in `tests/` | the package's test units (integration tests, benches, test harnesses, examples), doctest and test runs |
| a path in [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope) | the same |
| any other file of the package | the package and everything that depends on it |

The cost is a second source view for such a package. Non-test code that
reads a test-only path at compile time (`include_str!("../tests/…")`)
fails with a hint;
[`test.scopeTestsDir = false`](../reference/options/packages.md#packagesnametestscopetestsdir)
puts `tests/` back into every view.

## What has to be deterministic

Cutoff and reproducible products need byte-stable outputs. breakbulk makes
sure that:

- `-C metadata` comes from Cargo's own unit identity, never from
  derivation paths or absolute paths. The planner's skeleton always sits
  at the same absolute path, because Cargo hashes the absolute path of
  path crates outside the workspace root (unless `trim-paths` is on).
- Source paths are hidden, as described in [Source paths and debug
  information](products.md#source-paths-and-debug-information).
- Units never build incrementally: the planner strips `-C incremental`
  and never sets `CARGO_INCREMENTAL`, because the incremental setting is
  part of every unit's `-C metadata`.
- Binaries get a content-derived `--build-id`.
- CMake's internal state (`CMakeFiles`, with its configure log) is removed
  from build-script output after the run; the rest of the build tree is
  kept.

`nix run .#test-rebuild` builds every fixture's products and a sample
of its units twice and compares the bytes (see
[How breakbulk is tested](internals/testing.md#rebuild-check)).

## The rustc limit

A dependent rebuilds after almost any upstream edit, because rustc's crate
hash covers function bodies and source positions, and dependents record
it. Cargo behaves the same way. What is changing:

- [rust-lang/rust#154724](https://github.com/rust-lang/rust/pull/154724)
  (Rust 1.100) computes the crate hash from the encoded metadata bytes, so
  equal `rmeta` bytes mean an equal crate hash. It also makes any byte
  difference in metadata a link error between separately built `rmeta` and
  `rlib`.
- [Relink, Don't Rebuild](https://github.com/rust-lang/rust/issues/158844)
  (`-Z public-api-hash`) has not landed. Its implementation,
  [#156940](https://github.com/rust-lang/rust/pull/156940), is a draft;
  the [2026 goal](https://goals.rust-lang.org/2026/roadmap-fast-builds.html)
  is listed as unfunded.
- A published measurement on an async-heavy codebase found the public hash
  unchanged for only 2% of non-test edits: every `async fn` body edit
  changed it, because coroutine MIR is in the metadata.
- A public hash lets Cargo skip direct dependents, but a pure build system
  still rebuilds them, because their input bytes changed. Cutting off at
  the first dependent needs a physical split: what dependents read in one
  file, spans and private data in another. That is what to ask rustc for
  ([#15](https://github.com/schlarpc/breakbulk/issues/15)).

## Below the crate

- **`rmeta` and `rlib` are separate outputs.** Compiling a dependent needs
  only `rmeta`; linking needs `rlib`. A machine building one crate on
  cached dependencies downloads only their `rmeta`, and check and clippy
  variants use only `rmeta`.
- **Source narrowing from dep-info** (not built yet,
  [#7](https://github.com/schlarpc/breakbulk/issues/7)) would give each
  crate its exact file set, so edits outside its module tree change
  nothing. The cost is re-running macro expansion, and files that proc
  macros read are not tracked and must be declared.
- **Separate link derivations** would need nightly `-Zno-link` and
  `-Zlink-only`, so linking stays inside bin and test units.
- **No impure caches.** rustc's incremental state or a shared compiler
  cache in the sandbox would give reuse inside a crate, but outputs would
  then depend on build history and could not be cached or shared. That
  reuse belongs to local `cargo` in the dev shell.

## Pipelining

Cargo starts compiling a dependent as soon as an upstream library's
`rmeta` is written, while the upstream library is still generating code.
Nix publishes a derivation's outputs only when it finishes, so one
derivation per library cannot do that. Cargo's own measurements put the
gain at 10–20% on clean optimized builds (up to 26%), less on debug
builds, and close to nothing on few cores. breakbulk accepts that cost by
default.

A *pipelined split* would make a library two derivations, one for `rmeta`
and one for `rlib`. On stable rustc both must run the identical command,
because the kinds of output are part of the crate hash; the first stops
when rustc reports the metadata written. Possible backends:

| Backend | How | Cost |
| --- | --- | --- |
| Rerun and stop (as rules\_rust does) | run rustc twice | the frontend runs twice |
| `-Zno-codegen` (as Buck2 does) | a metadata-only compile, then a full one | the frontend runs twice; needs `RUSTC_BOOTSTRAP` on that crate's compiles only, with an empty `-Zallow-features=` |
| CRIU checkpoint and restore | the `rmeta` derivation checkpoints rustc at the metadata notification; the `rlib` derivation restores it and finishes codegen | Linux only; needs namespace privileges in the sandbox and a compatible CPU and kernel at restore |

None is built. Measured on real workspaces, the two rerun backends cost
23–49% more CPU and are slower than no split at 4 cores; only CRIU keeps
the gain ([#14](https://github.com/schlarpc/breakbulk/issues/14)).

Any backend would fall back to an unsplit compile, check that the `rlib`'s
crate hash matches the `rmeta` its dependents used, and allow a
per-package opt-out for crates that do not build reproducibly. Which
crates are split would be configuration
([`packages.<name>.pipelining`](../reference/options/packages.md#packagesnamepipelining)),
never a guess made on the building machine. Not options: a metadata-only
`--emit=metadata` compile (no optimized MIR for dependents' codegen, and a
different crate hash), and `-Zalways-encode-mir` (still a different crate
hash).
