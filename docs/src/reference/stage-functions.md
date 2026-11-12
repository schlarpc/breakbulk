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
| `lockfile` | stages and checks | The workspace's `Cargo.lock`, a path. `bindgen` reads the wasm-bindgen version from it. |
| `rootFiles` | stages and checks | Each root's file name in `linked`, mapped to its kind: `bin`, `staticlib`, `cdylib` or `dylib`. `install` lays the files out by kind. |
| `sourcesAllowedIn` | stages and checks | File name globs whose own references to sources `noSourceReferences` allows: each staticlib root's archive name in `linked`. |
| `buildScriptFlags` | stages and checks | The `flags` outputs of the build-script runs of the product's target that its roots depend on. Their `directives.json` names where the scripts placed files (`buildScriptFiles`). A list in IFD mode. In dynamic-derivation mode `{ rootInfo; }`: the roots' `breakbulk-root.json` files, which list the outputs at build time. |
| `linkedDebug` | stages and checks | The `debug` output of `linked`: the link units' debuginfo side files (`.pdb`, `.dwp`, `.dwo`). Only when `linked` has a `debug` output, which it always has in dynamic-derivation mode. |
| `debugSplit` | stages | Whether an earlier stage has a `debug` output. |
| `stageOrder` | checks | The stage names after `linked`, in order. |
| `checkName` | checks | The name the check runs under in `checks`. A failure message names it, since a check may run a helper under another name. |

A product made with `breakbulk.mkProduct` directly has
`name`, `sourcePaths` and `toolchainPaths` (empty unless given),
`linkedDebug`, `debugSplit`, `stageOrder` and `checkName` as above,
and the attributes of its `info` argument. `bindgen` also reads
`lockEntries` there, a lockfile's parsed entries
(`breakbulk.lockfile.read`), when there is no `lockfile`. Its stages get
the `target` its caller passes, `{ }` by default; the helpers then use
the traits of the platform `pkgs` builds for.
