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
unless they hold files their build does not read. The tests of a member
that depends on snapbox also see the workspace's root `Cargo.toml`
([Run snapshot tests](snapshot-tests.md)), so an edit to it re-runs
them.

The views and the steps that make them are explained in
[Fetching and source views](../explanation/internals/sources.md#source-views).

## Files outside a package's directory

If a crate reads files outside its own directory (`include_str!("../../wit/x.wit")`,
shared assets), name them for that package, relative to its directory
(here `crates/app`), as every path in a package's settings is:

```nix
modules = [{
  packages.app.extraSources = [ "../../wit" "../../shared/assets" ];
}];
```

In `workspaces.<ws>.memberDefaults`, a string is each member's own
path; give a directory every member reads as a path value
(`./shared/assets`).

They appear at their original relative paths, so the crate's paths work
unchanged, and only that package's units depend on them.

To find them, build: a unit that fails reading a path outside its view
(rustc's ``couldn't read `…` ``, a proc macro's or build script's error
with the path) ends with a hint naming the path and the option, as in

```text
hint: `docs/partials/rules.html` is not in this unit's source view; if it is in the repository, add it to `packages.app.extraSources`, or to `packages.app.test.sourceScope` for the package's test units only
```

[`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
adds the path for the package's tests only. A message
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
directory in its `extraSources` (relative to its own directory), also
when the directory belongs to another package. Crates that never read it need nothing, and do not
depend on it.

Registry and git crates do not see the repository: they see such a path
in an empty directory. When one reads it (openssl-sys's build script
reading `OPENSSL_DIR`, say), give that package the directory itself with
[`env`](../reference/options/packages.md#packagesnameenv), which takes
the place of Cargo's value:

```nix
packages.openssl-sys.env.OPENSSL_DIR = ./vendor/openssl;
```

A unit of such a crate that fails while a value from `[env]` names a
repository path prints that setting:

```text
hint: `openssl-sys` was given the repository path `vendor/openssl` in `OPENSSL_DIR` (from Cargo config `[env]`); registry and git crates do not see the repository: set `packages.openssl-sys.env.OPENSSL_DIR = ./vendor/openssl;`
```

The path is relative to the repository root. A repository path in
`build.rustflags` (`-L native=vendor/lib`) reaches registry and git
crates the same way, but no option replaces a rustc argument for one
package: the hint names the path and the flag. Use a path outside the
repository there.

A build script that checks whether a file exists (`Path::exists()`) and
does something else when it does not gets no warning for a missing file:
it does not fail, and it names no `rerun-if-changed` path. Read the build
script, and add such files to `extraSources` too.

## Choose files with a step

[`packages.<name>.sources`](../reference/options/packages.md#packagesnamesources)
is a set of named steps. A unit's view is every step in order, each
getting the files chosen so far and returning the next choice, as a
`lib.fileset` value:

```nix
modules = [
  ({ lib, ... }: {
    packages.app.sources.noDocs = { default, test, root, packageDir, ... }:
      if !test
      then lib.fileset.difference default (root + "/${packageDir}/docs")
      else default;
  })
];
```

- `default` is the files chosen so far.
- `unit` is `"compile"`, `"build-script-run"`, `"doctest"` or
  `"test-run"`, and `test` says whether the unit is one of the package's
  test units (a compile with its dev-dependencies, a doctest, a test
  run). Return `default` for a `unit` you do not know: more may be added.
- `cargoTarget` is the Cargo target the unit is of (`{ kind, name, path
  }`): the compiled target, the build script of a run, the library of a
  doctest, the test binary of a run.
- `root` is the repository root, `packageDir` the package directory
  relative to it (`""` for a package at the root) and `workspaceDir` the
  workspace's. `targets` lists the package's Cargo targets and
  `memberDirs` the workspace's members.
- Take `...`. breakbulk passes one more argument, so a step without
  `...` fails on its first use.

The built-in steps come first: `package` (the package directory),
`extraSources`, `sourceScope`, `testsDir`, `targetRoots` and `runFiles`,
which the reference describes. A step of yours runs
after them; `after` and `before` place it elsewhere, and `null` removes
any step:

```nix
packages.app.sources = {
  # Before the test runs' `runFiles` narrows their view.
  runData = {
    before = "runFiles";
    step = { default, unit, root, ... }:
      if unit == "test-run" then lib.fileset.union default (root + "/data") else default;
  };
  # Library code reads `tests/data` at compile time.
  testsDir = null;
};
```

Steps that nothing orders run built-in ones first, then by name.
`workspaces.<ws>.memberDefaults` can set a step for every member, and a
package can replace or remove it under the same name.

### Keep only what the root package builds from

For a package at the repository root, keep only the files the build
reads:

```nix
packages.mytool.sources.only = { default, root, ... }:
  lib.fileset.intersection default (lib.fileset.unions [
    (root + "/Cargo.toml")
    (root + "/build.rs")
    (root + "/src")
    (root + "/tests")
  ]);
```

`intersection` keeps a file only if `default` has it, so `tests/` stays
out of the non-test units' views, as it is by default. Every path in the list
must exist. Add everything the build reads: data files, `include_str!`
targets, and the paths a build script reads. Then an edit to
`flake.nix`, a README or the CI configuration rebuilds nothing.

### Leave a README and the manifest out of the build

Source prediction does this by default. A compile sees only its module
tree and the files it includes with a literal path. A README line or a
comment in `Cargo.toml` then rebuilds none of the package's non-test
compiles. Test compiles and build-script runs keep the package's view
unless you turn them on too, because tests and scripts often read files
the sources do not name:

```nix
packages.web.predictSources = {
  testCompiles = true;     # no macro from another crate gives tests env!("CARGO_MANIFEST_DIR")
  buildScriptRuns = true;  # build scripts declare every file they read
};
``` Prediction reads the
files from the package's widest view, so a library that includes a file
under `tests/` builds although `tests/` is not in its own view.

Files a proc macro reads are not found: the compile fails naming the
file, with a hint, and
[`predictSources.keep`](../reference/options/packages.md#packagesnamepredictsourceskeep)
keeps them:

```nix
packages.web.predictSources.keep = [ "templates" ];
```

A file outside the package directory needs only
[`extraSources`](../reference/options/packages.md#packagesnameextrasources):
predicted views keep every file of the unit's view outside the package
directory.

To see what each unit's view holds, or why a unit falls back to its
whole view, build the variant's
[`explainPredictions`](../reference/outputs.md#explainpredictions) and
read the file. See
[Source prediction](../explanation/internals/sources.md#source-prediction)
for what prediction reads and when it falls back.

To turn prediction off:

```nix
packages.web.predictSources.enable = false;
# Or for every member: workspaces.<ws>.memberDefaults.predictSources.enable = false;
```

With prediction off, you can leave the files out by hand: planning reads the manifest from
its own copy, so the units do not need it in their view. If nothing reads
these files when the crate builds, leave them out of its non-test
units' views:

```nix
packages.ruff_python_ast.sources.noMeta = { default, test, root, packageDir, ... }:
  if !test
  then lib.fileset.difference default (lib.fileset.unions [
    (root + "/${packageDir}/README.md")
    (root + "/${packageDir}/Cargo.toml")
  ])
  else default;
```

Do not do this when something reads them at build time. Common readers
are a doc attribute (`#![doc = include_str!("../README.md")]`), a build
script that parses its own manifest, and a proc macro that reads the
manifest of the crate that uses it (`proc-macro-crate`). An edit to the
manifest that changes the plan (a dependency, a feature) still rebuilds
the crate.

### Data that only test runs read

Some tests read files while they run, not when they compile. Add such
files for test runs only. An edit to them then re-runs the tests and
rebuilds no test binary:

```nix
packages.ruff.sources.fixtures = { default, unit, root, ... }:
  if unit == "test-run"
  then lib.fileset.union default (root + "/crates/ruff_linter/resources/test/fixtures")
  else default;
```

The test must find the files at run time: relative to its working
directory, which is the package directory, or through the
`CARGO_MANIFEST_DIR` environment variable. A path the test builds at
compile time (`env!("CARGO_MANIFEST_DIR")`, `include_str!`) names the
view of the test compile, where the files are not. Such a test needs the
files for its compile too.

### Files that only tests read, by pattern

To make files test-only by pattern, remove them from the non-test
units' views. For example, snapshot files under `src/`:

```nix
packages.ruff_linter.sources.snapshots = { default, test, root, packageDir, ... }:
  let snaps = lib.fileset.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}/src");
  in if !test then lib.fileset.difference default snaps else default;
```

An edit to a snapshot then rebuilds only the package's test units. For
whole directories, [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
does the same without a function.

### Files that only one target reads

`cargoTarget` names the Cargo target a unit is of (null for the
package's own view, which a unit the planner matched to no target
reads). For example, if only the `parser` integration test embeds the
files in `tests/parser-cases` (`include_str!`), leave them out of every
other target's compiles:

```nix
packages.my-crate.sources.parserCases = { default, unit, cargoTarget, root, packageDir, ... }:
  if unit == "compile" && cargoTarget != null && cargoTarget.name != "parser"
  then lib.fileset.difference default (root + "/${packageDir}/tests/parser-cases")
  else default;
```

An edit there then rebuilds only the `parser` test and re-runs the
package's tests. The other targets' roots are left out of each target's
compiles already (the built-in `targetRoots` step). A unit whose view no
step changes from its package's shares the package's view.

### When a unit misses a file

If a unit fails because a file is missing from its view, the hint names
the step that left it out:

```text
hint: `crates/app/docs/a.md` is under `crates/app/docs`, which is left out by `packages.app.sources.noDocs`; if the unit reads it, add it in an entry after that one, or change that entry
```

For a step that returns a bare file set, breakbulk records the deepest
directory that holds every file the step took away, so the hint names it
for any missing path there. A path outside the package directory that no
step left out gets a hint naming `extraSources` or `test.sourceScope`.
