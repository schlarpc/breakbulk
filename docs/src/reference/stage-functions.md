# Stage and check functions

A stage's `run` and a check's `run` are functions. Each takes one
attribute set and returns a derivation. The [stage helpers](stage-helpers.md)
are such functions. This page lists what a function gets and what it
must return.

## Stages

```nix
packages.app.stages.<name> = {
  after = "linked";
  run = { input, product, target, pkgs }: <derivation>;
};
```

| Argument | Value |
| --- | --- |
| `input` | The output of the stage before: `linked` (the root units' files under Cargo's names, as symlinks) or an earlier stage. A derivation whose output is a directory. Stages before `install` see the flat link output; stages after it see the installed layout. |
| `product` | What breakbulk knows about the product: the attribute set [below](#product). |
| `target` | The product's target: `{ triple; traits; }`, the target triple and its [traits](../explanation/internals/toolchains.md#target-traits), with the user's `targets.<triple>.traits` merged in. |
| `pkgs` | The repository's package set (`mkRepository`'s `pkgs`), which builds for the build machine. Take a stage's tools from it. |

The function returns a derivation, usually `pkgs.runCommand`. Its main
output is the next stage's `input`; the last stage's is the product.
The product's `debug` output is the `debug` output of the last stage
that has one.

breakbulk changes the derivation, through `overrideAttrs` or, for a bare
`derivation` call, its `drvAttrs`: its builder runs only when Cargo built
one of the product's binaries, and with [`ca`](options/repository.md#ca)
it is content-addressed. A stage that returns something else fails with
`ca`.

## Checks

```nix
packages.app.checks.<name> = {
  on = "linked";   # default: the product (the last stage)
  run = { input, product, pkgs }: <derivation>;
};
```

`input` is the output of the stage `on` names. `product` and `pkgs` are
as for a stage, with the check's attributes in `product` (below). A
check gets no `target`. The check passes when its derivation builds.

## `product`

`product` is a plain attribute set. A product of `mkRepository` has these
attributes:

| Attribute | Given to | Value |
| --- | --- | --- |
| `name` | stages and checks | The package's name in `Cargo.toml`, which is the product's name. |
| `sourcePaths` | stages and checks | The store paths of the workspace's source views and of every crate source. `noSourceReferences` fails when the product references one. |
| `toolchainPaths` | stages and checks | The Rust toolchain's store paths: rustc, its sysroot, cargo and components such as rust-src. |
| `package` | stages and checks | The package's `[package]` table from its `Cargo.toml`, as `builtins.fromTOML` reads it, with each field inherited from the workspace (`description.workspace = true`) replaced by the workspace's value. `componentize` and `wasmMetadata` take their metadata defaults from it. |
| `lockfile` | stages and checks | The workspace's `Cargo.lock`, a path. `bindgen` reads the wasm-bindgen version from it. |
| `rootFiles` | stages and checks | Each root's file name in `linked`, mapped to its kind: `bin`, `staticlib`, `cdylib` or `dylib`. `install` lays the files out by kind. |
| `sourcesAllowedIn` | stages and checks | File name globs whose own references to sources `noSourceReferences` allows: each staticlib root's archive name in `linked`. |
| `buildScriptFlags` | stages and checks | The `flags` outputs of the build-script runs of the product's target that its roots depend on ([below](#build-script-runs)). A list in IFD mode. In dynamic-derivation mode `{ rootInfo; }`: the roots' `breakbulk-root.json` files, which list the outputs at build time. |
| `linkedDebug` | stages and checks | The `debug` output of `linked`: the link units' debuginfo side files (`.pdb`, `.dwp`, `.dwo`). Only when `linked` has a `debug` output, which it always has in dynamic-derivation mode. |
| `debugSplit` | stages | Whether an earlier stage has a `debug` output. |
| `stageOrder` | checks | The stage names after `linked`, in order. |
| `checkName` | checks | The name the check runs under in `checks`. A failure message names it, since a check may run a helper under another name. |

A product made with `breakbulk.mkProduct` directly has
`name`, `sourcePaths` and `toolchainPaths` (empty unless given),
`linkedDebug`, `debugSplit`, `stageOrder` and `checkName` as above,
and the attributes of its `info` argument. `bindgen` also reads
`lockEntries` there, a lockfile's parsed entries
(`breakbulk.lockfile.read`), when there is no `lockfile`. Without
`info.package` the metadata helpers have no defaults. Its stages get
the `target` its caller passes, `{ }` by default; the helpers then use
the traits of the platform `pkgs` builds for.

## Build-script runs

A stage can read the build-script runs of the product's target that its
roots depend on, directly or through other packages:
`product.buildScriptFlags`. The runs of build scripts for the build
machine (those of proc macros and build dependencies) are not among
them.

Each run has two outputs. `out` holds the script's `OUT_DIR`, at a
nested path that copies Cargo's target directory. `flags` holds what
breakbulk read from the script's output:

| File | Contents |
| --- | --- |
| `metadata.json` | `package` and `version`: the package's name and version. `links`: its `links` name, only when it has one. `metadata`: the `[key, value]` pairs of its `cargo::metadata=key=value` lines, in printed order. `out`: the path of its `OUT_DIR`. |
| `directives.json` | Its other directives, and the copies of Cargo's `target/<profile>` that hold files the script placed next to the binaries (`targetDirs`; `buildScriptFiles` reads them). See [The `flags` output](unit-builder.md#the-flags-output). |

For wasmtime's C API crate, `metadata.json` reads:

```json
{"package":"wasmtime-c-api-impl","version":"50.0.1","links":"wasmtime-c-api",
 "metadata":[["include","/nix/store/…-wasmtime-c-api-impl-50.0.1-build-run/…/out/include"]],
 "out":"/nix/store/…-wasmtime-c-api-impl-50.0.1-build-run/…/out"}
```

`breakbulk.stageHelpers.buildScriptLookups` takes the stage arguments
and returns bash lines that define three shell functions. They read
the runs when the stage builds, so they work the same in both delivery
modes.

| Function | Prints |
| --- | --- |
| `buildScriptRuns` | Each run's `metadata.json` as one line of JSON, with `flags` added: the path of the run's `flags` output. |
| `buildScriptOutDir <package> [<version>]` | The `OUT_DIR` of the package's run. It fails when the roots depend on no run of the package, naming the packages that have runs. It fails when they depend on more than one version of it and no version is given, naming the versions. |
| `buildScriptMetadata <links> <key>` | The value of `key` in the metadata of the run whose package has that `links` name: what a dependent's build script sees as `DEP_<LINKS>_<KEY>`. When the script printed the key more than once, the last value counts. It fails naming the `links` names, or the run's keys, when there is no such run or key. |

Assign a result to a variable before you use it. Then a failing lookup
fails the stage, as with `set -e`. In `cp "$(buildScriptOutDir gen)/x" …`
the failure is lost.

```nix
packages.app.stages.headers = {
  after = "install";
  run = { input, pkgs, ... }@args:
    pkgs.runCommand "app-headers" { } ''
      set -euo pipefail
      ${breakbulk.stageHelpers.buildScriptLookups args}
      cp -RL ${input} $out
      chmod -R u+w $out
      include=$(buildScriptMetadata wasmtime-c-api include)
      cp -RL "$include" $out/include
    '';
};
```

The [`buildScriptPath`](stage-helpers.md#buildscriptpath) helper makes
this stage from its options. A product made with `breakbulk.mkProduct`
directly has the runs when its `info` has `buildScriptFlags`.
