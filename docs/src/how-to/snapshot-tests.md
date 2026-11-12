# Run snapshot tests

Snapshot-test libraries compare a test's output with a file in the
repository. Most of them find the file from the workspace root, because
`file!()` paths are relative to it. breakbulk builds and runs each test
in a [source view](../explanation/internals/sources.md#source-views), a
copy of the package's files in the store, not in your checkout. This page
says what each library needs there.

## What works by default

| Library | How it finds its files | In breakbulk |
| --- | --- | --- |
| snapbox (`file![…]`, `str![…]`) | `CARGO_RUSTC_CURRENT_DIR` at compile time, when the project sets it in `[env]`; otherwise the topmost directory above the compile's `CARGO_MANIFEST_DIR` that has a `Cargo.toml` | works |
| trycmd | case files relative to the working directory | works |
| expect-test (`expect_file![…]`) | `CARGO_WORKSPACE_DIR` at run time; otherwise the topmost directory above the run's `CARGO_MANIFEST_DIR` that has a `Cargo.toml` | works |
| insta | `INSTA_WORKSPACE_ROOT` at run time, then at compile time; otherwise `cargo metadata --no-deps` in the package directory | needs a setting, [below](#insta) |

snapbox and expect-test work because every member's test units and test
runs see the workspace's root `Cargo.toml`
([`test.workspaceManifest`](../reference/options/packages.md#packagesnametestworkspacemanifest)).
They do not see `Cargo.lock`. Test runs run in the package directory of
the view, as Cargo runs them, so trycmd's paths work as they are.

The root manifest has a cost: an edit to it rebuilds every member's test
binaries and re-runs every test, also when the plan does not change. The
library, bins and products never see the file, so they do not rebuild.
If no test needs the file, turn it off for every member:

```nix
workspaces.main.memberDefaults.test.workspaceManifest = false;
```

or for one package with `packages.<name>.test.workspaceManifest = false`.

## insta

insta runs `cargo metadata` to find the workspace root. That fails in a
view, because Cargo wants every member of the workspace, and the view
holds only the package. insta then uses the package directory, finds no
snapshot, and tries to write a new one into the store, which fails with
`Permission denied`.

Set the root for the package's test runs, and tell insta not to write:

```nix
packages.my-crate.test.env = {
  INSTA_WORKSPACE_ROOT = "../..";
  INSTA_UPDATE = "no";
};
```

- `INSTA_WORKSPACE_ROOT` is the workspace root, relative to the package
  directory, where the test runs. For a package at `crates/my-crate` it is
  `../..`; for a package at the workspace root it is `.`. So set it per
  package, or in `memberDefaults` only when every member is at the same
  depth. breakbulk has no value yet that names the view's workspace root
  for you.
- `INSTA_UPDATE = "no"`: on a mismatch, insta prints the diff and the test
  fails. Without it, insta also tries to write a `.snap.new` file.

## Keep snapshot files test-only

Only tests read snapshot files. If the library or a bin can see them, an
edit to a snapshot rebuilds the library and everything that depends on
it.

- Snapshots under `tests/` are test-only already: the `tests/` directory
  is in the test views only
  ([`test.scopeTestsDir`](../reference/options/packages.md#packagesnametestscopetestsdir)).
- Snapshots under `src/` (insta's `src/snapshots/` for unit tests) are in
  every view. Leave them out of the `"build"` view with a
  [`sources`](../reference/options/packages.md#packagesnamesources)
  function:

```nix
modules = [
  ({ lib, ... }: {
    packages.my-crate.sources = [
      ({ default, kind, root, packageDir, ... }:
        let snaps = lib.fileset.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}/src");
        in if kind == "build" then lib.fileset.difference default snaps else default)
    ];
  })
];
```

An edit to a snapshot then rebuilds only the package's test binaries
(they share one view) and re-runs its tests. For whole directories,
[`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
does the same without a function. More recipes are in [Rebuild less when
unrelated files change](filter-source.md).

## Update snapshots

A test run cannot update a snapshot: its view is in the Nix store, which
is read-only. When the output changes, the test fails and shows the
difference.

To accept new output, run the tests with Cargo in your checkout, for
example in the dev shell, and commit the changed files:

| Library | Command |
| --- | --- |
| insta | `cargo insta test --review`, or `INSTA_UPDATE=always cargo test` |
| snapbox | `SNAPSHOTS=overwrite cargo test` |
| trycmd | `TRYCMD=overwrite cargo test` |
| expect-test | `UPDATE_EXPECT=1 cargo test` |

The next build sees the new files and passes.
