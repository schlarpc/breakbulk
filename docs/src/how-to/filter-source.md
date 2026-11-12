# Rebuild less when unrelated files change

Each package's units see only that package's directory (plus its
`extraSources`), so an edit elsewhere in the repository does not rebuild
them. The exception is a package whose directory is the repository root:
a single-crate repository, or a workspace whose root `Cargo.toml` is also
a package. That package sees the whole repository except the directories
of its workspace's other members, so editing `flake.nix`, a README or CI
configuration rebuilds it and everything that depends on it. The members
do not see those files.

Members in subdirectories (`crates/foo`) need nothing on this page,
unless they hold files their build does not read. Their tests also see
the workspace's root `Cargo.toml`, for snapshot-test libraries
([Run snapshot tests](snapshot-tests.md)), so an edit to it re-runs
every member's tests.

The views and the steps that make them are explained in
[Fetching and source views](../explanation/internals/sources.md#source-views).

## Files outside a package's directory

If a crate reads files outside its own directory (`include_str!("../../wit/x.wit")`,
shared assets), name them for that package, relative to the repository
root:

```nix
modules = [{
  packages.app.extraSources = [ "wit" "../shared/assets" ];
}];
```

They appear at their original relative paths, so the crate's paths work
unchanged, and only that package's units depend on them.

To find them, build: a unit that fails reading a path outside its view
(rustc's ``couldn't read `…` ``, a proc macro's or build script's error
with the path) ends with a hint naming the path and the option, as in

```text
hint: `docs/partials/rules.html` is not in this unit's source view; if it is in the repository, add it to `packages.app.extraSources`
```

A test, doctest or test run names
[`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
instead, which adds the path for the package's tests only. A message
without a path gets no hint.

The same applies to a path from Cargo config, such as an `[env]` entry
with `relative = true`:

```toml
# .cargo/config.toml
[env]
ASSETS_DIR = { value = "assets", relative = true }
```

Every unit gets the variable, but each sees the path in its own view. A
crate that reads the files through it
(`include_str!(concat!(env!("ASSETS_DIR"), "/logo.svg"))`) lists the
directory in its `extraSources`, also when the directory belongs to
another package. Crates that never read it need nothing, and do not
depend on it. Registry and git crates see such a path in an empty
directory.

A build script that checks whether a file exists (`Path::exists()`) and
does something else when it does not gets no warning for a missing file:
it does not fail, and it names no `rerun-if-changed` path. Read the build
script, and add such files to `extraSources` too.

## Choose files with a function

[`packages.<name>.sources`](../reference/options/packages.md#packagesnamesources)
is a list of functions. Each gets the files chosen so far and returns
the next choice, as a `lib.fileset` value:

```nix
modules = [
  ({ lib, ... }: {
    packages.app.sources = [
      ({ default, kind, root, packageDir, ... }:
        if kind == "build"
        then lib.fileset.difference default (root + "/${packageDir}/docs")
        else default)
    ];
  })
];
```

- `default` is the files chosen so far: the package directory, with
  `extraSources` and the `test` options applied.
- `kind` is `"build"` (non-test compiles, build scripts and their runs),
  `"test"` (test compiles and doctests) or `"run"` (test runs). Return
  `default` for any other kind: more may be added.
- `root` is the repository root, and `packageDir` the package directory
  relative to it (`""` for a package at the root).
- Take `...`. breakbulk passes one more argument, so a function without
  `...` fails on its first use.

Functions from several places run in [layer
order](../explanation/configuration.md#shared-settings-and-layer-order):
those of `workspaces.<ws>.memberDefaults` first, then those of
`packages.<name>`, each followed by its `target.<triple>` and
`variant.<v>` layers. Each function gets the result of the one before.

### Keep only what the root package builds from

For a package at the repository root, keep only the files the build
reads:

```nix
packages.mytool.sources = [
  ({ default, root, ... }:
    lib.fileset.intersection default (lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/build.rs")
      (root + "/src")
      (root + "/tests")
    ]))
];
```

`intersection` keeps a file only if `default` has it, so `tests/` stays
out of the `"build"` view, as it is by default. Every path in the list
must exist. Add everything the build reads: data files, `include_str!`
targets, and the paths a build script reads. Then an edit to
`flake.nix`, a README or the CI configuration rebuilds nothing.

### Leave a README and the manifest out of the build

A README line or a comment in `Cargo.toml` rebuilds the crate and
everything that depends on it. Planning reads the manifest from its own
copy, so the units do not need it in their view. If nothing reads these
files when the crate builds, leave them out of `"build"`:

```nix
packages.ruff_python_ast.sources = [
  ({ default, kind, root, packageDir, ... }:
    if kind == "build"
    then lib.fileset.difference default (lib.fileset.unions [
      (root + "/${packageDir}/README.md")
      (root + "/${packageDir}/Cargo.toml")
    ])
    else default)
];
```

Do not do this when something reads them at build time. Common readers
are a doc attribute (`#![doc = include_str!("../README.md")]`), a build
script that parses its own manifest, and a proc macro that reads the
manifest of the crate that uses it (`proc-macro-crate`). An edit to the
manifest that changes the plan (a dependency, a feature) still rebuilds
the crate.

### Data that only test runs read

Some tests read files while they run, not when they compile. Add such
files for `"run"` only. An edit to them then re-runs the tests and
rebuilds no test binary:

```nix
packages.ruff.sources = [
  ({ default, kind, root, ... }:
    if kind == "run"
    then lib.fileset.union default (root + "/crates/ruff_linter/resources/test/fixtures")
    else default)
];
```

The test must find the files at run time: relative to its working
directory, which is the package directory, or through the
`CARGO_MANIFEST_DIR` environment variable. A path the test builds at
compile time (`env!("CARGO_MANIFEST_DIR")`, `include_str!`) names the
view of the test compile, where the files are not. Such a test needs the
files for `"test"` too.

### Files that only tests read, by pattern

To make files test-only by pattern, remove them from `"build"`. For
example, snapshot files under `src/`:

```nix
packages.ruff_linter.sources = [
  ({ default, kind, root, packageDir, ... }:
    let snaps = lib.fileset.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}/src");
    in if kind == "build" then lib.fileset.difference default snaps else default)
];
```

An edit to a snapshot then rebuilds only the package's test units. For
whole directories, [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
does the same without a function.

### When a unit misses a file

If a unit fails because a file is missing from its view, add the file
for that kind. A file that `test.sourceScope` or `test.scopeTestsDir`
left out gets a hint that names the option. breakbulk does not know
which files a function left out, so such a failure gets no hint.
