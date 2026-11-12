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
| A static Linux binary | `x86_64-unknown-linux-musl` | `presets.linuxStatic` |
| A Linux binary for another architecture | `aarch64-unknown-linux-gnu` | `presets.linux` |
| A Linux binary for old distributions | your own triple | `presets.linuxPortable { glibc = "2.17"; }` |
| A Windows program | `x86_64-pc-windows-gnu` | `presets.windows` |
| A Windows program (MSVC) | `x86_64-pc-windows-msvc` | `presets.windows { inherit sdk; }` (below) |
| wasm for browsers | `wasm32-unknown-unknown` | `presets.wasmWeb` |
| wasm for browsers, tests in headless Chromium | `wasm32-unknown-unknown` | `presets.wasmWeb { browser = "chromium"; }` |

A target whose linker rustc chooses itself (UEFI, bare metal) needs no
preset: `workspaces.default.targets.x86_64-unknown-uefi = { };` is
enough.

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

A target plans every member of the workspace. Three options of
`workspaces.<ws>.targets.<triple>` narrow that:
[`packages`](../reference/options/workspaces.md#workspacesnametargetsnamepackages)
(both plans),
[`tests`](../reference/options/workspaces.md#workspacesnametargetsnametests)
(test binaries, runs and doctests) and
[`products`](../reference/options/workspaces.md#workspacesnametargetsnameproducts).
Each takes a list of packages, or the packages to leave out:

```nix
workspaces.default.targets = {
  # cargo test --workspace --exclude uap-bench --exclude 'fuzz-*'
  x86_64-unknown-linux-gnu.tests.exclude = [ "uap-bench" "fuzz-*" ];
  wasm32-unknown-unknown.packages = [ "ui" ];
};
```

`{ exclude = [ … ]; }` selects what `--workspace --exclude` selects, so
you can copy the `--exclude` list from your CI. An entry is a package
name or a glob pattern as Cargo takes it (`*`, `?`, `[…]`, `[!…]`). An
entry that matches no member is an error; Cargo only warns. A variant's
[`packages`](../reference/options/workspaces.md#workspacesnamevariantsnamepackages)
takes the same forms.

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
  workspaces.default.targets.wasm32-unknown-unknown.packages =
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
workspaces.default.variants.clippy = {
  mode = "clippy";
  # No test harness on wasm: lint the libraries and bins only.
  target.wasm32-unknown-unknown.allTargets = false;
};
workspaces.default.variants.minimal = {
  noDefaultFeatures = true;
  # Not even the target's `windows` feature.
  target.x86_64-pc-windows-msvc.features = lib.mkForce [ ];
};
workspaces.default.variants.default = {
  # Test runs in repo.checks on wasm only.
  checks = false;
  target.wasm32-unknown-unknown.checks = true;
};
```

The layers apply in this order:

| Order | Layer |
| --- | --- |
| 1 | `variants.<v>` |
| 2 | `targets.<triple>.variantDefaults` |
| 3 | `variants.<v>.target.<triple>` |

Lists such as `features` concatenate. A single value, such as `profile`
or `checks`, set in two layers takes the later layer's value. To replace
the other layers' lists, use `lib.mkForce` on a list. See [Layers and
priorities](#layers-and-priorities).

`breakbulk.variants.packageFeaturePowerset` runs keep their own
`features`, `noDefaultFeatures` and `allFeatures` over `variantDefaults`:
each run selects one package (`-p`), and Cargo rejects a feature that
the selected package does not have
([priorities](#layers-and-priorities)).

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
Lists concatenate and `env` merges. A single value, such as
`test.runner`, set in two layers takes the later layer's value.

## Layers and priorities

In both kinds of layers, a more specific layer wins over the layers it
refines. You do not need `lib.mkForce` for that. The module system's
priorities still apply between layers:

- A value with a higher priority wins, whatever its layer.
  `lib.mkForce` (priority 50) in `variants.<v>` wins over a plain value
  in `variants.<v>.target.<triple>`.
- `lib.mkDefault` (priority 1000) loses to a plain value in any layer.
- Between values of the same priority, the later layer wins.

For variant layers, breakbulk does this by changing priorities. In
`targets.<triple>.variantDefaults`, a single value's priority number is
lowered by 0.25. In `variants.<v>.target.<triple>`, it is lowered by 0.5.
So a plain value is 100 in `variants.<v>`, 99.75 in `variantDefaults`
and 99.5 in `variants.<v>.target.<triple>`, and `lib.mkOverride 99` in
any layer wins over all three. Lists keep their priority, so that they
still concatenate.

Package layers are separate settings blocks. breakbulk compares their
single values by the same rule.

`breakbulk.variants.packageFeaturePowerset` gives each run's
`features`, `noDefaultFeatures` and `allFeatures` priority 90, so they
win over `variantDefaults`. To change them in the run's own
`target.<triple>`, use `lib.mkForce`.

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
