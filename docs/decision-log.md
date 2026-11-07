# Decision log

Decisions made while implementing, for the author to review. Each item says
what was decided, why, and what to do if you disagree. Newest last.

Status: **FYI** (already done, tell me if you object) · **ASK** (your call;
work continues on the stated default until you answer).

## 1. FYI: breakbulk's own code needs Rust 1.95 or newer

breakbulk itself is written with the 2024 edition of Rust and declares
Rust 1.95 as its minimum. That matches the oldest Cargo in the support window
(about six months of stable releases), so nothing here limits which projects
breakbulk can build. If you want breakbulk's own binaries to build on an
older compiler, say which one.

## 2. FYI: test toolchains come from rust-overlay

The flake pins `nixos-unstable` for nixpkgs and adds `oxalica/rust-overlay`
so tests can run against several Cargo releases (1.95, 1.97, 1.99 and
nightly). rust-overlay is used only for breakbulk's own tests and dev shell;
users still bring their own toolchain. If you prefer fenix, it is a small
swap.

## 3. FYI: how the work is being split

The three risk spikes from the implementation plan (tracing Cargo, Nix
dynamic-derivation delivery, environment capture) run in parallel with two
pieces that do not depend on them: the build-script output parser plus the
`plan.json` data types, and the Nix code that reads lockfiles, fetches
crates, builds the planning skeleton and predicts output names. Each runs on
its own branch and is merged after review. Spike write-ups land in
`docs/spikes/`.


## 4. FYI: `breakbulk-unit` depends on `serde` and `serde_json`

`breakbulk-unit` is an input of every unit, so every dependency is a reason
for a full rebuild when it changes. It still uses `serde` (with derive) and
`serde_json`: it must read `BREAKBULK_UNIT`, read and write
`directives.json` and `metadata.json`, and parse rustc's JSON diagnostics.
A hand-written JSON reader would be a few hundred lines of new code with its
own escaping bugs; `serde_json` is mature, and its version only changes when
`Cargo.lock` is deliberately updated. If you want no dependencies at all,
the cost is that hand-written parser.

## 5. ASK: the `BREAKBULK_UNIT` types live in `breakbulk-unit`, not `breakbulk-format`

The per-unit types (`RenderedUnit`, splice kinds, package targets) are defined
in `breakbulk-unit`'s library, and `breakbulk-format` depends on
`breakbulk-unit` and re-exports them. The other direction would make every
edit to the plan format (a new header field, a validation rule) change
`breakbulk-unit`'s inputs and so rebuild every unit. The wrapping table
(`wrap`) and the splice shape check are shared the same way, so the planner
checks sentinels with the same code that expands them. If you prefer a third
tiny crate for the shared types, it is a mechanical move.

## 6. FYI: run units carry four fields the plan example does not show

A `run` unit in `plan.json` also has `cwd` (the package directory Cargo ran
the script in), `rustVersion` (the package's `rust-version`), `targets` (the
package's targets from `cargo metadata`) and `nightlyFeaturesAllowed`. The
last three are what Cargo's directive parser takes as arguments: the
`cargo::` syntax is an error when `rust-version` is below 1.77,
`rustc-link-arg-bin=NAME=` must name a bin target, `rustc-link-arg-tests`
needs a test target, and `rustc-env=RUSTC_BOOTSTRAP=…` is an error on stable
but only a warning on nightly. The `rustc-link-arg-bin` splice carries the
bin name in a `bin` field.

## 7. FYI: two directive kinds are expanded across splice points, not one at a time

The design says each splice point expands to "run R's directives of that
kind, in the order the script printed them". Cargo's source and an experiment
with Cargo 1.99 show two exceptions, now implemented in
`breakbulk-unit/src/splice.rs`:

- **`rustc-link-search`.** Cargo gathers the `-L` paths of all build scripts
  a unit links, then puts every path inside the printing script's own
  `OUT_DIR` before every other path. Expansion does the same: each run's
  inside paths at its splice point, then all runs' outside paths after the
  last link-search splice point. The run records which paths are inside
  `OUT_DIR` when it parses its output.
- **`rustc-link-arg` and its forms.** Cargo keeps one list per run in printed
  order. A script printing `arg-bins=1`, `arg=2`, `arg-bins=3` gives the bin
  `1 2 3`; splicing kind by kind would give `2 1 3`. Expansion emits all of a
  run's applicable link args at its first link-arg splice point.

Both need the splice points involved to be adjacent, as Cargo emits them;
expansion and plan validation fail otherwise. One known gap: a `links`
override from config (`[target.<triple>.<links>]`) adds outside paths that
Cargo interleaves with the scripts' outside paths in dependency order;
breakbulk would put them after. The differential tests will show if this
matters.

## 8. ASK: an `error` directive with leading spaces does not fail the run in Cargo

Cargo fails a successful run only for stdout lines that begin exactly with
`cargo::error=`. A line like `  cargo::error=x` is still parsed and printed
as an error, but the build continues (checked with Cargo 1.99). The design
says breakbulk fails "on any `error` directive". The parser offers both
rules (`streamed_log_messages` is Cargo's; `BuildOutput::has_errors` is the
stricter one). The default for run mode is Cargo's rule, for parity. Say if
you want the stricter one.

## 9. FYI: what canonical `plan.json` means

Canonical JSON here is compact, with object keys sorted by their bytes and
`serde_json`'s string escaping; floats are refused. Before writing, the plan
is put in a normal form: adjacent literals in a concatenation are merged,
empty literals dropped, and a concatenation of literals only becomes a plain
string. Arrays that are sets (`roots`, `features`, crate types, a run's
`targets`, `metadataFrom`) are sorted; arrays whose order matters (`args`,
`program`, `envSplices`) are not.

## 10. FYI: the plan example in the implementation doc has one argument wrong

`["--extern", "cfg_if=", {"out": …}]` is one array, so by the format's own
rule it is one argument, `--externcfg_if=<path>`. It should read
`"--extern", ["cfg_if=", {"out": …}]`. The code follows the rule, not the
example.

## 11. FYI: how forbidden literals and sentinels are detected

A forbidden path (scratch, skeleton, vendor directory, `/build`, `$HOME`)
matches only as a whole path: `/build` matches `dependency=/build/x` and
`-L/build`, but not `/build.rs` or `/nix/store/…-src/build/x.c`. A sentinel
is `__bb` in any case followed by a non-alphanumeric character or the end, which
covers `__bb_R_cfg`, `__BB_R_ENV`, `__bb=R` and `DEP_X___BB`. The shim's
sentinel names must keep that prefix.

## 12. FYI: not done yet: dynamic-library path splices

The planner turns sentinel search paths found in `LD_LIBRARY_PATH`-style
variables into splice points, but the plan format has no shape for them yet,
and it depends on where the trace spike finds them. One finding for that
work: Cargo's rule for these variables keeps paths inside the whole build
directory (any script's `OUT_DIR`), not only inside the printing script's
own `OUT_DIR`, which is the rule for `-L` ordering. In breakbulk that means
"inside any run's `out`".
