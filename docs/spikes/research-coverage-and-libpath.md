# Research: coverage crash with nixpkgs' Rust 1.99, and one library-path rule

Nov 7, 2026. Answers decision-log entries 73 and 84. Scratch work (scripts,
clones, the crate survey) is in
`/tmp/claude-1000/-home-schlarpc-breakbulk/cov-libpath/`.

## 1. Coverage builds crash with nixpkgs' Rust 1.99 (entry 73)

**Answer.** This is a nixpkgs bug, and nixpkgs has already fixed it. nixpkgs
builds rustc 1.99 against LLVM 21. But the coverage runtime that ships with
that rustc is built from the LLVM 23 sources inside Rust's source tarball.
LLVM 23 changed the layout of the per-function coverage record. So the
runtime reads the records that LLVM 21 wrote at the wrong offsets, and it
crashes at exit. The fix ("rustc: use llvmPackages_23", nixpkgs commit
`aa0cf492b8fb`, PR #578990 into staging, merged 2026-10-28) is on `master`.
It is not yet on `nixos-unstable` (`f9a75f41be3a`, 2026-11-05), and it is not
in breakbulk's pinned nixpkgs (`1d060086d60c`). Confidence: high. The cause
was checked in the source, by the binary's section sizes, and by a swap
experiment.

### Minimal reproducer

Any instrumented program with two or more instrumented functions shows the
crash. The crate does not need dependencies.

```rust
// src/main.rs, in a `cargo new` package
#[inline(never)]
fn two() -> u32 { 2 }
fn main() { println!("{}", two()); }
```

```console
$ RUSTFLAGS=-Cinstrument-coverage cargo build    # nixpkgs rustc 1.99.0 (LLVM 21.1.8)
$ ./target/debug/min
2
Segmentation fault (core dumped)                 # exit 139
```

The same steps with rust-overlay's 1.99.0 (`rustc -vV`: LLVM 23.1.1) exit
with 0. Plain hello-world (one function) does not crash. Its `.profraw` is
still wrong, though: the header says raw version 11, and LLVM 21's
`llvm-profdata` rejects the file ("raw profile version mismatch: Profile
uses raw profile format version = 11; expected version = 10").

Backtrace (gdb, the `variants` fixture built by plain Cargo):

```
#0  initializeValueProfRuntimeRecord ()
#1  writeOneValueProfData.constprop.0 ()
#2  lprofWriteDataImpl ()
#3  lprofWriteData ()
#4  writeFile ()
#5  __llvm_profile_write_file ()
#6  __run_exit_handlers () from libc.so.6
#7  exit () from libc.so.6
=> mov (%rax,%rcx,8),%rax      with rax = 0x1
```

### Root cause

- nixpkgs' `pkgs/development/compilers/rust/1_99.nix` (at `1d060086`) takes
  the default `llvmPackages`, which is LLVM 21. `rustc.nix` passes
  `--enable-profiler` for Linux targets. This is a plain boolean, not a path
  to a prebuilt runtime.
- Rust's bootstrap then builds `profiler_builtins` from the vendored
  `src/llvm-project/compiler-rt`. See `compiler_rt_for_profiler` and the
  `LLVM_PROFILER_RT_LIB` / `RUST_COMPILER_RT_FOR_PROFILER` branch in
  `src/bootstrap/src/core/build_steps/compile.rs`, and
  `library/profiler_builtins/build.rs` (rustc 1.99.0 source tarball). The
  vendored LLVM is 23.1.1 (`src/llvm-project/cmake/Modules/LLVMVersion.cmake`).
  nixpkgs' `rm -rf src/llvm` does not remove `src/llvm-project`.
- The two `compiler-rt/include/profile/InstrProfData.inc` files differ:
  - LLVM 21.1.8 (and 22.1.8): `INSTR_PROF_RAW_VERSION 10`. The fields of
    `__llvm_profile_data` are NameRef, FuncHash, CounterPtr, BitmapPtr,
    FunctionPointer, Values, NumCounters, NumValueSites[3] and
    NumBitmapBytes. That is 64 bytes per record.
  - LLVM 23.1.1: `INSTR_PROF_RAW_VERSION 11`. It adds `UniformCounterPtr`
    after CounterPtr and `OffloadDeviceWaveSize` after NumValueSites. That is
    72 bytes per record.
- The binary agrees with this. `__llvm_prf_data` is 0x40 bytes for one
  function and 0xc0 bytes for three (64 bytes each, LLVM 21 layout). The
  runtime counts records as `ceil(size / sizeof(__llvm_profile_data))`
  (`__llvm_profile_get_num_data`, `InstrProfilingBuffer.c`) with its own
  72-byte size. It then walks misaligned records and runs past the section.
  It reads a garbage `Values` pointer (the crash has `rax = 1`, which fits a
  `NumCounters` of 1 read as a pointer) and crashes in the value-profiling
  writer. With one record, the garbage fields happen to be zero, so the
  program does not crash, but the profile is still wrong.
- **Swap experiment.** The same nixpkgs rustc builds the same fixture with
  `RUSTC_BOOTSTRAP=1 -Zno-profiler-runtime` and links nixpkgs'
  `llvmPackages_21.compiler-rt` `libclang_rt.profile-x86_64.a` instead. The
  program exits with 0. LLVM 21's `llvm-profdata merge` and `llvm-cov report`
  read the profile and report correct coverage (`app/src/main.rs` 100%,
  `lib-a/src/lib.rs` 50%). So only the runtime is wrong.
- rust-overlay works because its rustc and its `profiler_builtins` both come
  from upstream's LLVM 23.1.1.

### Upstream status

- Already reported as part of NixOS/nixpkgs#576588 ("Build failure:
  cargo-llvm-cov", open). In a comment there, Mic92 names the same cause
  (rustc on LLVM 21, profiler runtime on LLVM 23) and points to the fix
  `aa0cf492b8fb`.
- The fix's own commit message cites a different symptom of the same LLVM
  mismatch: an intrinsic signature error in cargo-binstall.
- The fix makes the versions match again for this release. It does not stop
  the problem from coming back: the next time nixpkgs' LLVM for rustc falls
  behind Rust's vendored LLVM across a profile-format change, coverage breaks
  the same way, without a build failure. The draft below proposes a
  structural guard. It has not been filed.

### Draft follow-up for nixpkgs (not filed)

> **rustc: build the profiler runtime from the same LLVM that rustc uses**
>
> `rustc.nix` passes `--enable-profiler`, so Rust's bootstrap compiles
> `profiler_builtins` from the `compiler-rt` sources vendored in the rustc
> tarball (`src/llvm-project`, Rust's own LLVM version). But rustc's codegen
> uses nixpkgs' `llvmPackages`. When the two LLVM versions disagree on the
> raw profile format, every `-Cinstrument-coverage` binary writes a broken
> profile, and with two or more functions it segfaults at exit in
> `initializeValueProfRuntimeRecord`. This happened with 1.99.0 on LLVM
> 21.1.8 against the vendored 23.1.1: LLVM 23 added `UniformCounterPtr` and
> `OffloadDeviceWaveSize` to `__llvm_profile_data` and bumped
> `INSTR_PROF_RAW_VERSION` from 10 to 11. #576588 hit it, and `aa0cf492b8fb`
> (LLVM 23) fixed it by aligning the versions.
>
> Two ways to keep this from coming back:
>
> 1. Point bootstrap at the matching prebuilt runtime:
>    `--set=target.<triple>.profiler=${llvmPackages.compiler-rt}/lib/linux/libclang_rt.profile-<arch>.a`.
>    Bootstrap supports a path here (`StringOrBool`, `Config::profiler_path`
>    → `LLVM_PROFILER_RT_LIB` → `profiler_builtins` links it
>    `static:+verbatim`). Then the runtime and codegen always share one LLVM.
> 2. Or add a `passthru.tests` entry that builds and runs a two-function
>    `-Cinstrument-coverage` program and checks its profile with the
>    matching `llvm-profdata`.
>
> Reproducer: `cargo new min`. Add a second `#[inline(never)]` function
> called from `main`. Build with `RUSTFLAGS=-Cinstrument-coverage`. Run.
> Segfault, exit 139.

Option 1 has not been tried on a full rustc build. Whether nixpkgs'
`compiler-rt` archive suits every target that nixpkgs builds with the
profiler (Darwin uses a different archive name) is not verified.

### What breakbulk should do

- When `flake.lock` moves to a nixpkgs that has `aa0cf492b8fb`, run the
  `variants-coverage` test with nixpkgs' rustc again, or with both
  toolchains. Until then, keep rust-overlay there as it is now.
- A breakbulk-side warning is possible but has little value now that the
  fix exists. A general check could be a tiny "coverage probe" derivation
  per toolchain: build the two-function program above with the variant's
  rustc, run it, and fail with a clear message if it crashes. It costs one
  cached derivation per toolchain. A version heuristic ("nixpkgs rustc
  whose LLVM major differs from upstream's for that release") would need a
  version table and would still miss cases. See the ASK in the final
  report.

## 2. One rule for "this library path is inside the build" (entry 84)

**Answer.** Cargo's rule is "lexically inside the artifact directory of the
relevant platform". It is not "inside an `OUT_DIR`" and not "inside the
build directory". A survey of 1207 popular crates found no build script that
points a `rustc-link-search` path into another script's `OUT_DIR` by any
route other than `DEP_*`. breakbulk now uses one rule in all four contexts:
own `out` or an upstream (`DEP_*`) run's `out`, decided once when the run's
output is parsed. This removes the separate test-run rule (commit
`bfa46f7`). Confidence: high for the Cargo rule (source and experiment);
medium-high for the survey (grep-based, method below).

### (a) Cargo's rule at 1.99

Source: rust-lang/cargo tag `0.100.0`, commit `5f94df4` (Cargo 1.99.0).

- `filter_dynamic_search_path(paths, root_output)` in `src/compiler/mod.rs`
  strips the `native=`-style kind and keeps a path when
  `dir.starts_with(root_output)`. This is `Path::starts_with`, so the check
  works on path components and does not normalize the path. A value such as
  `$OUT_DIR/../../../x` passes. Cargo's `master` has the same code.
- `root_output` is never the build directory. It is the **artifact
  directory** of a platform:
  - `Compilation::root_output[kind] = layout.artifact_dir().dest()` in
    `BuildRunner::compile` (`src/compiler/build_runner/mod.rs`).
  - `host_dest()` (`compilation_files.rs`) for compiles and runs.
  - That gives `target/<profile>` for the host, and
    `target/<triple>/<profile>` for a `--target` build.
- The four contexts:

  | Context | Paths considered | Compared against | Where |
  | --- | --- | --- | --- |
  | rustc compile | `library_paths` of `BuildScripts::plugins`: the `to_link` runs of the unit's `for_host` dependencies (proc macros, plugins) | host artifact directory | `add_plugin_deps`, called from `rustc()` in `mod.rs` |
  | build-script run | `plugins` of the run unit (its build dependencies' runs) | host artifact directory | `custom_build.rs`, `build_work`: `add_plugin_deps(.., host_target_root)` |
  | test process | `Compilation::native_dirs`: a `BTreeSet<PathBuf>` of the search paths of **every** run in the build, filled after the job queue finishes | `root_output[unit.kind]` | `Compilation::fill_env` (`compilation.rs`), non-rustc tools |
  | `rustdoc --test` | `native_dirs` | `root_output[Host]` (marked "TODO: handle doctest-xcompile") | `fill_env`, `ToolKind::Rustdoc` |

- Plugin sets are per platform. `plugins` come from `for_host` dependencies,
  so they are host runs. Every `OUT_DIR` of a platform lies under that
  platform's artifact directory in the default layout. So in practice the
  rule is "inside any run's `OUT_DIR` of the platform being compared, or
  anywhere else under that artifact directory".

**Experiment.** This used Cargo 1.99.0 and a scratch `CARGO_HOME`, on a
two-crate workspace. Package `a` (`links = "a"`) prints paths in its own
`$OUT_DIR/own`, in `$OUT_DIR/../../../profdir-sibling`, and in
`/opt/outside`, and passes `root=$OUT_DIR` as metadata. Package `app` uses
`a` as a dependency and as a build dependency, and its script prints
`$DEP_A_ROOT/via-dep`. The test, the doctest and `app`'s run print
`LD_LIBRARY_PATH`. Results (`dyl.sh`):

| Setup | Run of `app` gets | Test gets | Doctest gets |
| --- | --- | --- | --- |
| default | host `a`'s `own`, `profdir-sibling` (after Cargo's own entries) | `own`, `via-dep`, `profdir-sibling` | `own`, `via-dep`, `profdir-sibling` |
| `--target x86_64-unknown-linux-gnu` | host `a`'s `own`, `profdir-sibling` | the **target** runs' `own`, `via-dep`, `profdir-sibling` | the **host** run's `own`, `profdir-sibling` |
| `build.build-dir` outside `target/` | **none** | **none** | **none** |

`/opt/outside` never appears. These match the table above. They also match
breakbulk's sentinel table, rows "Dynamic-library path of …".

**A Cargo quirk found along the way.** With `build.build-dir` set (stable
since 1.91), `OUT_DIR`s live under the build directory. The filter still
compares against the artifact directory. So Cargo silently drops every
build-script library path from `LD_LIBRARY_PATH` for compiles, runs, tests
and doctests. This is not breakbulk's concern, because the planner uses a
scratch `CARGO_HOME` and the default layout. It does show that Cargo's
"inside the target directory" is a heuristic (rust-lang/cargo#3366), not a
contract. No existing Cargo issue was found (searched "build-dir dynamic
library path", "build-dir LD_LIBRARY_PATH", "filter_dynamic_search_path";
#17183 is a different build-dir `LD_LIBRARY_PATH` problem). Draft, not
filed:

> **Build-script `rustc-link-search` paths are dropped from the dynamic
> library path when `build.build-dir` is outside the target directory**
>
> `filter_dynamic_search_path` keeps a build script's `-L` path only if it
> starts with `Compilation::root_output`, which is the artifact directory
> (`target/debug`). With `build.build-dir` set elsewhere, every `OUT_DIR` is
> under the build directory, so no path passes. Tests, doctests, build
> scripts and proc-macro compiles that dlopen a library built by a `-sys`
> crate then fail with `build-dir` set and pass without it. Reproducer: a
> build script printing `cargo::rustc-link-search=native=$OUT_DIR/lib`, an
> integration test printing `LD_LIBRARY_PATH`, and
> `CARGO_BUILD_BUILD_DIR=/tmp/bd cargo test`. The path is present without
> `build-dir` and missing with it (Cargo 1.99.0; same code on master).
> Comparing against the build directory's root as well would fix it.

### (b) Survey of real crates

**Method.**

- Crates: the top 1000 crates on crates.io by all-time downloads, plus the
  top crates named `*-sys` (214 in total) and `*-src`. That is 1207 crates.
  Each is the newest stable version from `static.crates.io` (`survey/fetch.py`).
- 305 have a build script. 94 of those emit `rustc-link-search` or
  `rustc-flags`.
- A build script can learn another script's `OUT_DIR` only in these ways:
  1. `DEP_*` metadata;
  2. walking up from its own `OUT_DIR` or using `CARGO_TARGET_DIR`;
  3. a compile-time constant (`env!("OUT_DIR")`) in a build-dependency
     library;
  4. a user-set environment variable.
- The survey grepped all 94 scripts for (1) and (2). It read every hit
  (`DEP_`, `.parent()`, `ancestors()`, `../..`, `CARGO_TARGET_DIR`) in
  context.
- For (3), it downloaded the whole source of every non-trivial build
  dependency of the 94 crates that could return a path:
  - `*-src`: boringssl, sqlcipher, lua, luajit, luau0, openssl, z3;
  - `openblas-build`, `openvino-finder`, `cuda-config`, `cmk`,
    `webrtc-sys-build`, `pyo3-build-config`, `build-env`, `cxx-build`.
- It then grepped them for compile-time `OUT_DIR` use. (4) is outside
  Cargo's control and lands outside the target directory anyway.

**Findings.**

- Every `rustc-link-search` path is one of these:
  - inside the script's own `OUT_DIR`. This includes `cmake`, `cc` and
    autotools builds, and the `*-src` crates, which build into the
    *caller's* `OUT_DIR` (`Build::out_dir` defaults to the caller's
    `OUT_DIR`);
  - inside an upstream `OUT_DIR` through `DEP_*`. Examples: `rdkafka-sys`
    (`$DEP_LIBRDKAFKA_STATIC_ROOT/src`) and `grpcio-sys`
    (`$DEP_Z_ROOT/build`, `$DEP_Z_ROOT/lib`). Others read `DEP_*`
    include or root paths for headers;
  - outside the build entirely: `pkg-config`, `vcpkg`, `llvm-config`,
    `*_DIR` environment variables, system directories.
- None of the helper crates bakes its own `OUT_DIR` into a constant.
  `cxx-build` walks up to the target directory only to share headers
  (`target/cxxbridge`), not library paths.
- Two crates write files outside their `OUT_DIR`. `sdl2-sys` (`bundled`)
  and `ort-sys` (`copy-dylibs`) find the target directory by walking up from
  `OUT_DIR` and copy shared libraries into `target/<profile>` and `deps/`.
  Their `rustc-link-search` paths still point into their own `OUT_DIR`.
  These copies rely on Cargo putting `target/<profile>` on the path, which
  is a different gap: writing outside `OUT_DIR` cannot work in a Nix sandbox
  under any rule.
- **No crate points a search path into another script's `OUT_DIR` by a
  route other than `DEP_*`**, and none points into the target directory
  outside every `OUT_DIR`.

Limits: this is a grep plus reading, not a run. The 64 scripts without any
of the route markers were not read line by line. The user's own lockfiles
were not added (the field-trial repositories live outside this repository).

### (c) Recommendation and cost analysis

The candidate rules:

1. **Status quo.** Compiles, runs and doctests use the printing run's own
   `out` or a `DEP_*` upstream `out`. Test runs use "inside any run's `out`
   of the platform". This gives two rules, and the test-run rule makes every
   test run (and every dynamic-mode wrapper) take every same-platform run's
   `out` as an input.
2. **"Inside any same-platform run's `out`" everywhere.** This is closest to
   Cargo. For compiles and runs, though, each unit must know the `out` path
   of every same-platform run in the plan. That list changes whenever any
   build script anywhere changes. As a derivation attribute it would rebuild
   every compile that has a proc-macro dependency whenever any build-script
   package changes. Avoiding that needs string-without-context plumbing,
   with drift between delivery modes. This costs much more than it gains,
   given (b).
3. **Own `out` or `DEP_*` upstream `out`, decided once per path when the
   printing run's output is parsed, everywhere.** It is already stored per
   path (`LibraryPath::in_out_dir`, `in_build_dir` in `directives.json`) and
   already used by compiles, runs and doctests.

**Picked: 3, implemented in `bfa46f7`.**

- `lib/test-runs.nix`'s `dylibJq` now keeps a value when its run marked it
  `inOutDir` or `inBuildDir`. It filters before deduplicating, so a value
  that one run kept survives another run's copy that was not kept.
- `spec.dylib.outs`, the `stableSpec` copy of it, `lib/dynamic.nix`'s
  `--argjson outs` and `TestSpec::dylib_outs` in breakbulk-instantiate are
  removed.
- New check `test-runs-dylib-rule`.
- `docs/implementation.md` is updated (the value-dependent rule, test runs,
  the dynamic wrapper's contents).

Costs and effects:

- **Fidelity.** Compared with the old test-run rule, a test loses only paths
  that a run printed into a *different* run's `out` without a `DEP_*` edge.
  The survey found none. Compared with Cargo, all contexts still miss paths
  under the target directory but outside every `OUT_DIR`. These cannot exist
  in breakbulk, because a run can write only its own `out`.
- **Inputs.** Test runs and dynamic wrappers no longer depend on the `out`
  of runs that print no search path into it (for example bindgen or prost
  output). Outs that do hold a kept path are still in the closure, because
  `directives.json` names them and Nix records that as a reference. The
  rebuild triggers do not change: `flags` and `out` come from the same run
  derivation.
- **Old `flags` outputs** without `inBuildDir` read as `inOutDir`, as before.
- **Size.** About 40 lines of Nix and Rust, mostly deletions, plus a test.

If a crate is ever found that uses another route, the rule can grow one
case without becoming per-context again. For example, "inside the `out` of
any run in the printing run's input closure": the run would record the
`out`s of its build-dependency compiles' runs in `upstream_out_dirs`. That
is still decided once, at parse time.
