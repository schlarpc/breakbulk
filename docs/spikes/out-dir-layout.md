# Research: build scripts that write outside `OUT_DIR` (#23)

Nov 8, 2026. Scratch work (fixtures, scripts, logs, downloaded crate sources) is
in `/tmp/claude-1000/-home-schlarpc-breakbulk/e8361374-8a4d-4aba-953c-b1b171a7ac1f/scratchpad/`
(`research-cargo/`, `research-repro/`, `research-plumbing/`). Each finding says
whether it was **run** or **read** from source.

## Question

Some build scripts find Cargo's target directory by walking up from `OUT_DIR`
and write there. In breakbulk a run's `OUT_DIR` is its own `$out`
(`/nix/store/<hash>-<pkg>-build-run`), so the walk ends in `/nix/store`, `/nix`
or `/`. Proposal under study: make `OUT_DIR` a subdirectory of `$out` that
copies the path the traced Cargo used, relative to its target directory, for
example `$out/x86_64-unknown-linux-gnu/debug/build/sdl2-sys-1a2b3c/out`. A walk
then ends inside `$out`. `OUT_DIR` is still a real store path, so nothing
printed or embedded needs rewriting.

## 1. Cargo's layouts (run)

A stand-in build script printed `OUT_DIR` and did both crates' walks, on Cargo
1.99.1, 1.100 beta and 1.101 nightly. Paths are relative to the target
directory; `<t>` is the triple, present with `--target`.

| Cargo | `OUT_DIR` | creates `<profile>/deps`, `examples` |
| --- | --- | --- |
| ≤ 1.99 | `[<t>/]<profile>/build/<pkg>-<hash>/out` | yes |
| ≥ 1.100 (new layout, default) | `[<t>/]<profile>/build/<pkg>/<hash>/out` | no |
| ≥ 1.100 with `__CARGO_TEMPORARY_BUILD_DIR_NEW_LAYOUT_OPT_OUT=1` | as ≤ 1.99 | yes |

The new layout's `run/` directory holds only the script's stdout, stderr and
`root-output`, not `OUT_DIR` (Cargo `custom_build.rs` uses
`out_dir_new_layout`). This matches `docs/implementation.md` ("Trace planner")
and `run_tag`. With a separate `build.build-dir`, the walks land in the build
directory, not next to the binaries, on every version.

## 2. The crates under real Cargo (run)

| Crate | 1.99.1 | 1.100 beta, 1.101 nightly | 1.101 with opt-out |
| --- | --- | --- | --- |
| sdl2-sys 0.37 `bundled` | builds; libraries copied to `debug/` and `debug/deps/` | **panics**: its walk finds `debug/`, but `debug/deps/` does not exist (`build.rs:440`, "Failed to copy SDL2 dynamic library … to …/debug/deps/…") | builds |
| ort-sys 2.0.0-rc.10 `copy-dylibs` (`ORT_LIB_LOCATION` = nixpkgs onnxruntime) | builds; symlinks in `debug/`, `debug/examples/`, `debug/deps/` | **panics**: `nth(3)` is `debug/build`, which has no `examples/` (`build.rs:129`, `NotFound`) | builds |

**Both crates fail under real Cargo from 1.100 on**, the default layout from
the next stable release. They are broken upstream in the same way under any
tool that uses the new layout. Both leave partial files behind when they
panic.

sdl2-sys `bundled` also needed `CMAKE_POLICY_VERSION_MINIMUM=3.5` (CMake 4)
and `CFLAGS=-std=gnu17` (GCC 16's C23 default breaks SDL 2.26) to build at
all, under Cargo and under breakbulk. Neither has to do with #23.

## 3. The crates under breakbulk today (run)

A run's `OUT_DIR` is its store path, so:

- **stand-in**: the name walk resolves to `/nix` and `nth(3)` to `/`; writing
  there panics with `PermissionDenied`.
- **sdl2-sys `bundled`**: "Failed to copy SDL2 dynamic library from
  …-sdl2-sys-0.37.0-build-run/lib64/libSDL2main.a to /nix/libSDL2main.a".
- **ort-sys `copy-dylibs`**: `build.rs:129:66` unwrap, `PermissionDenied`.

`lib/sys-defaults.nix` has no entry for either crate.

The panic is hard to find. For sdl2-sys, about 900 lines of CMake output follow
it. For ort-sys, breakbulk's own hints about unset `rerun-if-env-changed`
variables follow it (42 lines, with duplicates). Neither shows up in Nix's last
25 log lines, and no hint names the cause.

## 4. Other crates that walk up (read)

- **tauri-build 2.7.4**: `try_build` always resolves the target directory as
  the parent of the first ancestor named `build` (`lib.rs:295-300`, `:732`). It
  handles both Cargo layouts. Under breakbulk no ancestor is named `build`, so
  **every Tauri app's build script exits 1 today**. This was read, not run. With
  the proposal it would work, and the resources and external binaries it
  copies would stay inside `$out`. Tauri is the most-used crate here, which
  makes it the strongest reason for the proposal.
- **cxx-build 1.0.205**: looks for a target directory (an absolute
  `CARGO_TARGET_DIR`, or an ancestor with `.rustc_info.json`, `CACHEDIR.TAG`, or
  a `target` next to a `Cargo.toml`). If it finds none, it uses the scratch
  crate's `OUT_DIR`. Every write ignores errors or has a fallback. It works
  today and would not change unless `$out` held a `CACHEDIR.TAG`.
- **No walk up**: pyo3-build-config, napi-build, prost-build, cc, cmake,
  vergen.
- The libpath survey (decision 119) only checked crates that print search
  paths, so it missed tauri-build. Grepping its 345 build scripts again finds
  only sdl2-sys and ort-sys. Its data is only in `/tmp` (`cov-libpath/survey/`),
  not in the repository.

## 5. What the proposal changes in breakbulk (read)

- **The plan does not record Cargo's `OUT_DIR`.** `Rewriter::path`
  (`rewrite.rs`) turns paths under a run's `OUT_DIR` into a reference to the
  run's `out` and drops the relative part; `RunUnit` has no such field. The
  path cannot be rebuilt from the unit id (host runs under `--target` have no
  triple directory; profile directory names; layout). Adding it is small:
  `RunRec.out_dir` and `ctx.scratch` are both at hand, and `build_dir_name`
  already computes the relative path. It means a new `RunUnit` field (with a
  serde default or a format bump), carried through `RenderedRun` and the
  rewriter (`OutRef.file`).
- **Instantiation needs nothing new.** Both delivery modes, `lib/instantiate.nix`,
  `breakbulk-drv` and the second resolver in `lib/test-runs.nix` already append
  `OutRef.file`.
- **breakbulk-unit**:
  - `run_env`: `OUT_DIR = $out/<rel>`.
  - Create what the traced Cargo creates: in the old layout, `<profile>/deps`
    and `examples`.
  - `in_out_dir` must test `$out/<rel>` and `in_build_dir` the `$out` root.
    That is closer to Cargo, which compares against `OUT_DIR` and the target
    directory.
  - `metadata.json`'s `out` stays the root.
  - The remap of the run's output in C flags and `--remap-path-prefix`: map
    the `$out` root to Cargo's build directory, or keep today's names by
    mapping `$out/<rel>`. Under trim-paths, mapping the root to
    `/cargo/build-dir` is exactly Cargo's single pair. That would replace the
    per-run `buildDirRemap` and the per-compile pairs.
  - Tests that assume `OUT_DIR == $out` (`run/tests.rs`, breakbulk-format's
    tests, `tests/smoke.rs`) need updating, and so does the golden resolver
    (`golden.rs`, which ignores `file` for runs).
- **Detection**: after a run, anything under `$out` that is outside `OUT_DIR`
  and outside the pre-created directories was written outside `OUT_DIR`, and
  can be named in a warning.
- **Cost**: every unit rebuilds once (all run specs change, and so do the
  compiles that read `OUT_DIR` or `-L` into a run). Store paths in run outputs
  get about 64 characters longer. Files written outside `OUT_DIR` become part
  of the output, so a script that writes something non-reproducible there
  would show up in `--rebuild` checks.

## Conclusions

1. sdl2-sys `bundled` and ort-sys `copy-dylibs` fail under real Cargo from
   1.100 on. If breakbulk copies the traced Cargo's layout, it fails where
   Cargo fails and works where Cargo works (≤ 1.99, or with the opt-out),
   without encoding either crate.
2. tauri-build fails under breakbulk on every Cargo version today and would
   work with the proposal. Reproduce it before relying on this.
3. The change is mostly in breakbulk-unit and one new plan field.
   Instantiation and the Nix library are unaffected, and every unit rebuilds
   once.
4. A separate fix, needed either way: when a run fails, put the cause where
   the user sees it (the panic is buried under CMake output or breakbulk's
   hints), and remove duplicate unset-variable hints.
