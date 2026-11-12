# The configuration model

breakbulk's settings are NixOS-style modules. Here is one module that uses
most of the pieces this page describes:

```nix
{
  # (the workspace's toolchain must include the wasm target)
  workspaces.default.targets = {
    x86_64-unknown-linux-gnu = { };
    wasm32-unknown-unknown.packages = [ "ui" ];
  };
  targets.wasm32-unknown-unknown.preset = breakbulk.presets.wasmWeb;

  packages.openssl-sys.inputs = p: [ p.openssl ];
  packages.app.env.GIT_REV = self.rev or "dirty";  # self: inline in flake.nix
  packages.app.env.UI_DIST =
    repo.workspaces.default.target.wasm32-unknown-unknown.packages.ui;

  workspaces.default.variants.clippy.mode = "clippy";
}
```

Modules suit configuration because presets, your settings and per-target
exceptions all have to merge, and the module system already merges lists
and attribute sets, has `mkBefore`, `mkAfter` and `mkForce`, checks types
and generates the [options reference](../reference/options.md). The
unit graph itself is not in the module system: evaluating modules is fine
for settings, but too slow for thousands of units.

## Repository, workspaces, targets

| Level | What it is | Options |
| --- | --- | --- |
| Repository | the result of one `mkRepository` call | [repository-wide](../reference/options/repository.md) |
| Workspace | one Cargo workspace, with its own lockfile and toolchain | [`workspaces.<name>`](../reference/options/workspaces.md) |
| Target | a target triple a workspace builds for | [`workspaces.<name>.targets`](../reference/options/workspaces.md#workspacesnametargets), and [`targets.<triple>`](../reference/options/targets.md) for its toolchain |

A target's toolchain is set once for the repository (`targets.<triple>`)
and can be refined for one workspace. Each workspace resolves it with its
own compiler, so a preset picks tools that match that workspace's rustc.
A target can also build only some packages (`packages = [ "ui" ]` above).

A target can be only built or only tested. Crates that ship as wasm but
run their unit tests natively are one example:

```nix
workspaces.components.targets = {
  wasm32-unknown-unknown.tests = false;       # products, no test runs
  x86_64-unknown-linux-gnu.products = false;  # test runs, no products
};
```

[`tests = false`](../reference/options/workspaces.md#workspacesnametargetsnametests)
leaves out test binaries, runs, apps and doctests, and the test plan is
not traced.
[`products = false`](../reference/options/workspaces.md#workspacesnametargetsnameproducts)
leaves out products and their checks, and the build plan is not traced.
Either also takes a list of packages, or the members to leave out
(`{ exclude = [ … ]; }`, see [Build for another target](../how-to/targets.md#some-packages-only)).

### Sharing between workspaces

Units are shared between workspaces when Cargo gives them identical
commands:

- **Registry crates** are shared when version, features, profile,
  toolchain and resolved dependencies are the same.
- **Path crates** also depend on where they sit. Cargo names a crate
  inside the workspace root by its relative path and one outside it by its
  absolute path. So a path crate shared by several workspaces is one unit
  only when it lies **outside every workspace root that uses it**.
- **A workspace member** differs from the same crate used as a plain
  dependency elsewhere (Cargo sets `CARGO_PRIMARY_PACKAGE` for members).

When two units you expected to share differ, `repo.explainSharing` says
why. It compares the units' commands and environment, not Cargo's hashes,
because `-C metadata` leaves out rustflags.

## What comes from your project

The planner runs your Cargo over your project's `.cargo/config.toml`, so
every setting there applies as it does locally, including nightly-only
ones such as `resolver.feature-unification` when your toolchain is
nightly.

The planner does **not** see:

- `~/.cargo/config.toml`;
- `CARGO_*` variables in your shell;
- flags in aliases or scripts.

Move such settings into the project's config. The dev shell warns when it
sees `CARGO_*` variables or a `~/.cargo/config.toml` that Nix builds will
not.

## Toolchain presets

A preset sets a target's toolchain: linker, C compiler and archiver,
[`cflags`](../reference/options/targets.md#targetsnamecflags), bindgen
settings, SDKs, extra rustflags, environment and test runner. Every tool
must be a store path; any other path is an error naming the tool.

Presets are named for what you want (`linux`, `linuxStatic`,
`linuxPortable`, `windows`, `wasmWeb`, `wasmComponent`), and the triple
picks how. For example, `linuxStatic` uses musl for a `-musl` triple and
static glibc for a `-gnu` one. See [Presets](../reference/presets.md).

How a target's settings reach the build:

- **Rustflags** go to Cargo with `--config`, under the key your project
  already uses (`[build]` or `[target.<triple>]`). Cargo reads only one
  rustflags key, so flags under the other key would make it ignore
  yours.
- **Host and target settings stay apart per unit**, not per triple. A
  target's environment is added only to that target's units, never
  through Cargo's `[env]`, which reaches every process. This matters when
  host and target are the same triple (static glibc, `linuxPortable`),
  where `CC_<triple>` cannot tell them apart.
- **Linkers:** when host and target are the same triple, Cargo gives the
  target linker to build scripts too; breakbulk puts the host linker back
  in those units. Cargo passes `-C linker` to every unit, so changing the
  linker rebuilds everything.

Details: [The traced planner](internals/planner.md),
[Target traits and presets](internals/toolchains.md).

## Per-package overrides

[`packages.<name>`](../reference/options/packages.md) sets environment,
tools and libraries for one package's units, and nothing else:

| Option | For | Example |
| --- | --- | --- |
| [`env`](../reference/options/packages.md#packagesnameenv) | variables | a build stamp: `GIT_REV`, `SOURCE_DATE_EPOCH` |
| [`nativeInputs`](../reference/options/packages.md#packagesnamenativeinputs) | tools that run on the build machine | `pkg-config`, `cmake`, `protoc` |
| [`inputs`](../reference/options/packages.md#packagesnameinputs) | libraries for the platform being built | `openssl` |
| [`extraSources`](../reference/options/packages.md#packagesnameextrasources) | files outside the package directory | `../../wit` |

A setting can be narrowed to some versions of the package
([`version`](../reference/options/packages.md#packagesnameversion)), to
one side ([`forHost`](../reference/options/packages.md#packagesnameforhostenv)
or [`forTarget`](../reference/options/packages.md#packagesnamefortargetenv),
below), to one target triple
([`target.<triple>`](../reference/options/packages.md#packagesnametarget)),
or to the plans of one variant
([`variant.<v>`](../reference/options/packages.md#packagesnamevariant)).
`target.<triple>` and `variant.<v>` take every package option, `forHost`
and `forTarget` included, and `variant.<v>` also takes `target.<triple>`:

```nix
packages.castaway.forTarget.env.CASTAWAY_GIT_REV = rev;  # every triple, target side
packages.ffmpeg-sys-next.target.x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpeg;
packages.foo.target.x86_64-pc-windows-msvc.forHost.env.X = "1";  # one triple, host side
packages.bar.target.x86_64-pc-windows-msvc.env.Y = "1";  # one triple, both sides
packages.baz.variant.coverage.test.env.RUST_LOG = "debug";  # one variant
```

A setting for one variant changes only that variant's units. The other
variants' units stay the same, so they are not rebuilt.

### Host and target sides

A plan for a target has host units, which run on the build machine, and
target units. `forHost` settings reach only host units, `forTarget`
settings only target units, and the top-level `env`, `nativeInputs` and
`inputs` reach both. As in Cargo:

| Unit | Side |
| --- | --- |
| a build script's compile | host |
| a build script's run | the side of the package it builds for |
| proc macros and build dependencies (and their dependencies) | host |
| libs, bins, tests, examples and doctests of a package built for the target | target |

So a stamp in `packages.<name>.env` also reaches the build-script compile,
and every new value recompiles the build script. Put it in
`forTarget.env` to change only the run and the package's own units. A
package used on both sides (a crate that both a build script and your
binary depend on) has units on each, and each gets its side's settings.

### Shared settings and layer order

Settings that every member of a workspace shares go in
[`workspaces.<ws>.memberDefaults`](../reference/options/workspaces.md#workspacesnamememberdefaults).
It takes the same options as `packages.<name>`:

```nix
workspaces.main.memberDefaults = {
  test.env.RUST_LOG = "debug";
  test.path = [ pkgs.git ];
  test.runner = "nextest";
};
packages.legacy.test.runner = "libtest";  # the package's own value wins
```

Members are the workspace's path packages. A unit's package settings are
these layers, lowest first. Each is followed by its own
`target.<triple>`, `variant.<v>` and `variant.<v>.target.<triple>`, for
the unit's triple and variant:

| Layer | Applies to |
| --- | --- |
| [`sysDefaults.packages.<name>`](../reference/options/repository.md#sysdefaultspackages) | curated `-sys` crates, where a package set exists |
| `workspaces.<ws>.memberDefaults` | the workspace's path packages |
| `packages.<name>` | that package, in every workspace |

Lists concatenate, `env` merges, and a single value (`test.runner`) is
the highest layer's that sets one. Priorities still count across layers:
`lib.mkForce` in a lower layer wins over a plain value in a higher one.
Variant layers (`variantDefaults`, `variants.<v>.target.<triple>`)
follow the same rule ([layers and
priorities](../how-to/targets.md#layers-and-priorities)).

breakbulk ships settings for common `-sys` crates, from nixpkgs'
`defaultCrateOverrides` ([`sysDefaults.packages`](../reference/options/repository.md#sysdefaultspackages)),
as the lowest layer under `packages`. They apply only on platforms with a
nixpkgs package set. They declare tools and libraries only. Switches that make a crate use a
system library instead of its bundled copy
(`LIBSQLITE3_SYS_USE_PKG_CONFIG` and the like) change what gets built, so
they are left to you.

### How inputs become environment

nixpkgs does it: a small derivation per package and platform runs a real
`stdenv` with the inputs and records what its setup hooks set
(`PKG_CONFIG_PATH`, compiler wrapper flags, …). Packages without inputs
share one capture per platform, which gives build scripts the same tools
and hardening flags as `buildRustPackage`.

A `-sys` crate's `rustc-link-lib` takes effect where the final binary
links, in another package's unit. So every unit that links also gets the
library search paths (`NIX_LDFLAGS`, nothing else) of the packages it
links that have inputs. The binary gets a run-time path to each such
library, as it would find the library on a system where it is installed.

Details: [Environment capture](internals/env-capture.md).

## The dev shell

`repo.workspaces.<ws>.devShell` sets up local Cargo as the planner runs
it, for one target,
[`devShell.target`](../reference/options/workspaces.md#workspacesnamedevshelltarget).
The shell sets these variables, in this order. A later value replaces
an earlier one.

1. Each package's `env`, `forHost.env` and `forTarget.env`, for every
   package in `Cargo.lock` order, with its layers for the target and the
   default variant. Without them, code such as
   `include_bytes!(env!("X"))` does not compile in the shell.
2. The target's `env`.
3. The Cargo env config for the target: its linker and rustflags, and
   `CARGO_PROFILE_<P>_TRIM_PATHS` when the planner turns trim-paths on.
4. `CARGO_BUILD_TARGET`.

When two packages set a variable to different values, the shell keeps
the last one and gives a warning. The warning names each package, its
value and the value the shell uses. breakbulk does not rank packages.
To choose a value, set it in
[`devShell.env`](../reference/options/workspaces.md#workspacesnamedevshellenv).

`devShell.env` applies last, over all of the above. A value sets or
replaces a variable. `null` removes it:

```nix
packages.app.forTarget.env.APP_WEB_DIST = webDist;
workspaces.main.devShell.env = {
  APP_WEB_DIST = null;  # build.rs uses its dev fallback
  RUST_LOG = "debug";
};
```

When a variable names a derivation, the shell needs that derivation,
so opening the shell builds it. With `null`, the shell does not need it.
A project's `build.rs` that has a fallback for an unset variable then
runs that fallback.

Do not change the variables from items 3 and 4 unless you must. Then
local Cargo builds with other flags than Nix does.

## Source views

A package's source is the package's directory plus its `extraSources`,
at their original places in the repository. So relative paths like
`../../wit` or `../shared/assets` work unchanged, and editing a file
outside them changes nothing for the package.

For tests:

- the package's `tests/` directory is test-only: only its test units
  (integration tests and benches with or without the libtest harness, test
  harnesses, examples, doctests and test runs) see it, so a fixture edit
  there re-runs the package's tests and rebuilds nothing else.
  [`test.scopeTestsDir = false`](../reference/options/packages.md#packagesnametestscopetestsdir)
  turns that off for code that reads `tests/` at compile time;
- [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
  makes more paths test-only: a path outside the package is added to its
  tests' source, and a path inside it is removed from the source of its
  other units;
- [`test.runFiles`](../reference/options/packages.md#packagesnametestrunfiles)
  narrows a test run to the files its tests read, so editing any other
  file of the package does not re-run it.

When a unit fails and its output names a repository path that its source
view lacks, the message names the path and the option that adds it:
`extraSources` for a library, bin or build script, `test.sourceScope`
for a test, a doctest or a test run, and `test.scopeTestsDir` for a
test-only path that non-test code reads
([Missing paths](../reference/unit-builder.md#missing-paths)). So does a
build script that fails while it names a `rerun-if-changed` path that is
missing from its sandbox. A build script that succeeds without such a
path often skipped work without saying so. The run then warns, and every
product above it fails its
[`buildScriptPaths`](../reference/stage-helpers.md#buildscriptpaths)
check, which names each path, its package and the option to add it to.
The product itself still builds. A path a script declares but does not
need goes in the check's `allow`. A build script that probes for a file
(`Path::exists()`) and takes another path when it is absent gets no
message: it neither fails nor names the file. Such a file must be in
`extraSources` too.

Registry crates are under `repo.sources.<crate>`, for steps that need a
file from inside a dependency (a bundled SDK, JS glue shipped in a
crate).

Details: [Fetching and source views](internals/sources.md).

## Products as inputs

A package's `env`, `inputs` or `nativeInputs` can name the product of
another package: in another workspace, for another target, or in the
same plan. `UI_DIST` in the example above is a wasm build of a member of
the same workspace. Products are passed by reference, so only the unit
that embeds the product, and its dependents, wait for it. The rest of
the build starts at once.

This needs a package that reads the product from where you put it,
usually an environment variable. A build script that builds the other
package with Cargo itself is a different case:
[A build script runs Cargo](../how-to/nested-cargo.md).

A plan is instantiated from the names of these settings only: which
variables `env` sets, and whether `inputs` and `nativeInputs` are empty.
A value is read when the derivation of a unit that uses it is made. For
this reason, `lib.mkIf` goes around a whole `env` set or `inputs` list,
not around one value in it.

A plan takes the settings of the packages it can contain: its selected
packages and what they depend on in `Cargo.lock`. Another package's
settings do not reach it, so a product of the wasm target in the example
does not depend on `app`'s `env`.

In dynamic-derivation mode, one derivation makes the derivations of all
units of a plan, and it takes every setting it is given as an input. So
a product of the same plan, as in the third form, is an infinite
recursion there (#126). Products of another target or another workspace
work in both modes.

A product that needs itself, directly or through other products, is an
infinite recursion. Determinate Nix evaluates in parallel, and there such
an evaluation can hang with no output. Run it again with
`--option eval-cores 1` to see the error.

## Variants

A variant is another plan for the same workspace and target: a profile, a
feature set, or a check mode
([`variants.<name>`](../reference/options/workspaces.md#workspacesnamevariants)).
Units that come out the same are shared. What is shared follows from how
Cargo builds:

| Between | Shared | Not shared |
| --- | --- | --- |
| build and check or clippy | build scripts, proc macros and their dependencies | other dependencies, which Cargo compiles in check mode |
| check and clippy | all dependencies | workspace members |
| build and coverage | host units | target units, which carry the instrumentation flag |
| build and test plans, with `testProfile` set to the variant's `profile` | units whose features dev-dependencies do not change | units whose features they change |
| build and test plans, with the default `testProfile` (`test`) | nothing, unless the `test` profile has the build profile's settings | everything |
| profiles with the same settings (`release`, `bench`, a profile that only inherits `release`) | everything: a unit depends on a profile's settings, not its name | nothing |
| profiles with different settings | nothing | everything |

A build or coverage variant has two profiles. Its
[`profile`](../reference/options/workspaces.md#workspacesnamevariantsnameprofile)
(default `release`) builds the products.
Its [`testProfile`](../reference/options/workspaces.md#workspacesnamevariantsnametestprofile)
(default `test`) builds the test binaries and doctests, as plain
`cargo test` does. Cargo's `test` profile inherits `dev`: debug
assertions and overflow checks are on, nothing is optimized, and the
project's `[profile.test]` applies over it. So a test that needs debug
assertions passes, and a fat-LTO release profile does not slow down every
test link. To test what you ship, set `testProfile = "release"` (the
variant's `profile`): the test plan then shares its dependencies with the
build plan, and a cold build compiles each of them once instead of once
per profile. Both options can differ per target, as every variant option
can (below).

Check and clippy variants check every target, as
`cargo check --all-targets` does, unless
[`allTargets`](../reference/options/workspaces.md#workspacesnamevariantsnamealltargets)
is off (for a gate that runs plain `cargo check`). They trace one Cargo
command with one profile, `profile`, for both plans, and ignore
`testProfile`. Give them the same profile as your build variant to
share build scripts and proc macros; Cargo's own `clippy` uses the dev
profile.

Clippy units find `clippy.toml` as `cargo clippy` does: clippy-driver
gets `CLIPPY_CONF_DIR` pointing at the member's directory in a small tree
that holds only the `.clippy.toml` and `clippy.toml` files of that
directory and its parents. Clippy takes the nearest one. A `clippy.toml`
at the repository root, above the workspace, works with no setup.

| | `cargo clippy` | breakbulk |
| --- | --- | --- |
| Where the search starts | the member's directory | the same |
| Where it stops | `/` (so `~/clippy.toml` counts) | the repository root |
| What an edit rebuilds | | only the clippy units of members below the file |

A `CLIPPY_CONF_DIR` you set in a package's `env` replaces breakbulk's.
`rustfmt.toml` needs nothing: no unit reads it, and the
[`fmt` check](../reference/options/workspaces.md#workspacesnamefmtenable)
already sees the rustfmt config files above the workspace.

For feature matrices, `breakbulk.variants.featurePowerset` and
`packageFeaturePowerset` generate variants, as cargo-hack does.

A variant's settings can differ per target: a target's `variantDefaults`
applies to every variant on it, and `variants.<v>.target.<triple>` to one
variant. See [Different features per
target](../how-to/targets.md#different-features-per-target).

### Cargo configuration per variant

A release job often sets Cargo settings for itself, with `--config` or
`CARGO_PROFILE_*` variables. When you can edit the project, a named
profile is the better way: `[profile.dist]` with `inherits = "release"`
in `Cargo.toml`, and `variants.dist.profile = "dist"`. Local Cargo then
builds the same thing. When the project keeps such settings out of its
manifests, give the variant
[`cargoConfig`](../reference/options/workspaces.md#workspacesnamevariantsnamecargoconfig),
the content of a Cargo config file:

```nix
variants.dist.cargoConfig.profile.release = {
  panic = "abort";
  strip = "debuginfo";
};
```

breakbulk writes it to one TOML file, and the planner passes it to Cargo
as `--config <file>`. Cargo merges a `--config` file over the project's
`.cargo/config.toml` files: its value replaces theirs, its arrays (such as
`build.rustflags`) are appended to theirs, and tables merge. breakbulk's
own reader of the project's config reads the file last in the same way.
That reader decides where the target's rustflags go and which `[env]`
variables the units get, so it agrees with Cargo.

- Keys that breakbulk sets itself are an evaluation error: the
  toolchain, the wrapper, the target and build directories, `build.target`
  and `build.profile`, linkers and runners, and `source`. The option's
  text lists them, with what to set instead.
- The file applies to every plan of the variant, but a `profile.<name>`
  table changes only the plans of that profile. `profile.release` reaches
  the products and not the tests, which use `testProfile` (`test`); set
  `profile.test` for them. Cargo builds tests and build scripts with
  `panic = "unwind"` whatever the profile says.
- Relative paths in the file, and `[env]` values with `relative = true`,
  do not resolve against your project: Cargo resolves them against the
  directory above the file's, a store directory. Use absolute paths.
- The dev shell does not apply it.

Cargo's debug settings come before the target's
[`debugInfo`](../reference/options/targets.md#targetsnamedebuginfo):

- `profile.<p>.debug` decides how much debug information rustc writes.
  `debugInfo` decides what happens to it afterwards (a `debug` output,
  kept, or stripped) and which source paths in it are hidden.
- `profile.<p>.strip` makes the link itself remove it (`-C strip`).
  `splitDebug` then finds none and leaves the file as it is, and the
  `debug` output stays empty. Cargo does the same without being asked
  when no crate of a binary has debug information (`release` without
  `debug`): an unset `strip` becomes `debuginfo`.
- `profile.<p>.trim-paths` in `cargoConfig` is the project setting
  trim-paths itself: the planner does not turn it on, and Cargo's own
  remap scope applies to every output, debug information included. See
  [Cargo's trim-paths](products.md#cargos-trim-paths).
