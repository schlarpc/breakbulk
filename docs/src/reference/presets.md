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
| `linuxStatic` (glibc) | `staticLibDirs`: directories of static archives to link, `relocationModel`: `"static"` for a non-PIE executable (default: static-pie, rustc's own) |
| all | `linkerKind`: the [linker kind](#linkers), as `targets.<triple>.linkerKind` sets it |
| `linuxPortable` | `glibc` (default `"2.17"`), `systemLibraries`: sonames a product may load besides glibc's (`[ "libGL.so.1" ]`), `rebuildInputs`: nixpkgs libraries to rebuild against that glibc (`[ "openssl" ]`) |
| `windows` (MSVC) | `sdk`: the CRT and Windows SDK from `breakbulk.lib.xwinSdk` (required), `crtStatic` (default `false`), `extraSdks` |
| `windows` (MinGW) | `crtStatic` (default `true`) |
| `wasmWeb` | `browser`: where tests run, `"node"` (default), `"chromium"` or `"firefox"` (headless) |
| `wasmComponent` | `withC`: compile C code for the component |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree; [Build for another target](../how-to/targets.md#windows-msvc)
shows how to get them. [Targets and
toolchains](../explanation/targets.md) explains what each preset sets up.

## Linkers

By default a preset links with the linker rustc itself would use for the
triple and the workspace's Rust release, always through nixpkgs' tools
and never with rustc's bundled `rust-lld`.
[`targets.<triple>.linkerKind`](options/targets.md#targetsnamelinkerkind)
picks another kind. It applies to the target's units, and to build
scripts and proc macros when the triple is your own machine's.

```nix
targets.x86_64-unknown-linux-gnu.linkerKind = "mold";
```

| Kind | Default for | The linker, and where it comes from |
| --- | --- | --- |
| `lld` | Linux targets that rustc links with its bundled lld | nixpkgs' wrapped C compiler with `-fuse-ld=lld`; lld from `llvmPackages_<major>`, rustc's LLVM major release |
| `cc` | other Linux targets (musl, and any with nixpkgs' rustc) | nixpkgs' wrapped C compiler with its default linker, GNU ld |
| `mold` | none | nixpkgs' wrapped C compiler with `-fuse-ld=mold`; nixpkgs' mold |
| `clang-lld` | `linux { crossLanguageLto = true; }` | clang and lld from `llvmPackages_<major>`, rustc's LLVM major release |
| `lld-link` | Windows MSVC | `lld-link` from `llvmPackages_<major>`, wrapped so that PDBs are reproducible |
| `mingw-lld` | Windows MinGW | the MinGW C compiler with nixpkgs' default lld |
| `wasm-ld` | wasm, except `wasm32-wasip2` | `wasm-ld` from `llvmPackages_<major>`, not rustc's `rust-lld` |
| `wasm-component-ld` | `wasm32-wasip2` | rustc's own `wasm-component-ld`, with `wasm-ld` from `llvmPackages_<major>` under it |

`linuxPortable` links with `zig cc`, which its `backend` sets; it takes
no other kind.

rustc links with its bundled lld where its build turns that on: the
rust-lang builds (rustup, rust-overlay, fenix) for an x86\_64 Linux build
machine, for `x86_64-unknown-linux-gnu` from Rust 1.90 (on nightly from
1.80) and for every `-linux-gnu` target from Rust 1.92. nixpkgs' rustc
is built without lld.

`rustc.llvmPackages` names the LLVM of nixpkgs' rustc. For other
toolchains the LLVM major release comes from a table of Rust releases, or
from `rustc -vV`. The lld is then nixpkgs' build of upstream LLVM with
that major release, not Rust's LLVM fork: its output is close to
`rust-lld`'s, but not byte-identical. To reproduce a build made with
`rust-lld` byte for byte, set
[`targets.<triple>.linker`](options/targets.md#targetsnamelinker).

A kind that cannot work is an evaluation error that names both sides:
a kind for another kind of target (`mold` for Windows), `mold` with
`crossLanguageLto` (cross-language LTO needs a linker that reads LLVM
bitcode, `clang-lld`), and `mold` with `relocationModel = "static"`
(mold 3.0.0 links non-PIE static glibc Rust programs that crash at
startup; `lld` and `cc` do not).

mold and lld lay out a program differently. The linker records itself in
the ELF `.comment` section (`Linker: LLD 23.1.3`, `mold 3.0.0`), and a
large program linked with mold had a 3.9 MB larger symbol table and
about 1 MB smaller loaded sections than with lld.
