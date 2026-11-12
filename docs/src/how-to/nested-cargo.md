# A build script runs Cargo

Some build scripts run Cargo themselves. They build another member of the
workspace, often for another target (a wasm guest, a firmware image), and
embed the result or read files next to it. Some tests do the same: they
spawn `cargo run`, or use `trybuild`, which runs Cargo on generated
crates.

breakbulk cannot analyse such a build. It plans from one Cargo
invocation, and the nested Cargo only starts when the build script runs,
inside one unit. breakbulk sees one build-script run, not the units in it.
So it cannot build them as their own derivations, share them with the
rest of the build, or cache them one by one.

This page shows how to let the nested build run, what that costs, and how
to avoid it.

## Let it run

In the sandbox, a build-script run lacks three things a nested Cargo
needs:

- **The workspace.** A unit sees only its package's directory. The nested
  Cargo reads the root `Cargo.toml`, `Cargo.lock` and the members it
  builds. Add them with
  [`extraSources`](../reference/options/packages.md#packagesnameextrasources).
- **The dependencies.** There is no network and no `~/.cargo`.
  [`workspaces.<ws>.vendor`](../reference/outputs.md#vendor) has every
  locked dependency, and `vendor.cargoHome` is a Cargo home that uses
  them, offline.
- **A home.** `HOME` is `/homeless-shelter`, which does not exist. Setting
  `CARGO_HOME` covers this too.

For a workspace whose `outer` package has a build script that runs
`$CARGO build -p inner --target-dir $OUT_DIR/nested`:

```nix
{ repo, ... }:
{
  packages.outer = {
    extraSources = [ "Cargo.toml" "Cargo.lock" "inner" ];
    forTarget.env.CARGO_HOME = repo.workspaces.default.vendor.cargoHome;
  };
}
```

[`forTarget`](../reference/options/packages.md#packagesnamefortargetenv)
gives the variable to the build-script run and not to the build script's
compile, which then does not rebuild
([Host and target sides](../explanation/configuration.md#host-and-target-sides)).
The setting names the repository it configures. This is not an infinite
recursion, because the vendor directory depends only on `Cargo.lock`. It
works in both delivery modes.

The rest of the run's environment is as under Cargo:

- `CARGO` and `RUSTC` name the workspace's toolchain. There is no
  `RUSTC_WRAPPER`.
- `CARGO_ENCODED_RUSTFLAGS` holds the target's rustflags, including those
  of its preset. The nested Cargo reads them and passes them to the units
  it builds for the target. Without `--target`, these include the nested
  build's build scripts and proc macros.
- The target's linker does not reach the nested Cargo. Cargo tells the
  build script about it in `RUSTC_LINKER`, but Cargo itself does not read
  that variable. The nested build links with `cc` from `PATH`. To choose
  another linker, set `CARGO_TARGET_<TRIPLE>_LINKER` next to `CARGO_HOME`.
- For a nested build for another target (`--target wasm32-wasip1`), the
  workspace's toolchain must have that target's standard library.

The source directory is read-only, so the build script must put its
target directory somewhere writable, such as under `OUT_DIR`. Most
scripts do.

## What it costs

- **The whole workspace is an input of the build-script run.** Any edit
  to the paths in `extraSources` runs it again. Then every unit that
  depends on the package rebuilds, and their tests run again. List only
  what the nested build reads.
- **Nothing in the nested build is shared.** The inner crates and their
  dependencies compile inside the one build-script run, every time it
  runs. They are not shared with the same crates in the plan, with other
  variants, or with other packages that run the same nested build.
- **Source paths are not hidden.** The nested build gets none of
  breakbulk's path remapping
  ([Source paths and debug information](../explanation/products.md#source-paths-and-debug-information)).
  Its artifacts keep the store paths of the run's source directory and of
  the crate sources it compiled, in debug information and panic
  messages. When the product embeds such an artifact, Nix finds these
  paths in its bytes, and they become runtime dependencies of the
  product. Its
  [`noSourceReferences`](../reference/options/packages.md#packagesnamechecks)
  check then fails and names them. Remove the check
  (`packages.outer.checks.noSourceReferences = null`) only if shipping
  the sources with the product is acceptable.

## Avoid it

These ways are in order of what they ask of the project.

### The build script takes prebuilt artifacts

Many build scripts that run Cargo also read an environment variable that
names a prebuilt artifact, and skip the nested build when it is set. Then
build the inner crate as a product, for its own target if needed, and
pass it in `env`:

```nix
{ repo, ... }:
{
  packages.outer.forTarget.env.INNER_WASM =
    "${repo.workspaces.default.target.wasm32-wasip1.packages.inner}/bin/inner.wasm";
}
```

The inner crate is then a set of ordinary units: shared, cached, and
with remapped paths. Only `outer`'s build-script run and what depends on
it wait for the product.
[Products as inputs](../explanation/configuration.md#products-as-inputs)
explains the details, including the limits in dynamic-derivation mode.

### Change the build script

If the build script has no such variable, add one: read the variable,
and run Cargo only when it is not set. This is a small change, and other
packagers can use it too.

### A stand-in `cargo`

If you cannot change the project, put a script named `cargo` on the
build-script run's `PATH` and in `CARGO`. It answers the build script's
Cargo commands by copying products to where the script looks for them.
For a script that runs `cargo build -p inner --target wasm32-wasip1
--target-dir <dir>`:

```nix
{ repo, pkgs, ... }:
let
  inner = repo.workspaces.default.target.wasm32-wasip1.packages.inner;
  cargo = pkgs.writeShellScriptBin "cargo" ''
    set -euo pipefail
    case "$*" in
      "build -p inner --target wasm32-wasip1 --target-dir "*) ;;
      *) echo "cargo stand-in: unexpected command: $*" >&2; exit 1 ;;
    esac
    dest="''${@: -1}/wasm32-wasip1/debug"
    mkdir -p "$dest"
    cp ${inner}/bin/inner.wasm "$dest/"
    chmod -R u+w "$dest"
  '';
in
{
  packages.outer.forTarget = {
    nativeInputs = _: [ cargo ];
    env.CARGO = "${cargo}/bin/cargo";
  };
}
```

It fails on every command it does not know, so a change in the build
script shows up as an error. Two traps:

- **Keep source store paths out of what the stand-in returns.** If the
  script also runs `cargo metadata`, the stand-in prints canned output.
  That output must not contain the store path of the source (in package
  ids, manifest paths or the workspace root). That path changes with
  every edit in the repository. So the stand-in would change too, and
  the build-script run and everything after it would rebuild on every
  edit. Compute the output once, replace the source path with a fixed
  string, and write the result with `pkgs.writeText`.
- **Look for scripts that fall back silently.** Some build scripts check
  whether a file exists and do something else when it does not, without
  an error. For example, one in wasmtime embeds an empty component when
  `../Cargo.toml` is missing. Read the script, and check the product.

## Tests that run Cargo

A test that spawns `cargo run` or uses `trybuild` needs the same things in
its test run: the workspace, the dependencies and a home. It also needs
tools that `cargo test` takes from your shell.

```nix
{ repo, pkgs, ... }:
let
  ws = repo.workspaces.default;
in
{
  packages.app.test = {
    sourceScope = [ "Cargo.toml" "Cargo.lock" "crates/inner" ];
    env = {
      CARGO_HOME = ws.vendor.cargoHome;
      CARGO_TARGET_DIR = "/tmp/nested-target";
    };
    path = [
      (pkgs.writeShellScriptBin "rustc" ''
        unset LD_LIBRARY_PATH
        exec ${ws.toolchain.rustc}/bin/rustc "$@"
      '')
      pkgs.stdenv.cc
    ];
  };
}
```

- [`test.sourceScope`](../reference/options/packages.md#packagesnametestsourcescope)
  adds the workspace files to the test's view only, so the library and
  bins of `app` do not depend on them. `extraSources` works too, for
  every unit of the package.
- [`test.env`](../reference/options/packages.md#packagesnametestenv)
  sets the Cargo home, and a target directory outside the read-only
  source. Tools that ask Cargo for the target directory follow
  `CARGO_TARGET_DIR`.
- `CARGO` is set, as under `cargo test`. `rustc` and a C compiler for
  linking are not on the test run's `PATH`, so
  [`test.path`](../reference/options/packages.md#packagesnametestpath) adds
  them.
- With nixpkgs' `rustc`, the wrapper above is needed. A test run's
  dynamic-library path holds a copy of the toolchain's target libraries,
  and with nixpkgs' `rustc` this includes `librustc_driver`. A `rustc`
  that loads that copy takes the copy's directory as its sysroot, and
  fails with "can't find crate for `core`". A rust-overlay toolchain
  keeps `librustc_driver` elsewhere, unless it has the `rustc-dev`
  component.

The costs are the same as for a build script: the test runs again after
any edit to these paths, and its nested build is shared with nothing.
