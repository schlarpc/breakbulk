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

A workspace package's source is `lib.fileset.toSource { root = <repository root>; fileset = …; }`. Because the root is the repository root, relative paths outside the crate resolve unchanged.

- **Default fileset:** the package directory, minus `target/`, `.git`, `result*`, any nested directories that belong to other workspace members, and the package's test-only paths: its `tests/` directory (unless [`test.scopeTestsDir`](../../reference/options/packages.md#packagesnametestscopetestsdir) is off) and the [`test.sourceScope`](../../reference/options/packages.md#packagesnametestsourcescope) entries inside it.
- **Plus:** the package's [`extraSources`](../../reference/options/packages.md#packagesnameextrasources), at their original relative paths.
- **Test units** (`--test` compiles, doctests and test runs) get a second view: the package directory without the test-only removals, plus `test.sourceScope`. A package with no test-only paths and no `sourceScope` has one view.
- **Non-test units** carry their package's test-only paths in the rendered unit (`testOnly`), only so that a failure naming one (a missing `include_str!` file) ends with a hint at the option.
- **Test runs** with [`test.runFiles`](../../reference/options/packages.md#packagesnametestrunfiles) run in a narrower view instead: `lib.fileset.toSource` of only the listed paths (relative to the package directory, at their places in the repository), or an empty package directory for `[ ]`. A listed path that does not exist is an evaluation error.

## The planning skeleton

The plan derivations' source is a skeleton, so they are rebuilt only when the manifests, the lockfile, config or the toolchain change:

- every `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml` and `rust-toolchain.toml`;
- an empty `README.md`, `README.txt` or `README` wherever one exists, because Cargo sets `CARGO_PKG_README` from its presence;
- an empty file for every file name in the conventional target directories (`src/lib.rs`, `src/main.rs`, `src/bin`, `examples`, `tests`, `benches`, including `*/main.rs` forms), every explicit `path =` target and every `build.rs`.

The skeleton copies file names only and needs no discovery rules; Cargo performs its own discovery during the trace.
