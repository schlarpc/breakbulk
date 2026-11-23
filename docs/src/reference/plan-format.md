# Plan format

`plan.json` is a versioned, deterministic description of one (workspace, target, variant, plan kind): every unit, with arguments split into literals, references and splice points. It contains no store paths for sources, so it changes only when manifests, the lockfile, config or the toolchain change.

`version` changes only when an existing field changes meaning or is removed or renamed. An added field leaves it as it is, so a reader should ignore fields it does not know. `units.json`, which instantiation writes, follows the same rule for its own `version`.

This abridged example shows one library compile and the build-script run
it depends on (`…` marks elided values):

```json
{
  "version": 7,
  "kind": "build",
  "cargo": "1.96.1",
  "nightlyFeaturesAllowed": false,
  "rustc": "1.96.1 (…)",
  "host": "x86_64-unknown-linux-gnu",
  "dylibPath": { "var": "LD_LIBRARY_PATH", "sep": ":" },
  "target": {
    "arg": "wasm32-unknown-unknown",
    "shortName": "wasm32-unknown-unknown",
    "exeSuffix": ".wasm",
    "debuginfo": { "splitDefault": "off", "artifacts": [] }
  },
  "variant": { "profile": "release", "features": [], "mode": "build" },
  "skeletonRoot": "/build/skeleton",
  "remap": { "trimPaths": false },
  "packages": {
    "registry+https://github.com/rust-lang/crates.io-index#ring@0.17.14": {
      "targets": [
        { "name": "build-script-build", "kind": ["custom-build"], "crateTypes": ["bin"] },
        { "name": "ring", "kind": ["lib"], "crateTypes": ["lib"] }
      ],
      "rustVersion": "1.66.0",
      "links": "ring_core_0_17_14_"
    }
  },
  "units": {
    "c-8f3a1d2e9b0c4f17": {
      "kind": "compile",
      "package": "registry+https://github.com/rust-lang/crates.io-index#ring@0.17.14",
      "crate": { "name": "ring", "types": ["lib"], "edition": "2021" },
      "platform": "target",
      "program": ["/nix/store/…-rustc/bin/rustc"],
      "args": [
        "--crate-name",
        "ring",
        [{ "crateSrc": "…ring@0.17.14", "rel": "src/lib.rs" }],
        "--extern",
        ["cfg_if=", { "out": "c-…", "output": "rmeta", "file": "libcfg_if-….rmeta" }],
        { "splice": "r-ring-…", "kind": "rustc-cfg" },
        { "splice": "r-ring-…", "kind": "rustc-link-lib" },
        { "splice": "r-ring-…", "kind": "rustc-link-arg", "kinds": ["rustc-link-arg"] }
      ],
      "env": {
        "CARGO_PKG_NAME": "ring",
        "OUT_DIR": [{ "out": "r-ring-…", "output": "out" }]
      },
      "envSplices": [{ "splice": "r-ring-…", "kind": "rustc-env" }],
      "cwd": { "crateSrc": "…ring@0.17.14", "rel": "" },
      "outputs": {
        "rmeta": ["libring-….rmeta"],
        "rlib": ["libring-….rlib"]
      }
    },
    "r-ring-…": {
      "kind": "run",
      "package": "…ring@0.17.14",
      "platform": "target",
      "program": [[{ "out": "c-…", "output": "bin" }]],
      "env": { "TARGET": "wasm32-unknown-unknown" },
      "cwd": { "crateSrc": "…ring@0.17.14", "rel": "" }
    }
  },
  "roots": [
    { "package": "…", "target": "app", "kind": "bin", "unit": "c-…", "test": false }
  ]
}
```

## Units

Every unit has one shape, tagged by **`kind`**:

- `compile`: a rustc (or wrapper) invocation, keyed `c-<hash>` (Cargo's `-C metadata`), with `outputs`.
- `run`: a build-script run, keyed `r-<package>-<hash>` (from its `OUT_DIR`). Its `program` is the script: one `out` reference to its compile unit's `bin` output.
- `doctest` (test plans): a library's traced `rustdoc --test`, keyed `d-<package name>`, run by the doctest derivation, which compiles and runs the examples in one process.
- `doc` (doc plans): a traced `rustdoc` of one Cargo target from `cargo doc`, keyed `o-<package name>-<version>-<crate name>`, without its output directory (`-o`): the docs derivation runs every doc unit into one output. See [Documentation](../explanation/internals/products.md#documentation).

The fields every unit has: `package` (Cargo's package id), `platform`, `program`, `env` and `cwd`; and, where they apply, `crate` (`name`, `types`, `edition`; every kind but `run`), `args`, `envSplices` and `dylibPathFrom`. Fields that belong to some kinds only (below) are rejected on the others.

- **Argument segments.** A string is a literal argument. An array is one argument made by concatenating literals and references. A reference object is `src` (a path in the source view of a workspace package's unit), `crateSrc` (in a fetched crate), `out` (in a unit's output) or `empty` (`{ "empty": <rel> }`, a repository path in a registry or git crate's unit, inside one constant empty directory; see [Path rewriting](../explanation/internals/planner.md#path-rewriting)). A splice object expands at build time to zero or more arguments, wrapped as the sentinel table shows, in the order the script printed them:
  - `{ "splice": R, "kind": K }` for `rustc-cfg`, `rustc-check-cfg` and `rustc-link-lib`: run R's values of kind K.
  - `{ "splice": R, "kind": "rustc-link-search", "in": "out" }` or `"in": "other"`: run R's search paths inside its `out`, or all its other search paths.
  - `{ "splice": R, "kind": "rustc-link-arg", "kinds": [ … ] }`: run R's link arguments whose kind is in `kinds`, in printed order across kinds. A `rustc-link-arg-bin` entry carries its bin name (`"rustc-link-arg-bin=app"`). One splice per run covers every link-arg kind, because Cargo keeps one ordered list of link arguments per run; one splice per kind would reorder them.
  - `{ "runner": "test" }` (doctest units only, at most once): where the traced `--test-runtool R --test-runtool-arg A …` was (the planner's own runner); the doctest's builder puts the runner of the doctest's platform there, or nothing.
  - `{ "searchPathsOf": [R, …], "literals": [ … ] }` (doctest units only): the search paths of every listed run, and the `literals` (search paths of `links` overrides in config), deduplicated and sorted by value, as Cargo's `-L` list for `rustdoc --test`. The traced list names every run of the invocation; the doctest derivation keeps only the runs in the doctest's own closure, as for its `dylibPathFrom`.
- **`envSplices`** add run R's `rustc-env` values to the unit's env.
- **`platform`** is `host` or `target`, observed from Cargo's output layout (for a doc unit, from its output directory: a proc macro's docs are the host's). A doctest's is `host` when the command has no `--target` (a proc macro's doctest), else `target`. Instantiation picks the matching toolchain spec, env capture and, for doctests, runner, so host and target settings never mix.
- **`outputs`** (compile units) maps each output (`rmeta`, `rlib`, `bin`) to the files it holds. **`uplifted`** (compile units; omitted when empty) maps a file of `outputs` to the name rustc writes it under. A bin, or an example, that Cargo uplifts is stored under its uplifted name, the target name and the target's `exeSuffix` (`my-app`, from rustc's `my_app-<hash>`), so `CARGO_BIN_EXE_<name>` names a file with the name it has under Cargo. Test and bench executables keep rustc's names, as under Cargo.
- **`test`** (compile units; omitted when false) marks a test unit: a compile Cargo builds with the package's dev-dependencies, decided from its Cargo target: a `--test` compile, a test or bench target with or without the libtest harness, or an example. Test units see the package's test view ([Source views](../explanation/internals/sources.md#source-views)), are named `<pkg>-<version>-test[-<crate>]`, remap every path scope, and take their dependencies' `rlib`s.
- **`cargoTarget`** (compile units; omitted when the planner matched none) is the Cargo target the unit compiles, `{ "kind": …, "name": … }`, matched by crate name and source path. `kind` is `lib` (whatever its crate types), `bin`, `example`, `test`, `bench` or `custom-build`. Instantiation gives the unit the view of its own target when its package has one, else the package's view ([Source views](../explanation/internals/sources.md#source-views)). Build-script runs read the package's view, or their own predicted view.
- **`metadataFrom`** (runs) lists upstream runs whose `DEP_<links>_*` metadata it receives, observed from sentinels. **`outDir`** (runs; omitted when empty) is where `OUT_DIR` lies inside the run's `out`, relative to Cargo's target directory. **`buildDirRemap`** (runs, under trim-paths) names Cargo's build-directory remap of each `OUT_DIR` the run names.
- **`after`** (doc units; omitted when empty) lists the doc units this one runs after: those documenting the crates it reads (its `--extern`s), as Cargo runs a crate's rustdoc after its dependencies'. The docs derivation runs the doc units in that order, otherwise by crate name, then package, then id. A cycle is rejected.

## Header

- **`kind`** is the plan kind: `build`, `test`, `bench` or `doc`, and **`variant.mode`** the variant's mode, `build` or `check`. Both are labels: the traced Cargo command comes from the Nix library's table of plan commands (`lib/cargo-commands.nix`), and they decide which units are roots (a check plan, like a doc plan, has none).
- **`dylibPath`** is the planning machine's dynamic-library path variable and the separator of its entries, given to the planner by the Nix library (`--dylib-path-var`, `--dylib-path-sep`, from the build machine's target traits through `testRuns.dylibPathOf`): the variable the planner reads Cargo's dynamic-path entries from (`dylibPathFrom`), and the one units put them on, since every unit's process runs on that machine too. Required.
- **`nightlyFeaturesAllowed`** is Cargo's `nightly_features_allowed` for the planning toolchain: whether a build script's `rustc-env=RUSTC_BOOTSTRAP=…` is an error or a warning.
- **`target`** describes the planned target: `arg`, what Cargo was given as `--target` (a triple, or a `.json` spec's path); `shortName`, Cargo's short name (the triple, or the spec's file stem), which names the docs derivation; `exeSuffix` (omitted when empty), the spec's `exe-suffix`; and `debuginfo`, what the planning rustc's target spec says about the debuginfo side files the target's links write (`rustc --print target-spec-json`; see [Target facts from rustc](../explanation/internals/planner.md#target-facts-from-rustc)). `debuginfo.splitDefault` is the `-C split-debuginfo` rustc uses when a unit's arguments give none (`off`, `packed` or `unpacked`). `debuginfo.artifacts` lists the side files, each `{ "suffix", "when", "perObject"?, "directory"? }`: `when` is `always` (an MSVC-style link's `.pdb`), `split-packed` (`.dwp`, Apple's `.dSYM` directory) or `split-unpacked` (`.dwo`, one per object file, `perObject`). Instantiation decides from it which units get a `debug` output ([Instantiation](../explanation/internals/instantiation.md)). Required.
- **`remap`** says how source paths are remapped: `trimPaths` and `trimPathsDefault` (omitted when false; see [trim-paths](../explanation/internals/planner.md#trim-paths)), and `rustSrc` (omitted without the `rust-src` component), the remap `[<sysroot>/lib/rustlib/src/rust, /rustc/<commit-hash>]` breakbulk adds to its own remaps so that standard-library paths name no toolchain store path.
- **`configEnv`** (omitted when empty) lists the variables the project's `[env]` config table sets on Cargo's processes; test runs take their values from the test unit's recorded env.
- **`packages`** describes, by package id, each package that has a unit in the plan, as `cargo metadata` does. `targets` lists every Cargo target (`name`, `kind`, `crateTypes`, and for a path package under the skeleton `srcPath`, relative to `skeletonRoot`), built or not; build-script runs check `rustc-link-arg-*` directives against them. `rustVersion` and `links` are the manifest's. A path package under the skeleton also lists its `dependencies`: the edges to the other such packages from the resolve of `cargo metadata --all-features` that one of the plan's compile units uses (so not the optional dependencies the variant's features leave off), each with its `kinds` as the resolve gives them (`{ "kind": null | "dev" | "build", "target": <cfg> | null }`). Test runners that read the package graph (`testRunners.nextest`) get the path packages, by name, through the root wrapper (see [Tests](../explanation/internals/products.md)).
- **`roots`** are the plan's products: bins, cdylibs and staticlibs in a build plan (plain `cargo build` never builds examples); test and example binaries in a test plan; bench binaries in the bench variant's plan. A set: the Rust type is an ordered set (like `features`, `metadataFrom` and an output's file names), so it is written sorted and without repeats by construction.

## Invariants

1. Keys and arrays are sorted, and the file is canonical JSON. Two traces of the same inputs produce byte-identical plans.
2. Every `out` reference names an output of a compile unit or a run's `out`; every splice, `metadataFrom`, `dylibPathFrom` and `searchPathsOf` entry names a run; every `after` entry names another doc unit; every unit's package is in `packages`.
3. No literal contains the scratch directory, the skeleton, the vendor directory, `/build`, `$HOME` or a sentinel token. Validation fails the plan otherwise.
4. Every literal store path is a declared toolchain input or a store path from the evaluation-time source map.
