# Presets

A target's toolchain comes from a preset. The target triple picks the
mechanism.

| Preset | Produces | Example triples |
| --- | --- | --- |
| `linux` | a normal Linux program (the native default) | `x86_64-unknown-linux-gnu`, `aarch64-…`, `riscv64gc-…` |
| `linuxStatic` | a self-contained static Linux program | `*-linux-musl`, or the host triple with static glibc |
| `linuxPortable` | a program for any Linux with glibc at least a given version | the host triple |
| `windows` | a Windows program (MSVC or MinGW) | `*-pc-windows-msvc`, `*-pc-windows-gnu`, `*-gnullvm` |
| `wasmWeb` | wasm for browsers and Node, through wasm-bindgen | `wasm32-unknown-unknown` |
| `wasmComponent` | a WebAssembly component | `wasm32-unknown-unknown`, `wasm32-wasip2` |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree. breakbulk downloads them with `breakbulk.xwinSdk`.

A target's preset is set by `targets.<triple>.preset`; see the
[module options](options.md).
