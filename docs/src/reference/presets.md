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
- A target whose linker rustc chooses itself needs no preset (below).
- Any other target needs a preset, or at least
  [`targets.<triple>.linker`](options/targets.md#targetsnamelinker).
  Without one, Cargo uses rustc's default linker for the triple, usually
  `cc`, which does not link for another architecture.

These targets build with no preset. rustc's target spec names its own
`rust-lld`, and the product has only the `install` stage:

| Triple | Product |
| --- | --- |
| `x86_64-unknown-uefi`, `aarch64-unknown-uefi` | a `.efi` program, its PDB in the `debug` output |
| bare metal (`x86_64-unknown-none`, …) | an ELF program |
| `wasm32-wasip1` | a core module, with the WASI libc that ships with rustc |
| `wasm32-unknown-unknown` | a core module, without wasm-bindgen or `wasm-opt` |

```nix
targets.wasm32-wasip1 = { };
```

Such a target has no C compiler and no test runner. A crate with C code
needs [`cc`](options/targets.md#targetsnamecc) for the target, and test
runs need a [`runner`](options/targets.md#targetsnamerunner) (wasmtime
for `wasm32-wasip1`).

## Arguments

| Preset | Arguments |
| --- | --- |
| `linux`, `linuxStatic` | `nativeBuilder`: run tests on a native builder for the target (see `testSystem`) instead of under qemu |
| `linux` | `crossLanguageLto`: LTO across Rust and C; clang and lld from rustc's LLVM, C compiled to bitcode (`-flto=thin`) |
| `linuxPortable` | `glibc` (default `"2.17"`), `systemLibraries`: sonames a product may load besides glibc's (`[ "libGL.so.1" ]`), `rebuildInputs`: nixpkgs libraries to rebuild against that glibc (`[ "openssl" ]`) |
| `windows` (MSVC) | `sdk`: the CRT and Windows SDK from `breakbulk.lib.xwinSdk` (required), `crtStatic` (default `false`), `extraSdks` |
| `windows` (MinGW) | `crtStatic` (default `true`) |
| `wasmWeb` | `browser`: where tests run, `"node"` (default), `"chromium"` or `"firefox"` (headless) |
| `wasmComponent` | `withC`: compile C code for the component |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree; [Build for another target](../how-to/targets.md#windows-msvc)
shows how to get them. [Targets and
toolchains](../explanation/targets.md) explains what each preset sets up.
