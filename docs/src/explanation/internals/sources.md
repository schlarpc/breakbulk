# Fetching and source views

Crates are fetched from the lockfiles: registry crates at build time, git sources during evaluation. Your own packages get source views, filtered copies of their directories, and planning runs over a skeleton with empty source files. This page covers each of those.

Fetch derivations are created from the lockfiles at evaluation time. Registry crates download at build time. Git sources are fetched during evaluation.

## Registry crates

- Every `Cargo.lock` in the repository is read with `builtins.fromTOML`. Entries are merged by (source, name, version, checksum), so a crate locked by several workspaces is fetched once.
- A crates.io entry becomes `fetchurl` of `https://static.crates.io/crates/<name>/<name>-<version>.crate`, using the lockfile's SHA-256 checksum. An unpack derivation then writes the `.cargo-checksum.json` (`{"files":{},"package":"<checksum>"}`) that Cargo's directory sources require.
- Other registries need their download URL template from [`registries.<name>.dl`](../../reference/options/repository.md#registriesnamedl), because reading the registry's `config.json` would need a fetch at evaluation time.

## Git dependencies

- A `git+<url>?…#<rev>` entry becomes `builtins.fetchGit { url; rev; allRefs = true; shallow = true; }`. A full revision makes the input locked, so this works in pure evaluation without a hash. Submodules are an option per URL.
- Without a content hash, every fresh machine clones the source during evaluation, and evaluation fails if the remote is unreachable. `gitHashes.<source url>` (optional) switches that source to a fixed-output fetch, which a binary cache can serve. This follows crane's `outputHashes`.
- The crate inside the repository is found by walking the fetched tree's `Cargo.toml` files, stopping at the first match. A `subdir` hint per URL skips the walk.
- Fetches are keyed by URL and locked revision, because two workspaces can lock the same git source at different revisions.
- With `lazy-trees = true` (Determinate Nix), `builtins.fetchGit` returns a virtual store path. That path does not exist, and it changes with every evaluation. So breakbulk copies each fetched tree to its real store path with `builtins.path` and the tree's NAR hash. Nix skips the copy when the path is already in the store. A crate's source path then names a real path, also where breakbulk writes it without string context, such as the source list of `noSourceReferences`. `gitTrees` values that are fetched trees (a `fetchGit` or `fetchTree` result, or a flake input) get the same treatment.

### Settings that name a fetched tree

A setting can name a path in a fetched tree as a string: `packages.<name>.env.FOO = "${inputs.foo}/data"`, or a rustflag `-L native=${inputs.foo}/lib`. With lazy trees, that string names the virtual path. Where the string reaches a derivation with its context, Nix puts the real path in its place. But breakbulk writes some strings without their context: the planner's spec (linker and rustflags), the generated Cargo config, the tool paths for instantiation, the dev shell's Cargo environment, dynamic mode's `values.json`, and the patterns of `noStorePaths`' `allow`. There, the virtual path would name nothing and change the derivation on every evaluation.

So at each of those places, breakbulk replaces every virtual path in the string with its real one first (`util.devirtualizeAndDiscard`; `util.devirtualize` keeps the context).

- **Finding a virtual path:** no builtin returns the real path of a virtual one. But Determinate Nix's `builtins.hashString` hashes a string with its virtual paths replaced by the real ones. So a store path in the string's context whose hash with its context differs from its hash without context is virtual. On Nix without lazy trees, and on Lix, the two hashes always agree, and the string is unchanged.
- **The real path:** `builtins.path` copies the virtual path's tree under the same name, as Nix does when the path reaches a derivation, so it is the same store path. This copies the tree during evaluation. Any unit that reads the value would copy it anyway.
- A `gitTrees` value that is such a string (`"${inputs.foo}"`, with no NAR hash) gets the same treatment.

## Vendoring for planning

Each workspace gets a vendor directory with one subdirectory per source, following crane's layout:

- **Registries:** one directory per registry, named by a hash of its URL.
- **Git:** one directory per source id (URL plus `branch`, `tag` or `rev` query, without the locked revision), named by a hash of the id.
- **Inside each:** `<name>-<version>` symlinks to the fetched crates, for crates in this workspace's lockfile only.

Generated config, passed as a file (`--config <file>`; an inline `--config` value may hold only one dotted key), replaces each source with its directory:

```toml
[source.crates-io]
replace-with = "breakbulk-<hash>"
[source.breakbulk-<hash>]
directory = "<vendor>/<hash>"
[source."git+https://github.com/me/serde?rev=abc"]
git = "https://github.com/me/serde"
rev = "abc"
replace-with = "breakbulk-<hash2>"
```

The planner sees exactly the crates in the lockfile, the lockfile's checksums are verified, and two sources providing the same name and version never collide.

Git crates that use workspace inheritance get the original `[workspace]` table as a stub `Cargo.toml` one level above them, so Cargo's own `find_workspace_root` does the merge. When one git source supplies inheriting crates from several workspaces (Sui's root and `external-crates/move` workspaces, for example), each workspace's table goes in its own hidden folder, `<hash>/.breakbulk-workspace-<hash>/Cargo.toml`, and each such crate's vendored manifest gets a `package.workspace` pointer to it; Cargo reads inheritable fields from a pointed-to workspace without checking membership. Directory sources only read immediate subfolders and the workspace search does not resolve symlinks, so neither nesting nor symlinks work. See [spikes/git-multi-workspace.md](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/git-multi-workspace.md).

## Source views

A workspace package's source is a view of the repository root: a `lib.fileset` value copied to the store with the repository root as its root. Because the root is the repository root, relative paths outside the crate resolve unchanged. Every path in the repository that a unit names (its working directory, a config `[env]` path) resolves in the unit's own view ([Path rewriting](planner.md#path-rewriting)).

### Three kinds of unit, and their targets

A package has one view for each kind of unit:

| Kind | Units |
| --- | --- |
| `"build"` | non-test compiles, build scripts and their runs |
| `"test"` | test compiles and doctests |
| `"run"` | test runs |

A test compile is a compile Cargo builds with the package's dev-dependencies: a `--test` compile, an integration test or bench (with or without the libtest harness), or an example. The planner records it on each compile unit (`test` in [`plan.json`](../../reference/plan-format.md)) from the unit's Cargo target, not from `--test`: Cargo compiles a `harness = false` test or bench as a plain bin, without `--test`, and such a test's own crate root is in `tests/`. Examples are test compiles because an example that reads `tests/data/…` works under Cargo; test and check plans build them, build plans never do, so their wider view rebuilds no product.

A doctest compiles and runs in one rustdoc process. It has kind `"test"`, and nothing is run-only for it.

A compile can also get a view of its own Cargo target. The planner records the target of each compile unit (`cargoTarget` in [`plan.json`](../../reference/plan-format.md)). When the package has a view for that target and kind, the unit reads it in place of the package's view. Otherwise it reads the package's view. Test runs and doctests always read the package's views, and so do build-script runs: Cargo re-runs a build script on an edit to any file of its package unless the script declares `rerun-if-changed` paths, and a script may read any of them (one that runs `cargo` on its own package needs every target's root). A run reads a view of its own only when [source prediction](#source-prediction) narrows it to its declared paths (`src:<dir>#run/custom-build/<name>`). So without prediction, an edit to an example or a bin re-runs the package's build script, and the package's units that depend on the run rebuild. Per-target views exist only for the targets whose files can differ from the package's: those the [`scopeTargetRoots`](../../reference/options/packages.md#packagesnamescopetargetroots) step narrows, or every target when the package has `sources` functions. Each one is a copy of the package's files in the store, made at evaluation.

Instantiation sees the views by key only: `src:<dir>` and `test-src:<dir>` for the package's views, and `src:<dir>#<kind>/<name>` and `test-src:<dir>#<kind>/<name>` for a target's. `sources.json` lists the targets that have one, by directory. A key for a target that the plan names but the package has no view for falls back to the package's key, so a prediction that misses a target gives a wider view, never a failed build.

### The pipeline

Each view is the result of a list of steps. A step is a function from `{ default, kind, cargoTarget, root, packageDir, ... }` to a file set. `cargoTarget` is `{ kind, name, path }` (`path` relative to the package directory) for a target's view, and null for the package's. It gets the previous step's result as `default`; the first step gets the empty set. The built-in steps come first, in this order:

1. **The package directory**, minus `target/`, `.git`, the `result` and `result-*` symlinks of `nix build` (`sourceViews.junkPaths`; a `results/` directory or `result.json` stays) and any nested directories that belong to other workspace members.
2. **[`extraSources`](../../reference/options/packages.md#packagesnameextrasources)** are added, for every kind, at their original relative paths.
3. **[`test.sourceScope`](../../reference/options/packages.md#packagesnametestsourcescope)** entries are added for `"test"` and `"run"`. For `"build"`, the entries inside the package are removed.
4. **[`test.scopeTestsDir`](../../reference/options/packages.md#packagesnametestscopetestsdir)**: for `"build"`, the package's `tests/` directory is removed, unless the option is `false`.
5. **[`scopeTargetRoots`](../../reference/options/packages.md#packagesnamescopetargetroots)**: for a target's view, the crate roots of the package's other bins, examples, tests and benches are removed, unless the option is `false`. A root `<dir>/main.rs` counts as its whole directory when `<dir>` is not `src`, `src/bin`, `tests`, `benches` or `examples` (`src/bin/tool/main.rs` removes `src/bin/tool`). For the library, a bin or a build script, the `examples/` and `benches/` directories are removed too. A path that holds the target's own root, the library's root or a build script is never removed. Files that are no target's root, such as `tests/common/mod.rs`, stay. The step comes after `test.sourceScope`, which can add a whole directory of roots back for the test kinds. The targets are predicted from the manifests, as [root names](instantiation.md#root-names-are-fixed-at-evaluation-time) are.
6. **[`test.runFiles`](../../reference/options/packages.md#packagesnametestrunfiles)**: for `"run"`, when set, the result is only the listed paths (relative to the package directory). A listed path that does not exist is an evaluation error.
7. **[`test.workspaceManifest`](../../reference/options/packages.md#packagesnametestworkspacemanifest)**: for `"test"` and `"run"`, the workspace's root `Cargo.toml` is added, unless the option is `false`. Snapshot-test libraries search upwards from the package for the topmost `Cargo.toml` ([Run snapshot tests](../../how-to/snapshot-tests.md)); expect-test searches from the run's `CARGO_MANIFEST_DIR`, so the step comes after `runFiles`. `Cargo.lock` is not added: no such library reads it.

Then the package's [`sources`](../../reference/options/packages.md#packagesnamesources) functions run, in [layer order](../configuration.md#shared-settings-and-layer-order). So the six options are shorthand for common steps. A function can do what they cannot: add files for `"run"` only, select files by a pattern (`lib.fileset.fileFilter`), or leave files out of `"build"`. A `sources` function must take `...`. breakbulk passes one extra argument, so that a function without `...` fails on its first call, not later when breakbulk adds an argument.

The view always holds the package directory, also when no file in it is chosen (`runFiles = [ ]`), because the package directory is the unit's working directory.

- **Root package:** in a workspace whose root `Cargo.toml` is also a package, that package's directory is the repository root (or the workspace's directory). So its view holds everything there except the other members' directories, unless a `sources` function narrows it. Each member's units run in the member's own view, which holds the member's directory, never in the root package's.
- **Test runs** read the `"test"` view, as their test binary does, unless the `"run"` view holds other files. Then the run's working directory and runtime `CARGO_MANIFEST_DIR` are the package directory of the `"run"` view.
- **Every unit** of a repository package carries its view in the rendered unit (`view`): the root, the package directory, the option that adds a path for its kind (`extraSources` for `"build"`, `test.sourceScope` for `"test"`), the paths that `test.sourceScope` and `test.scopeTestsDir` leave out of `"build"`, the junk paths of step 1 (`junk`), and, in a target's view, the paths `scopeTargetRoots` leaves out (`targetRoots`). A test run's spec carries the package directory and the test-only and junk paths, and the run adds `test.runFiles` when that option narrows it. They are only for the hints when a unit fails naming a path the view lacks ([Missing paths](../../reference/unit-builder.md#missing-paths)): one at the option or step that left a test-only path, a junk path or another target's root out, or "if it is in the repository, add it to" the kind's option for any other path outside the view, including one a `sources` function left out, since breakbulk cannot tell which function did. The left-out paths are relative to the repository root, so a test run, which must not name a source view (with `ca`, it would re-run on every edit), carries no store path for them.
- **Registry and git crates** have no view. A repository path in one of their units points into one constant empty directory instead. Such paths come from Cargo config: `[env]` with `relative = true`, which Cargo sets on every compile and build-script run, and, more rarely, `build.rustflags` naming a repository path (`-L native=…`). The rendered unit lists them (`repositoryPaths`: the path, and the variable or the argument that holds it), only for a hint when the unit fails. For a variable, the hint names [`packages.<name>.env`](../../reference/options/packages.md#packagesnameenv), which replaces Cargo's value (layer 5 over layer 3) with only that directory, as a store path: `packages.openssl-sys.env.OPENSSL_DIR = ./vendor/openssl;`. No option replaces a rustc argument, so for an argument the hint names the path and the flag. A variable the package's `env` already sets is not listed.

### Source prediction

With [`predictSources.enable`](../../reference/options/packages.md#packagesnamepredictsourcesenable), a package's compiles and build-script runs read a *predicted view*: the files of their view (the result of the pipeline above) that source prediction finds they read, and the paths [`predictSources.keep`](../../reference/options/packages.md#packagesnamepredictsourceskeep) names. A README line or a comment in `Cargo.toml` then changes none of the package's units. Test runs and doctests keep the package's views.

**What is predicted.** `breakbulk-predict` parses the sources with syn, without building anything (rustc's own dep-info would need every dependency built first, and so the plan's units before the views of their dependents could exist).

- A compile's crate root and its module tree, followed by rustc's rules (`rustc_expand/src/module.rs`): `foo.rs` owns `foo/`, inline modules add their name to the directory, a `#[path]` file counts as a `mod.rs`, a module file in a block needs `#[path]`. Every `cfg_attr(…, path = …)` alternative and both of `x.rs` and `x/mod.rs` are kept when they exist, so that what rustc picks, or the ambiguity it reports, is the same as in the whole view. Modules and includes in a macro's arguments (`cfg_if!`) count where the macro is used; an `include!`d file's own modules resolve against its directory, as in rustc (`expand_include`).
- Every `include!`, `include_str!` and `include_bytes!` with a literal path, relative to its file; `concat!(env!("CARGO_MANIFEST_DIR"), "…")`, relative to the package; and `#[debugger_visualizer]` files. Under `OUT_DIR` or absolute: no view holds them.
- A build-script run: the paths its script (with its modules and includes) declares in literal `rerun-if-changed` directives, relative to the package. That is Cargo's own contract: Cargo reruns the script for those paths and no other files.

**When it falls back.** A unit whose files cannot be known from the sources reads the view it would have narrowed: a `mod`, `#[path]` or include in a `macro_rules!` body (it resolves where the macro is used), a `mod $name`, an include with any other computed path, a file syn cannot parse (edition-2015 syntax), a run whose directive paths are computed (`"…={}"`) or that prints no `rerun-if-*` directive at all (Cargo then treats the whole package as its input). A package that build-depends on a crate that prints `rerun-if-changed` from its library code (`lib/directive-printers.nix`: `autocfg`, `bindgen`, `cxx-build`, `glib-build-tools`, `lalrpop`, `slint-build`, `tauri-build`, `vergen`, `vergen-lib`) keeps its runs' whole view ([`predictSources.buildScriptRuns`](../../reference/options/packages.md#packagesnamepredictsourcesbuildscriptruns)). A package with a `sourceOverlay` is not predicted, with an evaluation warning.

**Misses.** A file read some other way is not in the predicted view: a proc macro reading a file (template engines, `sqlx`'s `.sqlx`, `include_dir!`, `wit_bindgen::generate!`), a module a proc macro declares. rustc fails on every module or include it cannot read, naming the file, and most proc macros do too; the failure ends with a hint naming `predictSources.keep` ([Missing paths](../../reference/unit-builder.md#missing-paths)). A reader that tests whether a file exists and carries on without it is a silent miss. The curated keeps cover the known ones:

- clippy reads the `Cargo.toml` of the compile's working directory (`lint_groups_priority`) and skips the lint when it is missing, so a clippy variant's predicted views keep it: the workspace's for a member, the package's own for a package outside the workspace;
- `proc-macro-crate`, `find-crate` and `bevy_macro_utils` read the `Cargo.toml` of the crate that uses their macro, from `CARGO_MANIFEST_DIR` (`proc-macro-crate` also the workspace's), so their dependents keep it ([`sysDefaults.dependents`](../../reference/options/repository.md#sysdefaultsdependents)).

Against the dep-info of 1,778 crate roots (1,379 registry crates, 399 of field-trial repositories), prediction found every file rustc read for 1,291 registry roots and fell back for 88, with no undetected miss; the misses in the repositories were `wit_bindgen::generate!`'s `.wit` files, and clippy's `Cargo.toml`. It parses about 15 MB of Rust a second on one core.

**Where it runs.** The views it narrows are evaluation-time views of a target (`src:<dir>#<kind>/<name>`, `test-src:…`, and `src:<dir>#run/custom-build/<name>` for a build-script run, which instantiation looks up before its script's); the predicted view is that key's value. Each is the tree `breakbulk-predict` writes (the predicted paths that the view has, a directory with everything under it, and the package directory always, as `realize` keeps it), as a `source` store path with a recursive SHA-256 hash.

- IFD mode: one derivation per workspace instance runs `breakbulk-predict` over every predicted view's spec, and Nix copies each tree with `builtins.path`. The derivation reruns after any edit to a predicted package, in a second or so; units then depend only on the copies.
- Dynamic-derivation mode: the outer derivation gets the specs (`--predict`), writes each tree with the same code, and adds it over the daemon socket (`AddToStore`, `r:sha256`). Its NAR is `nix-store --dump`'s, so the path is IFD mode's, and so are the units (`nix run .#test-dynamic -- predict-sources` checks every unit `.drv` path).

A unit with a predicted view carries `predicted` in its rendered view, for the hints. `noSourceReferences` counts predicted views as source paths in IFD mode only: in dynamic-derivation mode they exist only once the outer derivation runs.

### Limits

- A path a test builds at compile time (`concat!(env!("CARGO_MANIFEST_DIR"), "/data/x")`, `include_str!`) is a path in the view the test was compiled in. Files added for `"run"` only are not there. Such a test needs the files for `"test"` too.
- A function cannot add a product of the build (a derivation output) to a view: a file set holds repository files only. [Products in a view](#products-in-a-view) do that.

### Products in a view

Some crates read files at a fixed path next to their sources, not through an environment variable: rust-embed's `#[folder = "ui/dist"]`, `include_dir!`, `include_bytes!("../dist/app.wasm")`. [`sourceOverlay`](../../reference/options/packages.md#packagesnamesourceoverlay) places a product (or any derivation or path) at such a path, relative to the package directory:

```nix
packages.assets.sourceOverlay."ui/dist" =
  repo.workspaces.ui.target.wasm32-unknown-unknown.packages.ui;
```

It is a layer on top of the pipeline, not a step of it. A file set is made of files that exist when Nix evaluates; a derivation output exists only once it is built, so a step that took one would make every evaluation build it (import from derivation). Instead, each of the package's three views, once realized, is copied by a small derivation that puts a symbolic link to each value at its path, replacing whatever the view has there.

- **Only this package's units** get the overlaid views. Its dependents depend on the product through its outputs, as with [`env`](../../reference/options/packages.md#packagesnameenv).
- **Instantiation does not depend on the product.** `breakbulk-instantiate` sees each view by key only (`src:<dir>`), and Nix substitutes the value afterwards, so planning and instantiating the host workspace never build the product.
- **A link, not a copy.** The product is passed by reference. A crate that canonicalizes paths (rust-embed does) sees the product's own store path.
- **A plan gets the views of the packages it can contain**, as it gets their settings: in dynamic-derivation mode the outer derivation depends on every view it is given, so another member's overlay of a product of this plan would make the plan depend on itself. An overlay of a product of the package's own plan needs the product's package in [`productInputs`](../configuration.md#products-as-inputs), as `env` does.

## The planning skeleton

The plan derivations' source is a skeleton, so they are rebuilt only when the manifests, the lockfile, config or the toolchain change:

- every `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml` and `rust-toolchain.toml`;
- an empty `README.md`, `README.txt` or `README` wherever one exists, because Cargo sets `CARGO_PKG_README` from its presence;
- an empty file for every file name in the conventional target directories (`src/lib.rs`, `src/main.rs`, `src/bin`, `examples`, `tests`, `benches`, including `*/main.rs` forms), every explicit `path =` target and every `build.rs`.

The skeleton copies file names only and needs no discovery rules; Cargo performs its own discovery during the trace.
