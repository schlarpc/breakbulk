# Write a preset

A preset is a module of a target's options, the same options
[`targets.<triple>`](../reference/options/targets.md) has. The built-in
presets in `breakbulk.lib.presets` are written this way, and yours can do
anything they do. This page shows how to write one.

## A preset is a module

Set your module as the target's
[`preset`](../reference/options/targets.md#targetsnamepreset):

```nix
targets.aarch64-unknown-linux-gnu.preset = { config, lib, pkgs, name, toolchain, ... }: {
  linker = lib.mkDefault "${pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc}/bin/aarch64-unknown-linux-gnu-cc";
  rustflags = [ "-C" "target-cpu=cortex-a72" ];
  env.MY_BOARD = lib.mkDefault "1";
};
```

breakbulk evaluates the target's options once per workspace that builds
the triple, and imports the preset into that evaluation. The preset gets
these module arguments:

| Argument | Value |
| --- | --- |
| `config` | The target's options, as set by everything: `config.traits` (the target's [traits](../explanation/internals/toolchains.md#target-traits)), `config.linkerKind`, `config.packageSet`, … |
| `pkgs` | The `pkgs` given to `mkRepository` |
| `name` | The target's name: its triple |
| `toolchain` | The workspace's [toolchain](../reference/options/workspaces.md#workspacesnametoolchain): `rustc`, `cargo`, … |

Set values with `lib.mkDefault`, so the user's own settings on the target
win without `lib.mkForce`. Lists (`rustflags`, `cflags`) concatenate with
the user's.

## Add stages and checks

A stage's fields merge one by one, so set each with `lib.mkDefault`. The
user can then change one field and keep the others:

```nix
{ lib, breakbulk, ... }: {
  stages.sign = {
    after = lib.mkDefault "install";
    run = lib.mkDefault mySigner;
  };
  checks.size.run = lib.mkDefault sizeCheck;
}
```

```nix
# The user's settings: the preset's `run`, after another stage.
targets.<triple>.stages.sign.after = "zip";
```

`null` removes a stage or a check: `targets.<triple>.stages.sign = null`.

## Give the preset options

A preset with options is a function from the options to the module:

```nix
let
  board = { cpu ? "generic" }: { lib, ... }: {
    rustflags = [ "-C" "target-cpu=${cpu}" ];
  };
in
{
  targets.aarch64-unknown-linux-gnu.preset = board { cpu = "cortex-a72"; };
}
```

## Choose from the traits with `lib.mkIf`

The names a module defines cannot depend on `config`: the module system
reads every module's names before any option's value. Read `config` in
values and in `lib.mkIf` conditions, never to choose which attributes to
return:

```nix
{ config, lib, ... }: lib.mkMerge [
  (lib.mkIf (config.traits.env == "musl") { rustflags = [ "-C" "target-feature=+crt-static" ]; })
  (lib.mkIf (config.traits.env == "gnu") { env.MY_LIBC = lib.mkDefault "glibc"; })
]
```

`if config.traits.env == "musl" then { … } else { … }` fails with
"infinite recursion".

## Build on a built-in preset

Import one and set more:

```nix
targets.x86_64-unknown-linux-gnu.preset = { lib, ... }: {
  imports = [ breakbulk.lib.presets.linux ];
  rustflags = [ "-C" "target-cpu=x86-64-v3" ];
};
```
