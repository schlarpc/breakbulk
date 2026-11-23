# Presets

A preset is a target's toolchain, packaged: linker, C compiler, archiver,
rustflags, environment, test runner and default post-link stages for one
kind of target. Set it with
[`targets.<triple>.preset`](options/targets.md#targetsnamepreset):

```nix
targets.x86_64-unknown-linux-musl.preset = breakbulk.lib.presets.linuxStatic;
targets.x86_64-pc-windows-msvc.preset = breakbulk.lib.presets.windows { inherit sdk; };
```

A preset is a module of the target's options. It is used as is, or
called with arguments first. It sets the target's options with
`lib.mkDefault`, so any option you set on the same target wins, and its
stages field by field. [Write a preset](../how-to/write-a-preset.md)
shows how to make your own.

The preset is named for what you want; the target triple picks how:

| Preset | Produces | Triples |
| --- | --- | --- |
| `linux` | a normal Linux program | `*-unknown-linux-gnu` (`x86_64`, `aarch64`, `riscv64gc`, …) |
| `linuxStatic` | a self-contained static Linux program | `*-linux-musl` (musl), or your own `-gnu` triple (static-pie glibc) |
| `linuxPortable` | a program for any Linux with glibc at least a given version | your own `-gnu` triple |
| `windows` | a Windows program | `*-pc-windows-msvc` (MSVC), `*-pc-windows-gnu` and `*-gnullvm` (MinGW) |
| `darwin` | a macOS program, built on Linux | `aarch64-apple-darwin`, `x86_64-apple-darwin` |
| `wasmWeb` | wasm for browsers and Node, through wasm-bindgen | `wasm32-unknown-unknown` |
| `wasmComponent` | a WebAssembly component | `wasm32-unknown-unknown`, `wasm32-wasip2` |
| `uefi` | a `.efi` program, its PDB in the `debug` output | `*-unknown-uefi` (`x86_64`, `aarch64`, `i686`) |

## Defaults

- A target gets a preset without any setting when that preset needs no
  arguments for its triple:

  | Triple | Default preset |
  | --- | --- |
  | your own machine's | `linux` (`linuxStatic` when `pkgs` is a musl package set) |
  | another `*-linux-gnu*` | `linux` |
  | `*-linux-musl*` | `linuxStatic` |
  | `*-pc-windows-gnu`, `*-gnullvm` | `windows` |
  | `wasm32-wasip2` | `wasmComponent` |
  | `*-unknown-uefi` | `uefi` |

  Options set on the target override the preset's, as with any preset;
  `preset = null` turns it off.
- A triple whose preset needs arguments or a choice has no default:
  `*-pc-windows-msvc` and macOS (their presets need the SDK), and
  `wasm32-unknown-unknown` (`wasmWeb` or `wasmComponent`). Such a target
  with no preset and no
  [`linker`](options/targets.md#targetsnamelinker) fails at
  evaluation, naming the preset to set.
- `preset = null` builds any target with the toolchain as Cargo finds
  it. A target whose linker rustc chooses itself needs no more (below).
- Any other target needs a preset, or at least
  [`targets.<triple>.linker`](options/targets.md#targetsnamelinker).
  Without one, Cargo uses rustc's default linker for the triple, usually
  `cc`, which does not link for another architecture.

These targets build with no preset. rustc's target spec names its own
`rust-lld`, and the product has only the `install` stage:

| Triple | Product |
| --- | --- |
| bare metal (`x86_64-unknown-none`, …) | an ELF program |
| `wasm32-wasip1` | a core module, with the WASI libc that ships with rustc |
| `wasm32-unknown-unknown`, with `preset = null` | a core module, without wasm-bindgen or `wasm-opt` |

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
| `linuxPortable` | `glibc` (default `"2.17"`), `systemLibraries`: sonames a product may load besides glibc's (`[ "libGL.so.1" ]`), `overlays`: nixpkgs overlays for the package set that builds library inputs against that glibc |
| `windows` (MSVC) | `sdk`: the CRT and Windows SDK from `breakbulk.lib.xwinSdk` (required), `crtStatic` (default `false`), `extraSdks` |
| `windows` (MinGW) | `crtStatic` (default `true`) |
| `darwin` | `sdk`: the macOS SDK, a package or a version for `breakbulk.lib.appleSdk` (required on Linux), `sdkVersion`: its version when the package has no `version`, `deploymentTarget`: the oldest macOS to run on, as `MACOSX_DEPLOYMENT_TARGET` for rustc and C build systems (default: rustc's, read at build time: `11.0` on arm64, `10.12` on x86\_64), `nativeBuilder`: run tests on a Mac builder |
| `wasmWeb` | `browser`: where tests run, `"node"` (default), `"chromium"` or `"firefox"` (headless) |
| `wasmComponent` | `withC`: compile C code for the component |

The MSVC toolchain needs Microsoft's CRT and Windows SDK, which are
unfree; [Build for another target](../how-to/targets.md#windows-msvc)
shows how to get them. The `darwin` preset needs Apple's macOS SDK, which
is unfree too and which breakbulk never fetches on its own on Linux
([macOS](../how-to/targets.md#macos)). [Targets and
toolchains](../explanation/targets.md) explains what each preset sets up.

## Linkers

By default a preset links with the linker rustc itself would use for the
triple and the workspace's Rust release, through nixpkgs' tools and not
with rustc's bundled `rust-lld`. macOS from Linux is the exception:
rustc's own linker there is Apple's, which does not run on Linux, so the
default is `rust-lld` when the toolchain ships it.
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
| `lld-link` | Windows MSVC, UEFI | `lld-link` from `llvmPackages_<major>`, wrapped so that PDBs are reproducible |
| `mingw-lld` | Windows MinGW | the MinGW C compiler with lld from `llvmPackages_<major>`, rustc's LLVM major release |
| `wasm-ld` | wasm, except `wasm32-wasip2` | `wasm-ld` from `llvmPackages_<major>`, not rustc's `rust-lld` |
| `wasm-component-ld` | `wasm32-wasip2` | rustc's own `wasm-component-ld`, with `wasm-ld` from `llvmPackages_<major>` under it |
| `rust-lld` | macOS on a Linux machine, with a rust-lang toolchain (rustup, rust-overlay, fenix) | the toolchain's own `rust-lld` as `ld64.lld`, whose LLVM is rustc's |
| `ld64.lld` | macOS on a Linux machine, with a toolchain that ships no `rust-lld` (nixpkgs' rustc) | `ld64.lld` from `llvmPackages_<major>` |

`linuxPortable` links with `zig cc` (the `zig` kind); it takes no other kind.

### Your own linker kind

[`targets.<triple>.linkerKinds`](options/targets.md#targetsnamelinkerkinds)
holds the kinds `linkerKind` may name, and takes more. A linker that a C
compiler driver runs with a flag is built with
`breakbulk.lib.presets.ccDriverLinker`, as the `cc`, `lld` and `mold`
kinds are, so rustc's own `-fuse-ld=lld` never bypasses nixpkgs' linker
wrapper:

```nix
targets.x86_64-unknown-linux-gnu = {
  linkerKinds.wild = {
    on = traits: traits.isLinux;
    what = "Linux";
    build = { packageSet, ... }: breakbulk.lib.presets.ccDriverLinker {
      inherit packageSet;
      cc = (packageSet.stdenvAdapters.useWildLinker packageSet.stdenv).cc;
      flag = "-fuse-ld=wild";
    };
  };
  linkerKind = "wild";
};
```

A kind may also say when it cannot link (`incompatible`) and whether it
reads LLVM bitcode (`bitcode`); a preset may add kinds to the targets it
sets up.

rustc links with its bundled lld where its build turns that on: the
rust-lang builds (rustup, rust-overlay, fenix) for an x86\_64 Linux build
machine, for `x86_64-unknown-linux-gnu` from Rust 1.90 (on nightly from
1.80) and for every `-linux-gnu` target from Rust 1.92. nixpkgs' rustc
is built without lld.

`rustc.llvmPackages` names the LLVM of nixpkgs' rustc. For other
toolchains the LLVM major release comes from a table of Rust releases, or
from `rustc -vV`. For a toolchain these misjudge (one built from source,
a fork), set the workspace's
[`toolchain.facts`](options/workspaces.md#workspacesnametoolchainfacts)
(`llvmMajor`, `llvmPackages`, `bundledLld`) once; every target follows. The lld is then nixpkgs' build of upstream LLVM with
that major release, not Rust's LLVM fork: its output is close to
`rust-lld`'s, but not byte-identical. To reproduce a build made with
`rust-lld` byte for byte, set
[`targets.<triple>.linker`](options/targets.md#targetsnamelinker).

On macOS the SDK has its own say. Each SDK version lists what its
linker must support, and a linker that lacks it is an evaluation error,
never a quiet switch to the other kind:

| SDK | The linker must | Which LLD does |
| --- | --- | --- |
| 14.4, 15.5, 26.5 | nothing more | any |
| 27.0 and later | read the `arm64e.x1` CPU subtype in the SDK's `.tbd` stub files | LLD 23.1.3 and later (Rust 1.100), and nixpkgs' lld of every major, which carries the fix as a patch |

So Rust 1.99's `rust-lld` (LLD 23.1.1) cannot link against SDK 27.0. The
error names the SDK, the requirement and the linker's LLD version, and
the ways out: an older SDK, a newer toolchain, or `linkerKind =
"ld64.lld"`. Cross-language LTO needs the linker's LLVM to be rustc's,
which `rust-lld`'s always is.

A kind that cannot work is an evaluation error that names both sides:
a kind for another kind of target (`mold` for Windows), `mold` with
`crossLanguageLto` (cross-language LTO needs a linker that reads LLVM
bitcode, `clang-lld` or `lld`), and `mold` with `relocationModel = "static"`
(mold 3.0.0 links non-PIE static glibc Rust programs that crash at
startup; `lld` and `cc` do not).

mold and lld lay out a program differently. The linker records itself in
the ELF `.comment` section (`Linker: LLD 23.1.3`, `mold 3.0.0`), and a
large program linked with mold had a 3.9 MB larger symbol table and
about 1 MB smaller loaded sections than with lld.

## Test runners

`breakbulk.lib.testRunners` has values for
[`test.runner`](options/packages.md#packagesnametestrunner), what starts a
test or bench binary in its run (see
[Tests](../explanation/products.md#tests)). It is not the target runner
([`targets.<triple>.runner`](options/targets.md#targetsnamerunner)),
which starts every program of a target and which a test runner starts
the binary under.

**`direct`** (the default) runs the binary itself with the run's `args`,
as `cargo test` and `cargo bench` do. It speaks libtest's protocol:
`RUST_TEST_THREADS` is `$NIX_BUILD_CORES` unless the environment set it,
and `#[ignore]` tests run only with `--include-ignored` or `--ignored` in
`args`.

**`nextest { profile ? "default"; configFile; package ? null; }`** runs
the one binary under cargo-nextest's reuse-build mode, with the project's
nextest configuration: retries, timeouts, default filter, test groups.
`configFile` defaults to the workspace's `.config/nextest.toml` when it
exists (`null`: none); `package` is the cargo-nextest to use (`null`: the
test machine's). The run's `args` go after `--`, which nextest emulates
(`--skip`, `--exact`, `--include-ignored`). It builds the binary list and
the `cargo metadata` nextest reads from the run's facts at build time:
every path package the test plan compiles with its Cargo targets, so
`package()`, `binary()`, `binary_id()`, `deps()` and `rdeps()` filters
match as under Cargo. `test-threads` is `$NIX_BUILD_CORES`, in a tool
configuration, which the project's profile and `NEXTEST_TEST_THREADS`
override. nextest's store (JUnit reports) is
`$TMPDIR/nextest-ws/target/nextest`, for
[`postRun`](options/packages.md#packagesnametestpostrun). A bench
without the libtest harness (Criterion) cannot be listed by nextest:
give it `bench.runner = breakbulk.lib.testRunners.direct`.

```nix
workspaces.main.memberDefaults.test.runner =
  breakbulk.lib.testRunners.nextest { profile = "ci"; };
```

A test runner of your own is a function from the run's facts to a shell
snippet that runs the tests. The snippet runs in a subshell of the run's
shell, in the run's working directory, with its environment exported and
`$binary` the test binary; its output goes to the build log and `$log`,
and its exit status is the run's. The facts:

| Fact | What it is |
| --- | --- |
| `pkgs` | the package set of the machine that runs the test |
| `package` | the package name |
| `kind` | `"test"`, or `"bench"` for a bench run |
| `binary` | `{ key; kind; name; }`: the binary's key (`lib/<crate>`, `bin/<name>`, `<test>`), its root kind (`lib`, `bin`, `test`, `bench`, `example`) and its Cargo target's name |
| `args` | the run's [`args`](options/packages.md#packagesnametestargs) |
| `platform`, `triple` | `"target"`, or `"host"` for a binary built for the build machine (a proc macro's unit tests), and that platform's triple |
| `hostTriple`, `targetTriple` | the build machine's triple and the plan's target triple |
| `launcher` | a program that starts the program given after it under the run's [`wrapper`](options/packages.md#packagesnametestwrapper) and the target runner, or `null` with neither |
| `withEnv` | shell words to put before a command so that it gets the variables the shell cannot export (`CARGO_BIN_EXE_<bin>` with a `-`) |
| `libDir` | the sysroot's library directory of the platform, or `null` |
| `pathPackages` | a JSON file: `packageId`, the tested package's id, and `packages.<name> = { dir; targets; dependencies; }` for every path package the plan compiles |
| `workspaceDir` | the Cargo workspace's directory in the repository, for the project's own configuration |

A run reads `pathPackages` only when its runner names it, so a change to
another package's targets re-runs only such runs.

```nix
# A harness that takes its own flags, under the launcher.
packages.app.test.runner = facts: ''
  exec ${facts.withEnv} ${toString facts.launcher} "$binary" --format tap
'';
```

## Test wrappers

`breakbulk.lib.wrappers` has ready-made values for
[`test.wrapper`](options/packages.md#packagesnametestwrapper) (see
[Tests](../explanation/products.md#tests)). Each takes its options and
returns a function of a package set, which breakbulk calls with the
package set of the machine that runs the test.

**`cargoTargetLayout { profile ? "debug"; }`** starts the test binary
from where Cargo puts it, for tests that find the repository by walking
up from `std::env::current_exe()` to `target`. In a fresh directory in
`$TMPDIR`, it links each entry of the run's source view
(`BREAKBULK_SOURCE_ROOT`) and copies the binary into
`target/<profile>/deps/`, then starts the copy. It is a copy because
`current_exe()` resolves symbolic links. The working directory stays the
package directory. The directory is removed when the test exits, so the
wrapper waits for the test instead of replacing its own process; INT and
TERM sent to the wrapper reach the test.

```nix
workspaces.main.memberDefaults.test.wrapper =
  breakbulk.lib.wrappers.cargoTargetLayout { profile = "debug"; };
```
