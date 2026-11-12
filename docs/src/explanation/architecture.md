# How a build works

Take a small workspace: a binary `app` that depends on `ring`, which has
a build script. `nix build` turns it into derivations in five steps.

```text
  your modules: presets, per-package settings, variants
        │
        │      1. Fetch         crates from Cargo.lock;
        │            │          a source view per package
        │            ▼
        ├─────▶ 2. Plan          trace real Cargo over a skeleton
        │            │          → plan.json
        │            ▼
        └─────▶ 3. Instantiate   plan.json → one .drv per unit
                     │
                     ▼
                4. Units         one derivation per Cargo unit
                     │
                     ▼
                5. Products      stages, test runs, checks
```

Planning (step 2) runs again only when `Cargo.toml`, `Cargo.lock` or Cargo
config change. After a source edit, Nix rebuilds only the units whose
inputs changed.

## 1. Fetch

breakbulk reads `Cargo.lock` and makes one fixed-output derivation per
registry crate, checked against the lockfile's hash. A crate is downloaded
only when a unit that needs it builds. Git dependencies are fetched during
evaluation, because finding a crate inside a repository needs its files.

Your own packages get a *source view*: a filtered copy of their directory,
at its place in the repository. Editing one package changes only that
package's source view.

## 2. Plan

breakbulk runs your Cargo, not a reimplementation of it. It runs
`cargo build` (and `cargo test` for tests and doctests) over a *skeleton* of
the workspace: the manifests, the lockfile and Cargo config, with empty
source files. A wrapper stands in for rustc:

- for each rustc call, it records the command line and environment, and
  writes empty outputs so that Cargo carries on;
- for each build script, it puts a stub in its place. Cargo runs the stub,
  which records the environment Cargo gave it and prints a marker for every
  kind of output a real build script can print.

Cargo then places each marker exactly where it would place real output:
on which rustc calls, in which position. That is how breakbulk knows,
without running `ring`'s build script, where its `cargo:rustc-link-lib`
lines will go. At build time the real values replace the markers.

The result is `plan.json`: every unit, with Cargo's exact command line,
and the edges between units. Tests compare these command lines with a
real `cargo build` on several Cargo releases.

Build and test plans are separate, because Cargo enables dev-dependency
features only when it builds tests. Units that come out the same in both
are shared.

Details: [The traced planner](internals/planner.md),
[Sentinel directives](../reference/sentinels.md),
[Plan format](../reference/plan-format.md).

## 3. Instantiate

`breakbulk-instantiate` turns the plan into one derivation per unit. It is
plain templating, so it is fast, and an unchanged unit always comes out
as the same derivation.

There are two ways to hand those derivations to Nix:

- **IFD mode** (the default on stable Nix): Nix builds the plan during
  evaluation and imports the result (import-from-derivation).
- **Dynamic-derivation mode** (Nix 2.36 and later): one derivation writes
  the unit derivations into the store as it builds.

Both give the same unit derivations. `mode = "auto"` picks dynamic mode
when the evaluator supports it.

Details: [Instantiation](internals/instantiation.md).

## 4. Units

A unit is one derivation for one rustc call or one build-script run. For
`app`:

| Unit | Outputs |
| --- | --- |
| compile `ring`'s build script | the script binary |
| run `ring`'s build script | `out` (its `OUT_DIR`), `flags` (what it printed) |
| compile `ring` | `rmeta`, `rlib` |
| compile `app` | the binary |

Units are input-addressed, so a binary cache serves them like any other
derivation. A library's `rmeta` and `rlib` are separate outputs: compiling
a dependent needs only `rmeta`, linking needs `rlib`.

Details: [The unit builder](../reference/unit-builder.md).

## 5. Products

The linked binaries pass through named post-link stages (split debug
information, strip, wasm-bindgen, …) to become the packages you build,
and test binaries become test runs. See [Products, stages and
tests](products.md).
