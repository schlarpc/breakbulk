# Presets

A preset is a target's toolchain, packaged: linker, C compiler, archiver,
rustflags, environment, test runner and default post-link stages for one
kind of target. Set it with
[`targets.<triple>.preset`](options/targets.md#targetsnamepreset):

```nix
targets.x86_64-unknown-linux-musl.preset = breakbulk.lib.presets.linuxStatic;
targets.x86_64-pc-windows-msvc.preset = breakbulk.lib.presets.windows { inherit sdk; };
```

A preset is used as is, or called with arguments first. It sets the
target's options at default priority, so any option you set on the same
target wins.

The preset is named for what you want; the target triple picks how:

| Preset | Produces | Triples |
| --- | --- | --- |
| `linux` | a normal Linux program | `*-unknown-linux-gnu` (`x86_64`, `aarch64`, `riscv64gc`, …) |
| `linuxStatic` | a self-contained static Linux program | `*-linux-musl` (musl), or your own `-gnu` triple (static-pie glibc) |
| `linuxPortable` | a program for any Linux with glibc at least a given version | your own `-gnu` triple |
| `windows` | a Windows program | `*-pc-windows-msvc` (MSVC), `*-pc-windows-gnu` and `*-gnullvm` (MinGW) |
| `wasmWeb` | wasm for browsers and Node, through wasm-bindgen | `wasm32-unknown-unknown` |
| `wasmComponent` | a WebAssembly component | `wasm32-unknown-unknown`, `wasm32-wasip2` |

## Defaults

- Your own machine's triple gets `linux` without any setting (or
  `linuxStatic` when `pkgs` is a musl package set).
- A target whose linker rustc chooses itself (UEFI, bare metal) needs no
  preset.
- Any other target without a preset fails at evaluation, naming
  `targets.<triple>.linker`.

## Arguments

| Preset | Arguments |
| --- | --- |
| `linux`, `linuxStatic` | `nativeBuilder`: run tests on a native builder for the target (see `testSystem`) instead of under qemu |
| `linuxPortable` | `glibc` (default `"2.17"`), `systemLibraries`: sonames a product may load besides glibc's (`[ "libGL.so.1" ]`), `rebuildInputs`: nixpkgs libraries to rebuild against that glibc (`[ "openssl" ]`) |
| `windows` (MSVC) | `sdk`: the CRT and Windows SDK from `breakbulk.lib.xwinSdk` (required), `crtStatic` (default `false`), `extraSdks` |
| `windows` (MinGW) | `crtStatic` (default `true`) |
| `wasmWeb` | `browser`: the test runner, `"node"` (default) |
| `wasmComponent` | `withC`: compile C code for the component |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree; [Build for another target](../how-to/targets.md#windows-msvc)
shows how to get them. [Targets and
toolchains](../explanation/targets.md) explains what each preset sets up.
