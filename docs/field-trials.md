# breakbulk: field trials

Nov 7, 2026 · @Chaz Schlarp

breakbulk was tried on three of the author's repositories, as the M4 exit
criterion asks: "one of the author's multi-workspace repositories with an
embedded product builds end to end, with its CI using `repo.checks`". The
modules are in `tests/field-trials/` (no source from the repositories; see
its README for how to point them at a checkout). Every build ran on read-only
copies under `/tmp`, in IFD mode, with breakbulk's pinned nixpkgs and each
repository's own `rust-toolchain.toml` (rust-overlay, 1.96.1).

**Result: go for M4.** datboi2, a repository with eleven workspaces, a
nightly-only workspace with git dependencies, eight wasm components and four
embedded products, builds end to end, and the checks its CI runs pass from
`repo.checks` (with the project settings listed below). Eight breakbulk bugs
were found and fixed, each with a regression check. kmsrsos (musl, two msvc
architectures, stamps, feature variants) builds and passes its CI checks;
mtgac builds except its wasm `check` gate. The gaps that remain are
listed at the end, by priority.

## Choosing the repositories

Rust repositories under `$HOME` with a `Cargo.lock`, surveyed for the
catalogued patterns:

| Repository | Lockfiles (packages) | Targets | Build scripts, -sys, embeds | Existing Nix |
| --- | --- | --- | --- | --- |
| **datboi2** | 10 (672 host; 31–50 each other) | native, wasm32 components, wasm32 browser (nightly) | wasm components and a web dist embedded through build-script env; C++ and C compiled to wasm by build scripts; libmagic; bundled SQLite; WIT files read by proc macros | crane, 811-line flake |
| **kmsrsos** | 4 (244, 44, 35, 1) | native, x86_64 musl, x86_64 and aarch64 msvc | build stamp through `option_env!`; a Windows resource through `rustc-link-arg-bins`; generated tables | crane, 2748-line flake (OS images, boot checks) |
| **mtgac** | 1 (414) | native, wasm32 browser (ring's C), x86_64 msvc | rust-embed of a trunk bundle; bundled SQLite; xtask; checked-in codegen | crane, trunk |
| castaway | 1 (998) | native, msvc | | crane |
| steam2fs, sindenrs | 1 (298, 126) | native, msvc | | crane |
| pewpedia | 1 (217) | native | | crane |
| hydra-pcie-camera | 2 (28, 113) | msvc, a Windows kernel driver (WDK) | | none |
| waddup | 6 | zkVM guests (SP1, RISC Zero) | | custom |
| shattered, shawarma | 50+ throwaway `lab/records/*/tools` lockfiles | native | | |

datboi2 is the M4 candidate: many workspaces, embedded products of another
target, a nightly workspace, cross-language build scripts. kmsrsos adds musl,
two msvc architectures, project rustflags, build stamps and feature
variants. mtgac adds a browser wasm target with C code, a workspace-wide
`--exclude` list and an embed by relative path. Together they cover every
catalogued pattern except riscv, zig and the pipelined split.

## datboi2

### What the module does

`tests/field-trials/datboi2/nix/rust.nix` (about 300 lines, against 811 in
the flake, of which the module replaces the Rust part):

- `host`: the root workspace, native, release, plus a `clippy` variant with
  `--deny warnings`.
- Eight component workspaces (`crates/datboi-{xf,ex}-*`, each its own
  lockfile), targets wasm32 and native (the flake runs their unit tests
  natively). The wasm32 product goes through `componentize` and a
  project stage `stamp` (git tree hashes of the crate and its guest crate,
  `wasm-tools metadata add`), installed as `lib/<module>.wasm`.
- `emu-ds`: nightly-2025-12-20 with three git dependencies, wasm-bindgen
  0.2.121 (`bindgen --no-typescript`), then a stage that adds the crate's
  asset files.
- Embeds as per-package env, by reference: `DATBOI_COMPONENTS_DIR` on
  datboi-runtime and datboi-ingest (a symlinkJoin of the eight component
  products), `DATBOI_WEB_DIST`, `DATBOI_EMU_DS` and `DATBOI_MAGIC_DB` on
  datboi-server.

### What worked

- Every plan traced on the first try once the bugs below were fixed:
  11 workspaces × their targets × build, test and clippy plans. The host
  build plan has 653 units (577 compiles, 76 build-script runs; 219 host,
  434 target).
- The datboi binary builds and runs, with the web dist, the emu core, the
  magic database and the eight components embedded. Only the units that
  read an embed's env wait for it; the rest of the host graph started at
  once.
- The components: the unrar C++ and the 7-Zip C compile to wasm in their
  build scripts with the project's own toolchain env, the cdylibs link,
  componentize and get stamped.
- The nightly emu workspace with git dependencies, next to stable ones.
- Shared path crates: `datboi-guest-transform` is a member of `host` and a
  path dependency of six component workspaces (outside their roots).
- Tests: 63 host test binaries and the components' native unit tests pass,
  with `fsck.vfat` on `PATH` for two packages (`test.path`), fixtures of
  sibling crates through `test.sourceScope`, and `CARGO_BIN_EXE_datboi` at
  run time (after fix 6).
- The default `noSourceReferences` check found a real source reference:
  `datboi-gen-openapi` (a dev tool) embeds `CARGO_MANIFEST_DIR` to write
  `openapi.json`. crane's build embeds `/build/source/…` there instead.

### Project settings the module supplies

These are things a user writes, as expected by the design:

- `extraSources = [ "wit" ]` on the two guest crates and datboi-runtime
  (wit-bindgen's and wasmtime's `bindgen!` read `../../wit`).
- `test.sourceScope` on datboi-runtime and datboi-exec, whose integration
  tests `include_bytes!` fixtures of sibling crates.
- The wasi toolchain env for the two extractors (`DATBOI_WASI_*`), and the
  unrar and 7-Zip sources, from the project's own `nix/*.nix` recipes.
  nixpkgs renamed `wasm32-unknown-wasi` to `wasm32-unknown-wasip1` since the
  flake's pin, so the paths differ from the flake's.
- `magic-sys.env.MAGIC_DIR`: see gap 3.
- `libsqlite3-sys` defaults removed: see gap 2.
- `targets.<native>.preset = presets.linuxGnu`: see gap 1.
- The web dist (npm, `importNpmLock`) and the magic database are ordinary
  derivations in the module, copied from the flake.
- `--skip component_bytes_are_pinned` on datboi-runtime's tests: four tests
  pin the blake3 of the crane-built components. breakbulk's components are
  deterministic but differ: crane's carry its build paths in panic
  locations (`/build/nest/datboi-guest-transform/src/cbor.rs`, the vendor
  directory with a scrubbed store hash) and wit-component 0.252 from the
  flake's wasm-tools; breakbulk's carry `./crates/…`, `miniz_oxide-0.8.9/…`
  and 0.262. A migration re-pins them once.

### Numbers

The machine has 8 cores and was shared with other agents throughout: load
averages were 22–43 during every measurement, so the times are noisy, and
each was taken once. Both tools got four cores: crane as one derivation with
`--cores 4` (cargo `-j4`), breakbulk as `--max-jobs 4 --cores 1`. Crate
downloads and toolchains were already in the store for both.

| Measurement | breakbulk | crane (the flake's) |
| --- | --- | --- |
| Cold build of the datboi binary (its 634-derivation closure; crane: `buildDepsOnly` + `buildPackage`) | 532 s (load 37 → 26) | 969 s (load 22 → 25): deps 668 s, package 301 s |
| …of which cargo/rustc time in crane's logs | — | `cargo check` 181 s, `cargo build` 356 s, `cargo test --no-run` 21 s (deps); `cargo build` 103 s (package) |
| Rebuild after a one-line edit of `crates/datboi/src/main.rs` (the leaf binary) | 40 s, 4 derivations (bin, linked, splitDebug, install); evaluation included, no replanning | 206 s (the package derivation recompiles all 16 workspace crates) |
| First evaluation (IFD: fetch and unpack 672 crates, plan, instantiate) | 3 min 51 s for the host product; over 10 min for everything in `repo.checks` | 1 min (crane's vendoring is a build step) |
| Full CI set from cold (`datboi2.ci`: 1707 derivations; products, 63 test runs, clippy, components' native tests, transforms, emu) | 2511 s at `--max-jobs 2 --cores 4` (load ~30) | not measured (the flake's `nix flake check` also runs a NixOS VM test and npm tests) |

breakbulk's cold build is about 1.2× crane's `cargo build` time alone, and
faster than crane's derivations, because `buildDepsOnly` runs `cargo check`,
`cargo build` and `cargo test --no-run` over the dependencies by default.
That is inside the design's "about 2× crane" budget. The first build in the
trial (before the fixes) took 1859 s at `--max-jobs 2 --cores 4` and higher
load; two concurrent units is too few for a graph this wide.

Units: the host build plan has 653 units, the test plan 791, the clippy
variant 653 + 792. Each component plan has 62–77 wasm32 units, and they are
shared across the eight component workspaces: xf-cso (64 units) and xf-ecm
(62) share 61 unit derivations, and 60 are common to those two and ex-7z.
Everything but the component crate itself is shared, including the guest
crate, a path dependency outside each component's root (the design's rule
for path crates). Across all 38 plans there are 4101 unit entries.

## kmsrsos

### What the module does

`tests/field-trials/kmsrsos/nix/rust.nix` (about 130 lines; the flake's
Rust wiring is about 300 of its 2748): one workspace, release, on four
targets: native (the whole workspace), `x86_64-unknown-linux-musl`
(`presets.linuxMusl`; server, client, os), and x86_64 and aarch64
`pc-windows-msvc` (`presets.msvc` with `crtStatic`; server and client).
Variants `clippy` (`--deny warnings`) and `policy` (the two
`kmsrs-policy/…` features). The build stamp (`KMSRSOS_GIT_COMMIT`,
`SOURCE_DATE_EPOCH`) is env on kmsrs-server only.

### What worked

- All four targets' products build: 348 s from cold for all of them
  (`--max-jobs 4 --cores 1`, load 25–29). The static server is static-pie
  with no references; the native one references glibc and gcc's libs only;
  the x86_64 `.exe` imports only system DLLs (`+crt-static`, no
  `VCRUNTIME140.dll`, which the project checks for) and carries the message
  table resource its build script passes with `rustc-link-arg-bins`; the
  aarch64 `.exe`s are ARM64 PE files.
- The project's own `[target.x86_64-pc-windows-msvc] rustflags =
  ["+crt-static"]` and the preset's flags both arrive (decision 33): the
  planner put the preset's under the same key.
- `ci` (build, clippy, every native test binary, the policy-feature tests):
  green, after the settings below. The flake's comment that crane needs the
  `+crt-static` flag twice because env rustflags replace the config's does
  not apply: breakbulk concatenates them.

### Project settings the module supplies

- `test.sourceScope` for kmsrs-server (its workspace, packaging, docs and
  kernel-config invariant tests read `.github/`, `Cargo.lock`, `flake.nix`,
  `flake.lock`, `docs/`, `os/`, `ci/`, `deploy/`, `harness/`, `fuzz/` and
  other crates), kmsrs-db (`crates/kmsrs-dbgen`) and kmsrs-vectors
  (`fuzz`). The first run failed with the test's own "cannot read …" message
  naming each path, which made this a mechanical fix.
- `noSourceReferences = null` for kmsrs-dbgen, a generator that finds its
  data through `CARGO_MANIFEST_DIR` (the check is right that it does).
- The xwin SDK through `breakbulk.xwinSdk` with the same pins as the flake's
  FOD (CRT 14.44.17.14, SDK 10.0.26100, both architectures). The hash is
  the same as the flake's, so the download was shared.

### Not covered

The coverage gate (`cargo llvm-cov` with a 90% threshold on three
packages: breakbulk's coverage variant produces the profiles, but no
report or threshold), the per-package feature powerset (gap 10), the
container image, OS images and boot checks (non-Rust derivations over
these products, which would consume `packages.*` unchanged), and the
nightly `fuzz` and `panic-audit` workspaces (no toolchain is pinned for
them in the repository; `cargo fuzz` adds sanitizer flags itself).

## mtgac

### What the module does

`tests/field-trials/mtgac/nix/rust.nix` (about 100 lines): one workspace
(16 crates and xtask, 414 packages in the lockfile) on three targets:
native (`presets.linuxGnu`), wasm32 (`presets.wasmBrowser`, restricted to
every member but mtgac and xtask, as the project's `cargo check-wasm`
alias), and x86_64 msvc (mtgac only). Variants `check` and `clippy`
(`--deny warnings`, dev profile as the flake's).

### What worked

- The mtgac binary, its Windows `.exe`, clippy over the workspace, and the
  Leptos UI as a wasm32 product through `bindgen` (wasm-bindgen 0.2.128,
  matched from the lockfile) and `wasmOpt` (after fix 8). ring's C code
  compiles for wasm32 with the preset's unwrapped clang, which the flake
  wires by hand (`CC_wasm32_unknown_unknown`).
- First evaluation (plans of three targets × three variants): about 5
  minutes, mostly unpacking crates (gap 8).

### What did not

- **The wasm gate.** breakbulk's `check` variant traces `cargo check` and
  `cargo check --all-targets` (decision 75). The flake's gate is plain
  `cargo check --target wasm32-unknown-unknown`. With `--all-targets`, the
  members' tests and dev-dependencies are checked for wasm32 too: tokio's
  `net` feature pulls in mio, which refuses wasm32 (`compile_error!`), and
  mtgac-catalog's `python_conformance` test uses a native-only function.
  These are real failures of `cargo check --all-targets --target wasm32`,
  but not what the project gates on (gap 4b).
- **The UI is not embedded.** See gap 6: rust-embed's literal `folder`
  path. mtgac's own flake ships the placeholder page too.
- Not run for lack of time: the native test runs (they are in
  `repo.checks`), trunk's HTML processing (hashed file names, the
  `index.html` rewrite), the asset pipeline (fixed-output downloads of the
  game client), cargo-deny, coverage.

### Project settings the module supplies

- `libsqlite3-sys` defaults removed (rusqlite `bundled`; gap 2).
- The member list for the wasm target, read from `crates/*` (the alias's
  `--exclude` has no breakbulk spelling; `targets.<t>.packages` takes an
  inclusion list).

## Fixes made in breakbulk

Each is a breakbulk bug found by the trials, fixed with a regression check.

1. **Cargo's inherited `LD_LIBRARY_PATH` leaked into plans** (99609c4,
   b0b9439). Cargo appends its own process's dynamic-library path to every
   one it sets, before the plugin runs' paths (cargo 0.97.0,
   `compilation.rs` `fill_env`, `compiler/mod.rs` `add_plugin_deps`).
   rust-overlay's cargo is a wrapper that exports libsecret's directory
   there, so every plan made with a rust-overlay toolchain from a
   `rust-toolchain.toml` with the `default` profile failed: "the store path
   …-libsecret is not a declared toolchain input". The planner now drops the
   baseline's value from those positions. Check: `plan-inherited-dylib-path`
   (walking-skeleton and directives with a wrapped cargo; fails without the
   fix).
2. **Git dependencies never resolved at instantiation** (a3d3942, also on
   main through the hardening branch). Crate sources were keyed without
   `git+` and always with `#name@version`; Cargo's package id keeps `git+`
   and the reference query and leaves the name out when the URL ends in it
   (cargo-util-schemas 0.11.0, `PackageIdSpec`'s `Display`). Check:
   `repository-pkgid-short` (two git sources through `gitTrees`).
3. **`presets.msvc { crtStatic = true; }` failed evaluation** (3ad54f3): the
   option shadowed the list of flags. Check: `presets-eval` `msvcCrtStatic`.
4. **Package inputs on a target without a package set failed evaluation of
   every plan** (66d5eaf). The curated `libsqlite3-sys` default has
   `inputs`, so any workspace with that crate in its lockfile and a wasm32
   or msvc target failed, even when the wasm plan never builds it. Host
   units of such a target now use the build machine's set; target units get
   a capture that fails with the old message when built. Check:
   `presets` `wasm-host-inputs`.
5. **Every product referenced the whole toolchain** (3531aff). With the
   `rust-src` component installed (rust-overlay's `default` profile), rustc
   names std's files by the local copy, so panic locations in std code
   instantiated in user crates carried
   `/nix/store/…-rust-default-1.96.1/lib/rustlib/src/rust/…`: the datboi
   binary had 58, each component several, and Nix recorded the toolchain as
   a runtime dependency. `noSourceReferences` does not look for it. The
   planner now records `rustSrcRemap` (`<sysroot>/lib/rustlib/src/rust` →
   `/rustc/<commit-hash>`, what Cargo's trim-paths adds, cargo 0.97.0
   `sysroot_remap`) and units add it to their remaps. Check:
   `products-rust-src` (fails without the fix).
6. **Test runs lacked `CARGO_BIN_EXE_*`** (1bfe998). Cargo sets them on the
   test process too, not only at compile time (cargo 0.97.0,
   `ops/cargo_test.rs`, the `unit_output` env from `artifact::get_env`);
   assert_cmd's `Command::cargo_bin` reads them at run time, so all of
   datboi's CLI tests failed. Check: `test-runs-test-control`
   (`bin_exe_at_run_time`, fails without the fix). Dynamic mode has the
   same change, untested on Nix master.
7. **Test runs failed for bins with a hyphen** (5cf007b), right after fix 6:
   `export CARGO_BIN_EXE_datboi-crash-child=…` is not valid shell. Names
   the shell cannot export now go through `env`. Check:
   `test-runs-test-control` (a `ctl-extra` bin). nextest runs get the same
   treatment after the merge with main.
8. **`wasmOpt` rejected every Rust wasm module** that uses `memory.copy`
   (mtgac's UI): rustc enables bulk memory and five other features on
   wasm32-unknown-unknown by default (its `CARGO_CFG_TARGET_FEATURE`, seen
   in the plans), while wasm-opt validates against the MVP unless told
   otherwise. The helper now passes `--enable-<f>` for that set
   (`features`, overridable). Check: `stages-wasm-opt-features`. trunk
   passes the same flags in mtgac's `index.html`.

## Gaps, by priority

ASK marks a choice for the author.

1. **The native target has no default preset.** Done (decision 105): the
   native target gets `presets.linuxGnu` on Linux glibc hosts unless
   another preset is set. Before: Without
   `targets.<native>.preset = presets.linuxGnu`, units link with rustc's
   self-contained `rust-lld` (`-fuse-ld=lld -B…/gcc-ld`), which bypasses
   nixpkgs' linker wrapper: no rpath for `-l` libraries (libmagic here) and
   no wrapper hardening. The design says the linker is chosen automatically
   ("Linux ELF on a Linux host: mold"); the implementation applies it only
   with an explicit preset, and every trial had to add it. Proposal: the
   native triple defaults to `presets.linuxGnu` (`preset = null` opts out).
   It changes every native unit once.
2. **Curated `-sys` defaults change what gets built.** Done (decision
   106): the four switches are gone, the inputs stay, and the trials no
   longer override libsqlite3-sys. Before:
   `lib/sys-defaults.nix` copies nixpkgs' `LIBSQLITE3_SYS_USE_PKG_CONFIG=1`,
   `ZSTD_SYS_USE_PKG_CONFIG=1`, `LIBGIT2_SYS_USE_PKG_CONFIG=1` and
   `AWS_LC_SYS_USE_SYSTEM=1`. Each replaces a vendored or bundled C library
   that the project chose (rusqlite's `bundled` in datboi2 and mtgac) with
   nixpkgs', so the binary differs from `cargo build`'s and from crane's,
   silently. That is against principle 8 ("never turned on behind the user's
   back"). The `inputs` are harmless (they only help the build script when
   it looks for a system library). Proposal: drop the four env switches,
   keep the inputs. Both trials removed them with `lib.mkForce`.
3. **Library inputs do not reach the links that need them.** crane and
   `buildRustPackage` give every link the stdenv's `NIX_LDFLAGS`, so a
   `-sys` crate that prints only `cargo:rustc-link-lib=magic` links. In
   breakbulk `packages.magic-sys.inputs` reaches only magic-sys's units,
   while the link happens in each binary's and test's unit; the link failed
   with "unable to find library -lmagic". It works when the build script
   prints `rustc-link-search` (pkg-config does; magic-sys does with
   `MAGIC_DIR`). Proposal: a package's input library directories go to the
   link units that depend on it (a link-time capture), or the failure hint
   names `MAGIC_DIR`-style env. Which is right needs a design decision.
4. **Variants and test plans apply to every target of a workspace.** The
   components' wasm32 target gets test plans, doctests and test runs under
   wasmtime in `repo.checks` (the flake runs their tests natively only);
   mtgac's `clippy` and `check` variants are planned for its wasm32 and msvc
   targets too. The trial filters `repo.checks` by name. Proposal:
   `workspaces.<ws>.targets.<triple>.{variants, tests}` to narrow per
   target.

   4b. **Check variants always include `--all-targets`.** Done (decision
   108): `variants.<v>.allTargets = false`. Before: mtgac's
   wasm gate is `cargo check` without it, and `--all-targets` fails there
   for reasons the project does not gate on (see mtgac). Proposal: a
   variant option `allTargets = true` (the default, decision 75) that a
   gate like this sets to false.
5. **Only the default variant's tests are in `repo.checks`.** kmsrsos's
   `policy-features` check (tests under two features) needs
   `target.<t>.variants.policy.namedTestRuns` wired by hand. Proposal: a
   per-variant `checks = true`.
6. **No way to embed a product at a fixed path in a source view.**
   mtgac embeds its trunk bundle with `#[derive(RustEmbed)] #[folder =
   "../mtgac-ui/dist/"] #[allow_missing = true]`: a literal path, not env.
   Products as inputs work only through env, so the binary gets the
   placeholder page; mtgac's own flake ships the placeholder too (the
   catalogued "embed silently falls back" pattern, live). Proposal:
   `packages.<name>.overlays."<repo path>" = <derivation>`, a product
   placed into the package's source view at that path.
7. **Modules cannot reach the repository or its root.** mkRepository gives
   modules `pkgs` only. A module that embeds another workspace's product
   needs the repository object (the products test and the trial driver pass
   it through `specialArgs` or a `let rec`), and reading project files needs
   `root`. Proposal: pass `root` and the result as module arguments.
8. **First evaluation is slow in IFD mode.** Planning needs every crate, so
   evaluation fetches and unpacks each one through IFD, one at a time:
   about 4 minutes for datboi2's host workspace, 3.5 for kmsrsos, 5 for
   mtgac, and over 10 for datboi2's 76 plans with checks. Later evaluations
   are seconds. Unpacking with a batch derivation per lockfile would cut
   it.
9. **`noSourceReferences` does not look for toolchain paths.** Fix 5 was
   found by hand. The check could also fail on the toolchain's store
   paths.
10. **No per-package feature powerset.** kmsrsos runs `cargo hack check
    --feature-powerset` (each package's own features, others at default);
    `variants.featurePowerset` sets features for the whole workspace with
    `--no-default-features`, which is a different matrix.
11. **Pinned bytes from another build tool.** Not a breakbulk bug, but a
    migration cost: datboi2 pins component hashes produced by crane's paths
    and the flake's wasm-tools. breakbulk's are reproducible; re-pinning is
    a one-time step, after which the pins guard breakbulk's bytes.
12. **One preset compiler per target, toolchains per workspace** (decision
    70). datboi2's wasm32 preset is configured with 1.96.1 while emu-ds uses
    nightly-2025-12; it worked because both use LLVM 21/22-compatible
    `wasm-ld`, but the preset cannot follow each workspace's compiler.
