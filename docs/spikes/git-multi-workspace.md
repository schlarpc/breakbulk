# Spike: one git source, several inheriting workspaces

Nov 7, 2026

## Result

**Needed, and fixed with a layout trick; no manifest normalization.**

- **It is real.** Every Rust project that depends on Sui by git hits it: `sui-types` (Sui's root workspace) and `move-core-types` (the separate `external-crates/move` workspace) come from the same git source, and both inherit from their own workspace. Sui's own examples and at least eight other public projects lock exactly that (see [Real-world cases](#real-world-cases)). breakbulk failed on all of them.
- **Reproduced.** `tests/fixtures/git-multi-workspace`: one repository with two workspaces that inherit other values for the same keys. Real Cargo builds the consumer from the real repository. breakbulk failed at evaluation with `git source file:///build/gitdep?branch=main has crates from several workspaces that use workspace inheritance; this vendor layout cannot serve both`.
- **Fix: one stub per workspace, named by `package.workspace`.** For such a source only, each workspace's stub `[workspace]` table goes into `<vendor>/<hash>/.breakbulk-workspace-<hash of stub>/Cargo.toml`, and each inheriting crate's vendored manifest gets `package.workspace = "../.breakbulk-workspace-<…>"`. Cargo itself still loads the table and does the merge. A directory source does not read dot directories as packages, so the stubs are invisible to it. Sources with one workspace keep the old layout byte for byte (no derivation of any existing fixture changes).
- **Verified** with real Cargo over a real git checkout (no source replacement): the build plan's argv equals real `cargo build -v` for every unit on Cargo 1.95.0, 1.99.0 and nightly 1.101 (2026-11-03), and the consumer built by breakbulk prints the same `CARGO_PKG_VERSION`, `_README`, `_LICENSE_FILE`, `_LICENSE` and `_DESCRIPTION` values as the real build.

Normalizing manifests with `cargo package` or `cargo vendor` was the planned fallback. It is worse on fidelity and much more work (see [Options](#options)), so it was not built.

Confidence: high for the tested shape (version, edition, readme, license-file, license, description, dependencies with added features, lints; three Cargo releases). Not tried: the real Sui repository through breakbulk (its tree is large; the vendor change is the same code path as the fixture).

Sources: Cargo at the `rust-1.99.0` branch, commit `5f94df4789f005f9a352888e8355ffc645b7ed0e` (tag `0.100.0`). Line numbers are from that commit.

## How to reproduce

```sh
nix build -f tests/git-multi-workspace layout build golden
nix build .#checks.x86_64-linux.git-multi-workspace-golden-1_95 \
          .#checks.x86_64-linux.git-multi-workspace-golden-nightly
```

| Attribute | What it checks |
| --- | --- |
| `repo` | `repo/` committed on `main` with a fixed date; the commit id equals the lockfile's (`b7d7b611…`) |
| `layout` | no stub one level up; two stub directories; `a`, `b` point to one, `c`, `d` to the other |
| `golden`, `golden-1_95`, `golden-nightly` | real Cargo fetches `file:///build/gitdep` (a bare copy of `repo`), builds `consumer -v`; `breakbulk-plan-golden` compares the plan with that log, using real Cargo's `cargo metadata` for crate directories (`~/.cargo/git/checkouts/…`) |
| `build` | the breakbulk-built `consumer` prints the same lines as the real build |

Expected output (both builds):

```
a 1.0.0 readme=../../README.md license-file=../../LICENSE b=1
c 2.0.0 readme=../TOOLS.md license=MIT description=tools workspace d=2
```

## Why one stub cannot serve both

A git crate inherits from the workspace that `find_workspace_root` finds. The current layout gives it one: `<vendor>/<hash>/Cargo.toml` above every crate directory of the source. Two workspaces with different `[workspace.package]` or `[workspace.dependencies]` need two tables. They cannot both be ancestors of the crate directories, for three reasons:

1. **A directory source reads only its immediate subdirectories.** `DirectorySource::update` (`src/sources/directory.rs`, lines 92-170) calls `self.root.read_dir()` once and loads each entry that has a `Cargo.toml` (`PathSource::new(&path, …)`, then `root_package()`). There is no recursion, so `<vendor>/<hash>/ws1/a-1.0.0/` is not found. Entries whose name starts with `.` are skipped (lines 108-115). One `[source]` can replace a git source only once (source replacement is looked up by `SourceId`), so a second directory for the same source is not possible either.
2. **The workspace search is lexical, so symlinks do not help.** `find_workspace_root` → `find_workspace_root_with_loader` (`src/workspace/workspace.rs`, lines 2162 and 2239) and `find_root_iter` (line 2290) walk `paths::ancestors(manifest_path)` of the path as given. The path is `<vendor>/<hash>/<crate>/Cargo.toml`, built by `DirectorySource` from its root, never canonicalized. Tested: making `<vendor>/<hash>/a-1.0.0` a symlink into `ws1/a-1.0.0`, with the stub at `ws1/Cargo.toml`, fails with `error inheriting edition from workspace root manifest's workspace.package.edition … failed to find a workspace root`.
3. **`package.workspace` works.** `load_inheritable_fields` (`src/workspace/parser/mod.rs`, lines 982-1007) has three cases. For `WorkspaceConfig::Member { root: Some(path_to_root) }` (the package has `package.workspace`), it joins the path to the manifest's directory, normalizes it lexically, and reads `[workspace]` from there with `inheritable_from_path`. It does not check membership and does not load the workspace's members. So any directory can hold the stub, including a dot directory inside the source's vendor directory.

## Options

| Option | Result |
| --- | --- |
| Nested per-workspace directories | Not possible: a directory source does not recurse (1 above) |
| Symlinked crate directories | Fails: the workspace search uses the path as given (2 above) |
| **Per-crate `package.workspace` pointer to a stub in a dot directory** | **Works on 1.95, 1.99 and nightly. Chosen.** |
| `cargo package --no-verify` per crate, vendor the `.crate` | Wrong `CARGO_PKG_README` and `_LICENSE_FILE`; offline problems; changes targets |
| `cargo vendor`'s normalized manifest | Right values, but needs a git checkout at build time, changes targets, and moves the units' sources |

### The pointer layout

Manual test first (real Cargo, offline, the fixture's crates copied into `<vendor>/H/`, the stubs in `<vendor>/H/.ws-1/` and `.ws-2/`, a `workspace = "../.ws-N"` line added to each `[package]`): builds, with the right versions, editions and features.

`readme` and `license-file` still need the rewrite breakbulk already does for one workspace. Cargo resolves inherited paths against the workspace root (`InheritableFields::readme` and `license_file`, `src/workspace/parser/mod.rs` lines 1120-1136, through `resolve_relative_path`, `src/workspace/workspace.rs` line 2134). Without the rewrite, the stub's directory becomes the root, and Cargo reports `readme=../.ws-1/README.md` instead of the checkout's `../../README.md`. The existing rewrite replaces the inherited key with the path relative to the crate's directory in the repository, so the value equals a checkout's.

The implementation (`lib/vendor.nix`, `pointerLayout`) decides per source. It collects the distinct stubs of the source's inheriting crates. With one stub, it uses the old layout and the old manifests (`rewritten null`), so existing derivations are unchanged. This was checked: the vendor derivations of `tests/plan`'s workspaces, `tests/git-revisions`' four workspaces, and the `vendor-git-inherit` and `vendor-collision` checks have the same `.drv` paths before and after. With several stubs, every inheriting crate's manifest is rewritten (`util.toTOML`, as for the readme rewrite), and the stubs are written to `.breakbulk-workspace-<hash>`. Crates that do not inherit keep their manifests.

Nothing else changes. Crate directories, package ids, the planner's `crateSrc` mapping and the units' sources (the fetched tree's subdirectory) stay the same. Units read their sources from the original tree, so a build script that reads its own `Cargo.toml` sees the original, as in a checkout. Only planning sees the vendored manifest. Cargo does not hash the manifest's text or `package.workspace` into `-C metadata`; the golden test confirms the argv, including `-C metadata` and `-C extra-filename`, equals the real build's.

### `cargo package`

`cargo package -p a -p b --no-verify --offline` in a checkout of the fixture's repository writes this `Cargo.toml` into `a-1.0.0.crate`, and copies `README.md` and `LICENSE` into the crate:

```toml
[package]
edition = "2021"
name = "a"
version = "1.0.0"
build = false
autolib = false
autobins = false
autoexamples = false
autotests = false
autobenches = false
readme = "README.md"
license-file = "LICENSE"

[lib]
name = "a"
path = "src/lib.rs"

[dependencies.b]
version = "1.0.0"
features = ["extra"]
```

- **`CARGO_PKG_README` and `_LICENSE_FILE` would differ from a checkout** (`README.md` instead of `../../README.md`). `prepare_toml_for_publish` (`src/workspace/parser/mod.rs`, around line 3089) rewrites a readme outside the package root to its file name, because `cargo package` copies it into the root (`src/ops/cargo_package/mod.rs` line 610). The same applies to `license-file`.
- **Offline packaging of one crate fails.** `-p a` alone fails offline: Cargo builds a lockfile for the packaged crate and resolves the `b` path dependency by its version against the registry. That works only with all path dependencies packaged together (`-p a -p b`) and nothing from the network. A real repository would need its registry dependencies too.
- **Targets change.** The normalized manifest turns off auto-discovery and lists only targets whose files are packaged (honoring `include` and `exclude`). A checkout discovers every target. The `path` of path dependencies is dropped.

### `cargo vendor`

For git packages, `cargo vendor` writes `manifest().to_normalized_contents()` of `prepare_for_vendor` (`src/ops/cargo_vendor.rs`, `cp_sources` from line 427, `prepare_for_vendor` from line 492: "the bare minimum of `prepare_for_publish` needed for #14348"). Tested on the fixture: `readme = "../../README.md"` and `license-file = "../../LICENSE"` stay relative (right values), and dependency paths stay. But:

- It runs on a git source, so a build-time derivation would have to recreate a git repository from the fetched tree, or use `[patch]`, which changes source ids.
- Like `cargo package`, it lists only packaged files' targets (`PathSource::list_files`, then `prepare_targets_for_publish`) and turns off auto-discovery. That can drop targets a checkout has.
- The normalized copy would be a new store path per crate. Either units build from it (all crate source paths and `--remap-path-prefix` values change for these sources, and the copy would need its own file selection), or planning and building see different manifests.

The pointer layout has none of these problems, and Cargo still does the whole merge.

## Real-world cases

Found with GitHub code search (`gh search code 'git+https://github.com/MystenLabs/sui' --filename Cargo.lock`), then each lockfile read:

| Project | Source of both `sui-types` and `move-core-types` |
| --- | --- |
| MystenLabs/sui `examples/rust/basic-sui-indexer` (also `clickhouse-sui-indexer`, `walrus-attributes-indexer`) | `git+https://github.com/MystenLabs/sui.git?branch=testnet` |
| MystenLabs/walrus | `git+https://github.com/MystenLabs/sui?tag=testnet-v1.83.1` |
| MystenLabs/seal | `git+https://github.com/mystenlabs/sui?rev=3ae8aec…` |
| MystenLabs/sui-gas-pool | `git+https://github.com/MystenLabs/sui?branch=testnet` |
| MystenLabs/mvr | `git+https://github.com/mystenlabs/sui.git?rev=ceaaff1…` |
| Talus-Network/nexus-sdk | `git+https://github.com/MystenLabs/sui?tag=testnet-v1.77.2` |
| fuzzland/sui-mev | `git+https://github.com/suiflow/mevsui?branch=relay-patch` (a Sui fork) |

In Sui, `external-crates/move/Cargo.toml` is its own workspace, and the root `Cargo.toml` lists those crates under `exclude`. Both workspaces use inheritance: at `testnet-v1.83.1`, `move-core-types` has 25 `.workspace` keys and `sui-types` 84. Sui's root crates depend on the move crates by path, so any consumer of a Sui crate gets crates from both workspaces through one git source. Sui's SDK README (`crates/sui-sdk/README.md`) tells users to depend on it this way: `sui-sdk = { git = "https://github.com/mystenlabs/sui", package = "sui-sdk" }`.

Not found to be cases (checked): aptos-core (its `third_party/move` crates are members of the root workspace); zksync-era (two inheriting workspaces, `core/` and `prover/`, but the public lockfiles checked, such as era-boojum-validator-cli, anvil-zksync and lightnode, use only `core/` crates). Repositories with a separate `fuzz/` or `xtask/` workspace are not a problem in practice, because consumers do not depend on those crates.
