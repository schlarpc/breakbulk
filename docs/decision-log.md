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

## 13. ASK: git dependencies that inherit settings from their own workspace

Some git dependencies say "my version/edition/dependencies come from my
workspace" (`version.workspace = true`). Cargo refuses to read such a crate
from a vendored copy unless it can find that workspace. Choice made: next to
each vendored git source, breakbulk writes a tiny `Cargo.toml` containing
only the original `[workspace]` section, and lets Cargo do the merge itself.
The alternative, rewriting each manifest in Nix, would copy Cargo's merge
rules, which change between Cargo releases. Limits: a single git repository
whose crates belong to two different workspaces fails with a clear error.
Tell me if you have such a dependency.

## 14. ASK: `gitHashes` uses a different hash than crane's `outputHashes`

To let a binary cache serve a git dependency instead of cloning it on each
fresh machine, you may give its hash. breakbulk passes it to Nix's built-in
git fetcher (so no import-from-derivation is needed); this is the hash of
the fetched tree, which is not the same number crane asks for. You get the
right value from Nix's "hash mismatch" error or `nix flake prefetch`. Keys
are the full `Cargo.lock` source string including the commit. If you would
rather copy hashes over from existing crane setups, this would have to
change to a build-time fetch, which needs import-from-derivation.

## 15. ASK: crate source paths change when nixpkgs changes

Each downloaded `.crate` file is fixed (same hash forever), but unpacking it
uses tools from the nixpkgs you pass in. So bumping nixpkgs gives every crate
a new source path, and every crate rebuilds. This usually costs nothing extra,
because a nixpkgs bump usually changes the compiler too. If you want crate
sources to survive nixpkgs bumps (for example, when you pin the compiler
separately from nixpkgs), breakbulk can unpack with its own pinned tools.

## 16. FYI: smaller findings from the Nix library work

- Git dependencies are fetched with submodules, and without honoring
  `export-ignore`, to match what Cargo sees in a real checkout.
- An alternative registry needs both its `index` URL and its download
  (`dl`) URL template in config, since `Cargo.lock` records only the index.
- `gitTrees.<url> = ./path` points a git dependency at a local checkout.
- Plain `cargo build` never builds examples; only the test plan
  (`cargo test --no-run`) does. The docs said build plans include
  examples; they will be corrected.
- The planning skeleton must include empty README files, because Cargo sets
  `CARGO_PKG_README` only when one exists.
- Cargo reads `.cargo/config.toml` from every parent directory. Inside the
  Nix sandbox that is harmless, but for local tests in a home directory it
  picks up `~/.cargo/config.toml`, so local trace tests must run outside
  the home directory.

## 17. ASK: one library, two path-hiding settings (shipped code vs tests)

Background: the design hides source paths differently for shipped binaries
(debug info keeps real paths so a debugger can find sources) and for test
binaries (hide everything, so a test binary's bytes don't change when an
unrelated file in its package changes). The setting is a compiler flag on
each crate, including libraries. A library used by both a shipped binary and
a test binary can only have one setting, unless it is compiled twice.

Current default: libraries use the shipped-binary setting; only the test
crate itself hides everything. Effect: tests share compiled libraries with
the normal build (good for cache and build time), but a test binary's debug
info still mentions the source paths of the workspace libraries it uses, so
editing an unrelated file in such a library (a README, say) changes the test
binary's bytes and re-runs its tests. The alternative is compiling workspace
libraries twice (once per setting), which doubles their build cost in
exchange for fewer test re-runs. Third option: strip debug info from the test
binary copy that the test run uses, keeping a debug copy aside.

## 18. FYI: the unit builder works end to end

`breakbulk-unit` (the program that builds every unit) now compiles crates and
runs build scripts. A hand-written two-crate example with a build script
builds as real Nix derivations, the binary runs, outputs are bit-identical on
rebuild, and no source or build-script path leaks into the binary. Details:

- Each unit starts from an empty environment plus a fixed base; only
  `TMPDIR` and `NIX_BUILD_CORES` come from outside.
- Build scripts killed by a signal fail with the signal named.
- When a build script declares it reads a file that isn't in its sandbox, the
  message names the option to add (`packages.<name>.extraSources`, etc.).
- Large unit descriptions can come in a file instead of an environment
  variable, because Linux limits one variable to 128 KiB.
- Proc macros' compiled library is stored in the same output slot as normal
  libraries' `.rlib` (internal detail).
