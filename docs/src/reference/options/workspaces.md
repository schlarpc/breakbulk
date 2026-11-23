<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Workspace options

`workspaces.<name>`: one Cargo workspace each.

## `workspaces`

The Cargo workspaces of the repository, by a name of your choice\.
Without any definition, a repository whose root has a ` Cargo.toml `
gets one workspace, ` default `, at the root, so ` mkRepository ` needs
no modules; declaring any workspace turns that default off\. A
definition is a module of the workspace’s options, so it can have
` imports `, such as ` breakbulk.variants.featurePowerset { … } `\.

*Type:*
attribute set of (submodule)

*Default:*
` { default.path = "."; } ` when the repository root has a ` Cargo.toml `,
else ` { } `

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.defaultTarget`

The target whose products and tests the workspace’s shortcuts
are (` packages `, ` tests `, ` testRuns `, and the flake-parts
module’s ` packages `), and the default of ` devShell.target `\.
Every target in ` targets ` is built either way; this only picks
which one the shortcuts name\. ` null `: the shortcuts are empty;
use ` target.<triple>.packages `\.

The default’s ` build.target ` is read from the project’s own
` .cargo/config.toml ` files (from the workspace directory up to
the repository root, with Cargo’s merging), as the planner reads
Cargo config: not ` $CARGO_HOME `’s, not the environment\. Only a
single triple counts: a list, ` host-tuple ` or a ` .json ` path
gives ` null `\. Reading it is an import-from-derivation, made only
when the earlier rules do not decide and the workspace has a
Cargo config file; setting this option skips it\.

Not Cargo’s own ` package.default-target ` (nightly, per package),
which breakbulk does not read\.

*Type:*
null or string

*Default:*
the native triple when it is one of ` targets `, else the only
target, else the project’s ` build.target ` when it is one of
` targets `, else ` null `

*Example:*

```nix
"x86_64-unknown-uefi"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.defaultVariant`

The variant whose products are ` packages.<pkg> ` and
` target.<triple>.packages.<pkg> `\. Every variant’s products are
also under ` target.<triple>.variants.<variant> `\.

*Type:*
string

*Default:*

```nix
"default"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.devShell.env`

Variables for the dev shell, applied last, over everything the
shell sets\. The shell sets, in this order:

 1. each package’s ` env `, ` forHost.env ` and ` forTarget.env `
    (its layers for ` devShell.target ` and the default
    variant), for every package in ` Cargo.lock ` order;
 2. the ` env ` of ` devShell.target `;
 3. the Cargo env config for ` devShell.target `: its linker,
    its rustflags, and trim-paths when the planner turns it on;
 4. ` CARGO_BUILD_TARGET `\.

A value sets or replaces the variable\. A variable set here is
not reported as a conflict between packages\. ` null ` removes
the variable: the shell does not set it, and does not depend on
the derivation its value named, so that derivation is not built
when the shell opens\. A variable from your own environment
stays set\.

Changing or removing a variable from 3 or 4 makes local Cargo
differ from the plan: it compiles with other flags than Nix
builds do, and ` -C metadata ` can differ\.

*Type:*
attribute set of (null or string or absolute path or package or signed integer or boolean)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  MY_ASSETS_DIR = null;  # unset: build.rs falls back to its dev path
  RUST_LOG = "debug";
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.devShell.target`

The target the dev shell is set up for, one of ` targets `\. The
shell exports ` CARGO_BUILD_TARGET=<target> `, so local Cargo
behaves as the planner’s (which always passes ` --target `):
rustflags stay off build scripts, and ` -C metadata ` matches\.
Binaries then go to ` target/<triple>/… `\. It also gets that
target’s linker and rustflags as the planner passes them, and
its ` env `\. ` null `: none of these, so the project’s own
` build.target ` (or Cargo’s host default) applies\.

The shell also merges every package’s ` env `, ` forHost.env ` and
` forTarget.env `, as the default variant’s plans on this target
see them\. Set ` devShell.env ` to change or remove any of these
variables\.

*Type:*
null or string

*Default:*

```nix
defaultTarget
```

*Example:*

```nix
"x86_64-unknown-uefi"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.fmt.enable`

Add a check, ` repo.checks."<ws>/fmt" `, that runs ` cargo fmt --check ` with ` toolchain.rustfmt ` on every member of the
workspace (` -p `, so path dependencies outside it are left to
their own workspace)\. It reads the workspace directory and any
` rustfmt.toml ` or ` .rustfmt.toml ` above it up to the repository
root, and needs no plan\.

A project that formats with treefmt (treefmt-nix) can use its
check instead\. Its rustfmt runs per file with one ` --edition `
(treefmt-nix’s default is 2024), while ` cargo fmt ` takes each
crate’s edition from its ` Cargo.toml `, and the edition sets
rustfmt’s style edition; so pin ` style_edition ` in
` rustfmt.toml `, or set ` programs.rustfmt.edition ` to the crates’
edition\. Point ` programs.rustfmt.package ` at
` repo.workspaces.<ws>.toolchain.rustfmt ` to use the same rustfmt\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host`

The workspace’s host side: build scripts, proc macros and
their dependencies, built for and run on the build machine in
every plan whatever the plan’s target\. Target settings
(` targets.<triple>.* `) never reach these units, the native
target’s included\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.env`

Environment added to the workspace’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linker`

The linker of the workspace’s host units (build
scripts, proc macros and their dependencies), in every
plan whatever its target: given to Cargo as
` target.<build machine's triple>.linker ` when the
plan’s target is another triple; on the build machine’s
own triple, host units’ ` -C linker ` and ` RUSTC_LINKER `
are rewritten to it\. One linker for every plan, so the
host units of a native plan and of a cross plan are the
same derivations\.

*Type:*
string or absolute path or package

*Default:*
the build machine’s linker of kind ` linkerKind ` (` breakbulk.presetHelpers.chooseLinker `)

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKind`

Which kind of linker ` linker ` is, as
[` targets.<triple>.linkerKind `](targets\.md\#targetsnamelinkerkind)
picks one for a target\. ` null `: the one rustc itself
picks for the build machine and the workspace’s Rust
release, through nixpkgs’ wrapped C compiler\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"mold"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds`

The linker kinds ` linkerKind ` may name: breakbulk’s own
(` breakbulk.presetHelpers.builtinKinds `: ` cc `, ` lld `, ` mold `,
` clang-lld `, ` zig `, ` lld-link `, ` wasm-ld `, ` wasm-component-ld `,
` mingw-lld `, ` rust-lld `, ` ld64.lld `, ` ld.lld `), whose fields are set with
` lib.mkDefault `, and any added here or by a preset\. A kind is
chosen only by name; the default kind for a target is
breakbulk’s rule (` breakbulk.presetHelpers.linkerKind `)\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  wild = {
    on = traits: traits.isLinux;
    what = "Linux";
    build = { packageSet, ... }: breakbulk.presets.ccDriverLinker {
      inherit packageSet;
      cc = (packageSet.stdenvAdapters.useWildLinker packageSet.stdenv).cc;
      flag = "-fuse-ld=wild";
    };
  };
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.bitcode`

Whether the linker reads rustc’s LLVM bitcode, as ` crossLanguageLto ` (` -C linker-plugin-lto `) needs\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.build`

` args: path `: the linker\. ` args ` is ` { pkgs; packageSet; llvm; lld; zig; triple; traits; } `: mkRepository’s
` pkgs `, the package set whose C toolchain drives the link,
nixpkgs’ LLVM packages of rustc’s major release (the
toolchain’s facts), an ` lld ` package a preset passes, or
null, and linuxPortable’s ` zig cc `\. A C compiler driver
with a flag is ` breakbulk.presets.ccDriverLinker { packageSet; flag; } `\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.incompatible`

` ctx: null or message `: why the kind cannot link in this
context, which is an evaluation error naming the kind\.
` ctx ` is ` { triple; traits; lto; staticNonPie; zig; } `
(` staticNonPie `: the link makes non-PIE static glibc
executables; ` zig `: linuxPortable’s ` zig cc `, or null)\.

*Type:*
raw value

*Default:*

```nix
_: null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.lld`

` args: { name; version; patches; } `, the LLD the kind links
with, for the macOS SDK’s linker requirements (` args `:
` { rustc; llvm; } `), or null for a kind that is not an
Apple linker\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.on`

` traits: bool `: whether the kind links for a target with these [traits](\.\./\.\./explanation/internals/toolchains\.md\#target-traits)\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.linkerKinds.<name>.what`

The targets ` on ` accepts, as messages name them (` "Linux" `)\.

*Type:*
string

*Default:*

```nix
"some"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.runner`

The runner of the host units’ tests (a proc macro’s
unit tests and doctests, which Cargo builds for the
build machine), as
[` targets.<triple>.runner `](targets\.md\#targetsnamerunner)
is a target’s\. ` null `: run directly\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.stdenv`

The stdenv of the host units’ environment capture\.
` null `: the build machine’s\. It must build for the
build machine\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Example:*

```nix
pkgs.clangStdenv
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.host.testSystem`

The Nix system that runs the host units’ test runs\. ` null `: the build machine’s\.

*Type:*
null or string

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.memberDefaults`

Settings for every member of this workspace (the path packages
of its ` Cargo.lock `): a module with the options of
[` packages.<name> `](packages\.md), evaluated for each member,
whose lockfile entry is its ` package ` argument\. They are a
layer under the package’s own ` packages.<name> ` settings:
lists concatenate (` lib.mkForce ` in ` packages.<name> ` replaces
them), ` env ` attributes merge, and the package’s own value
wins for single values (` test.runner `) unless this one has a
higher priority (` lib.mkForce `)
([layer order](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order))\.
Dependencies from a registry or git do not get them\.

*Type:*
module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  test.env.RUST_LOG = "debug";
  test.runner = breakbulk.lib.testRunners.nextest { };
  extraSources = [ "testdata" ];
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members`

The workspace’s member packages, by name: read it, do not set
it\. They are found as Cargo finds them: the root package, the
directories ` [workspace] members ` names (globs included) but
not those under ` [workspace] exclude `, and the path
dependencies of members inside the workspace directory\. It is
read from the manifests alone, so a module can compute a
selection from ` config.workspaces.<ws>.members `:

```nix
{ config, lib, ... }:
{
  workspaces.default.targets.x86_64-unknown-linux-gnu.variantDefaults.tests =
    lib.filter (lib.hasPrefix "core-")
      (lib.attrNames config.workspaces.default.members);
}
```

The selection options (` variants.<v>.packages `, ` tests `,
` products `, ` benches `) also take ` { exclude = [ … ]; } `: every
member but those\.

*Type:*
attribute set of (submodule) *(read only)*

*Default:*
the workspace’s members, by name

*Example:*

```nix
{
  app = {
    name = "app";
    path = ".";
    features = { };
    optionalDependencies = [ ];
    dependencies = [ "core" ];
  };
  core = {
    name = "core";
    path = "crates/core";
    features = { default = [ "std" ]; std = [ ]; serde = [ "dep:serde" ]; };
    optionalDependencies = [ "serde" ];
    dependencies = [ "serde" ];
  };
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.dependencies`

The names (renamed names where renamed) of all the
package’s dependencies, of every kind, in any
dependency table, ` [target.<cfg>] ` ones included\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.features`

The package’s ` [features] ` table as written: no
implicit features of optional dependencies\.

*Type:*
attribute set of list of string

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.name`

The package’s name\.

*Type:*
string

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.optionalDependencies`

The names (renamed names where renamed) of the
package’s optional dependencies, in any dependency
table, ` [target.<cfg>] ` ones included\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.path`

The package’s directory, relative to the repository
root as ` workspaces.<ws>.path ` is (` . ` for the root)\.

*Type:*
string

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.path`

The workspace root, relative to the repository root\. Its
` Cargo.lock ` is used\.

*Type:*
string

*Default:*

```nix
"."
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.roots.bench`

The roots of this workspace’s bench plans
(` cargo bench --no-run `), in place of the roots breakbulk predicts
from the manifests: the way around a bug in that
prediction, which fails instantiation with “the plan has
roots that were not predicted”\. ` null ` keeps the
prediction\. Each entry is a root name as that error
lists them, ` <package>/<kind>/<target> `, with ` -test `
added to the kind of a test root other than a test
target (` app/bin-test/app `), or ` { name; platform; } `
for a root whose platform the prediction gets wrong
(“planned for the host platform, but was predicted for
the target platform”)\. ` platform ` is ` host ` for a
target Cargo builds for the build machine (a proc
macro’s unit tests), else ` target `; a bare name, or
` platform = null `, takes the platform predicted for the
root, or ` target ` when it is not predicted\. Both
delivery modes use the list, for every target and
variant\. A listed root that a plan lacks is a stub, as a
predicted one is\.

*Type:*
null or (list of (string matching the pattern (\[^/]+)/(lib|bin|cdylib|dylib|staticlib|example|test|bench|(lib|bin|cdylib|dylib|staticlib|example|bench)-test)/(\[^/]+) or (submodule)))

*Default:*

```nix
null
```

*Example:*

```nix
[
  "app/bin/app"
  "app/bin-test/app"
  { name = "pm/lib-test/pm"; platform = "host"; }
]

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.roots.build`

The roots of this workspace’s build plans
(` cargo build `), in place of the roots breakbulk predicts
from the manifests: the way around a bug in that
prediction, which fails instantiation with “the plan has
roots that were not predicted”\. ` null ` keeps the
prediction\. Each entry is a root name as that error
lists them, ` <package>/<kind>/<target> `, with ` -test `
added to the kind of a test root other than a test
target (` app/bin-test/app `), or ` { name; platform; } `
for a root whose platform the prediction gets wrong
(“planned for the host platform, but was predicted for
the target platform”)\. ` platform ` is ` host ` for a
target Cargo builds for the build machine (a proc
macro’s unit tests), else ` target `; a bare name, or
` platform = null `, takes the platform predicted for the
root, or ` target ` when it is not predicted\. Both
delivery modes use the list, for every target and
variant\. A listed root that a plan lacks is a stub, as a
predicted one is\.

*Type:*
null or (list of (string matching the pattern (\[^/]+)/(lib|bin|cdylib|dylib|staticlib|example|test|bench|(lib|bin|cdylib|dylib|staticlib|example|bench)-test)/(\[^/]+) or (submodule)))

*Default:*

```nix
null
```

*Example:*

```nix
[
  "app/bin/app"
  "app/bin-test/app"
  { name = "pm/lib-test/pm"; platform = "host"; }
]

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.roots.doctests`

The packages whose libraries ` cargo test ` doc-tests, in
place of those breakbulk predicts from the manifests: the
way around a bug in that prediction, which fails test
plans with “the plan has doctests of …”\. ` null ` keeps the
prediction\. Packages the test plan does not select are
left out, as predicted ones are\. Both delivery modes use
the list\.

*Type:*
null or (list of string)

*Default:*

```nix
null
```

*Example:*

```nix
[
  "mylib"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.roots.test`

The roots of this workspace’s test plans
(` cargo test --no-run `), in place of the roots breakbulk predicts
from the manifests: the way around a bug in that
prediction, which fails instantiation with “the plan has
roots that were not predicted”\. ` null ` keeps the
prediction\. Each entry is a root name as that error
lists them, ` <package>/<kind>/<target> `, with ` -test `
added to the kind of a test root other than a test
target (` app/bin-test/app `), or ` { name; platform; } `
for a root whose platform the prediction gets wrong
(“planned for the host platform, but was predicted for
the target platform”)\. ` platform ` is ` host ` for a
target Cargo builds for the build machine (a proc
macro’s unit tests), else ` target `; a bare name, or
` platform = null `, takes the platform predicted for the
root, or ` target ` when it is not predicted\. Both
delivery modes use the list, for every target and
variant\. A listed root that a plan lacks is a stub, as a
predicted one is\.

*Type:*
null or (list of (string matching the pattern (\[^/]+)/(lib|bin|cdylib|dylib|staticlib|example|test|bench|(lib|bin|cdylib|dylib|staticlib|example|bench)-test)/(\[^/]+) or (submodule)))

*Default:*

```nix
null
```

*Example:*

```nix
[
  "app/bin/app"
  "app/bin-test/app"
  { name = "pm/lib-test/pm"; platform = "host"; }
]

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.targets`

The triples this workspace is built for\. Each is planned on its
own (` --target <triple> `)\. Besides ` variantDefaults `, an entry takes
every option of ` targets.<triple> `: they are merged with the
repository-wide ` targets.<triple> ` for this workspace only, as
two definitions of the same options merge (lists concatenate,
attribute sets merge, and a single value such as ` preset ` or
` linker ` set in both places needs ` lib.mkForce ` on the one that
should win)\. The spec is evaluated with this workspace’s
toolchain, so presets pick tools for its rustc\. The default is
the native triple only\.

*Type:*
attribute set of module

*Default:*

```nix
{ ${pkgs.stdenv.hostPlatform.rust.rustcTarget} = { }; }
```

*Example:*

````nix
{
  wasm32-unknown-unknown = {
    variantDefaults.packages = [ "ui" ];
    # Any `targets.<triple>` option, for this workspace only.
    rustflags = [ "--cfg" "getrandom_backend=\"wasm_js\"" ];
  };
}

````

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.targets.<name>.variantDefaults`

Settings for every variant planned on this target: any option of
` variants.<v> `, for facts about the target (“msvc needs the
` windows ` feature”, “wasm has no default features”)\. They are a
layer under each variant’s own settings, and its
` variants.<v>.target.<triple> ` is over both: lists concatenate,
and a single value set in two of these places takes the higher
one’s, without ` lib.mkForce `, so the variant’s own value wins over
this one\. Priorities still count across them: ` lib.mkForce ` here
wins over a plain value in the variant, for a fact the variants
must not change
([layers and priorities](\.\./\.\./how-to/targets\.md\#layers-and-priorities))\.

Its ` features ` reach every variant as written\. A variant that
selects packages (` variants.<v>.packages `, such as the
package-scope runs of ` breakbulk.variants.featurePowerset `) is
planned with ` -p <pkg> --features … `, which Cargo rejects when no
selected package accepts a feature\. A function module that reads
the variant’s ` config.packages ` can give such variants only what
they accept, with ` breakbulk.lib.acceptsFeature `
([features and package selections](\.\./\.\./how-to/targets\.md\#features-and-package-selections))\.

*Type:*
module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  noDefaultFeatures = true;
  features = [ "web" ];
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain`

The toolchain this workspace is planned and built with\. Any
rustc/cargo pair works: nixpkgs, rust-overlay, fenix\. A single
package that provides both may be given for both\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Example:*

```nix
let tc = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
in { rustc = tc; cargo = tc; }

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.cargo`

cargo (with ` bin/cargo `)\.

*Type:*
package

*Default:*

```nix
pkgs.cargo
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.clippy`

clippy (with ` bin/clippy-driver `), for clippy variants
([` breakbulk.variants.clippy `](\.\./presets\.md\#clippy))\.
It must be built for the same rustc: planning compares
` clippy-driver <rustc> --print sysroot ` with rustc’s
sysroot and fails when they differ\. The default is
nixpkgs’ clippy with nixpkgs’ rustc, and ` rustc ` itself
otherwise, as a rustup-style toolchain with the clippy
component (rust-overlay’s default profile, fenix’s
` toolchain `) has ` bin/clippy-driver `\.

*Type:*
package

*Default:*

```nix
if rustc == pkgs.rustc then pkgs.clippy else rustc
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts`

Facts about this toolchain that breakbulk would
otherwise read from its attributes, its own tables or
the toolchain itself (` breakbulk.toolchainFacts.of `)\.
Set one only for a source-built, forked or patched
toolchain those misjudge; ` null ` keeps breakbulk’s own
answer\. Presets read the result as ` toolchain.facts `,
so one setting here serves every target\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Example:*

```nix
{ llvmMajor = 22; bundledLld = false; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.bundledLld`

Whether the toolchain ships its own lld
(` rust-lld `, and ` gcc-ld ` for the C driver), as
rust-lang’s builds do: where rustc then links
Linux targets with it, the presets link with
nixpkgs’ lld (the ` lld ` linker kind), and macOS
targets link with the toolchain’s ` rust-lld `\.
` null `: false for a rustc with ` llvmPackages `
(nixpkgs’, built with ` --disable-lld `), true
otherwise\.

*Type:*
null or boolean

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.capabilities`

What this toolchain can do, where breakbulk would
otherwise decide it from the rustc and cargo
versions (or, for a toolchain whose ` version `
attribute is missing or not a Rust release, such
as fenix’s, by asking them through
import-from-derivation)\. The planner and the
instantiator read nothing else\. Whether Cargo
allows unstable features is not one of them: the
planner asks the cargo it runs\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Example:*

```nix
{ remapPathScope = false; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.capabilities.remapPathScope`

rustc takes ` --remap-path-scope ` (default: rustc 1\.95 or later)\.
Without it, every unit remaps every path scope, so debug info names
no real source paths even where it is split off\.

*Type:*
null or boolean

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.capabilities.trimPaths`

Cargo has the ` trim-paths ` profile setting (default: Cargo 1\.101 or
later, nightly 1\.101 included)\. The planner then turns it on when the
project has not\.

*Type:*
null or boolean

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.llvmMajor`

The major release of the LLVM inside rustc: the
LLVM tools presets take from nixpkgs (lld,
clang, lld-link, llvm-ar) are of this release\.
` null `: nixpkgs’ rustc’s own ` llvmPackages `, else
breakbulk’s table of Rust releases
(` breakbulk.llvmVersions `), else ` rustc -vV `\.

*Type:*
null or signed integer

*Default:*

```nix
null
```

*Example:*

```nix
23
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.llvmPackages`

The nixpkgs LLVM package set those tools come from
(it also gives ` llvmMajor `)\. ` null `: nixpkgs’
rustc’s own, else ` pkgs.llvmPackages_<llvmMajor> `\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Example:*

```nix
pkgs.llvmPackages_23
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.facts.wasiSdkVersion`

The wasi-sdk release whose wasi-libc the
toolchain bundles for ` wasm32-wasip2 `: C code
compiles against its headers
(` presets.wasmComponent { withC = true; } `)\.
` null `: from breakbulk’s table of Rust releases
(lib/wasi-sdk\.nix)\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"33"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.rustc`

rustc (with ` bin/rustc ` and ` bin/rustdoc `)\.

*Type:*
package

*Default:*

```nix
pkgs.rustc
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.rustfmt`

rustfmt (with ` bin/rustfmt ` and ` bin/cargo-fmt `), for the
` fmt ` check\. Formatting differs between rustfmt releases,
and ` rustfmt.toml ` options can need a nightly one, so it
defaults to the workspace’s own toolchain as ` clippy ` does:
nixpkgs’ rustfmt with nixpkgs’ rustc, and ` rustc ` itself
otherwise (a rustup-style toolchain with the rustfmt
component has both programs)\.

*Type:*
package

*Default:*

```nix
if rustc == pkgs.rustc then pkgs.rustfmt else rustc
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variantDefaults`

Settings for every variant of this workspace: a module with
the options of [` variants.<v> `](\#workspacesnamevariants)\. They
are the lowest layer of each variant’s settings, under the
target’s
[` variantDefaults `](\#workspacesnametargetsnamevariantdefaults),
the variant’s own settings and its ` target.<triple> `: lists
concatenate, and a single value set in a higher layer wins
without ` lib.mkForce `
([layers and priorities](\.\./\.\./how-to/targets\.md\#layers-and-priorities))\.
A function module gets the variant’s settings as ` config `,
with every layer applied
(` { config, lib, ... }: { features = lib.optional (config.mode == "check") "strict"; } `)\.

*Type:*
module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  sourcePaths = "remap";
  docs.noDeps = false;
  checks.buildScriptPaths = false;
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants`

Plan parameters\. Each variant is a separate pair of plans (build
and test) per target; units that come out identical are shared\.
While ` defaultVariant ` is ` "default" `, a ` default ` variant
(` { } `) is always defined, merged with yours: adding
` variants.clippy ` keeps it, and ` variants.default.profile `
changes it\. For a feature matrix, import
` breakbulk.variants.featurePowerset { … } ` in
` workspaces.<ws>.imports `
([feature matrices](\.\./\.\./how-to/feature-matrix\.md))\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ default = { }; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.packages`

The packages this variant plans on a target, in every plan\.
` true `: the whole workspace (` --workspace `)\. A list, or the
exclude form: each traced with ` -p `; features then name the
selected packages’ own features, as with ` cargo build -p <pkg> --features <f> ` (` breakbulk.variants.featurePowerset `
makes such variants with ` scope = "package" `)\. ` false `:
nothing, no plan is traced\. For every variant on one target,
set it in the target’s ` variantDefaults `
(` workspaces.<ws>.targets.<triple>.variantDefaults.packages `)\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean, list of package names, or { exclude = \[ … ]; }

*Default:*

```nix
true
```

*Example:*

```nix
[
  "my-lib"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.allFeatures`

Pass ` --all-features `\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.benches`

The bench plan, ` cargo bench --no-run ` with this variant’s
settings (use ` profile = "bench" `): bench binaries, and lib
and bin harnesses in bench mode, at
` target.<triple>.variants.<v>.benches.<pkg>.<binary> `\. ` false `:
none, the plan is not traced\. ` true `: those of the ` packages `
selection\. A list of packages, or the exclude form: ` cargo bench -p <pkg> … ` for those only\. Build variants
only\. The test plan
builds no benches (` cargo test --no-run ` does not)\. Each
bench binary also runs once, with ` --test `, as a check of the
variant, under the package’s
[` bench `](packages\.md\#packagesnamebench) run settings\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean, list of package names, or { exclude = \[ … ]; }

*Default:*

```nix
false
```

*Example:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.cargoConfig`

Cargo configuration for this variant’s plans, as the content
of a config file: what ` --config ` or ` CARGO_* ` variables set
for one CI job\. It is written to one TOML file that the
planner passes to Cargo as ` --config <file> `, over the
project’s own ` .cargo/config.toml ` files: a value replaces
theirs, and an array (` build.rustflags `) is appended to
theirs\. breakbulk’s own reader of the project’s config
(` build.rustflags `, ` target.<triple>.rustflags `, ` [env] `)
reads it last, the same way\. It applies to every plan of the
variant, so a ` profile.<name> ` table reaches only the plans
of that profile (` profile `, ` testProfile `)\. The dev shell does
not apply it\.

Keys that breakbulk sets itself are an evaluation error:
` build.rustc `, ` build.rustdoc `, ` build.rustc-wrapper `,
` build.rustc-workspace-wrapper `, ` build.target-dir `,
` build.build-dir `, ` build.target `, ` build.profile `,
` target.<key>.linker `, ` target.<key>.runner `, ` host.linker `,
` host.runner ` and ` source `\.

When the project can be edited, a named profile in its
` Cargo.toml ` (` [profile.dist] ` with ` inherits = "release" `,
and ` profile = "dist" ` here) does the same for profile
settings, and local Cargo sees it too\.

*Type:*
attribute set of (Cargo config value)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  profile.release = {
    panic = "abort";
    strip = "debuginfo";
  };
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.benches`

Put this build variant’s enabled bench runs
(` <pkg>/bench/<binary> `, each bench binary of
[` benches `](\#workspacesnamevariantsnamebenches) once in test
mode, ` bench.enable `) in ` repo.checks `, on a target that can
run tests\. Timed runs never happen inside Nix\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.buildScriptPaths`

Put the ` buildScriptPaths ` check of each plan whose outputs
are in ` repo.checks ` there too
([missing build-script paths](\.\./\.\./explanation/configuration\.md\#missing-build-script-paths)):
of a build variant, the build plan’s with
` products ` (` buildScriptPaths/build `) and the test plan’s
with ` tests ` (` buildScriptPaths/test `), on any target; of a
check variant, those of the plans its ` check `
builds\. For the whole workspace, set it in
[` variantDefaults `](\#workspacesnamevariantdefaults); for one
target, in that target’s ` variantDefaults `\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.check`

Put this check variant’s ` check ` (every unit of
its plans) in ` repo.checks `, as
` <ws>/<triple>/variant-<v>/check `\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.docs`

Put this variant’s documentation
(` target.<triple>.variants.<v>.docs `) in ` repo.checks `, as
` <ws>/<triple>/docs ` for the default variant and
` <ws>/<triple>/variant-<v>/docs ` for the others, in any
mode\. Off by default: any change to a documented crate runs
every rustdoc of the variant again\.

*Type:*
boolean

*Default:*

```nix
false
```

*Example:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.products`

Put this build variant’s products in
` repo.checks `, as ` <pkg>/build `, and their checks, as
` <pkg>/<check> `, under the variant’s prefix:
` <ws>/<triple>/ ` for the default variant,
` <ws>/<triple>/variant-<v>/ ` for the others\. A product
whose roots Cargo all skipped (required features) is left
out\. Variants made by ` breakbulk.variants.featurePowerset `
set this, ` tests ` and ` benches ` to ` false ` with
` lib.mkDefault `, so any plain definition, such as one in its
` variant `, overrides it\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks.tests`

Put this build variant’s enabled test runs
(` <pkg>/test/<binary> `, ` test.binaries.<key>.enable `) and
doctests (` <pkg>/doctest `, ` test.doctest.enable `) in
` repo.checks `, on a target that can run tests
(` canRunTests `)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.docs.noDeps`

Document only the planned packages, as ` cargo doc --no-deps `
does, in ` target.<triple>.variants.<v>.docs `\. ` false `: their dependencies
too, as ` cargo doc `; links to a dependency’s items then go to
its pages in the same folder\.

*Type:*
boolean

*Default:*

```nix
true
```

*Example:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.features`

Features to enable (` --features `), as Cargo spells them (` pkg/feat ` is allowed)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.mode`

Which Cargo command each plan of the variant traces\. ` build `:
products and test binaries (` cargo build `, ` cargo test `)\.
` check `: ` cargo check `, and for the test plan ` cargo check --tests --examples ` (what ` cargo test ` builds), metadata
only, no products or test runs;
` target.<triple>.variants.<v>.check ` builds every unit and is in
` repo.checks ` (` checks.check `)\. A lint (clippy) or a coverage
build is a preset over the other variant options:
[` breakbulk.variants.clippy `](\.\./presets\.md\#clippy) and
[` breakbulk.variants.coverage `](\.\./presets\.md\#coverage)\.

*Type:*
one of “build”, “check”

*Default:*

```nix
"build"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.noDefaultFeatures`

Pass ` --no-default-features `\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.products`

Products (` packages.<pkg> `) and their checks, from the build
plan\. ` true `: one for every package ` packages ` selects\.
` false `: none, and the build plan is not traced: a target that
is only tested (the native target of crates that ship as wasm
and run their unit tests natively); a check variant’s ` check `
then covers the test plan only\. A list of
packages, or the exclude form: products for those only, from
the same build plan of ` packages `\. Test binaries, test runs,
doctests and benches do not depend on it\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean, list of package names, or { exclude = \[ … ]; }

*Default:*

```nix
true
```

*Example:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.profile`

The Cargo profile (` --profile `) of the build plan, and of the
bench plan\. A check variant’s test plan uses it too\.
Units are shared between variants whose profiles have the same
settings, whatever their names\.

*Type:*
string

*Default:*

```nix
"release"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.rustcWorkspaceWrapper`

As ` rustcWrapper `, for workspace members only, as Cargo’s
` build.rustc-workspace-wrapper ` (` RUSTC_WORKSPACE_WRAPPER `):
Cargo starts ` [<rustcWrapper>] <wrapper> <rustc> ARGS… ` for
members, so dependencies stay shared with a variant without
it\. Clippy’s is clippy-driver
([` breakbulk.variants.clippy `](\.\./presets\.md\#clippy) sets it);
` wrapperEnv ` and ` wrapperConfig ` say what it reads\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"${my-lints}/bin/my-lint-driver"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.rustcWrapper`

A program every rustc invocation of the variant goes through,
as Cargo’s ` build.rustc-wrapper ` (` RUSTC_WRAPPER `): Cargo
starts ` <wrapper> <rustc> ARGS… ` for every crate, dependencies,
build scripts and its own queries (` rustc -vV `) included\. Use
it for a rustc driver (a verifier, a model checker) that must
see every crate, and set what it reads from the environment
with ` cargoConfig.env ` (the queries too) or
` packages.<name>.env ` (that package’s units)\. A path to an
executable in the store; the units of every crate then depend
on it\. It applies in every mode, and to every plan but the doc
plan\. A unit’s derivation names the wrapper, so units are not
shared with a variant without it\.

The planner checks that ` <wrapper> <rustc> --print sysroot `
prints rustc’s sysroot: a rustc driver must be built for this
rustc, as a driver with its own sysroot makes the units name
that sysroot’s crates\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"${verus}/bin/verus-driver"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.rustflags`

Flags added to the rustc arguments of the variant’s target
units, after the target’s own (` targets.<triple>.rustflags `),
under the key the project’s rustflags use (as the target’s
are)\. Host units (build scripts, proc macros) do not get them,
so they stay shared with other variants\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "-C"
  "instrument-coverage"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.sideFiles`

Where a unit puts the files a wrapper (` rustcWrapper `,
` rustcWorkspaceWrapper `) writes into rustc’s output directory
beyond the outputs: each rule sends a file whose name ends in
` suffix ` ` into ` a place; the first matching rule wins, and a
file no rule keeps is discarded\. A string is a rule with
` into = "beside" `\. The debuginfo files rustc writes beside a
linked output (` .pdb `, ` .dwp `, ` .dwo `, ` .dSYM `) are breakbulk’s
own rules, into the ` debug ` output, ahead of these\.

` beside ` is for files that a dependent’s compile reads: the
file is beside the crate file both in the dependency’s output
and in a dependent’s dependency directory (` -L dependency= `),
where breakbulk links it next to the crate file’s link\. So a
driver finds it beside the path it gets a crate by, whether
it resolves symlinks or not (Verus reads ` <stem>.vir ` beside
each ` --extern `’s real path, and beside the path rustc loaded
each other crate from)\. The rules apply to the units a wrapper
runs on; the others are a plain variant’s\.

*Type:*
list of ((submodule) or string convertible to it)

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  ".vir"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.sideFiles.*.into`

` beside `: a file ` <stem><suffix> `, where ` <stem> ` is
an output file’s name without its extension, goes
into that file’s output beside it (into each, when
an ` .rlib ` and an ` .rmeta ` share the stem)\. Any other
value names a derivation output of the unit (` debug `
on units that have one); a unit without it discards
the file\.

*Type:*
string

*Default:*

```nix
"beside"
```

*Example:*

```nix
"debug"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.sideFiles.*.suffix`

The end of the file’s name\.

*Type:*
string

*Example:*

```nix
".vir"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.sourcePaths`

How source paths are kept out of what this variant builds\.
Every value but ` keep ` gives each product the
` noSourceReferences ` check\. A project that sets Cargo’s
` trim-paths ` itself gets Cargo’s remaps whatever the value\.
For every variant of the workspace, set it in
[` variantDefaults `](\#workspacesnamevariantdefaults)\.

 - ` auto `: breakbulk turns Cargo’s ` trim-paths ` on
   (` --config profile.<p>.trim-paths="all" `) when the toolchain
   has it (its ` trimPaths ` capability: Cargo 1\.101 and later)
   and the project declares no ` trim-paths ` in any profile of
   the workspace root’s ` Cargo.toml ` or of its
   ` .cargo/config.toml ` files (any profile, package override or
   value counts; the files are read, not merged as Cargo
   would)\. Units without Cargo’s trim-paths get breakbulk’s own
   remaps\.
 - ` cargo `: breakbulk always turns Cargo’s ` trim-paths ` on,
   replacing the project’s own setting\. Planning fails when the
   toolchain lacks the ` trimPaths ` capability\.
 - ` remap `: breakbulk never turns Cargo’s ` trim-paths ` on and
   hides paths with its own remaps (Rust ` --remap-path-prefix `,
   C ` -ffile-prefix-map `)\.
 - ` keep `: breakbulk neither turns Cargo’s ` trim-paths ` on nor
   adds remaps of its own, and products get no default
   ` noSourceReferences ` check; binaries then reference their
   sources’ store paths\.

Under Cargo’s trim-paths, breakbulk’s own C prefix maps use
Cargo’s names, as cc-rs does\.

*Type:*
one of “auto”, “cargo”, “remap”, “keep”

*Default:*

```nix
"auto"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.target`

This variant’s settings on one of its targets: any option of
the variant (` features `, ` noDefaultFeatures `, ` profile `,
` testProfile `, ` cargoConfig `, ` rustflags `, ` wrapperEnv `, ` packages `, ` tests `, ` benches `, ` checks.tests `, …)
except ` targets `\. They apply over the target’s
` variantDefaults `
(` workspaces.<ws>.targets.<triple>.variantDefaults `) and the
variant’s own settings: lists concatenate, and a single value
set here wins over theirs without ` lib.mkForce `, unless one of
theirs has a higher priority (` lib.mkForce `)
([layers and priorities](\.\./\.\./how-to/targets\.md\#layers-and-priorities))\.
Only targets the variant is planned for are allowed\.

*Type:*
attribute set of module

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  x86_64-pc-windows-msvc.features = [ "windows" ];
  wasm32-unknown-unknown = {
    noDefaultFeatures = lib.mkForce true;
    tests = false;
  };
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.targets`

The workspace’s targets (` workspaces.<ws>.targets `) this
variant is planned for\. ` null `: every target\. A target left
out has no ` target.<triple>.variants.<v> `, and nothing of the
variant in ` repo.checks `; when the default variant is left
out, the target’s ` packages `, ` tests ` and test runs are empty\.
Use it for gates that apply to one target only (clippy
natively, a ` cargo check ` gate for wasm)\.

*Type:*
null or (list of string)

*Default:*

```nix
null
```

*Example:*

```nix
[
  "x86_64-unknown-linux-gnu"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.testProfile`

The Cargo profile of a build variant’s test plan
(test binaries, test runs, doctests)\. The default, ` test `, is
what plain ` cargo test ` uses: Cargo’s ` test ` profile inherits
` dev ` (debug assertions on, no optimization), with the
project’s ` [profile.test] ` over it\. Set it to the variant’s
` profile ` (` "release" `) to build tests as the products are
built: the test plan then shares its dependency units with the
build plan, while with two profiles of different settings it
shares none\. Check variants ignore it: they trace one Cargo
command with ` profile `, as ` cargo check ` and ` cargo clippy ` do\.

*Type:*
string

*Default:*

```nix
"test"
```

*Example:*

```nix
"release"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.tests`

The test plan (` cargo test `; for a check variant, ` cargo check --tests --examples `): test binaries, test
runs, test apps and doctests\. ` true `: those of the ` packages `
selection\. ` false `: none, and the test plan is not traced: a
target that is only built (a wasm component whose tests run
natively, with ` targets.<triple>.variantDefaults.tests = false `), or on a check variant plain ` cargo check `
(libraries and binaries)\. A list of packages, or the exclude
form: the test plan is ` cargo test -p <pkg> … ` for those only\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean, list of package names, or { exclude = \[ … ]; }

*Default:*

```nix
true
```

*Example:*

```nix
{ exclude = [ "*-bench" ]; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.wrapperConfig`

The files the workspace wrapper (` rustcWorkspaceWrapper `) reads
besides the crate’s sources: clippy’s ` clippy.toml ` and the
workspace’s ` Cargo.toml `\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.wrapperConfig.dirVar`

The variable that gives the wrapper’s units their
member’s directory in that tree, where the wrapper
starts its own lookup\. Unset (` null `): no tree\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"CLIPPY_CONF_DIR"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.wrapperConfig.search`

The workspace wrapper’s config file names, looked for in
each member’s directory and its parents up to the
repository root\. With ` dirVar `, the files found make one
tree per member, outside the source views, so editing one
rebuilds only the units the wrapper runs on\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  ".clippy.toml"
  "clippy.toml"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.wrapperConfig.workingDirFiles`

Files the wrapper reads from the compile’s working
directory (the workspace root for a member), relative to
it, which every source view (predicted ones included)
then holds\. Clippy reads the workspace’s ` Cargo.toml `
there for its ` [lints] ` checks\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "Cargo.toml"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.wrapperEnv`

Variables for the workspace wrapper (` rustcWorkspaceWrapper `):
Cargo gets them, as ` cargo clippy ` gives clippy-driver
` CLIPPY_ARGS `, and only the compile units the wrapper runs on
keep them, so every other unit stays shared with a variant
without them\. A package’s ` env ` still replaces them for that
package’s units\.

*Type:*
attribute set of string

*Default:*

```nix
{ }
```

*Example:*

```nix
{ CLIPPY_ARGS = "-Dwarnings__CLIPPY_HACKERY__"; }

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)
