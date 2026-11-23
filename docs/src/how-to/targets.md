# Build for another target

This page builds a workspace for a target other than the machine you are
on: a static musl binary, another architecture, Windows or wasm.

## A complete example

This flake builds the `app` package as a static musl binary:

```nix
{
  inputs = {
    breakbulk.url = "github:schlarpc/breakbulk";
    nixpkgs.follows = "breakbulk/nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, breakbulk, rust-overlay }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      # A toolchain with the target's standard library.
      rust = pkgs.rust-bin.stable.latest.minimal.override {
        targets = [ "x86_64-unknown-linux-musl" ];
      };
      repo = breakbulk.lib.mkRepository {
        inherit pkgs;
        root = self;
        modules = [{
          workspaces.default.toolchain = { rustc = rust; cargo = rust; };
          workspaces.default.targets.x86_64-unknown-linux-musl = { };
          targets.x86_64-unknown-linux-musl.preset = breakbulk.lib.presets.linuxStatic;
        }];
      };
    in
    {
      packages.${system}.default =
        repo.workspaces.default.target.x86_64-unknown-linux-musl.packages.app;
    };
}
```

`nix build` gives `result/bin/app`, a static-pie executable.

The rest of this page explains each part.

## The toolchain

nixpkgs' `rustc` has the standard library for your own machine only. For
another target, use a toolchain that includes it.
[rust-overlay](https://github.com/oxalica/rust-overlay) makes one with
`rust-bin.<channel>.<version>.minimal.override { targets = [ … ]; }`, or
from your `rust-toolchain.toml` with `rust-bin.fromRustupToolchainFile`.
Set it as the workspace's
[`toolchain`](../reference/options/workspaces.md#workspacesnametoolchain).

`nixpkgs.follows = "breakbulk/nixpkgs"` uses breakbulk's pinned nixpkgs,
whose cross toolchains breakbulk is tested with. Your own nixpkgs works
too.

## The targets

[`workspaces.<ws>.targets`](../reference/options/workspaces.md#workspacesnametargets)
says which targets a workspace builds. Once you list any, only those are
built: add your own machine's triple too (`x86_64-unknown-linux-gnu = { };`)
if you still want native products.

[`targets.<triple>`](../reference/options/targets.md) sets a target's toolchain for every
workspace that builds it. Its
[`preset`](../reference/options/targets.md#targetsnamepreset) is the usual way: a preset
sets the linker, C compiler, runner and post-link stages for that kind of
target. Choose one from [Presets](../reference/presets.md):

| You want | Triple | Preset |
| --- | --- | --- |
| A static Linux binary | `x86_64-unknown-linux-musl` | `presets.linuxStatic` (the default) |
| A Linux binary for another architecture | `aarch64-unknown-linux-gnu` | `presets.linux` (the default) |
| A Linux binary for old distributions | your own triple | `presets.linuxPortable { glibc = "2.17"; }` |
| A Windows program | `x86_64-pc-windows-gnu` | `presets.windows` (the default) |
| A Windows program (MSVC) | `x86_64-pc-windows-msvc` | `presets.windows { inherit sdk; }` (below) |
| A WebAssembly component | `wasm32-wasip2` | `presets.wasmComponent` (the default) |
| wasm for browsers | `wasm32-unknown-unknown` | `presets.wasmWeb` |
| wasm for browsers, tests in headless Chromium | `wasm32-unknown-unknown` | `presets.wasmWeb { browser = "chromium"; }` |

A triple whose preset needs no arguments gets it without any setting,
marked "the default" above: `workspaces.default.targets.aarch64-unknown-linux-gnu = { };`
is enough. So does a UEFI triple (`presets.uefi`), and a bare-metal
triple (`presets.bareMetal`: `x86_64-unknown-none`,
`thumbv7em-none-eabihf`, `riscv32imac-unknown-none-elf`, …), which links
with the toolchain's own `rust-lld`, or nixpkgs' lld for a toolchain
that ships none.

A triple whose preset needs arguments or a choice has no default: an
`-msvc` triple (the SDK), macOS (the SDK, `presets.darwin`) and
`wasm32-unknown-unknown` (`presets.wasmWeb` or
`presets.wasmComponent`). Building one with no preset and no `linker`
fails at evaluation, naming the preset to set. To build any target with
the toolchain as Cargo finds it, set `preset = null`.

A cross Linux triple's default preset uses nixpkgs' cross toolchain for
it, which a binary cache may not have: see
[Trade-offs](../explanation/trade-offs.md#costs).

## Another linker

A preset links with the linker rustc itself would use: lld or GNU ld on
Linux, through nixpkgs' C compiler. To use another one, such as mold,
set the target's
[`linkerKind`](../reference/options/targets.md#targetsnamelinkerkind):

```nix
targets.x86_64-unknown-linux-gnu.linkerKind = "mold";
```

On your own machine's triple, build scripts and proc macros link with it
too. [Presets](../reference/presets.md#linkers) lists the kinds.

## The outputs

Every target's products are under `target.<triple>`:

```nix
repo.workspaces.default.target.x86_64-unknown-linux-musl.packages.app
```

`repo.workspaces.<ws>.packages` and the dev shell use one target, the
workspace's [`defaultTarget`](../reference/options/workspaces.md#workspacesnamedefaulttarget):
your own machine's triple when it is listed, else the only target, else
the one the project's `.cargo/config.toml` names in `build.target`. Set
`defaultTarget` to choose another. See [Outputs](../reference/outputs.md)
for everything under `target.<triple>`.

## Some packages only

A variant plans every member of the workspace. Four of its options
narrow that:
[`packages`](../reference/options/workspaces.md#workspacesnamevariantsnamepackages)
(every plan),
[`tests`](../reference/options/workspaces.md#workspacesnamevariantsnametests)
(test binaries, runs and doctests),
[`products`](../reference/options/workspaces.md#workspacesnamevariantsnameproducts)
and
[`benches`](../reference/options/workspaces.md#workspacesnamevariantsnamebenches).
Each takes `true` (all of `packages`), `false` (none, and that plan is
not traced), a list of packages, or the packages to leave out. For
every variant on one target, set them in the target's
[`variantDefaults`](#different-features-per-target):

```nix
workspaces.default.targets = {
  # cargo test --workspace --exclude uap-bench --exclude 'fuzz-*'
  x86_64-unknown-linux-gnu.variantDefaults.tests.exclude = [ "uap-bench" "fuzz-*" ];
  wasm32-unknown-unknown.variantDefaults.packages = [ "ui" ];
};
```

A variant's own setting wins over them: `variants.<v>.tests = true`
tests a variant on every target.

`{ exclude = [ … ]; }` selects what `--workspace --exclude` selects, so
you can copy the `--exclude` list from your CI. An entry is a package
name or a glob pattern as Cargo takes it (`*`, `?`, `[…]`, `[!…]`). An
entry that matches no member is an error; Cargo only warns.

A target that is only built or only tested has `tests = false` or
`products = false`. Crates that ship as wasm but run their unit tests
natively are one example:

```nix
workspaces.default.targets = {
  wasm32-unknown-unknown.variantDefaults.tests = false;
  x86_64-unknown-linux-gnu.variantDefaults.products = false;
};
```

On a check variant (clippy's too), `tests = false` checks what plain `cargo
check` builds (libraries and binaries), and `products = false` checks
the test plan only.

For any other selection, compute a list from
[`workspaces.<ws>.members`](../reference/options/workspaces.md#workspacesnamemembers),
the name and directory of each member:

```nix
{ config, lib, ... }:
let
  members = config.workspaces.default.members;
in
{
  # The packages under crates/wasm/.
  workspaces.default.targets.wasm32-unknown-unknown.variantDefaults.packages =
    lib.attrNames (lib.filterAttrs (_: m: lib.hasPrefix "crates/wasm/" m.path) members);
}
```

## Different features per target

When you control the crate, prefer `cfg` and target-specific
dependencies (`[target.'cfg(windows)'.dependencies]`): they also work
under plain Cargo. Use the options below for crates whose own features
are the switch, as a CI matrix would pass
`--target wasm32-unknown-unknown --no-default-features --features web`.

A target's
[`variantDefaults`](../reference/options/workspaces.md#workspacesnametargetsnamevariantdefaults)
applies to every variant on that target:

```nix
workspaces.default.targets = {
  x86_64-unknown-linux-gnu = { };
  x86_64-pc-windows-msvc.variantDefaults.features = [ "windows" ];
  wasm32-unknown-unknown.variantDefaults = {
    noDefaultFeatures = true;
    features = [ "web" ];
  };
};
```

One variant can differ on one target with
[`variants.<v>.target.<triple>`](../reference/options/workspaces.md#workspacesnamevariantsnametarget),
which takes any variant option:

```nix
workspaces.default.imports = [
  (breakbulk.variants.clippy {
    # No test harness on wasm: lint the libraries and bins only.
    variant.target.wasm32-unknown-unknown.tests = false;
  })
];
workspaces.default.variants.minimal = {
  noDefaultFeatures = true;
  # Not even the target's `windows` feature.
  target.x86_64-pc-windows-msvc.features = lib.mkForce [ ];
};
workspaces.default.variants.default = {
  # Test runs in repo.checks on wasm only.
  checks.tests = false;
  target.wasm32-unknown-unknown.checks.tests = true;
};
```

The layers apply in this order:

| Order | Layer |
| --- | --- |
| 1 | `workspaces.<ws>.variantDefaults` |
| 2 | `targets.<triple>.variantDefaults` |
| 3 | `variants.<v>` |
| 4 | `variants.<v>.target.<triple>` |

[`workspaces.<ws>.variantDefaults`](../reference/options/workspaces.md#workspacesnamevariantdefaults)
holds settings for every variant of the workspace, on every target.

Lists such as `features` concatenate, in this order. A single value,
such as `profile` or `checks.tests`, set in two layers takes the later layer's
value: a variant's own setting wins over the target's defaults, as a
package's own settings win over `memberDefaults`. A fact about the
target that every variant must keep takes `lib.mkForce` in
`variantDefaults`. To replace the other layers' lists, use `lib.mkForce`
on a list. See [Layers and priorities](#layers-and-priorities).

### Features and package selections

`variantDefaults.features` reach every variant on the target as
written. A variant that selects packages
([`packages`](../reference/options/workspaces.md#workspacesnamevariantsnamepackages)),
such as each package-scope run of
[`breakbulk.variants.featurePowerset`](feature-matrix.md), is planned
with `-p <pkg> --features …`. Cargo then accepts only a selected
package's own features and optional dependencies, `<pkg>/<feature>` and
`<dependency>/<feature>`, and planning fails on any other.

To give such variants only the features they accept, make
`variantDefaults` a function of the variant's settings, and test each
feature with
`breakbulk.lib.acceptsFeature member feature`, Cargo's rule for one
member of
[`workspaces.<ws>.members`](../reference/options/workspaces.md#workspacesnamemembers):

```nix
{ config, lib, breakbulk, ... }:
let
  members = config.workspaces.default.members;
  # Every feature for a variant of the whole workspace; for one that
  # selects packages, those one of its packages accepts.
  accepted =
    variant: features:
    if builtins.isList variant.packages then
      lib.filter (
        f: lib.any (p: breakbulk.lib.acceptsFeature members.${p} f) variant.packages
      ) features
    else
      features;
in
{
  workspaces.default.targets.x86_64-pc-windows-msvc.variantDefaults =
    { config, ... }:
    {
      features = accepted config [ "windows" "app/gui" ];
    };
}
```

With it, a run of `core` gets `windows` if `core` has that feature, and
never `app/gui` unless `app` is a dependency of `core`. The function
reads the variant's settings with every layer applied.
`variantDefaults.noDefaultFeatures = true` applies to every run, so a
run with default features becomes the same as its `no-default-features`
run on that target.

## Package settings per target or variant

A package's settings
([`packages.<name>`](../reference/options/packages.md)) can apply to
one triple only, with
[`target.<triple>`](../reference/options/packages.md#packagesnametarget),
or to one variant's plans only, with
[`variant.<v>`](../reference/options/packages.md#packagesnamevariant).
Both take every package option:

```nix
packages.openssl-sys.target.x86_64-pc-windows-msvc.forTarget.env.OPENSSL_DIR = opensslWin;
packages.app = {
  # Lint settings for the clippy variant only: the other variants'
  # units do not change, so they are not rebuilt.
  variant.clippy.env.APP_LINT = "1";
  # A library that only the `full` variant needs, on one triple.
  variant.full.target.x86_64-unknown-linux-gnu.inputs = p: [ p.openssl ];
};
```

A variant layer applies in every workspace that has a variant of that
name. A name that no workspace has is an evaluation warning.

The layers of one `packages.<name>` apply in this order:

| Order | Layer |
| --- | --- |
| 1 | `packages.<name>` |
| 2 | `packages.<name>.target.<triple>` |
| 3 | `packages.<name>.variant.<v>` |
| 4 | `packages.<name>.variant.<v>.target.<triple>` |

`workspaces.<ws>.memberDefaults` and `sysDefaults.packages` have the
same layers, under those of `packages.<name>`
([layer order](../explanation/configuration.md#shared-settings-and-layer-order)).
Lists concatenate in this order and `env` merges. A single value, such
as `test.runner`, set in two layers takes the later layer's value.

## Layers and priorities

In both kinds of layers, a more specific layer wins over the layers it
refines. You do not need `lib.mkForce` for that. The module system's
priorities still apply between layers:

- A value with a higher priority wins, whatever its layer.
  `lib.mkForce` (priority 50) in `variants.<v>` wins over a plain value
  in `variants.<v>.target.<triple>`.
- `lib.mkDefault` (priority 1000) loses to a plain value in any layer.
- Between values of the same priority, the later layer wins.

breakbulk does this by changing priorities, and the module system
merges the layers. In `workspaces.<ws>.variantDefaults`, a single
value's priority number is raised by 0.5, in
`targets.<triple>.variantDefaults` by 0.25, and in
`variants.<v>.target.<triple>` it is lowered by 0.5. So a plain value is
100.5 and 100.25 in the two `variantDefaults`, 100 in `variants.<v>`
and 99.5 in `variants.<v>.target.<triple>`, and `lib.mkOverride 99` in
any layer wins over all four. Package layers get fractions between 0 and 1 the
same way, lowest layer least. Lists keep their priority, so that they
still concatenate, and are ordered by layer.

The same goes for the single values inside attribute sets and
submodules: each variable of `env`, each stage of `stages` and each
check of `checks`, `test.binaries.<key>.enable`. A priority around a
whole set is the module system's: `env = lib.mkForce { FOO = "a"; }`
replaces every definition of `env` at a lower priority, in any layer,
while `env.FOO = lib.mkForce "a"` forces one variable. A stage of
`stages` is one value: a higher layer's replaces it whole.

## A custom target

A target rustc does not know by name (a `.json` target spec, or an OS
breakbulk has no table entry for) works, but its products need
[`traits`](../reference/options/targets.md#targetsnametraits): the facts
breakbulk otherwise reads from its built-in table for the triple.

For a `.json` target spec, name the target after the file and give the
file as
[`rustcTarget`](../reference/options/targets.md#targetsnamerustctarget):

```nix
targets."my-board".rustcTarget = ./boards/my-board.json;
```

Cargo names a `.json` target by its file stem. It reads the target's
`linker` and `rustflags` from `[target.my-board]` and
`CARGO_TARGET_MY_BOARD_*`, puts its outputs in `target/my-board/`, and
gives build scripts `TARGET=my-board`, so cc-rs reads `CC_my_board`.
breakbulk uses the same name everywhere, and a file with another stem
is an evaluation error. Cargo and rustc get a copy of the file named
`my-board.json`.

Custom target specs are unstable: the workspace needs a nightly
toolchain, and the variant needs
`cargoConfig.unstable.json-target-spec = true`. rustc also needs
`-Zunstable-options` for a `.json` target; when your Cargo does not pass
it, add it to `cargoConfig.build.rustflags`.

Some facts come from rustc and need no traits. The planner asks your
rustc for the target's spec, so the executable suffix of the stored
binaries and which units get a `debug` output follow the `.json` file.

The products still read the table. The names of the root files in the
`linked` stage (`product.rootFiles`) and the `install` layout (which
suffixes go to `bin/` or `lib/`, where shared libraries and debug side
files go) are fixed when Nix evaluates the product, before anything
builds, so rustc cannot supply them. The check `target-traits-rustc`
compares the table with rustc for every built-in target; for your own
target, you state the facts. Give the base fields and the rest is
derived from them, then set any derived field that differs from your
spec:

```nix
targets."my-board".traits = {
  # Base fields: rustc's target_* cfg values.
  arch = "x86_64";
  vendor = "unknown";
  os = "none";
  env = "";
  abi = "";
  families = [ ];
  # The spec's "exe-suffix".
  executableSuffix = ".elf";
};
```

The file-name and layout fields are `executableSuffix`,
`sharedLibraryPrefix`, `sharedLibrarySuffix`, `staticLibraryPrefix`,
`staticLibrarySuffix` (the spec's `exe-suffix`, `dll-prefix`,
`dll-suffix`, `staticlib-prefix`, `staticlib-suffix`), `sharedLibraryDir`
(`"bin"` where DLLs are found beside the executable, `"lib"` elsewhere),
`debugArtifacts` (the debuginfo side files `install` places), and
`isWindows` and `isWasm`. Without traits, building a product fails with
a message naming `targets.<triple>.traits`. The linker kind, the test
runner and the default debug handling read the traits too, unless you
set [`linker`](../reference/options/targets.md#targetsnamelinker),
[`runner`](../reference/options/targets.md#targetsnamerunner) and
[`debugInfo`](../reference/options/targets.md#targetsnamedebuginfo)
yourself.

## Windows (MSVC)

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree. `breakbulk.lib.xwinSdk` downloads them with
[xwin](https://github.com/Jake-Shadle/xwin) as a fixed-output derivation;
pass it to the `windows` preset:

```nix
let
  sdk = breakbulk.lib.xwinSdk {
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "xwin-sdk";
    };
    manifestVersion = 17;
    crt = "14.44.17.14";
    sdk = "10.0.26100";
    arches = [ "x86_64" ];
    hash = nixpkgs.lib.fakeHash;
  };
in
modules = [{
  workspaces.default.targets.x86_64-pc-windows-msvc = { };
  targets.x86_64-pc-windows-msvc.preset = breakbulk.lib.presets.windows { inherit sdk; };
}];
```

To fill in the versions and the hash:

1. `manifestVersion` is the Visual Studio major version whose channel
   xwin reads; 17 is Visual Studio 2022.
2. List what that channel offers:

   ```sh
   nix run nixpkgs#xwin -- --accept-license --manifest-version 17 list
   ```

   The CRT version is in the `Microsoft.VC.<version>.CRT…` package names
   (`14.44.17.14`), the SDK version in the `Win11SDK_<version>…` names
   (`10.0.26100`). Running this accepts Microsoft's license, as calling
   `xwinSdk` does.
3. Build once with `hash = nixpkgs.lib.fakeHash`. The error prints the
   real hash; put it in place of `fakeHash`.

Tests run under wine. See [Targets and
toolchains](../explanation/targets.md#windows-msvc) for what the preset
sets up.

## macOS

On a Linux machine, `presets.darwin` builds `aarch64-apple-darwin` and
`x86_64-apple-darwin` programs. It needs Apple's macOS SDK, and you have
to pass it yourself. Apple's
[Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)
allows the SDK only on Apple-branded computers. So breakbulk never
downloads it on Linux by default, and without `sdk` the preset fails at
evaluation. Whether to use the SDK there is your own decision.

`breakbulk.lib.appleSdk` gives you the same download of the SDK that
nixpkgs uses on a Mac, marked unfree:

```nix
let
  sdk = breakbulk.lib.appleSdk {
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "macOS-SDK";
    };
    version = "14.4";
  };
in
modules = [{
  workspaces.default.targets.aarch64-apple-darwin = { };
  targets.aarch64-apple-darwin.preset = breakbulk.lib.presets.darwin { inherit sdk; };
}];
```

`version` is one that nixpkgs pins (14.4, 15.5, 26.5 or 27.0 at the time
of writing). `sdk` can also be your own package of an SDK directory; give
`sdkVersion` with it when it has no `version` attribute. The toolchain
needs the target (`targets = [ "aarch64-apple-darwin" ]` in
rust-overlay).

Each product is signed ad hoc, as macOS on Apple silicon requires, and
its debug information is a `.dSYM` bundle in the `debug` output, next to
where the file lands (`bin/app.dSYM`). Nothing on Linux runs macOS
programs, so test binaries build but do not run unless
`nativeBuilder = true` sends them to a Mac builder. See [Targets and
toolchains](../explanation/targets.md#macos) for what the preset sets
up.
