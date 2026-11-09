# Targets and toolchains

breakbulk's targets are presets, not special cases: each is a toolchain spec chosen by the target triple. Linux gnu and musl on x86\_64, aarch64 and riscv64, static glibc, portable Linux (old glibc), browser and component wasm, wasip2, Windows msvc and MinGW, and build-std targets work. Darwin does not yet ([#13](https://github.com/schlarpc/breakbulk/issues/13)).

| Target | Toolchain | Linker | Runner |
| --- | --- | --- | --- |
| x86\_64-unknown-linux-gnu | user's (e.g. from `rust-toolchain.toml`) | mold | native |
| aarch64-unknown-linux-gnu | user's + nixpkgs cross | mold | native aarch64 builder, else qemu-user |
| {x86\_64,aarch64}-unknown-linux-musl | user's + nixpkgs musl cross | mold or lld | native builder, else qemu-user |
| wasm32-unknown-unknown | user's, with target | lld (wasm flavor) | Node through wasm-bindgen's test runner (headless Chromium crashes in the sandbox, [#8](https://github.com/schlarpc/breakbulk/issues/8)), or wasmtime |
| {x86\_64,aarch64}-pc-windows-msvc | user's + xwin SDK (unfree) | lld-link | wine |
| Host triple, fully static glibc | user's + static archives | mold | native |
| wasm32-wasip2 | rustup-dist with target, + the matching wasi-sdk sysroot's headers for C | rustc's wasm-component-ld over version-matched wasm-ld | wasmtime |
| riscv64gc-unknown-linux-gnu | user's + nixpkgs cross | mold | qemu-user |
| x86\_64-pc-windows-gnu, x86\_64-pc-windows-gnullvm | user's + nixpkgs mingw-w64 cross (gcc/msvcrt; LLVM/ucrt) | lld through the mingw C driver | wine |
| Host triple, old glibc (`linuxPortable`, zig) | user's + `zig cc` | zig (its lld) | native, through the build machine's `ld.so` |
| x86\_64-unknown-none (build-std) | nightly with `rust-src`, user-supplied | rustc's own (rust-lld) | none |
| aarch64-apple-darwin (not yet) | user's, built on Mac builders | ld64 or lld | native |

## Bring your own toolchain

Any rustc/cargo pair works: nixpkgs `rustPlatform`, rust-overlay or fenix, including `fromRustupToolchainFile`. The planner runs the user's own cargo, so resolver and lockfile behavior match local builds. Nightly and build-std work when the user brings a nightly; the tool's defaults never need one.

Supported Cargo releases form a rolling window: roughly the last six months of stable, plus current nightly. Features newer than the floor (`--remap-path-scope`, `trim-paths`) have fallbacks; whether a toolchain has them is decided once, as its capabilities (from its version, or by asking it), and a vendor-forked toolchain can override them. Repositories pinned to older toolchains, MSRV variants and vendor-forked toolchains may work but are not tested.

## Linker selection

The linker is chosen automatically as a pure function of target, host and LTO mode, recorded in the plan, and overridable. One function makes the choice (`presets.chooseLinker`, with the decision itself in `presets.linkerKind`); every preset and the host spec call it, and [`targets.<t>.linker`](../reference/options/targets.md#targetsnamelinker) (or [`host.linker`](../reference/options/targets.md#targetsnamehostlinker)) overrides it.

- Linux ELF on a Linux host: **mold**, through nixpkgs' wrapped bintools. The native target gets the Linux preset by default, so this holds with no configuration. The wrapper's rpath handling, `NIX_LDFLAGS` and hardening flags apply because the unit environment carries the variables nixpkgs' setup hooks set (see [Per-package overrides](configuration.md#per-package-overrides)).
- Cross-language LTO (`-Clinker-plugin-lto`) or non-Linux host: **lld** from the LLVM release that matches rustc's (from a version table, because only nixpkgs' rustc names its LLVM; a rustc newer than the table is asked with `rustc -vV` at evaluation time).
- Where rustc's target spec names the linker itself (wasm, wasip2): defer to it, and only make sure the version-matched `lld` is the one found.
- Windows msvc: `lld-link` from the matching LLVM, wrapped so PDBs are reproducible. Windows MinGW (`-gnu`, `-gnullvm`): the toolchain's C driver with lld. The `linuxPortable` preset's zig backend asks for zig's own linker (`zig cc`).
- Any other target has no rule and fails at evaluation, naming `targets.<t>.linker`.
- Never rustc's self-contained `rust-lld`, which bypasses the Nix linker wrapper. rustc uses it by default on `x86_64-unknown-linux-gnu` since about 1.90, and its opt-out is a rustflag that cannot reach build scripts, so every C-driver linker wrapper (mold, clang with lld, MinGW, zig) drops the `-fuse-ld=lld` and `-B…/gcc-ld` arguments rustc adds.

## Windows msvc

The preset packages the common cross pattern once: an `xwin` CRT and SDK fixed-output derivation with pinned versions and `meta.license` unfree; `lld-link`; `clang-cl` and `llvm-lib` for C code; `-imsvc` include paths for cc and the same paths as `-isystem` for bindgen; `RC` and `LIB` for resource compilers; optional `crt-static`; and wine as the runner. It has an extension point for further SDKs, such as the Windows Driver Kit.

## wasm

- **Browser.** The `wasm-bindgen-cli` version is read from `Cargo.lock` and matched exactly; a missing version is a clear error. C code is compiled with an unwrapped clang targeting wasm32. A wrapped gcc can silently emit host objects instead.
- **Components.** Core modules from `wasm32-unknown-unknown` are componentized with `wasm-tools component new`, which gives components with no WASI imports. `wasm32-wasip2` std builds link straight to components with rustc's own `wasm-component-ld`. C code for `wasm32-unknown-unknown` components uses clang plus nixpkgs `wasilibc`, and the link uses that same wasi-libc (`-C link-self-contained=no`). On wasip2 the link keeps the wasi-libc bundled with Rust (turning it off also drops the program's `crt1-command.o`), and C code compiles against the headers of the wasi-sdk release that Rust release bundles, fetched as a fixed-output sysroot from a table of Rust release to wasi-sdk release; std, the C code and the library linked share one wasi-libc version.
- `wasm-opt` operates on core modules, so component pipelines run it before componentizing.

## Static and musl

Musl targets use nixpkgs cross toolchains with `crt-static`; the link uses Rust's self-contained crt, `libc.a` and libunwind (nixpkgs' musl has no `libunwind.a`), while C code compiles against nixpkgs' musl headers. Static glibc builds are static-pie by default. A static build on the host triple passes the host triple explicitly as the target, so target rustflags (`crt-static`, static relocation, static archive search paths) reach only target units, while build scripts and proc macros stay dynamic. Static-only environment (static `pkg-config` mode on musl and static glibc alike, static archive paths) is scoped to target units by platform, because on the host it makes build scripts link `libc.a` and crash.

## Portable Linux

`linuxPortable` builds Linux programs that run on other distributions, in the manner of Python's manylinux wheels: linked against an old glibc (2.17 by default), with everything Nix provides linked statically, so the program loads nothing at run time but glibc's own libraries, GCC's runtime (`libgcc_s.so.1`, `libstdc++.so.6`, as manylinux allows) and the system libraries the user names (`systemLibraries`, such as `libGL.so.1`). Native library inputs are rebuilt as static libraries only (`rebuildInputs`), pkg-config runs in static mode, and a default check reads each binary's `NEEDED` entries, as auditwheel does, and fails on any other library. A second default check fails on any Nix store path named anywhere in the product's files, with an allow-list: on another system nothing is there (a static OpenSSL's compiled-in configuration directory, for one, is rebuilt to point at `/etc/ssl`). There is no bundling or rpath option: the product needs nothing next to it. Its one backend is zig (`zig cc`). It is a same-triple preset: host units keep the host linker through the linker rewrite. Zig rebuilds its libc in an empty per-sandbox cache, so the preset includes a derivation that pre-warms that cache; zig's own wrapper copies it into the unit's `$TMPDIR` (zig cannot use a read-only cache), so the unit builder needs no zig special case. Tests run through the build machine's newer `ld.so`; a heavy check also runs the product and tests inside a CentOS 7 (glibc 2.17) container.
