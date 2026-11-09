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

A target whose linker rustc chooses itself (UEFI, bare metal) needs no
preset: `workspaces.default.targets.x86_64-unknown-uefi = { };` is
enough.

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
