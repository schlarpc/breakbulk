<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/breakbulk-lockup-dark.svg">
    <img src="docs/logo/breakbulk-lockup.svg" alt="breakbulk" width="260">
  </picture>
</h1>

breakbulk builds Rust projects with Nix, one derivation per Cargo unit.

A Cargo unit is one rustc call (a library, a binary, a test harness) or one
build-script run. breakbulk runs your own Cargo once to record what it would
do. It then turns each recorded step into its own Nix derivation, with
Cargo's exact command line. So:

- builds behave like `cargo build`, including build scripts, profiles,
  `.cargo/config.toml`, cross targets, wasm and Windows;
- each crate is a separate store path, shared across workspaces, projects
  and machines through an ordinary binary cache;
- a change rebuilds only the crates it affects and their dependents;
- nothing generated is checked in.

The name: [break-bulk cargo](https://en.wikipedia.org/wiki/Breakbulk_cargo) is loaded piece by piece, not in containers.

The design is in [docs/design.md](docs/design.md). How it is built is in
[docs/implementation.md](docs/implementation.md). Decisions made along the
way are in [docs/decision-log.md](docs/decision-log.md).

## Status

breakbulk is young. Its first users are the author's own repositories.

| Milestone | What | Status |
| --- | --- | --- |
| M0 | Spikes: tracing Cargo, dynamic derivations, env capture | Done |
| M1 | Traced planner, unit builder, import-from-derivation delivery, native Linux | Done |
| M2 | Module options, many workspaces, per-package overrides, env capture, dev shell | Done |
| M3 | Day-one targets: Linux gnu and musl, static glibc, wasm, Windows msvc | Done, except a headless Chromium test runner, cross-language LTO and tests on a real aarch64 builder |
| M4 | Post-link stages, test runs, doctests, benches, clippy, coverage, products as inputs | Done, except Windows post-link tests and the exit check on a real multi-workspace repository |
| M5 | Dynamic-derivation delivery (no import-from-derivation) | Works on Nix master. It turns on by itself once a released Nix has the feature. Test: `nix run .#test-dynamic`. Doctests and test apps are not in this mode yet |
| M6 | Pipelined split, dep-info source narrowing, nextest, docs product, measurements | Not started |
| M7 | Later targets: wasip2, riscv64, windows-gnu, build-std, Darwin, zig | wasip2, riscv64, windows-gnu (and gnullvm), zig and build-std done; Darwin not started (no Mac builders) |

## Quickstart

breakbulk is a flake. Its library is `breakbulk.lib`.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    breakbulk.url = "github:schlarpc/breakbulk";
  };

  outputs = { self, nixpkgs, breakbulk }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      repo = breakbulk.lib.mkRepository {
        inherit pkgs;
        root = self;           # the flake's own tree; `./.` works too
        modules = [ ./nix/rust.nix ];
      };
    in
    {
      packages.${system}.default = repo.workspaces.main.packages.app;
      checks.${system} = repo.checks;
      devShells.${system}.default = repo.workspaces.main.devShell;
    };
}
```

`root` is the repository root: a path (`./.`) or the flake's `self`. Both
give the same derivations. Any other value, such as a string outside the
Nix store, is an error.

A minimal module names the workspace. Everything else has a default.

```nix
# nix/rust.nix
{ pkgs, ... }:
{
  # The Cargo workspace at the repository root. Its Cargo.lock is used.
  workspaces.main.path = ".";

  # Optional: a build stamp that reaches only the `app` package's units.
  packages.app.env.GIT_REV = "dev";

  # Optional: a native library for one -sys crate.
  packages.openssl-sys = {
    nativeInputs = p: [ p.pkg-config ];
    inputs = p: [ p.openssl ];
  };
}
```

Then:

- `nix build` builds the `app` package for the native target. Binaries are
  in `result/bin`. Debug info is split off into a `debug` output.
- `nix flake check` builds every product and runs every test binary and
  doctest of the default variant.
- `nix develop` gives a shell where plain `cargo` behaves like the planner:
  it sets `CARGO_BUILD_TARGET` and the toolchain spec (linker, rustflags),
  and adds the packages' native inputs. Use it for the edit-compile loop.

breakbulk's own flake outputs (its packages, checks and dev shell) are
defined for the systems in its `systems` input, a
[nix-systems](https://github.com/nix-systems/nix-systems) flake
(`x86_64-linux` and `aarch64-linux`). To change the list, point it at
another: `inputs.breakbulk.inputs.systems.follows = "systems";`. The
library itself (`breakbulk.lib`) takes `pkgs` and works for any system.

With flake-parts, import `breakbulk.lib.flakeModule` and set
`perSystem.breakbulk.modules = [ ./nix/rust.nix ];`. `root` defaults to
the flake's `self`. It adds packages, checks and dev shells for you.

Other outputs, per workspace:

- `repo.workspaces.<ws>.target.<triple>.packages.<pkg>`: the product for one
  target. `.stages.<name>` gives each post-link stage.
- `repo.workspaces.<ws>.target.<triple>.tests.<pkg>.<test>`: test binaries.
- `repo.workspaces.<ws>.target.<triple>.testRuns.<pkg>.<test>`: test runs.
- `repo.workspaces.<ws>.target.<triple>.testApps.<pkg>.<test>`: run one test
  binary outside the sandbox, for network tests or a debugger.
- `repo.sources.<crate>`: a fetched crate source.
- `repo.explainSharing`: why a crate is built twice instead of shared.

## Configuration

All configuration is in NixOS-style modules. The full list of options is in
[docs/options.md](docs/options.md). The main groups:

- `workspaces.<ws>`: where each Cargo workspace is, its toolchain, its
  targets and its variants (profiles, features, check, clippy, coverage,
  benches).
- `targets.<triple>`: the toolchain spec of a target. Start from a preset
  (`breakbulk.presets.linux`, `linuxStatic`, `linuxPortable`, `windows`,
  `wasmWeb`, `wasmComponent`; each picks its mechanism from the triple) and override any field: linker, C
  compiler, rustflags, env, test runner, post-link stages, and
  `debugInfo` (`split` into a `debug` output, the default on Linux;
  `keep`; `strip`). On Linux the
  native target uses `linux` (or `linuxStatic` when the `pkgs` you pass
  is a musl one, such as `pkgs.pkgsMusl`) unless you set another preset. A preset
  follows each workspace's compiler: two workspaces on different Rust
  releases get matching LLVM tools and wasi-sdk headers without passing
  `rustc`. `workspaces.<ws>.targets.<triple>` takes the same options for
  one workspace.
- `packages.<name>`: settings for one package's units only: `env`,
  `nativeInputs`, `inputs`, `extraSources`, stages, checks, and `test`
  settings (env, extra `PATH`, libtest arguments, skip lists, a wider
  source view with `test.sourceScope`).
- `mode`, `ca`, `strictSources`, `registries`, `gitHashes`: repository-wide
  settings.

breakbulk reads your project's own `.cargo/config.toml`, so profiles,
`[env]`, rustflags and feature settings apply as they do locally. It does
not see `~/.cargo/config.toml`, `CARGO_*` variables in your shell, or flags
in aliases and scripts. Move such settings into the project's config. The
dev shell warns when it sees them.

## Supported targets

| Target | Preset | Linker | Test runner |
| --- | --- | --- | --- |
| x86\_64 and aarch64 Linux gnu | `linux` | mold | native, or qemu-user when cross |
| x86\_64 and aarch64 Linux musl | `linuxStatic` (or `linux`) | mold | native, or qemu-user |
| Host triple, fully static glibc | `linuxStatic` | mold | native |
| Host triple, old glibc (e.g. 2.17) | `linuxPortable` | zig cc | native |
| wasm32-unknown-unknown, browser | `wasmWeb` | lld (wasm) | wasm-bindgen test runner with Node |
| wasm32-unknown-unknown, component | `wasmComponent` | lld (wasm) | wasmtime |
| wasm32-wasip2 | `wasmComponent` | rustc's wasm-component-ld | wasmtime |
| x86\_64 and aarch64 Windows msvc | `windows` | lld-link | wine (x86\_64) |
| x86\_64 Windows gnu and gnullvm (mingw-w64) | `windows` | lld | wine |
| riscv64gc Linux gnu | `linux` | mold | qemu-user |

The Windows preset on msvc needs the Microsoft CRT and Windows SDK, which are
unfree. breakbulk downloads them with `breakbulk.xwinSdk`. build-std
(`-Zbuild-std`) works with a nightly that has `rust-src`. Darwin is not
supported yet.

## Known limitations

- **Test runs re-run more often than needed on stock Nix.** A test run
  should not re-run when its test binary's bytes did not change. That needs
  content-addressed derivations, an experimental Nix feature. breakbulk
  uses them only when Nix's `dynamic-derivations` feature is on, or when you
  set `ca = true`. Otherwise a test run re-runs whenever its binary's build
  step changes.
- **Import-from-derivation.** The default mode reads the plan at evaluation
  time. Nix must allow import-from-derivation (the default). Evaluation
  waits for Cargo planning when manifests, the lockfile or config change.
  Dynamic-derivation mode removes this, but needs Nix 2.36 or later.
- **Overhead for tiny crates.** Nix spends about 35 to 50 ms setting up each
  derivation. For many very small crates, a cold build can be several times
  slower than `cargo build`. Real crates take much longer to compile, so
  the share is smaller there.
- **No headless Chromium test runner yet.** Browser wasm tests run in Node
  with the wasm-bindgen test runner.
- **Cold builds lose Cargo's pipelining.** A dependent waits for the whole
  upstream crate, not only its metadata. Clean optimized builds can be
  slower than Cargo's: Cargo gained 5 to 39% from pipelining at 8 cores in
  the M6 measurements, and close to nothing at 4 cores on wide workspaces.

## Future work

These were measured in M6 and are not built yet. Details and numbers:
[docs/spikes/m6-measurements.md](docs/spikes/m6-measurements.md) and
"Future work" in [docs/design.md](docs/design.md#future-work).

- **Pipelining across derivations.** Splitting a library into a metadata
  step and a code step brings back Cargo's pipelining. Running the
  compiler's front end twice costs 23 to 49% more CPU and is slower than
  no split at 4 cores, so it is not used. The one approach that keeps the
  gain pauses the compiler with CRIU in one derivation and resumes it in
  the next; it needs a spike first.
- **Skipping dependents when a library's interface is unchanged.** Not
  possible today: the compiler writes a hash of every source file into the
  library's metadata, so any edit changes it. Replaying real history, it
  would have saved 1 to 4% of library compiles. It needs a compiler
  change that keeps source hashes and positions out of what dependents
  read. Rust's planned public-API hash (`-Zpublic-api-hash`) is not in
  nightly yet.
- **Content-addressed build steps on fresh machines.** Nix downloads every
  input of a content-addressed step before it can tell the step is cached:
  1.83 GB for one test run, against 440 bytes when input-addressed. This
  waits on a Nix fix (NixOS/nix#11928). Until then build steps are
  input-addressed, and content-addressed test runs are off unless Nix's
  `dynamic-derivations` feature is on or you set `ca = true`.

## Tip: fewer substituters, faster cold builds

Before it builds a derivation, Nix asks every configured binary cache
whether it has it. breakbulk makes many small derivations, so each extra
cache adds time: about 7 seconds per 300 crates with four caches. For
breakbulk builds, keep only the caches you need, for example:

```sh
nix build --option substituters "https://cache.nixos.org https://your-cache.example"
```

Setting `substituters` on the command line needs a trusted user, or the
caches in `trusted-substituters`.

## Development

- `nix develop -c cargo test` runs the Rust tests.
- `nix flake check` runs every test fixture. Some checks are heavy: they
  download the Windows SDK, build cross toolchains and run wine.
- `tests/loose-ends/update-options-doc.sh` regenerates
  [docs/options.md](docs/options.md); a flake check fails while it is out
  of date.

breakbulk is MIT-licensed. See [LICENSE](LICENSE).
