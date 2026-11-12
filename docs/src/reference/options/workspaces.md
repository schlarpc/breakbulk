<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Workspace options

`workspaces.<name>`: one Cargo workspace each.

## `workspaces`

The Cargo workspaces of the repository, by a name of your choice\.
Without any definition, a repository whose root has a ` Cargo.toml `
gets one workspace, ` default `, at the root, so ` mkRepository ` needs
no modules; declaring any workspace turns that default off\.

*Type:*
attribute set of (submodule)

*Default:*
` { default.path = "."; } ` when the repository root has a ` Cargo.toml `,
else ` { } `

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.benchSmoke`

Run each bench binary of ` target.<triple>.benches ` once in test
mode (` --test `) as a check (` <ws>/<triple>/<pkg>/bench-<name> `
in ` repo.checks `)\. Timed runs never happen inside Nix\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.cargoTrimPaths`

Who hides source paths in Rust code when Cargo has
` trim-paths ` (1\.101 and later: the toolchain’s ` trimPaths `
capability)\. ` null `: breakbulk turns it on
(` --config profile.<p>.trim-paths="all" `) unless the project
declares ` trim-paths ` in any profile of the workspace root’s
` Cargo.toml ` or of its ` .cargo/config.toml ` files (any profile,
package override or value counts; the files are read, not
merged as Cargo would), and leaves it to the project then\.
` true `: always on, replacing the project’s own setting (an
error without the capability)\. ` false `: never turned on by
breakbulk, which then hides paths with its own remaps; a
project that sets it itself still gets Cargo’s\. Under Cargo’s
trim-paths, breakbulk’s own C prefix maps use Cargo’s names, as
cc-rs does\. A variant’s own setting wins\.

*Type:*
null or boolean

*Default:*

```nix
null
```

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

 1. each package’s ` env `, ` forHost.env ` and ` forTarget.env `, for
    every package in ` Cargo.lock ` order;
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
` forTarget.env `\. Set ` devShell.env ` to change or remove any of
these variables\.

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

## `workspaces.<name>.docs.noDeps`

Document only workspace members (` cargo doc --no-deps `)\.

Not implemented yet ([\#6](https://github\.com/schlarpc/breakbulk/issues/6)): setting it only gives an evaluation warning\.

*Type:*
boolean

*Default:*

```nix
true
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

## `workspaces.<name>.memberDefaults`

Settings for every member of this workspace (the path packages
of its ` Cargo.lock `), with the options of
[` packages.<name> `](packages\.md)\. They are the lowest layer
under the package’s own ` packages.<name> ` settings: lists
concatenate, ` env ` attributes merge, and the package’s own value
wins for single values (` test.runner `)\. Dependencies from a
registry or git do not get them\.

*Type:*
submodule

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  test.env.RUST_LOG = "debug";
  test.runner = "nextest";
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
  workspaces.default.targets.x86_64-unknown-linux-gnu.tests =
    lib.filter (lib.hasPrefix "core-")
      (lib.attrNames config.workspaces.default.members);
}
```

The selection options also take ` { exclude = [ … ]; } `: every
member but those\.

*Type:*
attribute set of (submodule) *(read only)*

*Default:*
the workspace’s members, by name

*Example:*

```nix
{
  app = { name = "app"; path = "."; };
  core = { name = "core"; path = "crates/core"; };
}

```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.members.<name>.name`

The package’s name\.

*Type:*
string

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

## `workspaces.<name>.roots`

Replace the predicted root names\. The escape hatch for a bug in
breakbulk’s target auto-discovery\.

Not implemented yet ([\#46](https://github\.com/schlarpc/breakbulk/issues/46)): setting it only gives an evaluation warning\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.sourcePaths`

Whether source paths are hidden in what this workspace builds\.
` hide `: as ` cargoTrimPaths ` says, through
Cargo’s trim-paths or breakbulk’s own remaps, and every product
gets the ` noSourceReferences ` check\. ` keep `: breakbulk neither
turns Cargo’s trim-paths on nor adds remaps of its own (Rust or
C), and products get no default ` noSourceReferences ` check;
binaries then reference their sources’ store paths\. A project
that sets ` trim-paths ` itself still gets Cargo’s remaps\. A
variant’s own setting wins\.

*Type:*
one of “hide”, “keep”

*Default:*

```nix
"hide"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.targets`

The triples this workspace is built for\. Each is planned on its
own (` --target <triple> `)\. Besides ` packages `, an entry takes
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
    packages = [ "ui" ];
    # Any `targets.<triple>` option, for this workspace only.
    rustflags = [ "--cfg" "getrandom_backend=\"wasm_js\"" ];
  };
}

````

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.targets.<name>.packages`

The packages to plan for this target, each traced with ` -p `, in
the build and the test plan\. ` null ` traces ` --workspace `\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
null or (list of string) or (submodule)

*Default:*

```nix
null
```

*Example:*

```nix
{ exclude = [ "xtask" ]; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.targets.<name>.products`

Products on this target, the counterpart of ` tests `\. ` false `: none
(a target that is only tested, such as the native target of
crates that ship as wasm and run their unit tests natively): the
build plan is not traced, and the target has no ` packages.<pkg> `
and no product checks; test binaries, test runs, test apps,
doctests and benches are unchanged\. A list of packages: products
for those packages only\. ` true `: every package the variant plans\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean or (list of string) or (submodule)

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

## `workspaces.<name>.targets.<name>.tests`

Test binaries, test runs, test apps and doctests on this target\.
` false `: none (a target that is only built, such as a wasm
component whose tests run natively); the test plan is then not
traced, except for a check or clippy variant with ` allTargets `\. A
list of packages: the test plan is ` cargo test -p <pkg> … `
for those packages only, and only their tests are run\. ` true `: the
variant’s or target’s package selection\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
boolean or (list of string) or (submodule)

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

## `workspaces.<name>.targets.<name>.variantDefaults`

Settings for every variant planned on this target: any option of
` variants.<v> `, for facts about the target (“msvc needs the
` windows ` feature”, “wasm has no default features”)\. For each
variant on this target they merge over the variant’s own settings,
and its ` variants.<v>.target.<triple> ` merges over them, by module
rules: lists concatenate, and a single value set to different values
in two of these places needs ` lib.mkForce ` on the one that wins\.

Variants made by ` breakbulk.variants.packageFeaturePowerset ` keep
their own ` features `, ` noDefaultFeatures ` and ` allFeatures ` over
these: Cargo rejects a feature that no selected package has\.

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

## `workspaces.<name>.toolchain.capabilities`

What this toolchain can do, where breakbulk would otherwise
decide it from the rustc and cargo versions (or, for a
toolchain whose ` version ` attribute is missing or not a
Rust release, such as fenix’s, by asking them
through import-from-derivation)\. Set one only for a
forked or patched toolchain whose version says otherwise;
` null ` keeps breakbulk’s own answer\. The planner and the
instantiator read nothing else
(` breakbulk.toolchainFacts.of `)\.

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

## `workspaces.<name>.toolchain.capabilities.nightly`

Cargo allows unstable features (default: a ` -nightly ` or ` -dev `
Cargo release)\.

*Type:*
null or boolean

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.toolchain.capabilities.remapPathScope`

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

## `workspaces.<name>.toolchain.capabilities.trimPaths`

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

clippy (with ` bin/clippy-driver `), for ` clippy ` variants\.
It must be built for the same rustc: planning compares
` clippy-driver --rustc --print sysroot ` with rustc’s and
fails naming this option when they differ\. The default is
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

## `workspaces.<name>.variants`

Plan parameters\. Each variant is a separate pair of plans (build
and test) per target; units that come out identical are shared\.
While ` defaultVariant ` is ` "default" `, a ` default ` variant
(` { } `) is always defined, merged with yours: adding
` variants.clippy ` keeps it, and ` variants.default.profile `
changes it\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ default = { }; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.packages`

The packages this variant plans, each traced with ` -p `, in
place of the target’s ` packages ` (` workspaces.<ws>.targets.<triple>.packages `)\.
` null `: the target’s selection\. Features then name the
selected package’s own features, as with ` cargo build -p <pkg> --features <f> `; ` breakbulk.variants.packageFeaturePowerset `
makes such variants\.
` { exclude = [ … ]; } `: every member
([` members `](\#workspacesnamemembers)) but those, as ` --workspace --exclude <entry>… ` selects; each is traced with ` -p `\. An entry is a
package name, or a glob pattern as Cargo takes it (` * `, ` ? `, ` […] `,
` [!…] `)\. An entry that matches no member is an error (Cargo only
warns)\.

*Type:*
null or (list of string) or (submodule)

*Default:*

```nix
null
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

## `workspaces.<name>.variants.<name>.allTargets`

For ` check ` and ` clippy ` variants: also check every target,
as ` cargo check --all-targets ` does (tests, examples, benches
in test mode, through the test plan)\. ` false `: plain ` cargo check ` (libraries and bins, the build plan only), for gates
that do not check test code\. Only check and clippy variants
take ` false `\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.benches`

Also trace ` cargo bench --no-run ` with this variant’s settings
(use ` profile = "bench" `): bench binaries, and lib and bin
harnesses in bench mode, at
` target.<triple>.variants.<v>.benches.<pkg>.<bench> `\.
` target.<triple>.benches ` is the default variant’s when it has
benches, else the one variant with ` benches = true `\. The test
plan builds no benches (` cargo test --no-run ` does not)\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.cargoTrimPaths`

This variant’s ` workspaces.<ws>.cargoTrimPaths `\.

*Type:*
null or boolean

*Default:*

```nix
workspaces.<ws>.cargoTrimPaths
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.checks`

Put this build or coverage variant’s outputs in ` repo.checks `:
its products (` <pkg>/build `), their checks (` <pkg>/<check> `),
its enabled test runs (` <pkg>/test-<name> `) and doctests
(` <pkg>/doctest `)\. The default variant’s are under
` <ws>/<triple>/ `, any other variant’s under
` <ws>/<triple>/variant-<v>/ `\. A product whose roots Cargo all
skipped (required features) is left out\. Check and clippy
variants have no products or test runs; their ` check ` is in
` repo.checks ` regardless\.
Variants made by ` breakbulk.variants.featurePowerset ` and
` packageFeaturePowerset ` set this to ` false ` unless their
arguments set it\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.clippyArgs`

Clippy’s own arguments, as in ` cargo clippy -- ARGS `
(` CLIPPY_ARGS `), for a ` clippy ` variant\. They reach only the
units clippy-driver compiles (workspace members)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Example:*

```nix
[
  "-D"
  "warnings"
]
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

What the variant compiles\. ` build `: products and test binaries
(` cargo build `, ` cargo test `)\. ` check `: ` cargo check `
and ` cargo check --all-targets `, metadata only, no products or
test runs; ` target.<triple>.variants.<v>.check ` builds every
unit and is in ` repo.checks `\. ` clippy `: as ` check `, with
clippy-driver as ` RUSTC_WORKSPACE_WRAPPER ` (workspace members
only, so dependencies are shared with ` check `), and the
` clippy.toml ` files of each member’s directory and its parents
up to the repository root (` CLIPPY_CONF_DIR `)\. ` coverage `:
` build ` with ` -C instrument-coverage ` on target units\.
Use the same profile as the build variant to share host units;
Cargo’s own ` clippy ` uses the dev profile\.

*Type:*
one of “build”, “check”, “clippy”, “coverage”

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

## `workspaces.<name>.variants.<name>.profile`

The Cargo profile (` --profile `)\. Units are shared between
variants whose profiles have the same settings, whatever their
names\.

*Type:*
string

*Default:*

```nix
"release"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.sourcePaths`

This variant’s ` workspaces.<ws>.sourcePaths `\.

*Type:*
one of “hide”, “keep”

*Default:*

```nix
workspaces.<ws>.sourcePaths
```

*Declared by:*
 - [lib/modules/workspaces\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/workspaces.nix)

## `workspaces.<name>.variants.<name>.target`

This variant’s settings on one of its targets: any option of
the variant (` features `, ` noDefaultFeatures `, ` profile `,
` allTargets `, ` clippyArgs `, ` packages `, ` benches `, ` checks `, …)
except ` targets `\. They merge over the variant’s own settings
and the target’s ` variantDefaults `
(` workspaces.<ws>.targets.<triple>.variantDefaults `), in that
order, by module rules: lists concatenate, and a single
value set to different values in two of these places needs
` lib.mkForce ` on the one that wins\. Only targets the variant is planned for are allowed\.

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
    allTargets = false;
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
