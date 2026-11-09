# Build for another target

This page builds a workspace for a target other than the machine you are
on: a static musl binary, another architecture, Windows or wasm.

## 1. Use a toolchain that has the target

nixpkgs' `rustc` has the standard library for your own machine only. For
another target, use a toolchain that includes it, for example from
[rust-overlay](https://github.com/oxalica/rust-overlay):

```nix
let
  rust = pkgs.rust-bin.stable.latest.minimal.override {
    targets = [ "x86_64-unknown-linux-musl" ];
  };
in
modules = [{
  workspaces.default.toolchain = { rustc = rust; cargo = rust; };
}];
```

## 2. List the targets

```nix
modules = [{
  workspaces.default.targets.x86_64-unknown-linux-musl = { };
  targets.x86_64-unknown-linux-musl.preset = breakbulk.lib.presets.linuxStatic;
}];
```

[`workspaces.<ws>.targets`](../reference/options/workspaces.md#workspacesnametargets) says which targets a workspace builds. Once you
list any, only those are built: add your own machine's triple too
(`x86_64-unknown-linux-gnu = { };`) if you still want native products.
`targets.<triple>` sets the target's toolchain for every workspace; its
[`preset`](../reference/options/targets.md#targetsnamepreset) picks one of the [presets](../reference/presets.md). A target
whose linker rustc chooses itself (UEFI, bare metal) needs no preset.

## 3. Build

Every target's products are under `target.<triple>`:

```nix
repo.workspaces.default.target.x86_64-unknown-linux-musl.packages.app
```

When a workspace lists exactly one target, `packages` and the dev shell
use it. With several, they use the target the project's
`.cargo/config.toml` names in `build.target`, or [`defaultTarget`](../reference/options/workspaces.md#workspacesnamedefaulttarget) if you
set it.

## Windows (MSVC)

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree. `breakbulk.lib.xwinSdk` downloads them as a fixed-output
derivation; pass it to the `windows` preset:

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
    hash = "sha256-…";  # from the first build's error
  };
in
modules = [{
  workspaces.default.targets.x86_64-pc-windows-msvc = { };
  targets.x86_64-pc-windows-msvc.preset = breakbulk.lib.presets.windows { inherit sdk; };
}];
```

Tests run under wine. See [Targets and
toolchains](../explanation/targets.md#windows-msvc) for what the preset
sets up.
