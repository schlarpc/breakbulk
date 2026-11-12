# Instantiation

Instantiation turns `plan.json` into one derivation per unit. It is pure templating, shared by both delivery modes, so IFD mode and dynamic-derivation mode produce the same unit derivations. This page covers its inputs, the shape of each unit derivation, the two modes, and how root names are fixed before Cargo runs.

`breakbulk-instantiate` turns `plan.json` plus a source map into unit derivations. It does no compiling, fetching or source serialization. The same templating code serves both delivery modes, so both produce identical unit derivation paths.

## Inputs

- `plan.json`: the output of a plan derivation.
- `sources.json`: the names of workspace source views (keyed by directory relative to the repository root) and crate sources (keyed by package id).
- `toolchains.json`: the host and target specs, and the target's traits (`targetTraits`, see [Target traits](toolchains.md#target-traits)). Tool store paths are passed as plain strings, so that literal store paths in the plan (rustc in `program`) can be matched to a tool by prefix.
- `overrides.json`: per-package env and env-capture names, keyed `name@version` or `name`.

In IFD mode, nothing with string context reaches instantiation. `units.json` names every path it needs (`{"unit": id, "output": o}`, `{"input": key}`) and the Nix side fills in the values with their context. This has two consequences: the output must contain zero store references, because `builtins.fromJSON` refuses strings with context; and a source edit or an override change does not rerun instantiation at all, only a plan change or an added or removed input does. Dynamic-derivation mode runs the same instantiation, then does the Nix side's substitution itself (see [Dynamic-derivation mode](#dynamic-derivation-mode)). Unit tests check that both substitutions give identical text and inputs; `nix run .#test-dynamic` checks identical `.drv` paths on Nix master.
- The predicted root list.

Instantiation therefore realises nothing except the plan and the source views. Neither the toolchain, nor crate sources, nor embedded products are built before units are known.

## Derivation shape per unit

| Field | Value |
| --- | --- |
| `name` | `<crate>-<version>-<kind>`, for example `ring-0.17.14-lib` or `ring-0.17.14-build-run` |
| `builder` / `args` | `breakbulk-unit`, `["unit"]` |
| `env.BREAKBULK_UNIT` | Canonical JSON of the unit with every reference rendered |
| `outputs` | Library: `rmeta`, `rlib`. Bin or test: `out`. Build-script run: `out`, `flags`. Target-platform linking units (bins, tests, examples, cdylibs, dylibs, staticlibs) also `debug`, last, for their debuginfo side files, when the traced command makes rustc write them; so do target-platform libraries with an `rlib` output, for the per-object ones only (`.dwo` with `-C split-debuginfo=unpacked`, which rustc writes beside every object it compiles). One function decides both (`CompileUnit::has_debug_output`). Nix outputs are fixed before the build, so one function decides it from the argv and the target's traits (breakbulk-format `writes_debuginfo_side_files`, used by instantiation in both modes; the traits arrive as `toolchains.json`'s `targetTraits`, see [Target traits](toolchains.md#target-traits)): the unit gets one when any of the traits' `debugArtifacts` applies. An artifact with `when = "always"` (the `.pdb` of msvc and UEFI) applies to every crate the linker produces (`bin`, `cdylib`, `dylib`, `--test`), because rustc passes `/DEBUG` to the MSVC-style linker whatever `-C debuginfo` and `-C strip` say (rustc_codegen_ssa `back/linker.rs`, `MsvcLinker::debuginfo`); one with `when = "split-packed"` or `"split-unpacked"` (ELF's `.dwp` and `.dwo`) when the effective `-C split-debuginfo` is that value and debuginfo is on (the last `-C debuginfo` or `-g` wins, as in rustc's `select_debuginfo`). A target whose traits list none (wasm) never gets one. Input-addressed |
| `inputs` | `Built{drv, output}` for each referenced unit output, crate source, toolchain component and env capture; `Opaque` for each source view |
| `system` | The builder platform: the planner's system for compile units |

Referenced outputs are input-addressed or fixed-output, so their paths are known and rendered literally. The one exception is a product referenced through a package override in dynamic-derivation mode: products are resolved at build time there, so the reference is a placeholder and the referencing unit is resolved at build time too. So is every unit downstream of it, and each such reference is a placeholder as well ([spike B](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/B-delivery.md)).

## IFD mode

The instantiate derivation runs `breakbulk-instantiate --emit json` and writes `units.json`, mapping each unit to its complete derivation attributes, plus a map from root names to units. The Nix side imports it and applies `derivation` to each entry. Nix computes output paths. A unit's attribute names do not depend on its substituted values: `passAsFile` is always there, naming `BREAKBULK_UNIT` when that is long and empty otherwise. So selecting one unit's output does not evaluate the values of any unit, and a package's `env` can name a product of the same plan.

## Dynamic-derivation mode

One outer derivation per plan (`lib/dynamic.nix`) is content-addressed with text-hashed outputs and requires the system feature `builder-rpc-v0`, which Nix advertises automatically when `dynamic-derivations` is enabled (Nix master since 2026-07-21; first release 2.36). Nix's own error names the missing feature. It is named `<ws>-<triple>-<variant>` for the build plan and `<ws>-<triple>-<variant>-test` for the test plan, because submitted outputs must be named `<outer name>-<output>` and that name appears in store paths. It has one output per predicted root, `<package>.<kind>.<target>.drv` (the root name with `/` as `.`), one per predicted doctest in the test plan, `<package>.doctest.drv`, plus `units.drv` (below). The bench plan, when there is one, is `<ws>-<triple>-<variant>-bench`.

Its builder is `breakbulk-drv`, a separate binary with its own Cargo workspace and lockfile (`crates/breakbulk-drv/`, excluded from the main workspace), so that harmonia and tokio reach neither the main `Cargo.lock`, from which every breakbulk binary is built (a harmonia update must not change `breakbulk-unit` and so every unit), nor `breakbulk-instantiate`, which IFD mode builds before evaluation can continue. It uses `breakbulk-instantiate` as a library:

1. It runs the same instantiation as IFD mode over the same `sources.json`, `toolchains.json`, `overrides.json` and `roots.json`, giving the same `units.json` structure in memory.
2. It substitutes every reference as `lib/instantiate.nix` does, from `values.json`: every input key's value without context, plus its string context as `builtins.getContext` gives it. From those contexts and the unit references it computes each derivation's input derivations and input sources exactly as `derivation` would (a plain path becomes an input source, an output an input derivation; `drvPath` strings with "all outputs" context are rejected). Every unit gets `passAsFile` as in IFD mode: `BREAKBULK_UNIT` above the same length, empty below it.
3. It writes units, root stubs and wrappers in topological order with harmonia (pinned git commit) over the restricted daemon socket in `$NIX_REMOTE`, one connection for the whole build: output paths from harmonia's `hashDerivationModulo` (input `.drv` files it wrote are kept in memory, because the builder cannot read back what it added; the others are read from the store), the ATerm added as a text-hashed object whose references are its input sources and input derivations. `nix derivation add` cannot be used: paths added during the build are not visible inside its sandbox, and it reads its inputs. Every output variable must be present (as an empty string) before hashing. A derivation with a content-addressed or deferred input stays deferred, and its dependents reference its outputs by placeholder.
4. Each root gets a wrapper derivation named `<outer name>-<package>.<kind>.<target>`, submitted with `SubmitOutput` as that root's output.

   Its output is a directory: `root`, a symlink to the root unit's output (for a test binary Cargo did not build, to its stub's, which succeeds); `not-built`, the reason, for a root Cargo did not build (a product root then has no `root` and does not depend on its stub, which is not written); `debug`, the unit's debuginfo side files; and `breakbulk-root.json`, which says whether the plan has the root (or why not) and, for a test binary, what its test run and test app need from the plan (runtime `CARGO_*` env, the project's `[env]` variables Cargo set on it, the `flags` of its `rustc-env` runs, the `flags` of every run of its platform for the dynamic-library path, the package's directory, and nextest's synthesized metadata), with real paths that are all inputs of the wrapper.
5. Each predicted doctest gets the doctest derivation IFD mode makes, with the package's test configuration (`BREAKBULK_TEST_RUNNER`, `_ARGS`, `_ENV`, as `testRuns.doctestConfig` gives them; their values come in `values.json`, so changing them reruns the outer derivation), and a wrapper `<outer name>-<package>.doctest` linking its output as `root`, or with `not-built` when the plan has no doctest for the package. A doctest in the plan that was not predicted is an error. Doctests are predicted from the manifests as `cargo test` selects them: the lib target of each selected member with `doctest` on and a `lib`, `rlib` or `proc-macro` crate type.

The outer derivation's inputs are the plan, `breakbulk-drv`, the files above, and every `.drv` that a value's context names, as a plain path: the builder needs those `.drv` files to hash the units, but nothing is built before it runs except the plan. It prints one `breakbulk-drv: wrote <unit> <.drv path>` line per derivation; the dynamic-mode test compares them with IFD mode's.

On the evaluation side, each root is a small derivation that symlinks `builtins.outputOf <outer>."<output>".outPath "out"` + `/root`, and carries `breakbulkRoot` as in IFD mode, with `dynamic = true`, `unit = "<dynamic>"` and `wrapper` (the wrapper's output placeholder). Downstream code that needs only the root's output works unchanged.

What is not known at evaluation time in this mode, and what that changes:

- **Unit derivations** (`ws.units`) are not available; reading them is an error. Instead, the outer derivation has one more output, `units.drv`, a derivation that depends on every output of every unit of the plan (`ws.allUnits.<kind>`). Check and clippy variants, which have no roots, build their plans through it. `explainSharing` reads the units through IFD mode (`ifdUnits`: importing `units.json`, which builds `breakbulk-instantiate` and the plans): they are the same derivations, except downstream of an embedded product, where it describes IFD mode's.
- **Roots Cargo did not build** (required features) cannot be told apart from built ones at evaluation time. Their wrappers have `not-built`, checked at build time: building such a product root fails with the reason, as in IFD mode, and a product's `linked` stage leaves the root out (IFD mode leaves them out at evaluation time). `.unbuilt` is empty.

  When no root is left, `linked` holds only the no-binaries marker (`breakbulk-no-binaries`, listing the reasons), and every stage and check, guarded by the stage machinery, copies the marker to its outputs instead of running (see [Stage ordering](products.md#stage-ordering)).

  So `repo.checks` has the full product and its checks in dynamic mode too, and they succeed when Cargo built nothing; IFD mode leaves such a product out of `repo.checks`, where it is a stub that fails with the reasons. A skipped test binary's test run succeeds and writes the reason, as IFD mode's stub does.
- **Test runs** read what they need from the wrapper's `breakbulk-root.json` at build time (`dynamic.mkTestRuns`), with the same environment, working directory, runner and arguments as IFD mode. With `test.runner = "nextest"` they write nextest's metadata from the wrapper's (`TestSpec.nextest`, with the sysroot library directory filled in at build time). Both modes take a test binary's spec (runtime env, `[env]` values, runs, package directory, nextest's metadata) from one function, `test_spec` in `breakbulk-instantiate`. IFD mode reads it from `units.json`'s test roots (`testSpec`, references as parts, substituted by `lib/instantiate.nix` like unit attributes); `lib/test-runs.nix` adds only what the Nix side knows (the sysroot library directory, the target's dynamic-library variable) and does not read `plan.json`.
- **Doctests** are the outer derivation's (step 5); `doctests.<pkg>` links the wrapper's `root`, or, for a predicted doctest the plan lacks, logs why.
- **Test apps** read the wrapper's `breakbulk-root.json` when they run (`dynamic.mkTestApps`). The app script depends on the wrapper, so it is resolved at build time, and its program path is a placeholder at evaluation time; `nix run` with `ca-derivations` builds it and substitutes the real path (`resolveString` in Nix's `src/nix/app.cc`). Every predicted test binary has an app; one Cargo did not build fails with the reason.

The spike result is in [spikes/B-delivery.md](https://github.com/schlarpc/breakbulk/blob/spikes-archive/docs/spikes/B-delivery.md).
- `recursive-nix` is not used. It has an open removal proposal, and `builder-rpc-v0` replaces it for this purpose.

## Mode selection

`mode = "auto"` (the default) chooses dynamic-derivation mode when `builtins ? outputOf` (the builtin is only registered when the `dynamic-derivations` feature is enabled) and `builtins.compareVersions builtins.nixVersion "2.36pre" >= 0` (master reports `2.36.0pre…`, which compares below `"2.36"`). Otherwise it chooses IFD. Determinate Nix reports its upstream base version there, so the same check works for it.

`mode = "ifd"` and `mode = "dynamic"` override the choice; `mode = "dynamic"` on an evaluator without `builtins.outputOf` is an evaluation error. A daemon or builder older than the evaluator still fails with Nix's own error; the docs point to `mode = "ifd"`.

The daemon needs `dynamic-derivations` too: a daemon without it refuses to store the outer derivation ("text-hashed derivation output") even when the evaluator has it. mkRepository resolves the mode once and passes it to each workspace instance as `delivery`.

Unit derivations are identical in both modes. Products are not (resolved at build time in dynamic-derivation mode, input-addressed in IFD mode), so teams that mix Nix versions should pin the mode to share product cache entries.

## Root names are fixed at evaluation time

Nix attribute names, and a dynamic derivation's outputs, must be known at evaluation time, but the roots are discovered by the planner. The Nix library predicts them from the manifests with `builtins.fromTOML` and directory listings, implementing Cargo's documented target auto-discovery: `src/main.rs`, `src/bin/*.rs` and `src/bin/*/main.rs`, `examples`, `tests`, `benches`, the `auto*` switches, explicit target tables merged with discovered ones, custom `path =`, and `test`/`bench` flags.

`required-features` is ignored during prediction, because deciding it would need feature resolution. The prediction is a superset of what Cargo builds, computed separately for build and test plans. Instantiation fills each predicted root with:

- the real root, when the plan contains it;
- for a product the plan lacks, a stub derivation that fails with the reason ("`admin-cli` was not built by Cargo in variant `release`: required features `[cli]` not enabled");
- for a test run the plan lacks, a stub that succeeds and logs that the test was skipped, as `cargo test` does.

A root in the plan that was not predicted is an error listing both sets, because it means the discovery implementation has a bug. An explicit [`roots`](../../reference/options/workspaces.md#workspacesnameroots) option is the escape hatch. A single "all roots" output was rejected because building any one product would then build every product.
