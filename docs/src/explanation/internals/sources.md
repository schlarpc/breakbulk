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

### Three kinds of unit

A package has one view for each kind of unit:

| Kind | Units |
| --- | --- |
| `"build"` | non-test compiles, build scripts and their runs |
| `"test"` | test compiles and doctests |
| `"run"` | test runs |

A test compile is a compile Cargo builds with the package's dev-dependencies: a `--test` compile, an integration test or bench (with or without the libtest harness), or an example. The planner records it on each compile unit (`test` in [`plan.json`](../../reference/plan-format.md)) from the unit's Cargo target, not from `--test`: Cargo compiles a `harness = false` test or bench as a plain bin, without `--test`, and such a test's own crate root is in `tests/`. Examples are test compiles because an example that reads `tests/data/…` works under Cargo; test and check plans build them, build plans never do, so their wider view rebuilds no product.

A doctest compiles and runs in one rustdoc process. It has kind `"test"`, and nothing is run-only for it.

### The pipeline

Each view is the result of a list of steps. A step is a function from `{ default, kind, root, packageDir, ... }` to a file set. It gets the previous step's result as `default`; the first step gets the empty set. The built-in steps come first, in this order:

1. **The package directory**, minus `target/`, `.git`, `result*` and any nested directories that belong to other workspace members.
2. **[`extraSources`](../../reference/options/packages.md#packagesnameextrasources)** are added, for every kind, at their original relative paths.
3. **[`test.sourceScope`](../../reference/options/packages.md#packagesnametestsourcescope)** entries are added for `"test"` and `"run"`. For `"build"`, the entries inside the package are removed.
4. **[`test.scopeTestsDir`](../../reference/options/packages.md#packagesnametestscopetestsdir)**: for `"build"`, the package's `tests/` directory is removed, unless the option is `false`.
5. **[`test.runFiles`](../../reference/options/packages.md#packagesnametestrunfiles)**: for `"run"`, when set, the result is only the listed paths (relative to the package directory). A listed path that does not exist is an evaluation error.
6. **[`test.workspaceManifest`](../../reference/options/packages.md#packagesnametestworkspacemanifest)**: for `"test"` and `"run"`, the workspace's root `Cargo.toml` is added, unless the option is `false`. Snapshot-test libraries search upwards from the package for the topmost `Cargo.toml` ([Run snapshot tests](../../how-to/snapshot-tests.md)); expect-test searches from the run's `CARGO_MANIFEST_DIR`, so the step comes after `runFiles`. `Cargo.lock` is not added: no such library reads it.

Then the package's [`sources`](../../reference/options/packages.md#packagesnamesources) functions run, in [layer order](../configuration.md#shared-settings-and-layer-order). So the five options are shorthand for common steps. A function can do what they cannot: add files for `"run"` only, select files by a pattern (`lib.fileset.fileFilter`), or leave files out of `"build"`. A `sources` function must take `...`. breakbulk passes one extra argument, so that a function without `...` fails on its first call, not later when breakbulk adds an argument.

The view always holds the package directory, also when no file in it is chosen (`runFiles = [ ]`), because the package directory is the unit's working directory.

- **Root package:** in a workspace whose root `Cargo.toml` is also a package, that package's directory is the repository root (or the workspace's directory). So its view holds everything there except the other members' directories, unless a `sources` function narrows it. Each member's units run in the member's own view, which holds the member's directory, never in the root package's.
- **Test runs** read the `"test"` view, as their test binary does, unless the `"run"` view holds other files. Then the run's working directory and runtime `CARGO_MANIFEST_DIR` are the package directory of the `"run"` view.
- **Every unit** of a repository package carries its view in the rendered unit (`view`): the root, the package directory, the option that adds a path for its kind (`extraSources` for `"build"`, `test.sourceScope` for `"test"`), and the paths that `test.sourceScope` and `test.scopeTestsDir` leave out of `"build"`. A test run's spec carries the package directory and those paths, and the run adds `test.runFiles` when that option narrows it. They are only for the hints when a unit fails naming a path the view lacks ([Missing paths](../../reference/unit-builder.md#missing-paths)): one at the option that left a test-only path out, or "if it is in the repository, add it to" the kind's option for any other path outside the view, including one a `sources` function left out, since breakbulk cannot tell which function did. The left-out paths are relative to the repository root, so a test run, which must not name a source view (with `ca`, it would re-run on every edit), carries no store path for them.
- **Registry and git crates** have no view. A repository path in one of their units (Cargo sets config `[env]` on every compile) points into one constant empty directory instead.

### Limits

- A path a test builds at compile time (`concat!(env!("CARGO_MANIFEST_DIR"), "/data/x")`, `include_str!`) is a path in the view the test was compiled in. Files added for `"run"` only are not there. Such a test needs the files for `"test"` too.
- A function cannot add a product of the build (a derivation output) to a view. A view holds repository files only.

## The planning skeleton

The plan derivations' source is a skeleton, so they are rebuilt only when the manifests, the lockfile, config or the toolchain change:

- every `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml` and `rust-toolchain.toml`;
- an empty `README.md`, `README.txt` or `README` wherever one exists, because Cargo sets `CARGO_PKG_README` from its presence;
- an empty file for every file name in the conventional target directories (`src/lib.rs`, `src/main.rs`, `src/bin`, `examples`, `tests`, `benches`, including `*/main.rs` forms), every explicit `path =` target and every `build.rs`.

The skeleton copies file names only and needs no discovery rules; Cargo performs its own discovery during the trace.
