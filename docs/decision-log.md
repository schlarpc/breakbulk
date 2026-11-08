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

> ack

## 2. FYI: test toolchains come from rust-overlay

The flake pins `nixos-unstable` for nixpkgs and adds `oxalica/rust-overlay`
so tests can run against several Cargo releases (1.95, 1.97, 1.99 and
nightly). rust-overlay is used only for breakbulk's own tests and dev shell;
users still bring their own toolchain. If you prefer fenix, it is a small
swap.

> ack

## 3. FYI: how the work is being split

The three risk spikes from the implementation plan (tracing Cargo, Nix
dynamic-derivation delivery, environment capture) run in parallel with two
pieces that do not depend on them: the build-script output parser plus the
`plan.json` data types, and the Nix code that reads lockfiles, fetches
crates, builds the planning skeleton and predicts output names. Each runs on
its own branch and is merged after review. Spike write-ups land in
`docs/spikes/`.

> ack

## 4. FYI: `breakbulk-unit` depends on `serde` and `serde_json`

`breakbulk-unit` is an input of every unit, so every dependency is a reason
for a full rebuild when it changes. It still uses `serde` (with derive) and
`serde_json`: it must read `BREAKBULK_UNIT`, read and write
`directives.json` and `metadata.json`, and parse rustc's JSON diagnostics.
A hand-written JSON reader would be a few hundred lines of new code with its
own escaping bugs; `serde_json` is mature, and its version only changes when
`Cargo.lock` is deliberately updated. If you want no dependencies at all,
the cost is that hand-written parser.

> ack

## 5. ASK: the `BREAKBULK_UNIT` types live in `breakbulk-unit`, not `breakbulk-format`

The per-unit types (`RenderedUnit`, splice kinds, package targets) are defined
in `breakbulk-unit`'s library, and `breakbulk-format` depends on
`breakbulk-unit` and re-exports them. The other direction would make every
edit to the plan format (a new header field, a validation rule) change
`breakbulk-unit`'s inputs and so rebuild every unit. The wrapping table
(`wrap`) and the splice shape check are shared the same way, so the planner
checks sentinels with the same code that expands them. If you prefer a third
tiny crate for the shared types, it is a mechanical move.

>would third tiny crate incur more rebuilds? are there types in -unit that -unit itself doesn't care about

> Resolved: no change. A third crate wouldn't save rebuilds, since the unit builder depends on those types itself.

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

>ack. how solid do we feel about these going forward?

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

> ack

## 8. ASK: an `error` directive with leading spaces does not fail the run in Cargo

Cargo fails a successful run only for stdout lines that begin exactly with
`cargo::error=`. A line like `  cargo::error=x` is still parsed and printed
as an error, but the build continues (checked with Cargo 1.99). The design
says breakbulk fails "on any `error` directive". The parser offers both
rules (`streamed_log_messages` is Cargo's; `BuildOutput::has_errors` is the
stricter one). The default for run mode is Cargo's rule, for parity. Say if
you want the stricter one.

>stick with cargo

> Resolved: keep Cargo's rule.

## 9. FYI: what canonical `plan.json` means

Canonical JSON here is compact, with object keys sorted by their bytes and
`serde_json`'s string escaping; floats are refused. Before writing, the plan
is put in a normal form: adjacent literals in a concatenation are merged,
empty literals dropped, and a concatenation of literals only becomes a plain
string. Arrays that are sets (`roots`, `features`, crate types, a run's
`targets`, `metadataFrom`) are sorted; arrays whose order matters (`args`,
`program`, `envSplices`) are not.

> ack. do we express set-ness vs list-ness in our rust types?

## 10. FYI: the plan example in the implementation doc has one argument wrong

`["--extern", "cfg_if=", {"out": …}]` is one array, so by the format's own
rule it is one argument, `--externcfg_if=<path>`. It should read
`"--extern", ["cfg_if=", {"out": …}]`. The code follows the rule, not the
example.

> ack

## 11. FYI: how forbidden literals and sentinels are detected

A forbidden path (scratch, skeleton, vendor directory, `/build`, `$HOME`)
matches only as a whole path: `/build` matches `dependency=/build/x` and
`-L/build`, but not `/build.rs` or `/nix/store/…-src/build/x.c`. A sentinel
is `__bb` in any case followed by a non-alphanumeric character or the end, which
covers `__bb_R_cfg`, `__BB_R_ENV`, `__bb=R` and `DEP_X___BB`. The shim's
sentinel names must keep that prefix.

>ack

## 12. FYI: not done yet: dynamic-library path splices

The planner turns sentinel search paths found in `LD_LIBRARY_PATH`-style
variables into splice points, but the plan format has no shape for them yet,
and it depends on where the trace spike finds them. One finding for that
work: Cargo's rule for these variables keeps paths inside the whole build
directory (any script's `OUT_DIR`), not only inside the printing script's
own `OUT_DIR`, which is the rule for `-L` ordering. In breakbulk that means
"inside any run's `out`".

>i'm not sure what the consequences of this are

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

>let's discuss this some more

> Resolved: one git repository with several inheriting workspaces (real case: Sui) now works via per-workspace stubs and `package.workspace` pointers; see `docs/spikes/git-multi-workspace.md`.

## 14. ASK: `gitHashes` uses a different hash than crane's `outputHashes`

To let a binary cache serve a git dependency instead of cloning it on each
fresh machine, you may give its hash. breakbulk passes it to Nix's built-in
git fetcher (so no import-from-derivation is needed); this is the hash of
the fetched tree, which is not the same number crane asks for. You get the
right value from Nix's "hash mismatch" error or `nix flake prefetch`. Keys
are the full `Cargo.lock` source string including the commit. If you would
rather copy hashes over from existing crane setups, this would have to
change to a build-time fetch, which needs import-from-derivation.

>why does crane do it that way? what's the tradeoff

> Resolved: no change; answered in discussion (crane fetches at build time, breakbulk needs the tree at evaluation time).

## 15. ASK: crate source paths change when nixpkgs changes

Each downloaded `.crate` file is fixed (same hash forever), but unpacking it
uses tools from the nixpkgs you pass in. So bumping nixpkgs gives every crate
a new source path, and every crate rebuilds. This usually costs nothing extra,
because a nixpkgs bump usually changes the compiler too. If you want crate
sources to survive nixpkgs bumps (for example, when you pin the compiler
separately from nixpkgs), breakbulk can unpack with its own pinned tools.

>seems fine as is

> Resolved: no change.

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
  
>ack

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

>let's discuss more

> Resolved: default kept; opt-in `test.stripForRun` added (127).

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
  
>ack

## 19. FYI: environment capture works (spike C: go)

Packages' native dependencies (openssl, a C compiler, libclang for bindgen)
are turned into environment variables by running a real nixpkgs build
environment once per package and platform and saving what it set. Replaying
that saved environment gave byte-identical results to `buildRustPackage` for
`openssl-sys`, `ring` and a bindgen crate, both natively and when
cross-compiling to aarch64. Write-up: `docs/spikes/C-env-capture.md`.

>ack. is the stdenv overridable if needed?

## 20. ASK: how you name a package's libraries for build scripts

Build scripts and proc macros run on the build machine, so the libraries
they link must be the build machine's. Proposed: you write the list once as
a function, `inputs = p: [ p.openssl ]`, and breakbulk calls it with the
right package set for each side. The alternative is two lists you fill in
yourself (`inputs` and `host.inputs = [ buildPackages.openssl ]`), which is
more explicit but easy to get wrong silently. Default: the function form.

>agree on function form.

> Resolved: function form.

## 21. ASK: build-machine C code is hardened more than in `buildRustPackage`

When cross-compiling, `buildRustPackage` turns off nixpkgs' security
hardening flags for C code compiled for the build machine (inside build
scripts). breakbulk keeps them on, because its host environment is a normal
nixpkgs one. This only matters if some build script's C code fails to compile
with hardening. Default: keep hardening on; a per-package switch can turn it
off if needed.

>agree

> Resolved: keep hardening on.

## 22. FYI: build timestamp comes from one place

`SOURCE_DATE_EPOCH` is set in the fixed base of every unit (to nixpkgs'
default, 1980), not in each captured environment, so a per-package build
stamp overrides it in exactly one place.

>ack

## 23. FYI: C code's debug info will have source paths hidden too

Crates like `ring` compile C with debug info that embeds their source path.
Rust's path hiding doesn't touch C, so units will add the matching
`-ffile-prefix-map` flags to C compiler flags. Without it, shipped binaries
could still reference crate sources.

>ack

## 24. FYI: Nix's dynamic-derivation route works, with changes (spike B: go)

The plan's second delivery route, where Nix itself writes the per-crate build
steps during the build (instead of reading a generated JSON file), works on
Nix's development branch. It produces exactly the same build step IDs as the
JSON route, so the two share cache entries. It will first be in a released
Nix as 2.36; Determinate Nix doesn't have it yet. Two corrections to the docs
were made: Nix's own `nix derivation add` command can't be used for this, and
the feared extra recompiles for embedded products on caches like FlakeHub
don't happen. Write-up: `docs/spikes/B-delivery.md`.

>ack

## 25. ASK: use the harmonia library to write build steps in dynamic mode

The dynamic route has to write many small build-step files into the Nix store
from inside a build. Nix's command-line tool can't do that here; the
`harmonia` Rust library (MIT, by the Nix community; used for binary cache
servers) can, and gave byte-identical results. Catch: harmonia is
pre-release (version 0.0.0-alpha), so breakbulk would pin a specific git
commit. Alternative: shell out to `nix store add` and let Nix scan for
references, which is slower and less precise. Default: harmonia, pinned.
This only matters for milestone M5.

> agree

> Resolved: harmonia, pinned.

## 26. ASK: pushing to a public cache in dynamic mode uploads your source

In the dynamic route, the usual "push everything this build used" command
also uploads the filtered source trees of your workspace packages. That's
fine for a private cache or open-source code, but would leak private code to
a public cache. Options: just document it (default), or have breakbulk print
a warning when it detects the pattern. Tell me if you want the warning or a
different default.

>document seems fine? not sure why this is dynamic mode specific though

> Resolved: documented in design.md's operational notes.

## 27. FYI: product names in dynamic mode include workspace, target and variant

Nix requires the names of dynamically produced outputs to start with the name
of the step that produced them. breakbulk names that step
`<workspace>-<target>-<variant>`, so product store paths look like
`…-app-x86_64-unknown-linux-gnu-release-server`. Tell me if you'd prefer a
different scheme.

>ack

## 28. FYI: the first post-link step of a product will not be content-addressed

The step that picks up a product's raw link output (`linked`) can be a plain
step rather than a content-addressed one; both work. Plain is chosen because
caches that don't store the extra records content-addressing needs (FlakeHub
Cache) can still serve it. The later stages (strip, sign, ...) stay
content-addressed so an unchanged input doesn't re-run them.

>ack

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

>ack

## 30. ASK: names of outputs inside a workspace

Each predicted output is named `<package>/<kind>/<target>`, for example
`app/bin/app` or `app/test/integration`. A binary target that is also built
as a test (unit tests inside `src/main.rs`) gets `bin-test`:
`app/bin-test/app`. These are internal names; the user-facing attribute
names (`packages.app`, `tests.app.integration`) are built from them later.
Tell me if you want a different internal scheme before it spreads.

> ack

## 31. FYI: a library's own unit tests aren't predicted yet

`cargo test` also builds each library's `#[cfg(test)]` unit tests as a test
binary. The output-name prediction doesn't list those yet. This will be
fixed when the planner lands. Benchmarks that Cargo didn't select count as
"skipped" (succeed with a message) rather than failing.

>ack

## 32. FYI: tracing Cargo works (spike A: go)

The central bet of the design holds: breakbulk can run your real Cargo with
a stand-in compiler, record exactly what Cargo would run, and later
reproduce it. On Cargo 1.95, 1.97, 1.99 and current nightly, the recorded
commands, with build-script output filled in afterwards, matched a real
`cargo build` exactly for every unit (32 of 32 comparisons). Where
build-script output lands is identical across all four versions. Write-up:
`docs/spikes/A-trace-fidelity.md`. A few doc statements were wrong and are
being corrected (benches, profiles, see 35).

> ack

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

>ack

## 34. ASK: turning on Cargo's built-in path hiding (`trim-paths`)

Cargo 1.101 (not yet released as stable) can hide source paths itself, and
the design says breakbulk should switch it on when the project hasn't
chosen. breakbulk can't tell from outside whether the project chose, without
copying Cargo's profile rules. Proposed: plan once; if the result shows
path hiding is off and Cargo is new enough, plan again with it on. Planning
reruns only when manifests or the lockfile change and is quick compared to a
build. Alternative: never turn it on automatically and keep breakbulk's own
path hiding (works on all versions). Only relevant from Cargo 1.101.

>ack. lets make sure we test this

> Resolved: implemented and tested on Cargo 1.101 nightly (120); edge cases in 121.

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
  
>ack

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

>ack

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
  
>ack

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
  
>ack

## 39. ASK: Windows builds need a small linker fix to be reproducible

Windows `.exe` files came out different on every rebuild: the linker writes
the path of a randomly named temporary folder into the debug-symbol file,
and that file's hash goes into the `.exe`. Microsoft's own "reproducible"
switch doesn't fix it. A small wrapper around the linker that copies the
inputs to a fixed path first makes rebuilds identical. Question: keep it as
part of the Windows preset (default; only Windows pays for it), or move it
into breakbulk's unit builder for all targets?

>is this a generic fixup step that we're extending in a pre-shipped windows profile, or more hardcoded than that?

> Resolved: answered: it's the msvc preset's linker wrapper, not a generic step; linker choice is now one function (124).

## 40. ASK: how strictly to pin the Windows SDK download

By default the SDK download reads Microsoft's live catalogue. The C runtime
version is exact, but files within SDK 10.0.26100 can be updated by
Microsoft; if that happens, a fresh machine's build fails with a hash
mismatch (it never silently changes). You can additionally pin the
catalogue file itself (`channelManifest`), which removes that risk unless
Microsoft deletes old catalogue URLs. Default: optional. Make it required?

>optional

> Resolved: stays optional.

## 41. ASK: choosing the LLVM tools that match your Rust compiler

Windows and wasm builds use LLVM tools (linker, C compiler) that should match
the LLVM version inside rustc. Only nixpkgs' own rustc says which LLVM it
uses; toolchains from rust-overlay or fenix don't. Proposed: a small table
mapping Rust version to LLVM major version, shipped with breakbulk, with an
option to override. Alternative: ask rustc at build time, which would need
import-from-derivation to pick the tool package.

>table mapping as optimization with fallback to IFD? unless you disagree, loosely held

> Resolved: table plus a `rustc -vV` fallback (114).

## 42. ASK: should slow tests run in plain `nix flake check`?

Windows SDK download (252 MB), wine runs and cross toolchains make
`nix flake check` slow. They currently run there (marked HEAVY in
`flake.nix`). Alternative: a separate `heavyChecks` output that CI runs
explicitly. Default: keep them in `checks`.

>keep

> Resolved: keep.

## 43. FYI: evaluation speed is fine; graph size grows too fast (scale test)

A synthetic workspace shaped like zed's real lockfile was run at 300, 1,000
and ~3,700 crates. Filling in names at evaluation time (entry 29) costs only
3–6% of evaluation, so it stays. But every crate's build step currently lists
all crates below it as inputs, so the total grows roughly with the square of
the crate count: at ~3,700 crates, 154 MB of Nix build-step files and ~10 s
of evaluation, and about 1.5 minutes to write them the first time.
Write-up: `docs/spikes/scale.md`.

>probably deserves an optimization pass

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

>agree

> Resolved: done (64).

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

>accept

> Resolved: accepted.

## 46. FYI: every extra binary cache slows cold builds

Nix looks up each new build step on every configured cache before building.
With the four caches configured on this machine, that added 7 s per 300
crates. This will go in the docs as a tip: a project with a private cache
can limit substituters for breakbulk builds.

>ack

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

>ack

## 48. ASK: every crate sees which `cargo` built it

Cargo 1.97+ tells every compile and build script the path of the `cargo`
binary (`CARGO`), which some crates use. breakbulk keeps it, so updating
Cargo rebuilds every crate. In practice Cargo and rustc are updated together
and a rustc update rebuilds everything anyway. Alternative: drop it, which
breaks the rare crate that reads `env!("CARGO")`. Default: keep.

>keep

> Resolved: keep.

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
  
>ack

## 50. FYI: breakbulk's unit builder will get its own narrow source

Right now all four breakbulk programs are built from the same source tree,
so any planner change would also rebuild the unit builder and therefore
every crate of every project. The unit builder will be built from only its
own files, so only changes to it cause a full rebuild.

>ack

## 51. FYI: post-link stages work

Products can now pass through named steps after linking (split debug info,
strip, wasm-bindgen, wasm-opt, make a wasm component, deterministic zip,
install layout), each its own Nix build step and each removable or
reorderable. Checks can look at any intermediate step (for example the
unstripped binary). Every product gets a default check that fails if the
shipped output still references source code. Debuggers find symbols in the
split-off debug output. Zips are byte-identical across rebuilds.

>ack

## 52. ASK: content-addressed steps only when Nix supports them

The design uses content-addressing for post-link steps and test runs, so an
unchanged input doesn't re-run them. Stock Nix refuses such steps at
evaluation time (an experimental feature, `ca-derivations`), and the error
can't be caught or tested for in Nix code. Default: turn content-addressing
on only when Nix's dynamic-derivations feature is on (detectable, and it
requires `ca-derivations` anyway); otherwise steps are ordinary and simply
re-run when their input's build step changes. You can force it either way
with `ca = true/false`. Effect for you today: on your current Nix setup
(no experimental features), test runs and post-link steps re-run whenever
their binary's build step changes, even if the bytes are identical.

>ack

## 53. ASK: three rules for ordering post-link steps

- If two steps' order isn't determined by their `after`/`before`
  settings, evaluation fails rather than picking one silently.
- A step with no `after`/`before` runs right after linking. (The docs said
  "after the previous step in the preset's list", which needs to know
  where a step came from; the preset's own steps do set `after`.)
- When you remove a step (`= null`), steps that said "after it" move up
  to its place instead of failing. A reference to a step name that never
  existed is still an error.
  
>agree. should this just be an error or is that bad ergos? agree, nulling is effectively nooping

> Resolved: keep the error.

## 54. FYI: C debug info would have defeated "same bytes, skip re-run"

nixpkgs (and breakbulk's unit builder, copying it) seeds the C compiler with
the build step's output path, and GCC writes that into debug info. So any
change to a crate's build step, even one that doesn't change the code,
changed the binary's bytes. The seed will instead come from Cargo's own ID
for the unit, which only changes when the crate actually changes.

>ack

## 55. FYI: milestone M2's configuration layer works

`mkRepository` with NixOS-style module options now drives everything: many
workspaces in one repository, per-package settings, a curated set of
defaults for common `-sys` crates (copied from nixpkgs), a dev shell, and
`explainSharing`. Passing tests:
- three workspaces share exactly the crates they should; where they don't,
  `explainSharing` names the reason (for example "different source path"
  or "member here, dependency there");
- editing an unrelated sibling file rebuilds nothing; editing a build stamp
  rebuilds only the stamped package;
- outputs that Cargo skips for missing features fail (products) or report
  "skipped" (tests) with the reason;
- a missing native dependency fails naming the option to set.
Options not implemented yet give an evaluation warning, or an error where
silently ignoring them would build the wrong thing.

>"curated set" fairly well separated and easily extensible (should we adopt the nix-systems flake pattern for extension or is that overkill)? ack the rest

## 56. ASK: when two settings apply to the same package

You can configure a package as `packages.openssl-sys` (all versions) and
`packages."openssl-sys@^0.9"` (some versions). Both apply; the
version-specific one is applied last, so its environment variables win and
its input lists are added to the other's. Alternative: the most specific
entry replaces the general one entirely.

>ack

## 57. ASK: your settings add to the built-in `-sys` crate defaults

breakbulk ships default native dependencies for common `-sys` crates. If you
also set `inputs` for such a crate, yours are added to the defaults; use
`lib.mkForce` to replace them, or `sysDefaults.enable = false` to drop all
defaults. Alternative: any setting of yours replaces the default silently,
which is easier to reason about for a single crate but surprising when you
only meant to add one library.

>ack.

## 58. ASK: what the dev shell warns about

The dev shell warns about settings in your shell environment that the
planner won't see: `CARGO_*` variables (except ones that only affect output
location, terminal, network or credentials), plus `RUSTFLAGS`,
`RUSTDOCFLAGS`, `RUSTC`, `RUSTDOC`, the rustc wrapper variables, and a
`config.toml` in your Cargo home. The docs only mentioned `CARGO_*`. Is
that list right, too noisy, or missing anything you use?

>sounds reasonable.

## 59. FYI: naming of outputs

- `packages.<pkg>` holds the package's binaries in `bin/` and its C
  libraries in `lib/`.
- Tests are named by test name; a library's own unit tests are `lib`, a
  binary's are `bin-<name>`, an example's are `example-<name>`.
- The default variant is called `default` and uses the `release` profile.
- Extra options beyond the docs: per-variant `noDefaultFeatures` and
  `allFeatures`; `defaultVariant`; `gitSubdirs`, `gitSubmodules`;
  `sysDefaults.enable`.
- A flake-parts module is available as `breakbulk.lib.flakeModule`.

>ack. do we integrate with nix-systems if relevant?

## 60. FYI: tests run as Nix build steps

Each test binary gets its own test-run step with Cargo's environment,
working directory and library paths; doctests run once per library, with
output identical to `cargo test --doc`; each test binary also has a runnable
app for running outside the sandbox (network tests, debuggers). Changing one
binary's skip list re-runs only that binary's tests. `CARGO_BIN_EXE_<name>`
points at the real built binary.

>ack

## 61. ASK: "identical test binary, skip the re-run" barely works yet

The design promises that a test binary whose bytes didn't change isn't
re-run. Tested with content-addressing enabled: it still re-runs, because
two other inputs of every test run change on any edit:
- the test's working directory is the package's source tree (Cargo does
  the same), so editing any file in that package re-runs its tests; this
  one is arguably correct, since tests may read those files;
- following Cargo's rule, every test's library search path lists the
  output of every build script in the workspace, so editing any package
  that has a build script re-runs every test.
Suggested fix for the second: a small content-addressed step that copies
those build-script library directories, so their paths stay the same when
their contents do. Default: do it later in M4/M6. (Reminder: on your current
Nix setup content-addressing is off anyway, see 52.)

>discuss

> Resolved: build-script library folders fixed (86); working directory kept; opt-in `test.runFiles` added (127).

## 62. ASK: test apps run everything

The runnable test apps (for running outside the sandbox) deliberately don't
apply your skip lists or test arguments, since their purpose is to run what
the sandbox skips. They do use the same environment, working directory and
runner. Alternative: apply the same arguments by default and let you add
more on the command line.

>discuss

> Resolved: no change.

## 63. FYI: test naming and gaps

- Checks are named `test/<pkg>/<binary>` and `doctest/<pkg>`.
- The project's `[env]` table from `.cargo/config.toml` doesn't reach test
  processes yet (Cargo applies it; the plan doesn't record which variables
  came from it). To fix.
- Test runs get a plain shell environment without a C compiler; tests that
  compile C need it added via `test.path`.
  
>ack. let's make sure that gets fixed

## 64. FYI: the graph-size fix landed, with measured results

Library build steps now list only their direct dependencies (entry 44).
Compiler commands are identical before and after (checked on 234 build
steps), and rebuilds are bit-identical. At ~3,700 crates: input links
758k → 32k, build-step files 166 MB → 40 MB, first evaluation 85 s → 10 s.
Other M1 items also done:
- breakbulk's own programs build from narrow sources, so changing the
  planner no longer rebuilds every crate (entry 50);
- the `sys-native` test (openssl via pkg-config, a cmake crate, a bindgen
  crate) passes, and each package's native dependencies reach only that
  package;
- nightly Cargo (with its new build-directory layout) works;
- C compiler seeds now come from Cargo's unit ID (entry 54);
- test binaries for packages with feature-gated binaries now plan
  correctly.
  
>ack.

## 65. ASK: CMake leaves non-reproducible files in build-script output

Build scripts that use CMake (through the `cmake` crate) leave CMake's
build tree in their output folder, including randomly named scratch
folders. So `nix build --rebuild` flags them as non-reproducible, even
though the library they produce is fine. Real crates like `libz-ng-sys`
hit this. Options: (a) automatically delete `build/CMakeFiles` from
build-script output after the script runs (default proposal: it is never
read by later steps); (b) accept it and exempt such steps from the
reproducibility check; (c) leave as is.

>downsides of a? sounds good to me but idk

> Resolved: option a implemented (114).

## 66. FYI: a test that runs a feature-gated binary Cargo didn't build

If a binary is skipped because its required features are off, Cargo still
tells integration tests where it would be. breakbulk points that at a
path that never exists, so a test that runs it fails, as under Cargo.
Alternative: point it at a stub that fails with "not built because
features X are off", which gives a clearer message but differs from Cargo.

>ack

## 67. FYI: milestone M3's day-one targets work

All six toolchain presets work and every M3 test passes in the Nix sandbox:
- static musl binaries (x86_64 and aarch64, tests run under qemu) and fully
  static glibc binaries, with no dynamic loader or shared libraries, while
  build scripts stay dynamic;
- a target spec on the host's own triple doesn't leak into build scripts;
- cross-compiled `-sys` crates (openssl, cmake, bindgen) for aarch64;
- Windows: C code, a resource file, bindgen; tests run under wine;
  ARM64 links; `.exe` rebuilds are byte-identical;
- wasm for browsers (tests run in Node with the lockfile-matched runner)
  and wasm components (C code via wasi-libc, no imports).
Not working yet: headless Chromium as a test runner (crashes in the
sandbox; Node works), cross-language LTO, and testing on a real aarch64
build machine.

>ack. LTO planned?

## 68. ASK: breakbulk overrides rustc's built-in linker on Linux

Since about Rust 1.90, rustc links Linux x86_64 programs with its own bundled
linker by default, which skips nixpkgs' linker wrapper (and its rpath and
hardening handling). The official opt-out is a compiler flag, and compiler
flags can't reach build scripts. So breakbulk's linker wrapper quietly
removes rustc's "use the bundled linker" arguments and links with mold.
Alternative: use the official flag for your own code only and let build
scripts keep rustc's bundled linker.

>discuss. should we use rustc's built in linker? how is our linker selection handled, is it a hardcoded table or more principled?

> Resolved: option 1 kept; linker choice consolidated into one function (124).

## 69. ASK: fully static glibc builds are position-independent

The docs said static glibc builds use `relocation-model=static`. With the
mold linker, such Rust programs link but crash at startup (bfd and lld are
fine). Default now: static position-independent executables (static-pie),
which work with mold. `relocationModel = "static"` brings back the old
setting. Alternative: keep non-PIE and use the slower bfd linker for this
preset.

>ack, any downsides to static pie? _slightly_ slower code i assume?

## 70. ASK: Windows and wasm presets need your compiler passed in

These presets need to know your rustc's LLVM version (to pick matching
`lld-link`, `clang-cl`, etc.), but targets are configured repository-wide
while compilers are chosen per workspace. So you write
`presets.msvc { inherit sdk rustc; }`, or give `llvmMajor` directly. A
cleaner design would let a preset read the workspace's compiler itself;
that needs targets to become per-workspace, which is a bigger change. Worth
doing?

>probably worth doing.

> Resolved: done (130).

## 71. FYI: smaller preset choices

- musl builds link with Rust's own bundled C runtime pieces (nixpkgs' musl
  lacks one library Rust needs); C code still uses nixpkgs' musl headers.
- The host-side linker is also mold, so build scripts are shared between
  all targets on the same machine.
- Windows-specific environment (`RC`, `LIB`, ...) also reaches build
  scripts that belong to the Windows build, since they need it; only
  build-machine-side steps stay clean.
- breakbulk now reads `include` and `cfg(...)` keys in your
  `.cargo/config.toml` when deciding where to add its compiler flags
  (entry 33).
  
>ack

## 72. FYI: milestone M4's products and variants work

Passing: products go through their post-link steps by default (Linux:
split debug info, then install), with your own steps and checks per target
and per package; shipped binaries contain no source paths while the
separate debug output lets gdb show source lines; editing a README doesn't
change a test binary; one workspace can embed another workspace's product
without the rest of its build waiting for it; check, clippy, coverage,
feature-powerset and bench variants share exactly the build steps they
should. All checks run green on `main`. Not done yet: the wasm version of
the embed test, Windows post-link tests, separate source scopes for tests
(`test.sourceScope`), and trying one of your real repositories end to end
(that is the M4 exit criterion; it needs your input on which repo).

>ack

## 73. ASK: coverage builds crash with nixpkgs' Rust 1.99

Coverage-instrumented programs built with nixpkgs' rustc 1.99 crash when
they exit, inside the coverage runtime. Plain `cargo` with the same compiler
does the same, so it isn't breakbulk's fault; rust-overlay's 1.99 works,
and the test uses that. It looks like a nixpkgs bug. Want me to dig in and
prepare an upstream report (I won't file anything without your OK)?

>yes, in a subagent

> Resolved: root cause found, nixpkgs bug already fixed upstream (117); follow-ups in 118.

## 74. ASK: build IDs are turned on for targets that split debug info

Splitting debug info needs a build ID in each binary. breakbulk turns on
nixpkgs' own linker-wrapper switch for it (`NIX_SET_BUILD_ID=1`) on target
build steps when the target's steps include splitting debug info. This
changed every target build step once. Alternative: each preset passes the
linker flag itself.

>ack

## 75. ASK: lint variants and benchmarks

- `check` and `clippy` variants check all targets, like the usual
  `cargo clippy --all-targets`; they produce no binaries or test runs.
- A variant opts into benchmarks with `benches = true` (usually with
  `profile = "bench"`). `benches.<pkg>.<bench>` comes from the default
  variant if it has benches, else from the one variant that does; if
  several do, that's an error asking you to pick.
Do these match how you'd want to configure them?

>ack

## 76. FYI: smaller product choices

- How source paths are hidden follows the target's post-link steps, not
  each package's, because each library is compiled once and shared. A
  package that removes debug splitting keeps source paths in its binary;
  the default "no source references" check will catch that.
- Targets name their default post-link chain with `stagePreset`; every
  preset sets it.
- Products keep file extensions (`bin/app.exe` on Windows).
- `clippyArgs` works like `cargo clippy -- ARGS` and reaches only your own
  crates, so dependencies stay shared with `check`.
  
>ack

## 77. FYI: milestone M5's dynamic-derivation mode works on Nix master

With a development build of Nix (in a private store; your system Nix was
not touched), breakbulk can now have Nix itself create the per-crate build
steps during the build, with no import-from-derivation. Results on three
test projects: the same build-step IDs as the default mode, byte-identical
products, and all test runs pass. It turns on automatically once a released
Nix (expected 2.36) has the feature and you enable `dynamic-derivations`
(in both the evaluator and the daemon). Run the test with
`nix run .#test-dynamic` (builds Nix master; ~13 GB private store).
The harmonia library lives in a separate small program with its own
lockfile, so its updates never rebuild your crates.

>ack

## 78. ASK: dynamic mode gaps

- Doctests and runnable test apps don't exist in dynamic mode yet; doctests
  are doable next. Worth it now, or wait until a Nix release ships the
  feature?
- A product containing a binary that Cargo skipped (required features off)
  fails with the reason in dynamic mode, while the default mode quietly
  leaves that binary out. Matching the default mode needs a "not built"
  marker checked at build time. Default: make them match.
  
>do it now. match them.

> Resolved: done (111).

## 79. FYI: trying breakbulk on your own repositories (read-only copies)

To meet milestone M4's exit criterion ("one of the author's real
repositories builds end to end"), an agent is copying a few of your Rust
repositories from your home directory into a scratch directory and
building the copies with breakbulk. Your repositories themselves are not
modified, built in place, or pushed anywhere, and secrets like `.env`
files are skipped. Only the breakbulk module files (no source) go into
`tests/field-trials/`, and findings go into `docs/field-trials.md`. If you'd
rather some repositories stay out of this, say which.

>ack, good

## 80. FYI: loose ends fixed, README and options reference added

- Fixed a real bug: variables from your `.cargo/config.toml` `[env]` table
  were dropped from every crate, so `env!("X")` on such a variable failed.
  They now reach compiles, test runs and doctests as under Cargo.
- Per-package settings now add to toolchain list variables like `PATH`
  instead of replacing them.
- `packages.<name>.test.sourceScope` works: tests can see a wider part of
  the repository without affecting the package's other build steps.
- The dev shell sets the same linker and compiler flags the planner uses,
  so `cargo build` in the shell produces the same crate IDs as breakbulk.
- A native program can embed a wasm component built by another workspace.
- `README.md` (overview, status, quickstart, limitations) and
  `docs/options.md` (generated from the module options; a check keeps it
  in sync) are new.
  
>ack

## 81. ASK: opening the dev shell now runs the planner once

To export exactly the flags the planner uses, evaluating the dev shell now
builds the native build plan first (import-from-derivation). It reruns only
when manifests, lockfile or config change, but the first `nix develop` is
slower. Alternative: compute the flags in Nix without the planner,
duplicating one small rule. Default: run the planner.

>ack. what happens when the planner fails (eg cargo.toml is broken)

> Resolved: done (114); caveat for Cargo 1.101+ in 135.

## 82. FYI: breakbulk builds itself, within the speed budget

breakbulk's own workspace now builds through breakbulk (`checks.self-host`),
and the self-built programs produce byte-identical plans and products. Cold
build of breakbulk's 39 crates on a busy machine: `cargo build --release`
18–29 s, nixpkgs `buildRustPackage` 25–49 s, breakbulk 38–50 s, so roughly
1.4× the crane-style build, inside the "≤ 2× crane" budget (noisy; needs a
quiet machine to confirm). This partly answers entry 45 for real crates.

>ack, will this be able to actually self-bootstrap when consumed as a crate?

## 83. FYI: a randomized test against real Cargo found and fixed 7 bugs

A new check generates random small workspaces (dependency kinds, proc
macros, `links` chains, build scripts printing shuffled directives in both
syntaxes, config overrides) and compares every compiler, build-script and
doctest command and environment with real Cargo's. 32 seeds run in
`nix flake check`; 130 passed in a longer run. Fixed bugs included wrong
order of library search paths, missing link arguments for C-compatible
libraries from dependencies, and two planner crashes (a build script
replaced by a config override; a workspace member that is also a
build-time dependency).

>ack

## 84. ASK: one rule for "this library path is inside the build"

Cargo adds a build script's library paths to the runtime library path only
if they lie inside Cargo's build directory. breakbulk has no single build
directory, so it counts a path as inside when it points into the script's
own output folder or into the output folder of a `links` dependency it
received metadata from. A path reaching some other build script's output
by another route would be missed. This doesn't seem to happen in practice;
tell me if you know a crate that does it.

>idk man, research in a subagent?

> Resolved: one rule everywhere (119).

## 85. ASK: doctests use the wider test source scope too

`test.sourceScope` (entry 80) also applies to the package's doctests, since
they are tests. Alternative: only test binaries get the wider view.

>agree

> Resolved: agreed.

## 86. FYI: hardening across Cargo versions, test cutoff, git dependencies

- The randomized comparison against real Cargo and the exact-command tests
  now run on Cargo 1.95, 1.97, 1.99 and nightly. No differences in Cargo's
  behavior were found; three test-tool bugs were fixed.
- With content-addressing enabled, editing a package that has a build
  script no longer re-runs other packages' tests whose binaries didn't
  change (fixes the second half of 61). Verified in a private store.
- Git dependencies were broken: breakbulk named git crates differently
  from Cargo, so any git dependency failed. Fixed (found independently by
  two agents) and tested with a local repository locked at two revisions
  by different workspaces.
  
>ack

## 87. ASK: opt-in heavy tests as `nix run` commands

Two tests can't run under plain `nix flake check` because they need Nix
features your system Nix doesn't enable: dynamic mode (`nix run
.#test-dynamic`) and content-addressed test cutoff (currently
`tests/test-cutoff/run.sh`). Proposed: give the second a `nix run
.#test-cutoff` entry too, so all opt-in tests are found the same way.

>why not test.dynamic or similar? or is there a way to make a check derivation not run by default?

> Resolved: answered: checks can't be opt-in, and these tests need a different Nix, so they stay `nix run` commands: `nix run .#test-dynamic`, `.#test-cutoff` and `.#test-options`.

## 88. FYI: independent code review fixed 5 bugs

A reviewer agent re-read the code and fixed: a missing space that could
glue the C compiler seed flag to the next flag; unescaped quotes in some
environment values breaking the unit description; `["cdylib",
"staticlib"]` libraries failing at the link step; config-file rustflags
merged differently from Cargo; and a hidden skeleton path that escaped
validation. Each has a regression test. The unit builder changed, so every
crate rebuilds once.

>ack

## 89. ASK: where Windows `.pdb` and DWARF `.dwp` debug files go

The compiler doesn't announce these files, and the unit builder currently
deletes them with a warning. So Windows products built with debug info
have no `.pdb`. Putting them in the main output would make the product
reference intermediate libraries (and possibly sources). Proposed: a
separate `debug` output on binary build steps, which products' install
step copies into their own `debug` output, matching how Linux debug info
is split. Default: do that.

>do it

> Resolved: done (96).

## 90. ASK: one package opting out of debug splitting

How source paths are hidden is decided per target (entry 76). The review
confirmed the consequence: a package that removes `splitDebug` keeps real
source paths in its binary, and its default "no source references" check
fails; a package that adds `splitDebug` on a target without it gets no
build ID. Options: (a) keep per-target and document "change stages per
target, not per package" (default); (b) compile the affected libraries
twice when packages disagree.

>a

> Resolved: a (per target); enforcement comes with the consolidation work.

## 91. FYI: M6 measurements: pipelining split and rmeta cutoff are no-go for now

Details in `docs/spikes/m6-measurements.md`.
- **Pipelining.** Cargo starting dependents early saves 5–39% on real
  workspaces at 8 cores (ripgrep 39%, rust-analyzer 27%, helix 5%). The
  cheap ways for breakbulk to recover it compile each library's front end
  twice, which costs 23–49% more CPU and is slower at 4 cores. Not worth
  building. The only approach that keeps the gain (pausing and resuming the
  compiler process, "CRIU") is worth a spike later.
- **Skipping rebuilds when a library's interface file is unchanged.** It
  can't work today: rustc writes a hash of every source file into the
  interface file, so even adding a comment changes it. Replaying 50 real
  ripgrep commits saved 1% of library compiles. Rust's planned fix
  (`-Zpublic-api-hash`) isn't in nightly yet.
- **CA test runs on a fresh machine** download all their inputs first
  (1.8 GB including the compiler) before Nix can tell the run is cached,
  versus 440 bytes for an ordinary test run. This confirms the design's
  choice to keep content-addressing off for caches serving fresh machines.
  
>agree, let's document these as future state though. CA test is brutal wtf

## 92. FYI: nextest support

`packages.<name>.test.runner = "nextest"` runs that package's test binaries
through nextest, honoring `.config/nextest.toml` (retries, timeouts, default
filters, JUnit output, test threads). Each binary is still its own Nix test
run.

>is that inferable? or is it always a user flip in the flake

## 93. ASK: make nextest a workspace-wide switch?

nextest's config is workspace-wide, but the switch is per package, so you'd
repeat it for each package. Proposed: also allow a workspace-level default.

>agree

> Resolved: done (114).

## 94. ASK: test runs depend on the whole Rust toolchain

Test runs need only the Rust standard library's runtime files, but depend on
the whole toolchain (1.1 GB) to get them. On a fresh machine that's a big
download for content-addressed runs. Proposed: a small derivation holding
only those files. Default: do it.

>ack

> Resolved: done (96).

## 95. ASK: what to ask rustc upstream for

The design plans to ask the Rust project for a "physical split" of library
metadata (what dependents read vs. everything else). The measurements show
the request should explicitly name the per-file source hashes, which today
change the interface file on every edit. Nothing will be filed without you.

>ack

## 96. FYI: review follow-ups done

- Windows `.pdb` and DWARF `.dwp`/`.dwo` debug files are now kept, in a
  separate `debug` output (entry 89's default). Windows products have
  `$debug/bin/app.pdb` next to `$out/bin/app.exe`, and the main output
  still references no sources.
- Toolchain flags that turn on a `cfg(...)` config key are now placed the
  way Cargo would place them.
- Dynamic-mode test runs get the `[env]` table.
- Test runs download only the Rust runtime libraries (66 MB) instead of the
  whole toolchain (entry 94).
- Smaller fixes: bench naming, `CARGO_BIN_EXE_*` with same-named binaries in
  two packages, a runner given as a list, overlays kept for test runs on
  another system. Dead code removed.
- nextest in dynamic mode still falls back to plain libtest with a warning.

>are the debug files useful when separated like that? have we proven they work?

> Resolved: proven with gdb and llvm-symbolizer (120).

## 97. ASK: every binary build step gets an extra (usually empty) `debug` output

Nix needs a build step's outputs declared up front, so every binary, test
and C-compatible library step now has a `debug` output, empty unless the
compiler wrote side files. Downloading a binary never fetches it. Cost:
one extra small store path per such step. Alternative: declare it only on
Windows targets or when your profile sets `split-debuginfo`, which saves
paths but could miss a case.

>discuss

> Resolved: option 2, as one function (124).

## 98. FYI: milestone M7's later targets work

wasm32-wasip2, riscv64 Linux, Windows via MinGW (`windows-gnu` and
`windows-gnullvm`) and a zig preset that targets glibc 2.17 all build, and
their tests pass under their runners (wasmtime, qemu, wine). Windows MinGW
and zig outputs rebuild byte-identically. riscv64 needs no new preset;
`linuxGnu` with that triple works, `-sys` crates included. Building the
standard library from source (`-Zbuild-std`) doesn't plan yet: Cargo wants
the standard library's own crates.io dependencies, which breakbulk doesn't
vendor. The fix is described in the implementation doc. Darwin has notes
only (no Mac builders).

>ack. we going to fix those gaps?

## 99. ASK: C libraries for wasip2

The design said to turn off Rust's bundled copy of the WASI C library so C
headers and library match. On wasip2 that switch also removes the program's
start-up code, so nothing links. Instead, breakbulk puts nixpkgs' copy first
and swaps in its start-up files. Alternative: leave Rust's copy alone,
simpler but with mismatched C headers and library versions.

>ack, i think? discuss

> Resolved: option 2 implemented (124).

## 100. ASK: where wasip2 command-line programs are installed

All wasm targets install into `pkg/`. For wasip2 programs meant to run
under wasmtime, `bin/` would be more natural. Default: keep `pkg/`;
switching is a small change to the install step.

>pkg seems fine?

> Resolved: keep `pkg/`.

## 101. ASK: Windows MinGW programs link their runtime statically

Otherwise the `.exe` needs a GCC runtime DLL that isn't shipped next to it,
so it won't run on its own (or under wine). Default: static.

>ack

## 102. ASK: the zig preset and native libraries

zig targets an old glibc (2.17), but native libraries from nixpkgs (openssl
and so on) are built against a new glibc, which defeats the purpose. The
preset is meant for projects whose C code is bundled. Should breakbulk warn
when a package on a zig target declares native inputs? Default: document
only.

>shouldn't that incur a rebuild? or is that scope creep

> Resolved: opt-in `rebuildInputs` plus a warning (120).

## 103. ASK: zig tests don't prove the program runs on old glibc

zig-built programs ask for the standard Linux loader path, which the Nix
sandbox doesn't have, so tests run them through the build machine's newer
glibc. That works (glibc is backward compatible) but doesn't prove the
program runs on glibc 2.17; only a symbol-version check does that today.
Option: run tests in a container or VM with an old glibc (heavy).
Default: symbol-version check only.

>we should add a real test with a container

> Resolved: CentOS 7 container test added (120).

## 104. FYI: field trials on your repositories: datboi2 builds end to end

Full write-up: `docs/field-trials.md`. On read-only copies:
- **datboi2** (11 workspaces, a nightly workspace with git dependencies,
  8 wasm components, 4 embedded products) builds end to end, and the
  checks its CI runs pass from `repo.checks`. This meets M4's exit
  criterion. Cold build of the main binary: breakbulk 532 s vs crane 969 s
  (crane's number includes its extra check/test passes; vs crane's build
  alone breakbulk is ~1.2×). One-line edit to the leaf binary: 40 s vs
  206 s. Busy machine, single runs.
- **kmsrsos** builds for native, static musl and Windows x86_64/aarch64;
  build, clippy and tests pass.
- **mtgac** partly works (see 108 and 110).
Eight breakbulk bugs were found and fixed, each with a regression check.

>what is "native" in kmsrsos? host == target?

## 105. ASK: use the Linux preset by default for the native target

Without a preset, the native target links with rustc's bundled linker and
skips nixpkgs' linker wrapper; every trial had to add `presets.linuxGnu`.
The design already says the linker choice is automatic. Proposed: the
native target gets `linuxGnu` unless you set another preset. Rebuilds every
native crate once.

>agree

> Resolved: done (114).

## 106. ASK: the curated `-sys` defaults switch crates to system libraries

Some curated defaults (copied from nixpkgs) set variables like
`LIBSQLITE3_SYS_USE_PKG_CONFIG`, which silently swap a crate's bundled C
library (for example rusqlite's `bundled` feature) for nixpkgs' copy. That
changes what gets built behind your back. Proposed: drop those switches
from the defaults, keep the library inputs.

>agree

> Resolved: done (114).

## 107. ASK: native libraries for binaries that link a `-sys` crate

A package's native inputs reach only that package's own build steps. When
a `-sys` crate prints just `-lmagic` (no search path), the final binary's
link step, which belongs to another package, can't find the library;
datboi2 needed `MAGIC_DIR` set by hand. Options: (a) pass each package's
library search paths along to every binary that depends on it (closest to
how it works locally); (b) keep it per package and document. Needs your
call.

>i think A sounds right, discuss?

> Resolved: option A implemented (127).

## 108. ASK: check variants without `--all-targets`

Check and clippy variants always check all targets (entry 75). mtgac's wasm
check gate doesn't, so it fails under breakbulk. Proposed: an `allTargets`
switch on variants, default on.

>agree

> Resolved: done (114).

## 109. FYI: other gaps from the trials, by priority

Listed at the end of `docs/field-trials.md`. The main ones: variants and
test plans can't be narrowed to one target; only the default variant's
tests reach `repo.checks`; modules don't receive `root` or the repository
object; first evaluation in import-from-derivation mode is slow (~4 min
for datboi2, mostly fetching crates one by one); the "no source
references" check doesn't look for toolchain paths; no per-package
feature powerset.

>are we fixing these?

> Resolved: done (132).

## 110. ASK: embedding a product at a fixed path in the source

mtgac's UI is embedded with rust-embed, which reads files from a fixed
path relative to the source rather than from an environment variable.
breakbulk can pass products only through environment variables. Option:
let a package place a product at a path inside its source view (only that
package's build steps would change). Default: not implemented yet.

>this is similar to other forms of input like env vars right?

> Resolved: answered (yes, same idea as env vars); not implemented yet, recorded as a TODO.

## 111. FYI: dynamic mode now matches the default mode (resolves 78)

Doctests, test apps, nextest, `explainSharing` and products with
feature-gated binaries all work in dynamic mode, with identical build-step
IDs, product bytes and test outcomes on eight fixtures (Nix master, private
store). Nothing changed for the default mode.

## 112. ASK: dynamic-mode checks for products whose binaries all need features

In dynamic mode, Nix can't know at evaluation time whether Cargo built any
of a product's binaries. For a product where every binary needs a feature,
`repo.checks` therefore uses a lighter check: it builds the binaries Cargo
did build and logs the skipped ones, instead of the full product with its
post-link steps and "no source references" check (which would fail
`nix flake check` when everything is skipped). Alternative: keep the full
product in checks and accept that failure. Default: the lighter check.

## 113. FYI: `explainSharing` uses import-from-derivation even in dynamic mode

It's a debugging tool, not part of a build, so it reads the build steps the
default way. For crates downstream of an embedded product it describes the
default mode's version of them.

## 114. FYI: your config answers are implemented

105 (Linux preset by default), 106 (no system-library switches in the `-sys`
defaults), 108 (`allTargets` on variants), 93 (workspace-wide nextest
default), 65 (CMake's scratch files removed after build scripts; rebuilds
now reproducible), 41 (LLVM table with a `rustc -vV` fallback), 55/59
(flake systems from a nix-systems input), 81 (the dev shell works with a
broken `Cargo.toml`). Each has a test.

## 115. ASK: musl build machines

The Linux preset default (105) applies when the build machine is Linux with
glibc. On a musl build machine (Alpine-style), the native target gets no
preset. Should it get `linuxMusl`?

## 116. ASK: `nix-systems/default-linux` instead of `default`

You said `nix-systems/default`; the flake uses `default-linux` because
`default` also lists the two macOS systems, which breakbulk doesn't support
yet. It's a one-line switch once Darwin works.

## 117. FYI: the coverage crash is a nixpkgs bug, already fixed upstream (resolves 73)

nixpkgs builds Rust 1.99 against LLVM 21 but compiles its coverage runtime
from LLVM 23 sources; LLVM 23 changed the coverage record layout, so
instrumented programs crash at exit. Already reported (nixpkgs#576588) and
fixed on nixpkgs master (PR #578990, "rustc: use llvmPackages_23"), not yet
in `nixos-unstable`. Details and a two-line reproducer:
`docs/spikes/research-coverage-and-libpath.md`.

## 118. ASK: coverage follow-ups

- When breakbulk's pinned nixpkgs has the fix, should the coverage test
  switch back to nixpkgs' Rust, or run with both toolchains?
- Add a small per-toolchain "does coverage work" probe that fails with a
  clear message, so a future mismatch doesn't show up as a crash at exit?
- Two upstream drafts exist (a nixpkgs follow-up to prevent recurrence, and
  a Cargo bug: with `build.build-dir` outside `target/`, Cargo drops build
  scripts' library paths from `LD_LIBRARY_PATH`). Want either filed? Nothing
  has been sent.

## 119. FYI: one rule for "library path inside the build" (resolves 84)

Cargo's real rule is a plain path-prefix check against its target
directory. breakbulk now uses one rule in all four places (compiles, build
scripts, tests, doctests): a path counts if it's inside the printing build
script's own output or inside the output of a build script it received
`links` metadata from. A survey of 1,207 popular crates (94 printing library
search paths) found none that reach another build script's output any other
way. The Cargo-like "any build script's output" rule would make every
compile with a proc macro rebuild whenever any build script anywhere
changed. Two crates (`sdl2-sys` bundled, `ort-sys` copy-dylibs) copy
libraries into Cargo's target directory itself; no rule can support that in
a sandbox, so that's a separate known gap.

## 120. FYI: verification results (resolves 34, 96, 98, 103; updates 102)

- **trim-paths (34):** works on Cargo 1.101 nightly. breakbulk uses Cargo's
  own path hiding when the project turns it on, and turns it on itself
  otherwise; a shared path crate outside the workspace root now gets the
  same crate ID from different workspaces and checkout locations.
- **Debug files (96):** proven with real debuggers. gdb, given only a
  product's `debug` output, shows a backtrace with file and line through a
  dependency; packed `.dwp` files didn't work at first (wrong place) and
  were fixed; on Windows, `llvm-symbolizer` resolves addresses through the
  `.pdb` to `src/main.rs:40`.
- **zig (103):** tests now run inside a real CentOS 7 (glibc 2.17)
  container in the Nix sandbox; a negative control confirms the check
  can fail.
- **zig native libraries (102):** new opt-in `rebuildInputs` rebuilds listed
  nixpkgs libraries with zig against glibc 2.17 (zlib ~10 s, OpenSSL
  ~5 min); other library inputs on zig targets get a warning.
- **build-std (98):** works. The standard library's own dependencies come
  from the toolchain's `rust-src`, so nothing extra is downloaded.

## 121. ASK: trim-paths details

- breakbulk turns trim-paths on as `"all"` and then applies its own
  per-product scope, so build scripts see `CARGO_TRIM_PATHS_SCOPE=all`.
- A project that explicitly sets `trim-paths = "none"` is overridden,
  because breakbulk can't tell that from "not set" without copying Cargo's
  profile rules.
- Mixed settings (on for some packages via profile overrides, off for
  others) fail planning. Alternative: apply breakbulk's own path hiding to
  just the "off" ones.
Acceptable?

## 122. ASK: zig follow-ups

- The CentOS 7 container check downloads an image from Docker Hub and runs
  in the regular checks (marked heavy). Move it behind a `nix run` command
  like the dynamic-mode tests?
- `rebuildInputs` must also list those libraries' own library dependencies
  by hand; rebuilding dependencies automatically would also rebuild build
  tools.
- zig-built binaries get no runtime library path to the rebuilt libraries;
  they're found via `LD_LIBRARY_PATH` or by shipping them alongside.
  Alternatives: link them statically, or have the zig linker record store
  paths.

## 123. FYI: smaller verification notes

- On Cargo 1.101+, `cargo` in the dev shell needs
  `CARGO_PROFILE_<P>_TRIM_PATHS=all` to get the same crate IDs as the plan;
  the dev shell will set it.
- Bare-metal build-std targets (`x86_64-unknown-none`) link with rustc's
  bundled lld, since there's no nixpkgs linker wrapper for them; the
  "never rust-lld" rule (68) is about the Linux wrapper.

## 124. FYI: linker function, debug-output rule, wasip2 change (resolves 68, 97, 99)

- **68:** linker choice now lives in one function (`lib/presets/linker.nix`):
  `linkerKind` decides (mold, clang+lld for cross-language LTO, lld-link,
  wasm-ld, wasm-component-ld, MinGW+lld, zig) from the target triple, LTO
  mode and preset flavor; `chooseLinker` builds it. Every preset calls it;
  `targets.<t>.linker` still overrides. No build step changed (714 checked).
- **97:** build steps declare a `debug` output only when the compiler will
  write side files, decided by one function from the traced command.
  Linux release builds no longer get empty `debug` outputs.
- **99:** wasip2 keeps Rust's bundled wasi-libc and compiles C code against
  headers from the matching wasi-sdk release (table: Rust 1.95–1.96 → 30,
  1.97–1.99 → 33, 1.100–1.102 → 34, sourced from Rust's CI pins). The
  fetched library is byte-identical to the one inside each Rust toolchain,
  so std, C code and C library are one version. The link wrapper is gone.

## 125. ASK: Windows writes a `.pdb` even without debug info

You said "`.pdb` whenever debug info is on", but rustc always passes
`/DEBUG` to the Windows linker, so release builds with debug info off also
write a PDB (1.2 MB for the test program). It carries symbol names for
stack traces. Default: keep it in the `debug` output for every Windows
binary. Alternative: discard it when debug info is off.

## 126. FYI: smaller notes from batch A

- With `split-debuginfo = "unpacked"`, libraries' `.dwo` files are still
  discarded, so source-level debugging into dependency code needs `packed`.
- Building on a non-Linux machine now fails at evaluation with a clear
  message instead of silently choosing mold.

## 127. FYI: test options and link-step library folders (resolves 17, 61, 107)

- **17:** `test.stripForRun` (per package, or workspace default) makes test
  runs use a copy of the test binary with debug info and build ID removed.
  Verified with content-addressing on: after a README edit in a workspace
  library, the test run was not re-run.
- **61:** `test.runFiles = [ "tests/fixtures" ]` narrows a test's working
  folder to the listed paths; editing an unlisted file no longer changes
  the test run, and a test reading an unlisted file fails loudly.
- **107:** every build step that links gets the library search folders
  (`NIX_LDFLAGS`) of the other packages it links, host and target kept
  apart, so a `-sys` crate that prints only `-lfoo` now works from another
  package, and the binary records an rpath to the library.
- The test that was too strict with content-addressing on is fixed, and
  the dynamic-mode skip is gone.

## 128. ASK: dynamic mode doesn't skip unchanged test re-runs yet

In dynamic mode, test runs read their settings from a generated file that
names the package's source folder and build-script outputs, so any edit
there re-runs them, even with content-addressing, `stripForRun` and
`runFiles`. Everything still works; only the "same binary, skip the
re-run" saving is missing in dynamic mode. Fix: content-addressed copies
of that file's inputs, like the default mode has. Do it now, or wait until
dynamic mode is usable on a released Nix?

> Resolved: later; recorded under "Known gaps (TODO)" in
> `docs/implementation.md`.

## 129. FYI: link steps take only `NIX_LDFLAGS` from other packages

Build-tool library folders (`NIX_LDFLAGS_FOR_BUILD`, e.g. cmake's) and
`NIX_CFLAGS_LINK` aren't passed along, since setup hooks don't normally
use them for libraries a binary links. If some library's setup hook does,
it gets added.


## 130. FYI: presets follow each workspace's compiler; future work written up (resolves 70, 91)

- **70:** a target's settings are now worked out per workspace: the
  repository-wide `targets.<triple>` settings plus the workspace's own
  `workspaces.<ws>.targets.<triple>`, evaluated with that workspace's
  compiler. Two workspaces on Rust 1.96 and 1.99 building wasm get LLVM 22
  tools with wasi-sdk 30 and LLVM 23 tools with wasi-sdk 33 respectively.
  You no longer pass `rustc` to presets. This fixed a real mismatch in
  datboi2 (its nightly workspace was linked with the wrong LLVM's linker).
- **91:** `docs/design.md` has a "Future work" section (pipelining via
  CRIU, interface-only rebuild cutoff blocked on rustc, content-addressed
  units blocked on NixOS/nix#11928), checked against upstream status today.

## 131. ASK: setting the same target field in both places

Repository-wide and per-workspace target settings combine like any two
module definitions: lists concatenate, attribute sets merge, and a single
value (like `preset` or `linker`) set in both places is an error unless one
side uses `lib.mkForce`. Alternative: the workspace's value wins
automatically for single values. Default: the module-system rule.

## 132. FYI: field-trial gaps closed (resolves 109, 19, 123; and `root = self`)

- `root = self` works alongside `./.` (same build steps; with lazy trees,
  your tree isn't copied to the store an extra time).
- Modules receive `root`, `repo` and `breakbulk` as arguments.
- Variants and test plans can be narrowed: `variants.<v>.targets`,
  `variants.<v>.packages`, and `workspaces.<ws>.targets.<t>.tests`
  (`false`, or a package list).
- Every variant's tests reach `repo.checks`, named by variant.
- `breakbulk.variants.packageFeaturePowerset` gives exactly the runs
  cargo-hack prints (checked on kmsrsos: 13 runs).
- The "no source references" check also fails on Rust toolchain paths.
- `targets.<t>.stdenv` / `host.stdenv` override the C build environment.
- On Cargo 1.101+, `cargo` in the dev shell gets the same crate IDs as the
  plan.

## 133. ASK: other variants' tests run in `nix flake check` by default

Every build or coverage variant's tests now go into `repo.checks`; set
`variants.<v>.checks = false` to leave one out. So a coverage variant's
tests run in `nix flake check` unless turned off. Alternative: off by
default, opt in per variant.

## 134. ASK: toolchain references in products are now an error

The default check fails when a product depends on rustc, its sysroot or
cargo at run time. A binary built with `-C prefer-dynamic` legitimately
needs libstd; the error message says how to keep only the source part of
the check (`noSourceReferences { toolchain = [ ]; }`). OK as a default?

## 135. ASK: on Cargo 1.101+, the dev shell needs a working manifest again

To know whether the planner turned trim-paths on itself, the dev shell
reads the build plan's header, which needs a working `Cargo.toml`. This
undoes decision 81 for Cargo 1.101+ only; 1.99 and earlier are unchanged.
Alternative: always set the trim-paths variable on 1.101+, which overrides
a project's own setting. Neither is perfect; a third option is to fall
back to "always set it" when planning fails.

## 136. FYI: the ten scattered decisions now each have one home

Following your "all 10, extensible for bring-your-own targets":
- **Target traits** (`lib/target-traits.nix`): one record of facts per
  target (OS, environment, object format, file names, debug side files,
  library path variable, default post-link steps), parsed the way rustc
  names targets and checked against `rustc --print cfg` for all 248 targets
  it recognises. For a custom target, set `targets.<triple>.traits`; every
  decision then uses them. The Rust side receives the traits instead of
  parsing target names.
- **Three real bugs fixed along the way:** a package changing debug
  splitting now gets a warning (90); Windows tests can now load DLLs built
  by build scripts (wine looks at `WINEPATH`, not `LD_LIBRARY_PATH`); musl
  builds now link pkg-config libraries statically (previously a link
  error with private dependencies).
- **Consolidated without changing any build step:** version gates,
  runner choice, per-target variable names, the package-set table,
  toolchain facts (LLVM, wasi-sdk), and the two Nix/Rust duplicate pairs
  (nextest metadata, test runtime variables).
- **Behaviour change:** test and bench binaries get `.exe` / `.wasm`
  names on those targets.
- Every crate rebuilds once: breakbulk's unit builder no longer includes
  its own test files in its source, so future test edits don't rebuild
  anything.
Deferred, in "Known gaps (TODO)": install-layout sorting from traits
(MinGW `.a` placement, macOS `.dylib`).

## 137. ASK: package-level `splitDebug` mismatch: warning or error?

When a package adds or removes `splitDebug` against its target's setting,
breakbulk now warns (removing it can be deliberate). Make it an error?

## 138. FYI: Android counts as Linux

`isLinux` is true for `*-linux-android`, as in nixpkgs, so Android targets
keep Linux linker and post-link choices.
