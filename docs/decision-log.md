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

## 19. FYI: environment capture works (spike C: go)

Packages' native dependencies (openssl, a C compiler, libclang for bindgen)
are turned into environment variables by running a real nixpkgs build
environment once per package and platform and saving what it set. Replaying
that saved environment gave byte-identical results to `buildRustPackage` for
`openssl-sys`, `ring` and a bindgen crate, both natively and when
cross-compiling to aarch64. Write-up: `docs/spikes/C-env-capture.md`.

## 20. ASK: how you name a package's libraries for build scripts

Build scripts and proc macros run on the build machine, so the libraries
they link must be the build machine's. Proposed: you write the list once as
a function, `inputs = p: [ p.openssl ]`, and breakbulk calls it with the
right package set for each side. The alternative is two lists you fill in
yourself (`inputs` and `host.inputs = [ buildPackages.openssl ]`), which is
more explicit but easy to get wrong silently. Default: the function form.

## 21. ASK: build-machine C code is hardened more than in `buildRustPackage`

When cross-compiling, `buildRustPackage` turns off nixpkgs' security
hardening flags for C code compiled for the build machine (inside build
scripts). breakbulk keeps them on, because its host environment is a normal
nixpkgs one. This only matters if some build script's C code fails to compile
with hardening. Default: keep hardening on; a per-package switch can turn it
off if needed.

## 22. FYI: build timestamp comes from one place

`SOURCE_DATE_EPOCH` is set in the fixed base of every unit (to nixpkgs'
default, 1980), not in each captured environment, so a per-package build
stamp overrides it in exactly one place.

## 23. FYI: C code's debug info will have source paths hidden too

Crates like `ring` compile C with debug info that embeds their source path.
Rust's path hiding doesn't touch C, so units will add the matching
`-ffile-prefix-map` flags to C compiler flags. Without it, shipped binaries
could still reference crate sources.

## 24. FYI: Nix's dynamic-derivation route works, with changes (spike B: go)

The plan's second delivery route, where Nix itself writes the per-crate build
steps during the build (instead of reading a generated JSON file), works on
Nix's development branch. It produces exactly the same build step IDs as the
JSON route, so the two share cache entries. It will first be in a released
Nix as 2.36; Determinate Nix doesn't have it yet. Two corrections to the docs
were made: Nix's own `nix derivation add` command can't be used for this, and
the feared extra recompiles for embedded products on caches like FlakeHub
don't happen. Write-up: `docs/spikes/B-delivery.md`.

## 25. ASK: use the harmonia library to write build steps in dynamic mode

The dynamic route has to write many small build-step files into the Nix store
from inside a build. Nix's command-line tool can't do that here; the
`harmonia` Rust library (MIT, by the Nix community; used for binary cache
servers) can, and gave byte-identical results. Catch: harmonia is
pre-release (version 0.0.0-alpha), so breakbulk would pin a specific git
commit. Alternative: shell out to `nix store add` and let Nix scan for
references, which is slower and less precise. Default: harmonia, pinned.
This only matters for milestone M5.

## 26. ASK: pushing to a public cache in dynamic mode uploads your source

In the dynamic route, the usual "push everything this build used" command
also uploads the filtered source trees of your workspace packages. That's
fine for a private cache or open-source code, but would leak private code to
a public cache. Options: just document it (default), or have breakbulk print
a warning when it detects the pattern. Tell me if you want the warning or a
different default.

## 27. FYI: product names in dynamic mode include workspace, target and variant

Nix requires the names of dynamically produced outputs to start with the name
of the step that produced them. breakbulk names that step
`<workspace>-<target>-<variant>`, so product store paths look like
`…-app-x86_64-unknown-linux-gnu-release-server`. Tell me if you'd prefer a
different scheme.

## 28. FYI: the first post-link step of a product will not be content-addressed

The step that picks up a product's raw link output (`linked`) can be a plain
step rather than a content-addressed one; both work. Plain is chosen because
caches that don't store the extra records content-addressing needs (FlakeHub
Cache) can still serve it. The later stages (strip, sign, ...) stay
content-addressed so an unchanged input doesn't re-run them.

## 29. ASK: the generated per-crate build file contains names, not paths

In the default (import-from-derivation) mode, breakbulk's Rust code
generates a JSON file describing every per-crate build step, which Nix then
reads. The docs planned to write real store paths into it. Instead it writes
named placeholders ("the source of package X", "output rlib of unit Y") and
Nix fills in the real paths when it reads the file. Benefits: editing a
source file or changing a per-package setting no longer reruns that
generation step at all, and nothing (no crate download, no toolchain) has to
be built before Nix can read the file. Cost: Nix does a bit more string work
per unit at evaluation time. This needs measuring on a graph with ~1,000
units; if it is too slow, the fallback is the original design.

## 30. ASK: names of outputs inside a workspace

Each predicted output is named `<package>/<kind>/<target>`, for example
`app/bin/app` or `app/test/integration`. A binary target that is also built
as a test (unit tests inside `src/main.rs`) gets `bin-test`:
`app/bin-test/app`. These are internal names; the user-facing attribute
names (`packages.app`, `tests.app.integration`) are built from them later.
Tell me if you want a different internal scheme before it spreads.

## 31. FYI: a library's own unit tests aren't predicted yet

`cargo test` also builds each library's `#[cfg(test)]` unit tests as a test
binary. The output-name prediction doesn't list those yet. This will be
fixed when the planner lands. Benchmarks that Cargo didn't select count as
"skipped" (succeed with a message) rather than failing.

## 32. FYI: tracing Cargo works (spike A: go)

The central bet of the design holds: breakbulk can run your real Cargo with
a stand-in compiler, record exactly what Cargo would run, and later
reproduce it. On Cargo 1.95, 1.97, 1.99 and current nightly, the recorded
commands, with build-script output filled in afterwards, matched a real
`cargo build` exactly for every unit (32 of 32 comparisons). Where
build-script output lands is identical across all four versions. Write-up:
`docs/spikes/A-trace-fidelity.md`. A few doc statements were wrong and are
being corrected (benches, profiles, see 35).

## 33. ASK: projects that set `rustflags` under `[build]`

Cargo takes extra compiler flags from exactly one place: per-target settings
(`[target.x86_64-unknown-linux-gnu] rustflags`) win, and `[build] rustflags`
is then ignored entirely. breakbulk's toolchain presets add flags (for
example `+crt-static` for static builds) as per-target settings, so a
project that puts its own flags under `[build]` would silently lose them.
Proposed default: the planner reads the project's `.cargo/config.toml`
files (a documented format), and if the project uses `[build] rustflags`
and no per-target flags, breakbulk adds its flags under `[build]` too; the
trace then confirms both sets of flags arrived. Alternatives: require
projects to use per-target flags (simplest, but a trap), or fail planning
with a message when both are present.

## 34. ASK: turning on Cargo's built-in path hiding (`trim-paths`)

Cargo 1.101 (not yet released as stable) can hide source paths itself, and
the design says breakbulk should switch it on when the project hasn't
chosen. breakbulk can't tell from outside whether the project chose, without
copying Cargo's profile rules. Proposed: plan once; if the result shows
path hiding is off and Cargo is new enough, plan again with it on. Planning
reruns only when manifests or the lockfile change and is quick compared to a
build. Alternative: never turn it on automatically and keep breakbulk's own
path hiding (works on all versions). Only relevant from Cargo 1.101.

## 35. FYI: corrections to the design from the tracing spike

- `cargo test --no-run` does not build benchmarks; they come only from the
  separate bench variant.
- Two profiles with the same settings (for example `release` and `bench`)
  produce identical, shared build steps. Only differing settings separate
  them.
- Changing the linker rebuilds every crate, not just binaries, because Cargo
  passes the linker to every compile. breakbulk keeps Cargo's behavior.
- Current nightly Cargo uses a new layout for its build directory; breakbulk
  will support both layouts.
- Nightly toolchains split library metadata out of `.rlib` files, so linking
  needs both files of each dependency.
- The design's "rustflags are concatenated with project config" was only
  true when both use the same config key (see 33).

## 36. ASK: C code's debug info names sources by short names

To keep crate source paths out of shipped binaries, C code compiled by build
scripts now has its source paths replaced with short names (like
`ring-0.17.14/crypto/...`) everywhere, including debug info. For Rust code,
the design keeps real paths in debug info (moved to a separate `debug`
output) so a debugger finds sources automatically. For C, that isn't
possible with this approach, because a build script doesn't know which final
product its C code ends up in. Effect: when debugging into C code from a
`-sys` crate, you'd point the debugger at the source by hand. Alternative:
leave C debug info alone and only hide `__FILE__`, at the risk of shipped
binaries keeping a reference to crate sources if debug info isn't split off.
Default: hide everywhere.

## 37. FYI: environment capture is in production code

- Variables that hold lists (`PATH`, `PKG_CONFIG_PATH`, C/linker flag
  variables, and ~15 similar) are appended across layers instead of
  replaced. The list is built into the unit builder, so extending it later
  rebuilds everything once.
- C compiler path hiding goes through nixpkgs' compiler wrapper, so it
  reaches cc-rs, cmake, make, C++ and assembly. The wasm and Windows presets
  use compilers without that wrapper and will need to add it themselves.
- A captured environment for host tools is the same derivation whether the
  build is native or cross, so it's built once and shared.

## 38. FYI: Windows (msvc) and wasm groundwork works

- breakbulk can download Microsoft's C runtime and Windows SDK (via the
  `xwin` tool) as a pinned, reproducible Nix download, marked unfree. A test
  program with C code, generated bindings, a Windows resource and Windows API
  calls cross-compiles from Linux and runs under wine; the ARM64 Windows
  build compiles and links. Write-up: `docs/spikes/msvc.md`.
- The `wasm-bindgen` command-line tool is picked to match the exact version
  in your `Cargo.lock`, from nixpkgs when it has it, else built from a
  table of known hashes (seeded with 0.2.123 and 0.2.125–0.2.130).
  Unknown versions fail with a message naming the version.
- Unfree permission is granted only to the SDK package. Note: your personal
  `~/.config/nixpkgs/config.nix` allows all unfree packages, which hides
  this in impure evaluations; flake checks are unaffected.

## 39. ASK: Windows builds need a small linker fix to be reproducible

Windows `.exe` files came out different on every rebuild: the linker writes
the path of a randomly named temporary folder into the debug-symbol file,
and that file's hash goes into the `.exe`. Microsoft's own "reproducible"
switch doesn't fix it. A small wrapper around the linker that copies the
inputs to a fixed path first makes rebuilds identical. Question: keep it as
part of the Windows preset (default; only Windows pays for it), or move it
into breakbulk's unit builder for all targets?

## 40. ASK: how strictly to pin the Windows SDK download

By default the SDK download reads Microsoft's live catalogue. The C runtime
version is exact, but files within SDK 10.0.26100 can be updated by
Microsoft; if that happens, a fresh machine's build fails with a hash
mismatch (it never silently changes). You can additionally pin the
catalogue file itself (`channelManifest`), which removes that risk unless
Microsoft deletes old catalogue URLs. Default: optional. Make it required?

## 41. ASK: choosing the LLVM tools that match your Rust compiler

Windows and wasm builds use LLVM tools (linker, C compiler) that should match
the LLVM version inside rustc. Only nixpkgs' own rustc says which LLVM it
uses; toolchains from rust-overlay or fenix don't. Proposed: a small table
mapping Rust version to LLVM major version, shipped with breakbulk, with an
option to override. Alternative: ask rustc at build time, which would need
import-from-derivation to pick the tool package.

## 42. ASK: should slow tests run in plain `nix flake check`?

Windows SDK download (252 MB), wine runs and cross toolchains make
`nix flake check` slow. They currently run there (marked HEAVY in
`flake.nix`). Alternative: a separate `heavyChecks` output that CI runs
explicitly. Default: keep them in `checks`.

## 43. FYI: evaluation speed is fine; graph size grows too fast (scale test)

A synthetic workspace shaped like zed's real lockfile was run at 300, 1,000
and ~3,700 crates. Filling in names at evaluation time (entry 29) costs only
3–6% of evaluation, so it stays. But every crate's build step currently lists
all crates below it as inputs, so the total grows roughly with the square of
the crate count: at ~3,700 crates, 154 MB of Nix build-step files and ~10 s
of evaluation, and about 1.5 minutes to write them the first time.
Write-up: `docs/spikes/scale.md`.

## 44. ASK: list only direct dependencies on each library build step

Fix for 43: each library build step lists only its direct dependencies;
the indirect ones still reach the compiler, because each library's output
carries a small file naming the ones below it, and Nix copies those along
automatically. What gets rebuilt, and what compiler commands run, stays
exactly the same; downloading from a cache still fetches only the small
metadata files, not the full libraries. Estimated effect at ~3,700 crates:
build-step files 154 MB → 16 MB, evaluation and setup about 10× faster.
Default: do it, after the planner lands (it touches the plan format and the
unit builder).

## 45. ASK: Nix's fixed cost per build step vs. the "≤ 2× crane" budget

Nix spends 35–50 ms setting up each build step, and does this one step at a
time even when building in parallel (it's in Nix's main build loop). For
tiny crates (well under 0.1 s of compile each), a cold breakbulk build was
3.7–5.2× slower than `cargo build -j8`. The design says more than ~2× crane
is a bug to investigate. Real crates compile for much longer, so the share is
smaller; the planner's real-project measurement will tell. Options: accept
it and measure on real projects (default), report it upstream to Nix
(setting sandboxes up in parallel), or merge tiny crates into one step (not
recommended: loses per-crate sharing).

## 46. FYI: every extra binary cache slows cold builds

Nix looks up each new build step on every configured cache before building.
With the four caches configured on this machine, that added 7 s per 300
crates. This will go in the docs as a tip: a project with a private cache
can limit substituters for breakbulk builds.

## 47. FYI: milestone M1's core works end to end

`breakbulk-plan` now traces a real workspace, and `mkWorkspace` builds it
crate by crate through Nix (import-from-derivation mode). Passing: the
walking skeleton (one binary, one crates.io dependency, one build script),
plus the `directives`, `build-dep-leak`, `crate-types` and
`dev-dep-features` fixtures and a build-script-killed-by-signal test. Every
product behaves like plain `cargo build`'s, unit commands match real Cargo
exactly on 1.95, 1.97 and 1.99, and rebuilds are bit-identical. Still open
for M1: the `sys-native` fixture, a randomized directive test, nightly
Cargo's new layout, and toolchain presets (M3).

## 48. ASK: every crate sees which `cargo` built it

Cargo 1.97+ tells every compile and build script the path of the `cargo`
binary (`CARGO`), which some crates use. breakbulk keeps it, so updating
Cargo rebuilds every crate. In practice Cargo and rustc are updated together
and a rustc update rebuilds everything anyway. Alternative: drop it, which
breaks the rare crate that reads `env!("CARGO")`. Default: keep.

## 49. FYI: smaller planner choices

- Test binaries that ask Cargo for a scratch directory
  (`CARGO_TARGET_TMPDIR`) get `/tmp/breakbulk-target-tmp`; the test run
  step creates it.
- The planner sets its compiler wrapper and directories with `--config`
  (which wins over project config) instead of environment variables.
- Build-job counts are recorded as 1 in plans and replaced with the real
  core count at build time, so the planning machine's core count never
  affects build step identity.
- A library's own unit tests are now predicted as outputs (closes 31).
- Projects that turn on Cargo's `trim-paths` fail planning with "not
  supported yet"; this can't happen before Cargo 1.101.

## 50. FYI: breakbulk's unit builder will get its own narrow source

Right now all four breakbulk programs are built from the same source tree,
so any planner change would also rebuild the unit builder and therefore
every crate of every project. The unit builder will be built from only its
own files, so only changes to it cause a full rebuild.
