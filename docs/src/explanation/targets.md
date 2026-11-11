# Targets and toolchains

A target is not a special case in breakbulk. Each one is a toolchain
spec, usually from a [preset](../reference/presets.md), chosen by the
target triple. For example, `x86_64-unknown-linux-musl` with
`presets.linuxStatic` gives nixpkgs' musl cross toolchain, mold as the
linker, and qemu (or a native builder) to run the tests.

To set a target up, see [Build for another target](../how-to/targets.md).
This page explains what each kind of target gets, and why.

## What works

| Target | Toolchain | Linker | Tests run on |
| --- | --- | --- | --- |
| `x86_64-unknown-linux-gnu` | yours | mold | the build machine |
| `aarch64-unknown-linux-gnu` | yours + nixpkgs cross | mold | an aarch64 builder, else qemu-user |
| `riscv64gc-unknown-linux-gnu` | yours + nixpkgs cross | mold | qemu-user |
| `{x86_64,aarch64}-unknown-linux-musl` | yours + nixpkgs musl cross | mold | a native builder, else qemu-user |
| your own triple, static glibc | yours + static archives | mold | the build machine |
| your own triple, old glibc (`linuxPortable`) | yours + `zig cc` | zig | the build machine's `ld.so` |
| `{x86_64,aarch64}-pc-windows-msvc` | yours + xwin SDK (unfree) | lld-link | wine (x86_64); none (aarch64) |
| `x86_64-pc-windows-gnu`, `-gnullvm` | yours + nixpkgs mingw-w64 cross | lld, through the MinGW C driver | wine |
| `aarch64-pc-windows-gnullvm` | yours + nixpkgs LLVM mingw-w64 cross | lld, through the MinGW C driver | none |
| `wasm32-unknown-unknown` | yours, with the target | wasm-ld | Node (wasm-bindgen's runner), headless Chromium or Firefox, or wasmtime |
| `wasm32-wasip2` | yours, with the target | rustc's wasm-component-ld | wasmtime |
| `x86_64-unknown-none` (build-std) | a nightly with `rust-src` | rustc's own | none: no `test` crate, so test binaries do not compile |

For a preset's target, "none" means nothing on the build machine runs the target's programs.
The test binaries and doctests still build, but their runs fail with a
message naming `targets.<triple>.runner` and `testSystem`, and they are
not in `repo.checks`, so `nix flake check` checks what can be checked.
Setting either option gives the target a runner and puts its runs back
(`target.<triple>.canRunTests` says which applies).

"Yours" means the toolchain you give the workspace (see below). macOS
targets do not work yet
([#13](https://github.com/schlarpc/breakbulk/issues/13)).

wasm tests run in Node by default. With `browser = "chromium"` or
`"firefox"`, every test runs in that headless browser, inside the Nix
sandbox:

| Sandbox gap | What the runner does |
| --- | --- |
| No `/etc/fonts`: Chromium aborts in its font code once a page loads ("Unable to receive message from renderer") | Points `FONTCONFIG_FILE` at a fontconfig file with DejaVu fonts (the runner's `fonts` argument) |
| Chromium's own sandbox (user namespaces), a small `/dev/shm` | Nothing: wasm-bindgen-test-runner always starts Chromium with `--no-sandbox` and `--disable-dev-shm-usage`. The Nix sandbox still contains the browser. |
| No writable home | `HOME` and the browser profile live under `$TMPDIR` |

Details: [Target traits and presets](internals/toolchains.md).

## Bring your own toolchain

Any rustc and cargo pair works: nixpkgs' `rustPlatform`, rust-overlay or
fenix, including a toolchain made from your `rust-toolchain.toml`. Set it
as the workspace's
[`toolchain`](../reference/options/workspaces.md#workspacesnametoolchain).
breakbulk runs your own cargo, so resolver and lockfile behavior match
your local builds.

Nightly and build-std work when you bring a nightly. breakbulk's defaults
never need one.

Supported Cargo releases are a rolling window: about the last six months
of stable, plus the current nightly.

- Newer features (`--remap-path-scope`, `trim-paths`) have fallbacks.
  Whether a toolchain has them is decided once, as its
  [`capabilities`](../reference/options/workspaces.md#workspacesnametoolchaincapabilities),
  from its version or by asking it. A patched or forked toolchain can
  override them.
- Older toolchains, MSRV builds and forked toolchains may work, but are
  not tested.

## Linker selection

A preset picks the linker from the target's traits. One function makes
the choice for every preset
(`presets.linkerKind`, used by `presets.chooseLinker`).
[`targets.<triple>.linker`](../reference/options/targets.md#targetsnamelinker)
and
[`host.linker`](../reference/options/targets.md#targetsnamehostlinker)
override it.

| Target | Linker |
| --- | --- |
| Linux | **mold**, through nixpkgs' wrapped C compiler |
| Linux, with cross-language LTO | clang with lld; C code compiled to bitcode by the same clang |
| Windows MSVC | `lld-link`, wrapped so that PDBs are reproducible |
| Windows MinGW (`-gnu`, `-gnullvm`) | the MinGW C driver with lld |
| wasm | `wasm-ld`; on `wasm32-wasip2`, rustc's `wasm-component-ld` over it |
| `linuxPortable` | zig's own linker (`zig cc`) |
| anything else | none: the preset fails at evaluation and names `targets.<triple>.linker` |

On Linux the link goes through nixpkgs' wrapper, so its rpath handling,
`NIX_LDFLAGS` and hardening flags apply. That works because each unit's
environment carries what nixpkgs' setup hooks set (see [Per-package
overrides](configuration.md#per-package-overrides)).

Every LLVM tool comes from the LLVM release that matches rustc's. Only
nixpkgs' rustc says which LLVM it uses, so breakbulk keeps a table of
Rust release to LLVM release, and asks `rustc -vV` for a rustc newer than
the table.

### Never rustc's own `rust-lld`

Since about Rust 1.90, rustc links `x86_64-unknown-linux-gnu` with its
bundled `rust-lld` by default. That bypasses the Nix linker wrapper.
rustc's opt-out is a rustflag, and rustflags never reach build scripts.
So every C-driver linker breakbulk uses (mold, clang with lld, MinGW,
zig) drops the two arguments rustc adds for it (`-fuse-ld=lld` and
`-B…/gcc-ld`).

The exceptions are targets without a preset, such as UEFI and bare metal
(`x86_64-unknown-none`): nixpkgs has no linker wrapper for them, so they
use the linker rustc's own target spec names.

## Windows msvc

The `windows` preset packages the usual MSVC cross setup:

- the CRT and Windows SDK from `xwin`, as a pinned fixed-output derivation
  (unfree: Microsoft's license);
- `lld-link` for linking;
- `clang-cl` and `llvm-lib` for C code, with the SDK's include paths for
  cc (`-imsvc`) and for bindgen (`-isystem`);
- `RC` and `LIB` for resource compilers;
- optional static CRT (`crtStatic`);
- wine as the test runner.

`extraSdks` adds further SDKs, such as the Windows Driver Kit.

## wasm

**Browser** (`wasmWeb`):

- The `wasm-bindgen-cli` version comes from `Cargo.lock` and must match
  exactly; a missing version is a clear error.
- C code compiles with an unwrapped clang for wasm32. A wrapped gcc can
  silently build host objects instead.

**Components** (`wasmComponent`):

- On `wasm32-unknown-unknown`, core modules become components with
  `wasm-tools component new`. They have no WASI imports. C code uses
  clang and nixpkgs' `wasilibc`, and the link uses that same wasi-libc.
- On `wasm32-wasip2`, std programs link straight to components with
  rustc's `wasm-component-ld`. The link keeps the wasi-libc bundled with
  Rust. C code compiles against the headers of the wasi-sdk release that
  Rust release bundles, so std, the C code and the library share one
  wasi-libc version.
- `wasm-opt` works on core modules, so it runs before componentizing.

## Static and musl

- **musl** targets use nixpkgs' musl cross toolchain with `crt-static`.
  The link uses Rust's own crt, `libc.a` and libunwind (nixpkgs' musl has
  no `libunwind.a`); C code compiles against nixpkgs' musl headers.
- **Static glibc** builds are static-pie.
- A static build of your own triple still names that triple as the
  target. So the static settings (rustflags, static `pkg-config`, static
  archive paths) reach only target units, and build scripts and proc
  macros stay dynamic. On the host, those settings would make build
  scripts link `libc.a` and crash.

## Portable Linux

`linuxPortable` builds programs that run on other Linux distributions,
like Python's manylinux wheels:

- It links against an old glibc (2.17 by default), with `zig cc`.
- Everything Nix provides is linked statically. At run time the program
  loads only glibc's libraries, GCC's runtime (`libgcc_s.so.1`,
  `libstdc++.so.6`) and the system libraries you name
  (`systemLibraries`, such as `libGL.so.1`).
- Native library inputs must be rebuilt as static libraries
  (`rebuildInputs`), and `pkg-config` runs in static mode.
- Two checks run on every product: one reads each binary's `NEEDED`
  entries, as auditwheel does, and fails on any other library; the other
  fails on any Nix store path in the product's files, which would not
  exist on another system.
- There is no bundling or rpath option: the product needs nothing next to
  it.

Tests run with the build machine's newer `ld.so`. A heavier check, run
outside `nix flake check`, also runs the product and its tests in a
CentOS 7 (glibc 2.17) container.

Details: [linuxPortable](internals/toolchains.md#linuxportable-zig).
