# Plan format

`plan.json` is a versioned, deterministic description of one (workspace, target, variant, plan kind): every unit, with arguments split into literals, references and splice points. It contains no store paths for sources, so it changes only when manifests, the lockfile, config or the toolchain change.

This abridged example shows one library compile and the build-script run
it depends on (`…` marks elided values):

```json
{
  "version": 1,
  "kind": "build",
  "cargo": "1.96.1",
  "rustc": "1.96.1 (…)",
  "host": "x86_64-unknown-linux-gnu",
  "target": "wasm32-unknown-unknown",
  "variant": { "profile": "release", "features": [], "mode": "build" },
  "skeletonRoot": "/build/skeleton",
  "trimPaths": false,
  "trimPathsDefault": false,
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
      "links": "ring_core_0_17_14_",
      "script": { "out": "c-…", "output": "bin" },
      "env": { "TARGET": "wasm32-unknown-unknown" },
      "metadataFrom": []
    }
  },
  "roots": [
    { "package": "…", "target": "app", "kind": "bin", "unit": "c-…", "test": false }
  ]
}
```

## Fields

- **Argument segments.** A string is a literal argument. An array is one argument made by concatenating literals and references. A reference object is `src`, `crateSrc` or `out`. A splice object expands at build time to zero or more arguments, wrapped as the sentinel table shows, in the order the script printed them:
  - `{ "splice": R, "kind": K }` for `rustc-cfg`, `rustc-check-cfg` and `rustc-link-lib`: run R's values of kind K.
  - `{ "splice": R, "kind": "rustc-link-search", "in": "out" }` or `"in": "other"`: run R's search paths inside its `out`, or all its other search paths.
  - `{ "splice": R, "kind": "rustc-link-arg", "kinds": [ … ] }`: run R's link arguments whose kind is in `kinds`, in printed order across kinds. A `rustc-link-arg-bin` entry carries its bin name (`"rustc-link-arg-bin=app"`). One splice per run covers every link-arg kind, because Cargo keeps one ordered list of link arguments per run; one splice per kind would reorder them.
  - `{ "searchPathsOf": [R, …] }` (only in `rustdoc --test`): the search paths of every listed run, deduplicated and sorted by value.
- **`envSplices`** add run R's `rustc-env` values to the unit's env.
- **`platform`** is `host` or `target`, observed from Cargo's output layout. Instantiation picks the matching toolchain spec and env capture, so host and target settings never mix.
- **`metadataFrom`** on a run lists upstream runs whose `DEP_<links>_*` metadata it receives, observed from sentinels.
- **`trimPaths`** and **`trimPathsDefault`** (omitted when false): see [trim-paths](../explanation/internals/planner.md#trim-paths).
- **`pathPackages`** (test plans only): each path package under the skeleton that the plan compiles, keyed by package id, as `cargo metadata` describes it. `targets` lists every Cargo target (`name`, `kind`, `crateTypes`, and `srcPath` relative to `skeletonRoot`), built or not. `dependencies` lists the edges to the other listed packages, each with its `kinds` (`{ "kind": null | "dev" | "build", "target": <cfg> | null }`). nextest test runs read them (see [Tests](../explanation/internals/products.md)).
- **`roots`** are the plan's products: bins, cdylibs and staticlibs in a build plan (plain `cargo build` never builds examples); test and example binaries in a test plan; bench binaries in the bench variant's plan. A set: the Rust type is an ordered set (like `features`, `metadataFrom` and an output's file names), so it is written sorted and without repeats by construction.

## Invariants

1. Keys and arrays are sorted, and the file is canonical JSON. Two traces of the same inputs produce byte-identical plans.
2. Every `out` reference and every splice names a unit in the same plan.
3. No literal contains the scratch directory, the skeleton, the vendor directory, `/build`, `$HOME` or a sentinel token. Validation fails the plan otherwise.
4. Every literal store path is a declared toolchain input or a store path from the evaluation-time source map.
