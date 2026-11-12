# Port a crane flake

[crane](https://github.com/ipetkov/crane) builds a workspace in a few
large derivations: the dependencies first (`buildDepsOnly`), then the
workspace on top of them. breakbulk makes one derivation per Cargo unit,
from a plan that it traces from your own Cargo. Most of crane's functions
have no counterpart call. They become settings in a breakbulk module.

This page maps crane's functions to breakbulk's options, ports a
repository with several workspaces and toolchains, and lists what
differs in the output.

## crane's functions

| crane | breakbulk |
| --- | --- |
| `buildDepsOnly`, `cargoArtifacts` | nothing: every unit is its own derivation, and plans share the units that come out the same |
| `buildPackage`, `cargoBuild` | `repo.workspaces.<ws>.packages.<pkg>`, one [product](../reference/outputs.md#products) per package |
| `cargoTest` | a test run per test binary, in `repo.checks`; arguments after `--` in [`test.args`](../reference/options/packages.md#packagesnametestargs) |
| `cargoDocTest` | a doctest run per library, in `repo.checks` |
| `cargoNextest` | [`test.runner = "nextest"`](../reference/options/packages.md#packagesnametestrunner), for one package or in [`memberDefaults`](../reference/options/workspaces.md#workspacesnamememberdefaults); each test binary is still its own check |
| `cargoClippy` | a variant with [`mode = "clippy"`](../reference/options/workspaces.md#workspacesnamevariantsnamemode); the arguments after `--` in `cargoClippyExtraArgs` go in [`clippyArgs`](../reference/options/workspaces.md#workspacesnamevariantsnameclippyargs), and `--all-targets` is the default ([`allTargets`](../reference/options/workspaces.md#workspacesnamevariantsnamealltargets)) |
| `cargoFmt` | [`workspaces.<ws>.fmt.enable`](../reference/options/workspaces.md#workspacesnamefmtenable) |
| `cargoLlvmCov`, `cargoTarpaulin` | a variant with `mode = "coverage"`: instrumented products, and test runs that keep their raw profiles; no report |
| `cargoDoc` | `repo.workspaces.<ws>.target.<triple>.docs`, the folder `cargo doc` writes ([Documentation](../reference/outputs.md#documentation)); `--no-deps` is the default ([`docs.noDeps`](../reference/options/workspaces.md#workspacesnamedocsnodeps)); not in `repo.checks` |
| `cargoAudit`, `cargoDeny` | not covered |
| `cleanCargoSource`, `filterCargoSources`, a `fileset` source | automatic: one [source view](../explanation/configuration.md#source-views) per package; add files with [`extraSources`](../reference/options/packages.md#packagesnameextrasources), [`sources`](../reference/options/packages.md#packagesnamesources) and [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope) |
| `cargoExtraArgs` (`--features`, `-p`) | a variant's [`features`](../reference/options/workspaces.md#workspacesnamevariantsnamefeatures), [`noDefaultFeatures`](../reference/options/workspaces.md#workspacesnamevariantsnamenodefaultfeatures) and [`packages`](../reference/options/workspaces.md#workspacesnamevariantsnamepackages) |
| `CARGO_PROFILE` | a variant's [`profile`](../reference/options/workspaces.md#workspacesnamevariantsnameprofile) and [`testProfile`](../reference/options/workspaces.md#workspacesnamevariantsnametestprofile) |
| `env` and other attributes of the derivation | [`packages.<name>.env`](../reference/options/packages.md#packagesnameenv), [`forTarget.env`](../reference/options/packages.md#packagesnamefortargetenv), [`forHost.env`](../reference/options/packages.md#packagesnameforhostenv), per package |
| `nativeBuildInputs`, `buildInputs` | [`packages.<name>.nativeInputs`](../reference/options/packages.md#packagesnamenativeinputs) and [`inputs`](../reference/options/packages.md#packagesnameinputs), per package |
| a `preBuild` that copies a built artifact into the source (`ui/dist` for rust-embed) | [`packages.<name>.sourceOverlay`](../reference/options/packages.md#packagesnamesourceoverlay) |
| `postInstall` and other phases | a [stage](../explanation/products.md#your-own-stages-and-checks) ([`packages.<name>.stages`](../reference/options/packages.md#packagesnamestages)) |
| `overrideToolchain` | [`workspaces.<ws>.toolchain`](../reference/options/workspaces.md#workspacesnametoolchain) |
| `mkCrossToolchainEnv`, `CARGO_BUILD_TARGET` | the workspace's [`targets`](../reference/options/workspaces.md#workspacesnametargets) and a [preset](../reference/presets.md) per triple ([`targets.<triple>.preset`](../reference/options/targets.md#targetsnamepreset)) |
| `vendorCargoDeps` | [`repo.workspaces.<ws>.vendor`](../reference/outputs.md#vendor) |
| `devShell` | `repo.workspaces.<ws>.devShell` ([The dev shell](../explanation/configuration.md#the-dev-shell)) |

A product never runs tests, so `doCheck = false` has no counterpart. To
leave test runs out of `repo.checks`, use
[`targets.<triple>.tests`](../reference/options/workspaces.md#workspacesnametargetsnametests)
or [`test.binaries.<key>.enable`](../reference/options/packages.md#packagesnametestbinariesnameenable).

## A repository with several workspaces

A crane flake often calls `crane.mkLib` once per toolchain and builds
each workspace on its own. This repository has three Cargo workspaces,
each with its own `Cargo.lock`:

```text
rust-toolchain.toml        1.99.0, with the wasm32 target
Cargo.toml                 the host workspace: crates/*
crates/server/             a binary
components/greet/          a workspace of its own: a wasm component
tools/squares/             a workspace of its own, on a nightly:
  rust-toolchain.toml        a code generator
```

`server` embeds the `greet` component (`include_bytes!(env!("GREET_COMPONENT"))`),
and its build script runs the `squares` generator (`SQUARES_GEN`). The
component is built for `wasm32-unknown-unknown`, and its unit tests run
natively.

The flake passes one module to `mkRepository`. Its `pkgs` has
rust-overlay's overlay, for `rust-bin`:

```nix
repo = breakbulk.lib.mkRepository {
  inherit pkgs;
  root = self;
  modules = [ ./nix/rust.nix ];
};
```

The module:

```nix
# nix/rust.nix
{ pkgs, root, repo, breakbulk, ... }:
let
  wasm = "wasm32-unknown-unknown";
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  # rust-overlay's toolchains, from the files rustup reads.
  stable = pkgs.rust-bin.fromRustupToolchainFile (root + "/rust-toolchain.toml");
  nightly = pkgs.rust-bin.fromRustupToolchainFile (root + "/tools/squares/rust-toolchain.toml");
in
{
  workspaces = {
    # The root workspace, linted and format-checked.
    host = {
      path = ".";
      toolchain = {
        rustc = stable;
        cargo = stable;
      };
      fmt.enable = true;
      variants.clippy = {
        mode = "clippy";
        clippyArgs = [ "-D" "warnings" ];
      };
    };
    # Built for wasm32, tested natively.
    greet = {
      path = "components/greet";
      toolchain = {
        rustc = stable;
        cargo = stable;
      };
      targets = {
        ${wasm}.tests = false;
        ${native}.products = false;
      };
    };
    # The nightly workspace.
    squares = {
      path = "tools/squares";
      toolchain = {
        rustc = nightly;
        cargo = nightly;
      };
    };
  };

  targets.${wasm}.preset = breakbulk.presets.wasmComponent;

  # Products of the other workspaces, for the server's own units and its
  # build-script run.
  packages.server.forTarget.env = {
    GREET_COMPONENT = "${repo.workspaces.greet.target.${wasm}.packages.greet}/lib/greet.wasm";
    SQUARES_GEN = "${repo.workspaces.squares.packages.squares}/bin/squares";
  };
}
```

What each part replaces:

- **One `crane.mkLib` per toolchain** becomes each workspace's
  `toolchain`. Each workspace is planned with its own Cargo and
  lockfile. A preset picks its tools to match the rustc of the workspace
  that uses it.
- **`CARGO_BUILD_TARGET = "wasm32-unknown-unknown"`** becomes the
  workspace's `targets`. `tests = false` leaves out the wasm32 test
  binaries, and `products = false` leaves out the native products, so
  the component is built for wasm32 and tested natively. The
  `wasmComponent` preset turns the core module into a component.
- **A crane package passed into another derivation's environment**
  becomes a product in a package's `env`. Only the units of that package
  read it, so a new component rebuilds `server` and nothing else.
  `forTarget.env` keeps it off the build script's compile, which is a
  host unit ([sides](../explanation/configuration.md#host-and-target-sides)).
  The build-script run and `server`'s own units get it.

The outputs:

| Output | What it is |
| --- | --- |
| `repo.workspaces.host.packages.server` | the server binary (`bin/server`) |
| `repo.workspaces.greet.target.wasm32-unknown-unknown.packages.greet` | the component (`lib/greet.wasm`) |
| `repo.workspaces.squares.packages.squares` | the generator |
| `repo.checks` | every product, test run and doctest, `host/fmt` and the clippy check |

`workspaces.<ws>.packages` is the workspace's default target, here the
build machine's triple. Other targets are under
`workspaces.<ws>.target.<triple>`.

## What differs from crane's output

- **breakbulk always passes `--target`**, also for your own machine's
  triple. crane does not by default. So the project's rustflags
  (`build.rustflags` in `.cargo/config.toml`) do not reach build scripts,
  proc macros or their dependencies. A crate that is both a dependency
  and a build-dependency compiles twice, and a clippy variant lints such
  a member twice. See [Cargo with
  `--target`](../explanation/trade-offs.md#cargo-with---target).
- **The bytes differ.** Panic locations and debug information name
  remapped paths, not crane's `/build/source` or its vendor directory
  ([Source paths](../explanation/products.md#source-paths-and-debug-information)).
  The order of functions in a module can also differ. A test that pins
  the hash of a crane-built artifact needs a new pin. The new bytes are
  stable: a component ported from crane kept its function bodies, and
  `nix build --rebuild` gave the same bytes.
- **The linker is the one rustc would choose**, for the triple and Rust
  release, but nixpkgs' build of it, through nixpkgs' C compiler wrapper.
  Where a rust-lang toolchain links with its bundled `rust-lld`, crane
  links with that, outside the wrapper. See [Linker
  selection](../explanation/targets.md#linker-selection).
- **A workspace whose root `Cargo.toml` is also a package works.** That
  package's source view is the root directory without the other members'
  directories, so an edit to `flake.nix` or a README rebuilds it. Narrow
  it as in [Keep only what the root package builds
  from](filter-source.md#keep-only-what-the-root-package-builds-from).
- **A build script that runs Cargo** sees only its package's directory,
  with no network and no vendored dependencies. crane runs it in the
  whole source with the vendored dependencies. See [A build script runs
  Cargo](nested-cargo.md).
- **Tests are built in Cargo's `test` profile**, as `cargo test` builds
  them. crane's `cargoTest` uses `--release`. To match crane, set the
  variant's `testProfile = "release"`. The tests then also share their
  dependencies with the products
  ([Tests](../explanation/products.md#tests)).
- **There are more checks.** crane makes one check per function you
  call. breakbulk makes one per product, test binary, doctest, and check
  or clippy variant, named `<ws>/<triple>/<pkg>/test-<name>` and so on
  ([`checks`](../reference/outputs.md#checks)). Build them as groups:
  `checks.<system>.all`, one workspace, or your own patterns
  ([Run the checks in CI](ci.md)).
- **Test runs run in parallel.** crane runs one `cargo test` or nextest
  process. breakbulk runs up to `max-jobs` test runs at once, each with
  `$NIX_BUILD_CORES` test threads. A timing-sensitive test can time out.
  See [test threads](../explanation/products.md#tests).
- **A `Cargo.toml` edit plans the workspace again.** Planning runs Cargo
  over the manifests and the lockfile, and a source edit does not re-plan.
  crane rebuilds the dependencies after such an edit; breakbulk rebuilds
  only the units whose commands changed.
- **The first evaluation builds the plans.** In IFD mode, evaluation
  waits for each workspace's plan, which needs its crates' sources, so
  the first evaluation of a large workspace takes minutes. Later ones
  read the plans from the store
  ([Trade-offs](../explanation/trade-offs.md#costs)).
- **The dev shell is set up for Cargo.** crane's `devShell` adds the
  checks' inputs. `repo.workspaces.<ws>.devShell` also sets every
  package's `env`, the target's linker and rustflags, and
  `CARGO_BUILD_TARGET`, so local builds land in `target/<triple>/`, not
  `target/debug/`. When two packages set one variable to different
  values, the shell warns and keeps the last one
  ([The dev shell](../explanation/configuration.md#the-dev-shell)).
