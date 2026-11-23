<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Package options

`packages.<name>`: settings for one package's units.

## `packages`

Per-package overrides, by crate name\. They apply in every workspace
whose lockfile has a package of that name, and only to that
package’s units\. Each is a module of the options below, evaluated
for each locked package of the name, with that package’s lockfile
entry (` { name, version, source ? null, ... } `) as its ` package `
argument: ` { package, ... }: lib.mkIf (breakbulk.versionReq.matches ">=0.42" package.version) { … } ` applies to the matching versions
only, as does ` breakbulk.whenVersion ">=0.42" { … } `\. A name that no
lockfile has is an evaluation warning\.

*Type:*
attribute set of module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  openssl-sys = { nativeInputs = p: [ p.pkg-config ]; inputs = p: [ p.openssl ]; };
  app.env.GIT_REV = self.rev or "dirty";
  "libsqlite3-sys".env.LIBSQLITE3_SYS_USE_PKG_CONFIG = "1";  # opt in to the system SQLite
  aws-lc-sys = breakbulk.whenVersion ">=0.42" { env.AWS_LC_SYS_PREBUILT_NASM = "1"; };
}

```

*Declared by:*
 - [lib/modules/packages\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/packages.nix)

## `packages.<name>.bench`

Run settings for the runs of the package’s bench binaries (a
bench, and the library’s and bins’ harnesses in bench mode),
over ` test `’s and under ` test.binaries.<key> ` ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings))\.
A variant with [` benches `](workspaces\.md\#workspacesnamevariantsnamebenches)
builds them with ` cargo bench --no-run `, and each enabled one
runs once with ` --test `, as a check of that variant
(` <pkg>/bench/<binary> `), so that a bench that no longer runs
fails CI\. Timed runs never happen inside Nix\. A package whose
` test.runner ` is ` testRunners.nextest ` sets ` bench.runner = breakbulk.lib.testRunners.direct ` for a bench without the libtest
harness (Criterion), which nextest cannot list\.

*Type:*
module of run settings

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  enable = false;
  runner = breakbulk.lib.testRunners.direct;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.bench.enable`

[` test.enable `](\#packagesnametestenable) for the package’s bench runs\.

*Type:*
boolean

*Default:*
` test.enable `’s

## `packages.<name>.bench.args`

[` test.args `](\#packagesnametestargs) for the package’s bench runs\.

*Type:*
list of string

*Default:*
` test.args `’s

## `packages.<name>.bench.env`

[` test.env `](\#packagesnametestenv) for the package’s bench runs\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean or function that evaluates to a(n) (string or absolute path or package or signed integer or boolean)) (replaces) or list of them (appends)

*Default:*
` test.env `’s

## `packages.<name>.bench.path`

[` test.path `](\#packagesnametestpath) for the package’s bench runs\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*
` test.path `’s

## `packages.<name>.bench.postRun`

[` test.postRun `](\#packagesnametestpostrun) for the package’s bench runs\.

*Type:*
strings concatenated with “\\n”

*Default:*
` test.postRun `’s

## `packages.<name>.bench.preRun`

[` test.preRun `](\#packagesnametestprerun) for the package’s bench runs\.

*Type:*
attribute set of (null or string)

*Default:*
` test.preRun `’s

## `packages.<name>.bench.runner`

[` test.runner `](\#packagesnametestrunner) for the package’s bench runs\.

*Type:*
test runner (function from the run’s facts to a shell snippet)

*Default:*
` test.runner `’s

## `packages.<name>.bench.stages`

[` test.stages `](\#packagesnameteststages) for the package’s bench runs\.

*Type:*
attribute set of (null or submodule)

*Default:*
` test.stages `’s

## `packages.<name>.bench.stages.<name>.enable`

Whether the stage exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

## `packages.<name>.bench.stages.<name>.after`

The stage or stages this one runs after\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

## `packages.<name>.bench.stages.<name>.before`

The stage or stages this one runs before\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

## `packages.<name>.bench.stages.<name>.ca`

false: the stage’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

## `packages.<name>.bench.stages.<name>.run`

` { input, product, target, pkgs }: <derivation> `: the stage’s output from its input, the previous stage’s\.

*Type:*
raw value

## `packages.<name>.bench.wrapper`

[` test.wrapper `](\#packagesnametestwrapper) for the package’s bench runs\.

*Type:*
null or raw value

*Default:*
` test.wrapper `’s

## `packages.<name>.buildScript.outDirRemove`

State a tool leaves in this package’s build-script output that
nothing reads after the run and that differs between runs: after
each successful run of the build script (on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)), in
every directory of the output that holds a file named ` beside `,
` path ` is deleted\. Lists concatenate over the layers\.

The curated [` sysDefaults.dependents `](repository\.md\#sysdefaultsdependents)
entry of the ` cmake ` crate gives every package that depends on it
directly ` { beside = "CMakeCache.txt"; path = "CMakeFiles"; } `:
CMake’s configure log there names randomly named try-compile
directories, and the ` cmake ` crate reads only ` CMakeCache.txt `
and ` Makefile ` of its build tree, within the run
([assumption E3](\.\./assumptions\.md\#e3-cmake-rs-reads-nothing-from-cmakefiles-after-the-run))\.
` lib.mkForce [ ] ` turns it off for a package that reads
` CMakeFiles ` later\.

*Type:*
list of (submodule)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  {
    beside = "meson-info";
    path = "meson-logs";
  }
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.buildScript.outDirRemove.*.beside`

The file name that marks a directory the rule applies in\.

*Type:*
string

*Example:*

```nix
"CMakeCache.txt"
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.buildScript.outDirRemove.*.path`

What to delete there: a file or a directory, relative to it\.

*Type:*
string

*Example:*

```nix
"CMakeFiles"
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.buildScriptPaths.allow`

` rerun-if-changed ` paths this package’s build script declares
and does not need, as shell glob patterns matched against the
path as the script printed it (` "*" `: every path)\. The
[` buildScriptPaths `](\.\./\.\./explanation/configuration\.md\#missing-build-script-paths)
check of each plan fails when a build-script run declared a path
that was not in its view, unless the run’s package allows it
here\. It applies to the package’s runs on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)\. A path
the script reads goes in ` extraSources ` (in the repository) or
` inputs ` (outside it) instead\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "../Cargo.lock"
  "/usr/include/*"
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.checks`

Checks on this package’s products, as ` targets.<triple>.checks `\.
They are added to the target’s checks and to the default checks
(` noSourceReferences `, ` buildScriptFiles `)\. ` null ` removes a check
from this package only\.

*Type:*
attribute set of (null or submodule)

*Default:*

```nix
{ }
```

*Example:*

```nix
{ noSourceReferences = null; }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.checks.<name>.enable`

Whether the check exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.checks.<name>.ca`

false: the check’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.checks.<name>.on`

The stage whose output the check reads (` linked ` for the raw link output); null: the product\.

*Type:*
null or string

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.checks.<name>.run`

` { input, product, target, pkgs }: <derivation> `, which fails when the check does\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.env`

Environment for every unit of this package, on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)
(compiles and build-script runs)\. Values may be derivations,
including the products of other plans: another workspace,
target or variant (a binary of this workspace for this build:
[` breakbulk.variants.tools `](\.\./\.\./how-to/workspace-tools\.md));
not of the plan that builds this package, which would depend on
itself\. They are passed by reference, and only this package’s
units read them\.

A string (or path, package, number, boolean) replaces the
variable’s value from the layers below, the env capture’s included; a
list of them is appended to it, joined with the variable’s separator
(` envSeparators `; by default ` : ` for search paths and unknown names, a
space for flag lists such as ` NIX_CFLAGS_COMPILE `; see
[the table](\.\./unit-builder\.md\#list-variables))\. Lists from every
layer concatenate; ` lib.mkForce ` keeps only its own definition\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean) (replaces) or list of them (appends)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.envSeparators`

The separator a variable’s lists are joined with, by name, for
this package’s ` env `, ` forHost.env `, ` forTarget.env ` and
` test.env `: what goes between the earlier value and an appended
list, and between the list’s values\. Without an entry, the
built-in table’s ([list variables](\.\./unit-builder\.md\#list-variables)),
else ` : `\.

*Type:*
lazy attribute set of string

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  CMAKE_PREFIX_PATH = ":";
  RUSTDOCFLAGS = " ";
}
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.extraSources`

Files and directories outside the package directory that its
units read (` include_str!("../../wit/x.wit") `, a sibling assets
directory, patches), at their original relative paths\. Strings
are relative to the package directory, as every path of a
package’s settings is\. The built-in entry
` sources.extraSources ` of [` sources `](\#packagesnamesources) adds them for every unit\.
A library, bin or build script that fails naming a path outside
its source view ends with a hint naming the path and this
option\.

*Type:*
list of (absolute path or string)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "wit"
  "../shared/assets"
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forHost.env`

Environment for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

A string (or path, package, number, boolean) replaces the
variable’s value from the layers below, the env capture’s included; a
list of them is appended to it, joined with the variable’s separator
(` envSeparators `; by default ` : ` for search paths and unknown names, a
space for flag lists such as ` NIX_CFLAGS_COMPILE `; see
[the table](\.\./unit-builder\.md\#list-variables))\. Lists from every
layer concatenate; ` lib.mkForce ` keeps only its own definition\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean) (replaces) or list of them (appends)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forHost.inputs`

Libraries for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forHost.nativeInputs`

Build-machine tools for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forTarget.env`

Environment for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

A string (or path, package, number, boolean) replaces the
variable’s value from the layers below, the env capture’s included; a
list of them is appended to it, joined with the variable’s separator
(` envSeparators `; by default ` : ` for search paths and unknown names, a
space for flag lists such as ` NIX_CFLAGS_COMPILE `; see
[the table](\.\./unit-builder\.md\#list-variables))\. Lists from every
layer concatenate; ` lib.mkForce ` keeps only its own definition\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean) (replaces) or list of them (appends)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forTarget.inputs`

Libraries for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.forTarget.nativeInputs`

Build-machine tools for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.inputs`

Libraries for the platform being built (` openssl `), for this
package’s units on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)\. A function of a package set
(` p: [ p.openssl ] `), called with the build machine’s set for host
units and with the target’s set for target units; or a list used
as given\. Elements may be the products of other packages, as in
` env `\. Their library search paths (` NIX_LDFLAGS `, not compiler
flags or ` PATH `) also reach the link steps of the packages that
link this one (bins, tests, cdylibs, doctests of dependents), on
the same platform, so a ` -sys ` crate may print ` rustc-link-lib `
without a search path; binaries get an rpath to the library\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.nativeInputs`

Tools that run on the build machine (` pkg-config `, ` cmake `,
` protoc `), for this package’s units on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)\. A function of
the build platform’s package set, or a list\. Elements may be the
products of other packages, as in ` env `\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.predictSources.enable`

Whether this package’s compiles and build-script runs see
only the files source prediction finds they read, so that an
edit to any other file of the package (its ` README.md `, a
comment in its ` Cargo.toml `, a file only a test reads) rebuilds
none of them\.

A compile’s predicted view is the module tree of its Cargo
target’s crate root, followed as rustc does (` mod ` items,
` #[path] ` and ` cfg_attr(…, path = …) `), and the files of every
` include! `, ` include_str! ` and ` include_bytes! ` with a literal
path (also ` concat!(env!("CARGO_MANIFEST_DIR"), "…") `) and of
` #[debugger_visualizer] `\. A build-script run’s is the paths its
script declares with literal ` rerun-if-changed ` directives,
which is what Cargo reruns it for\. Prediction reads the
package’s widest view (its test compiles’ view, with the
unit’s own), so a predicted read wins over an entry of
[` sources `](\#packagesnamesources) that left the file out of the unit’s view (the
` tests/ ` directory, another target’s root)\. Test runs and
doctests keep their views\. ` sourceOverlay ` entries go on top
of the predicted view\.

Files read in a way the prediction does not see are misses: a
proc macro reading a file (` askama ` templates, ` sqlx `’s
` .sqlx `, ` include_dir! `), a module a proc macro declares\. rustc
and most proc macros fail naming the file, and the failure ends
with a hint naming ` predictSources.keep `\. A unit whose files
cannot be predicted (a ` mod ` or include in a ` macro_rules! `
body, an include with a computed path, a file syn cannot parse,
a build script whose directives are computed or that prints
none) sees its own view, as without prediction\. A package with
a ` sourceOverlay ` has a derivation for each predicted view;
without [` ca `](repository\.md\#ca), every edit to the package
rebuilds its units\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.predictSources.buildScriptRuns`

Whether ` predictSources ` narrows this package’s build-script
runs to their declared ` rerun-if-changed ` paths\. The curated
[` sysDefaults.dependents `](repository\.md\#sysdefaultsdependents)
entries set it to ` false ` for a package whose
` [build-dependencies] ` name a crate whose library code prints
such directives, which source prediction cannot read\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.predictSources.keep`

Paths every predicted view of this package keeps, when the
package’s widest view has them: files a proc macro or build
script reads that source prediction does not see\. A string is
relative to the package directory (a directory keeps
everything under it); a path is absolute\. A function gets the
unit’s descriptor, as a ` sources ` step does without ` default `
(` unit ` is ` "compile" ` or ` "build-script-run" ` here, and
` cargoTarget ` is never null), and returns a ` lib.fileset `
value\. Lists concatenate in layer order\. The curated defaults keep ` Cargo.toml ` for the
dependents of ` proc-macro-crate ` (also the workspace’s),
` find-crate ` and ` bevy_macro_utils `, which read it from
` CARGO_MANIFEST_DIR `, and a variant’s ` wrapperConfig.workingDirFiles `
are kept (clippy’s: the working directory’s ` Cargo.toml `)\.

*Type:*
list of (string or absolute path or function from { unit, test, cargoTarget, root, packageDir, workspaceDir, targets, memberDirs, \.\.\. } to a file set)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "templates"
  ({ root, packageDir, ... }:
    lib.fileset.fileFilter (f: f.hasExt "sql") (root + "/${packageDir}/migrations"))
]

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.sourceOverlay`

Products to place in this package’s source views, by path
relative to the package directory: for crates that read files
at a fixed path next to their sources (` rust-embed `’s
` #[folder = "ui/dist"] `, ` include_dir! `, ` include_bytes! `)
rather than through an environment variable\. Each value is a
derivation (the product of another package, in this workspace
or another, as in ` env `), a path, or a string such as
` "${product}/share/ui" `\. It appears in every view of the
package (its build, test and run units) as a symbolic link to
the value, which replaces whatever the repository has at that
path\. The value is passed by reference: only this package’s
units depend on it, and planning and instantiation do not\.
Workspace packages only: registry and git crates have no view,
and setting it for one is an evaluation warning\. A predicted
view gets the entries too, on top of the files prediction
chose\.
See [Fetching and source
views](\.\./\.\./explanation/internals/sources\.md\#products-in-a-view)\.

*Type:*
lazy attribute set of (package or absolute path or string)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  "ui/dist" = repo.workspaces.ui.target.wasm32-unknown-unknown.packages.ui;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.sources`

The named steps that choose the files of this package’s source
views\. A unit’s view is every entry’s step in order, each on the
result of the one before, from the empty set; source prediction
([` predictSources `](\#packagesnamepredictsourcesenable)) and then
[` sourceOverlay `](\#packagesnamesourceoverlay) act on the result\.
An entry is a function, or ` { step; after; before; } `; ` null `
removes it\. A step gets an attribute set and returns a
` lib.fileset ` value inside the repository root, or ` { files; removed; } ` with the paths (relative to the root) it left out,
for hints; it gets ` default `, the files chosen so far, and the
unit’s descriptor:

 - ` unit `: ` "compile" `, ` "build-script-run" `, ` "doctest" ` or
   ` "test-run" `\. More may be added: return ` default ` for one you do
   not know\.
 - ` test `: whether the unit is one of the package’s test units: a
   compile Cargo builds with its dev-dependencies (test harnesses,
   integration tests, benches, examples), a doctest or a test run\.
 - ` cargoTarget `: the Cargo target the unit is of, ` { kind, name, path } ` (` kind `: ` "lib" `, ` "bin" `, ` "example" `, ` "test" `,
   ` "bench" ` or ` "custom-build" `; ` path `: its crate root, relative to
   the package directory): the compiled target, the build script of a
   run, the library of a doctest, the test binary of a run\. null for
   the package’s own view, which a unit the planner matched to no
   target reads\.
 - ` root `: the repository root, a path\.
 - ` packageDir `: the package directory, relative to ` root ` (` "" ` for
   a package at the root)\.
 - ` workspaceDir `: the Cargo workspace’s directory, relative to ` root `\.
 - ` targets `: every Cargo target of the package, as ` cargoTarget `\.
 - ` memberDirs `: the directories of the workspace’s members, relative
   to ` root `\.

A step must take ` ... `\. breakbulk passes one more argument, so
that a step without ` ... ` fails on its first use, not when
breakbulk adds an argument\. The error names an argument the step
does not take; the extra one’s name says to add ` ... `\.

The built-in entries, in order, each made by a constructor of
` breakbulk.lib.sourceSteps `:

 - ` package `: the package directory, without its top-level
   ` target/ `, ` .git ` and ` result ` symlinks of ` nix build `, and
   without nested workspace members\.
 - ` extraSources `: [` extraSources `](\#packagesnameextrasources),
   for every unit\.
 - ` sourceScope `: [` test.sourceScope `](\#packagesnametestsourcescope),
   added for the test units and its paths inside the package
   taken out for the others\.
 - ` testsDir `: the package’s ` tests/ ` directory taken out for
   its non-test units (the library, bins, the build script and
   its run), so a fixture edit there rebuilds no library, bin or
   product\. Set it to ` null ` when one of them reads from ` tests/ `
   (` include_str!("../tests/…") `, a build script that generates
   tests from fixtures, a library that builds a path into
   ` tests/ ` from ` CARGO_MANIFEST_DIR ` that the tests read)\.
 - ` targetRoots `: for one Cargo target’s compiles, the crate
   roots of the package’s other bins, examples, tests and
   benches taken out (a root ` <dir>/main.rs ` outside ` src/ `,
   ` src/bin/ `, ` tests/ `, ` benches/ ` and ` examples/ ` counts as its
   whole directory), and for the library, a bin or the build
   script, the ` examples/ ` and ` benches/ ` directories\. So an
   edit to ` tests/foo.rs ` rebuilds only that test\. Shared files,
   such as ` tests/common/mod.rs `, stay\. Set it to ` null ` when a
   target reads another target’s root (` #[path = "../other.rs"] `,
   a library that ` include_str! `s an example)\.
 - ` runFiles `: [` test.runFiles `](\#packagesnametestrunfiles), for
   test runs\.

An entry runs after the entries its ` after ` names and before
those its ` before ` names; one with neither runs after every
built-in entry\. Entries left unordered run built-in ones first,
in their order, then by name\. A reference to a removed entry is
dropped\. A unit that fails naming a path its view lacks ends with a
hint naming the entry that left it out, where one did (for a step
that returns a bare file set: under the deepest directory that
holds every file it took away)\. Each
entry is one value: of two
[layers](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order)
that set it, the higher one’s wins\. An attribute set given for
a built-in entry takes the fields it leaves out from the
built-in one, so ` sources.testsDir.after = "mine" ` moves it and
` sources.testsDir.enable = true ` brings it back over a lower
layer’s ` null `\. See [Fetching and source
views](\.\./\.\./explanation/internals/sources\.md\#source-views) and
[Rebuild less when unrelated files
change](\.\./\.\./how-to/filter-source\.md)\.

*Type:*
attribute set of (null, step function or { step, after, before, enable })

*Default:*

```nix
{ }
```

*Example:*

````nix
{
  fixtures = { default, unit, root, ... }:
    if unit == "test-run"
    then lib.fileset.union default (root + "/crates/linter/resources/fixtures")
    else default;
  # Library code reads `tests/data` at compile time.
  testsDir = null;
}

````

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages`

Post-link stages for this package’s products, as ` targets.<triple>.stages ` (` after = "install" ` for wrappers and packaging)\.

*Type:*
attribute set of (null or submodule)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages.<name>.enable`

Whether the stage exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages.<name>.after`

The stage or stages this one runs after\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages.<name>.before`

The stage or stages this one runs before\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages.<name>.ca`

false: the stage’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.stages.<name>.run`

` { input, product, target, pkgs }: <derivation> `: the stage’s output from its input, the previous stage’s\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.target`

Settings for this package on one target triple: a module with every
option of the package level (` env `, ` forHost `, ` forTarget `,
` stages `, ` test `, …)\. They apply to the plans for that triple, as a
layer over the settings of the same definition
([layer order](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order)):
` env ` still means both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides) (the build-script compile of a plan
for this triple included), ` forTarget.env ` the target side only\.

*Type:*
attribute set of module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpegWin;
  x86_64-pc-windows-msvc.stages.sign = { after = "install"; run = sign; };
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.enable`

Whether a run is part of ` repo.checks ` and the check groups\. The
binary is built either way (a doctest compiles and runs in one
rustdoc process, so a disabled doctest run builds nothing of it in
the checks; ` doctests.<pkg> ` still builds it)\. For a library
whose manifest sets ` doctest = false `, there is no doctest run to
enable\. A single value ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings)):
` memberDefaults.test.binaries.<key>.enable = false ` with ` true `
for a few packages runs only theirs\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.args`

Arguments for the test binary, which the test runner passes on
(libtest’s, for a binary with its harness)\. A doctest run passes each to
` rustdoc --test ` as ` --test-args `, so ` [ "--skip" "src/lib.rs - net" ] ` skips a doctest by name\. Bench runs start with ` --test `
(the ` bench ` layer’s own definition: ` lib.mkForce ` replaces it)\.
Lists concatenate ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings))\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "--skip"
  "net::"
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.binaries`

Run settings for one binary of this package, over ` test `’s
and, for a bench run, ` bench `’s ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings)), by its key
(and the name of its check, ` <ws>/<triple>/<pkg>/… `):

 - an integration test (` [[test]] `, ` tests/cli.rs `): its name,
   ` cli ` (check ` test/cli `);
 - the library’s unit tests: ` lib/ ` and the library’s crate
   name, ` lib/my_crate ` (check ` test/lib/my_crate `, and
   ` bench/lib/my_crate ` for its bench run);
 - a bin’s unit tests: ` bin/ ` and the bin’s name, ` bin/my-tool `
   (check ` test/bin/my-tool `, ` bench/bin/my-tool `);
 - an example, or a bench with ` test = true `: ` example/<name> `,
   ` bench/<name> ` (check ` test/example/<name> `,
   ` test/bench/<name> `);
 - a bench: ` bench/<name> ` (check ` bench/bench/<name> `)\.

The key is the binary’s one name: in ` tests `, ` testRuns `,
` testApps `, ` benches `, ` benchRuns `, checks and apps\.

A key that names no test or bench binary of the package is an
evaluation error listing the package’s keys\. The keys come from
the package’s manifest, so a binary that only some targets or
variants build (` required-features `) has its key on all of
them\. Under ` memberDefaults `, a key must name a binary of some
member\.

*Type:*
attribute set of module of run settings

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  net.args = [ "--skip" "needs_network" ];
  "lib/my_crate".env.RUST_LOG = "debug";
  "bin/my-tool".enable = false;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.binaries.<name>.enable`

[` test.enable `](\#packagesnametestenable) for this binary’s runs\.

*Type:*
boolean

*Default:*
` test.enable `’s

## `packages.<name>.test.binaries.<name>.args`

[` test.args `](\#packagesnametestargs) for this binary’s runs\.

*Type:*
list of string

*Default:*
` test.args `’s

## `packages.<name>.test.binaries.<name>.env`

[` test.env `](\#packagesnametestenv) for this binary’s runs\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean or function that evaluates to a(n) (string or absolute path or package or signed integer or boolean)) (replaces) or list of them (appends)

*Default:*
` test.env `’s

## `packages.<name>.test.binaries.<name>.path`

[` test.path `](\#packagesnametestpath) for this binary’s runs\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*
` test.path `’s

## `packages.<name>.test.binaries.<name>.postRun`

[` test.postRun `](\#packagesnametestpostrun) for this binary’s runs\.

*Type:*
strings concatenated with “\\n”

*Default:*
` test.postRun `’s

## `packages.<name>.test.binaries.<name>.preRun`

[` test.preRun `](\#packagesnametestprerun) for this binary’s runs\.

*Type:*
attribute set of (null or string)

*Default:*
` test.preRun `’s

## `packages.<name>.test.binaries.<name>.runner`

[` test.runner `](\#packagesnametestrunner) for this binary’s runs\.

*Type:*
test runner (function from the run’s facts to a shell snippet)

*Default:*
` test.runner `’s

## `packages.<name>.test.binaries.<name>.stages`

[` test.stages `](\#packagesnameteststages) for this binary’s runs\.

*Type:*
attribute set of (null or submodule)

*Default:*
` test.stages `’s

## `packages.<name>.test.binaries.<name>.stages.<name>.enable`

Whether the stage exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

## `packages.<name>.test.binaries.<name>.stages.<name>.after`

The stage or stages this one runs after\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

## `packages.<name>.test.binaries.<name>.stages.<name>.before`

The stage or stages this one runs before\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

## `packages.<name>.test.binaries.<name>.stages.<name>.ca`

false: the stage’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

## `packages.<name>.test.binaries.<name>.stages.<name>.run`

` { input, product, target, pkgs }: <derivation> `: the stage’s output from its input, the previous stage’s\.

*Type:*
raw value

## `packages.<name>.test.binaries.<name>.wrapper`

[` test.wrapper `](\#packagesnametestwrapper) for this binary’s runs\.

*Type:*
null or raw value

*Default:*
` test.wrapper `’s

## `packages.<name>.test.doctest`

Run settings for the package’s doctest run (` doctests.<pkg> `,
check ` <ws>/<triple>/<pkg>/doctest `), over ` test `’s
([run settings](\.\./\.\./explanation/configuration\.md\#run-settings))\. rustdoc compiles and runs each example itself,
so ` wrapper `, ` runner `, ` preRun ` and ` stages ` are an error
here, and ` test `’s do not apply to doctests\.

*Type:*
module of run settings

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  enable = false;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.doctest.enable`

[` test.enable `](\#packagesnametestenable) for the package’s doctest run\.

*Type:*
boolean

*Default:*
` test.enable `’s

## `packages.<name>.test.doctest.args`

[` test.args `](\#packagesnametestargs) for the package’s doctest run\.

*Type:*
list of string

*Default:*
` test.args `’s

## `packages.<name>.test.doctest.env`

[` test.env `](\#packagesnametestenv) for the package’s doctest run\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean or function that evaluates to a(n) (string or absolute path or package or signed integer or boolean)) (replaces) or list of them (appends)

*Default:*
` test.env `’s

## `packages.<name>.test.doctest.path`

[` test.path `](\#packagesnametestpath) for the package’s doctest run\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*
` test.path `’s

## `packages.<name>.test.doctest.postRun`

[` test.postRun `](\#packagesnametestpostrun) for the package’s doctest run\.

*Type:*
strings concatenated with “\\n”

*Default:*
` test.postRun `’s

## `packages.<name>.test.env`

Environment for runs (test runs, doctests and bench runs) and test
apps\. It comes after the environment Cargo gives the binary
(` [env] `, the build script’s ` rustc-env `, ` CARGO_* `), so it can
replace any of it\. Variables merge ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings))\.

A value can also be a function of the run, ` run: … `, with
` run.workspaceRoot `: the absolute path of the workspace’s root
directory in the files the run sees (its source view, or the checkout
for a test app with ` checkout `)\. For example
` INSTA_WORKSPACE_ROOT = run: run.workspaceRoot; `\. More attributes may
be added, so take them with ` { workspaceRoot, ... } `\.

A string (or path, package, number, boolean) replaces the
variable’s value from the layers below, the env capture’s included; a
list of them is appended to it, joined with the variable’s separator
(` envSeparators `; by default ` : ` for search paths and unknown names, a
space for flag lists such as ` NIX_CFLAGS_COMPILE `; see
[the table](\.\./unit-builder\.md\#list-variables))\. Lists from every
layer concatenate; ` lib.mkForce ` keeps only its own definition\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean or function that evaluates to a(n) (string or absolute path or package or signed integer or boolean)) (replaces) or list of them (appends)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.path`

Packages whose ` bin ` directories go on ` PATH ` in runs and test
apps, after the environment\. A function of the package set of
the machine that runs the test (the target’s ` testSystem `, else
the build machine; the build machine’s for doctests and test
apps), or a list used as given\. Lists concatenate ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.

*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it

*Default:*

```nix
[ ]
```

*Example:*

```nix
p: [ p.git ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.postRun`

A shell snippet run inside each passing run (test, doctest or
bench), after the tests: ` $log ` is the run’s raw output and ` $out `
the run’s output directory, empty otherwise\. Under
` testRunners.nextest `, nextest’s store (JUnit reports) is
` $TMPDIR/nextest-ws/target/nextest `\.
Snippets concatenate ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings)): the package’s first, then the
binary’s or the doctest run’s\. Whatever a snippet puts in ` $out `
decides whether the run is reproducible: breakbulk keeps ` $out `
empty so that ` nix build --rebuild ` of a passing run succeeds,
and the output stays in the build log (` nix log `)\.
` cp "$log" "$out/log" ` keeps the raw output, for a binary cache
that does not store build logs or a CI that keeps them as
artifacts; it holds timings and, with several test threads, lines
in a varying order, so such a run is not reproducible under
` nix build --rebuild `\.

*Type:*
strings concatenated with “\\n”

*Default:*

```nix
""
```

*Example:*

```nix
"cp -r \"$TMPDIR/nextest-ws/target/nextest/ci\" \"$out/junit\""
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.preRun`

Shell snippets run before the binary, in name order, in the run’s
shell after its environment (` env `, ` path `) is set: what they
export reaches the test\. ` null ` removes an entry\. Each entry is a
single value of its own ([run settings](\.\./\.\./explanation/configuration\.md\#run-settings)), so a more specific layer
replaces one entry and keeps the others\. The entries breakbulk
defines:

 - ` home `: a fresh, empty ` HOME ` in ` $TMPDIR `, as a test’s home is
   under ` cargo test `, unless the environment set another than
   Nix’s ` /homeless-shelter `\. With ` home = null ` a run keeps
   ` /homeless-shelter `, so a test that writes to its home fails, as
   compiles do\. ` XDG_* ` stay unset, so tools fall back to
   directories under ` HOME `\.
 - ` coverage `, in the variant of
   [` breakbulk.variants.coverage `](\.\./presets\.md\#coverage) (its
   ` memberDefaults.variant.<v> ` layer): ` LLVM_PROFILE_FILE ` into
   ` $TMPDIR/profraw `, which the run’s ` postRun ` moves into
   ` $out/profraw ` when it passes\.

Doctests and test apps do not run them: rustdoc runs the examples
itself, with a fresh ` HOME ` and ` RUST_TEST_THREADS `
(` test.doctest.preRun ` is an error), and a test app keeps the
user’s environment\.

*Type:*
attribute set of (null or string)

*Default:*
` home ` (see the description)

*Example:*

```nix
{
  home = null;  # keep Nix's /homeless-shelter
  db = "initdb -D \"$TMPDIR/db\" && pg_ctl -D \"$TMPDIR/db\" -w start";
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.runFiles`

Narrow what this package’s test runs see: their working
directory (and runtime ` CARGO_MANIFEST_DIR `) is a view holding
only these paths, relative to the package directory, at their
usual places; ` [ ] ` gives an empty directory\. Editing any other
file of the package then leaves the test run’s own inputs
unchanged, so with content addressing (` ca `) a byte-identical
test binary is not re-run\. A test that reads a file not listed
fails\. ` null `: the view of the package’s test compiles, as
` cargo test ` sees it\. Test apps keep that view\. A built-in
step of [` sources `](\#packagesnamesources), for kind ` "run" `: a later function can
still add files, such as another package’s fixtures\. Strings
are relative to the package directory\.
` repo.config.ca ` says whether [` ca `](repository\.md\#ca) is on\.

*Type:*
null or (list of string)

*Default:*

```nix
null
```

*Example:*

```nix
[
  "tests/fixtures"
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.runner`

The test runner: what starts the binary in its run, a function
from the run’s facts (the binary, its ` args `, its platform, a
launcher that applies the ` wrapper ` and the target runner, the
package graph, …) to a shell snippet, so a harness breakbulk does
not know needs no change to breakbulk
([Test runners](\.\./presets\.md\#test-runners) lists the facts and
the contract)\. Each binary is its own run\.
[` breakbulk.lib.testRunners `](\.\./presets\.md\#test-runners) has
` direct ` (the binary itself, as ` cargo test ` runs it; it sets
libtest’s ` RUST_TEST_THREADS ` to the build’s cores unless the
environment set it) and ` nextest { profile; configFile; package; } `
(cargo-nextest’s reuse-build mode over the one binary, with the
project’s nextest configuration: retries, timeouts, default
filter, test groups)\. Doctests run under rustdoc whatever this
says (` test.doctest.runner ` is an error)\. Test apps start the
binary directly\. Not the target runner
([` targets.<t>.runner `](targets\.md\#targetsnamerunner)), which
starts every program of the target (wine, qemu)\.

*Type:*
test runner (function from the run’s facts to a shell snippet)

*Default:*

```nix
breakbulk.lib.testRunners.direct
```

*Example:*

```nix
breakbulk.lib.testRunners.nextest { profile = "ci"; }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.sourceScope`

Paths (paths, or strings relative to the package directory)
that only this package’s test units see: the
units Cargo builds with its dev-dependencies (test harnesses,
integration tests and benches with or without the libtest
harness, examples), its doctests and its test runs, whose
working directory is the package directory of their view\. A
path outside the package is added to the test view\. A path
inside the package is also removed from the view of its other
units (the library, bins, build script)\. Either way, editing
it rebuilds only this package’s test units and re-runs its
tests\. The package’s ` tests/ ` directory is in this scope too
(the built-in entry ` sources.testsDir `)\. The built-in entry
` sources.sourceScope ` of [` sources `](\#packagesnamesources) applies it\. A test unit or
test run that fails naming a path outside its source view ends
with a hint naming the path and this option\.

*Type:*
list of (absolute path or string)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "testdata"
]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages`

Stages the binary goes through before a run executes it, as a
product’s [` stages `](\#packagesnamestages) (` { after ? null; before ? null; run; } `; ` null ` removes one; there is no
` install `): the run executes the last stage’s output, a directory
holding the one binary\. A stage’s ` target ` argument also has
` packageSet `, the platform’s package set or null\.

With [` ca `](repository\.md\#ca) (` repo.config.ca `) the default is
` strip = { run = breakbulk.stageHelpers.strip { buildId = false; }; } `\.
Workspace libraries keep real source paths and line tables in
their debug info, so an edit to any file of such a library (a
README, a function the test never calls) changes the bytes of
every test binary that links it; the stripped copy does not
change, and the run is not re-run\. Panic messages keep their file
and line; backtraces still name functions, but not files, lines
or inlined frames\. The unstripped binary stays in
` tests.<pkg>.<binary> ` for debugging\. Without ` ca ` a stage’s
output is input-addressed and saves no run, so there is none\.
Doctests have no binary to stage (` test.doctest.stages ` is an
error)\.

*Type:*
attribute set of (null or submodule)

*Default:*
with [` ca `](repository\.md\#ca), ` strip `; else none

*Example:*

```nix
{ strip = null; }  # run the unit's own binary

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages.<name>.enable`

Whether the stage exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages.<name>.after`

The stage or stages this one runs after\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages.<name>.before`

The stage or stages this one runs before\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages.<name>.ca`

false: the stage’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.stages.<name>.run`

` { input, product, target, pkgs }: <derivation> `: the stage’s output from its input, the previous stage’s\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.test.wrapper`

A program that starts the binary, in its runs and test apps:
Cargo’s runner protocol, ` <wrapper> <binary> <args…> `, in the
package directory, with ` BREAKBULK_SOURCE_ROOT ` (the root of the
run’s source view, or of the checkout for a test app with
` checkout `) and ` BREAKBULK_NEXT ` (a program that starts the binary
under the target’s runner, or directly without one) in its
environment\. It ends with ` exec "$BREAKBULK_NEXT" <binary> <args…> `, the binary possibly moved\. It runs outside the target’s
runner, on the machine that runs the test\. A program, or a
function from the package set of that machine to one\. The test
runner gets it in its launcher (` testRunners.nextest ` gives nextest
the launcher as the target runner, for listing as for each test)\.
[` breakbulk.lib.wrappers `](\.\./presets\.md\#test-wrappers) has
ready-made ones\. Doctests do not use it: rustdoc runs each example
itself (` test.doctest.wrapper ` is an error)\. ` null `: none\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Example:*

```nix
breakbulk.lib.wrappers.cargoTargetLayout { profile = "debug"; }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)

## `packages.<name>.variant`

Settings for this package in the plans of one variant
(` workspaces.<ws>.variants.<v> `): a module with every option of the
package level, ` target.<triple> ` included\. They are a layer over
the settings of the same definition and their ` target.<triple> `
layer
([layer order](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order)),
and leave the units of other variants unchanged: a lint setting for
a ` clippy ` variant does not rebuild the release variant\. A variant
layer’s ` target.<triple> ` applies to that variant on that triple
only\. The layer applies in every workspace that has a variant of
that name; a name that no workspace has is an evaluation warning\.

*Type:*
attribute set of module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  coverage.test.env.RUST_LOG = "debug";
  full.inputs = p: [ p.openssl ];
  full.target.x86_64-pc-windows-msvc.forTarget.env.OPENSSL_DIR = opensslWin;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)
