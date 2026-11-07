# Spike: Windows msvc cross toolchain

Nov 7, 2026

## Result

**Go.** A pinned xwin CRT and SDK as a fixed-output derivation, plus `lld-link`, `clang-cl`, `llvm-lib` and `llvm-rc` from the `llvmPackages` that matches rustc's LLVM, is enough for plain cargo to cross-build Rust with C code, bindgen and a Windows resource to `x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc` in the Nix sandbox. The x86\_64 program runs under wine in the sandbox and prints the expected output. The aarch64 program compiles and links (`PE32+ … ARM64`). No breakbulk code is involved.

Three findings change or add to the implementation doc:

1. **The linked `.exe` is not reproducible as is.** rustc links from a temp dir with a random name, lld-link writes that path into the PDB, and the PDB's hash becomes the `.exe`'s PDB GUID. The preset needs a small linker wrapper (or the same step in `breakbulk-unit`). See [Determinism](#determinism).
2. **`INCLUDE` and `LIB` alone are enough.** `clang-cl`, bindgen's libclang (for an msvc target), `llvm-rc` and `lld-link` all read them. The per-triple `CFLAGS_<triple>`, `BINDGEN_EXTRA_CLANG_ARGS_<triple>` and `-Lnative` flags from the preset table also work, and the preset should still set them; see [Which variables are needed](#which-variables-are-needed).
3. **`RC`, `RCFLAGS`, `LIB` and `INCLUDE` have no triple suffix**, so the preset must scope them to target units by platform, as the design already says for preset env.

Confidence: high for the tested shape (Rust + C + bindgen + RCDATA resource, `windows-sys`, dynamic and static CRT). Not tested: C++ (`cxx`, the STL), ATL/MFC, `cmake`-based `-sys` crates, the `embed-resource` and `winres` crates, and DLL outputs.

Pins: nixpkgs `1d060086d60cb76a40cf37109f979d88a5bd6396` and rust-overlay `74cebce67ef6671ea48fda353a5be2d229bd2920` (the repository's `flake.lock`); rustc 1.99.1 (LLVM 23.1.1) from rust-overlay; `llvmPackages_23` (23.1.3); xwin 0.9.0; `wineWow64Packages.minimal` 11.0.

## How to reproduce

```sh
nix build .#checks.x86_64-linux.msvc-sdk       # the SDK (network, unfree) and its layout
nix build .#checks.x86_64-linux.msvc-x86_64    # build spikes/msvc, run under wine
nix build .#checks.x86_64-linux.msvc-aarch64   # build only
nix build --rebuild .#checks.x86_64-linux.msvc-sdk   # the SDK is deterministic
```

| File | What it is |
| --- | --- |
| [`lib/xwin-sdk.nix`](../../lib/xwin-sdk.nix) | `breakbulk.xwinSdk`: the fixed-output SDK derivation |
| [`spikes/msvc/`](../../spikes/msvc/) | The test crate (`build.rs`, `src/main.rs`, `csrc/`) and `default.nix`, which builds it with plain cargo |
| [`spikes/msvc/env.sh`](../../spikes/msvc/env.sh) | The full env, as a shell script |
| [`spikes/msvc/lld-link-stable-tmp.sh`](../../spikes/msvc/lld-link-stable-tmp.sh) | The determinism wrapper |
| [`tests/presets/default.nix`](../../tests/presets/default.nix) | The flake checks |

The crate links C code compiled by `clang-cl` through the `cc` crate (`csrc/smoke.c` includes `<windows.h>` and calls the CRT). It generates bindings with bindgen 0.72 for its own header and for `GetCurrentProcessId` from `<windows.h>`. It compiles `csrc/smoke.rc`, an RCDATA resource that includes `<windows.h>`, with `$RC`, and links the `.res` with `cargo:rustc-link-arg-bins`. It calls `windows-sys` 0.61 (`GetCurrentProcessId`, `FindResourceW`, `LoadResource`). At run time it checks that the C, bindgen and `windows-sys` results agree, and that the resource is present:

```
smoke: c_add=42 pid_match=true resource=resource-ok
```

## The SDK derivation

`breakbulk.xwinSdk { pkgs; manifestVersion ? 17; crt; sdk; arches; hash; }` runs:

```sh
xwin --cache-dir $TMPDIR/xwin-cache --accept-license --log-level warn --http-retry 5 --timeout 600s \
  --crt-version 14.44.17.14 --sdk-version 10.0.26100 --arch x86_64,aarch64 \
  --manifest-version 17 --channel release \
  splat --output $TMPDIR/splat
cp -a $TMPDIR/splat $out
```

It is a fixed-output derivation with `outputHashMode = "recursive"` and `meta.license = unfree`. `SSL_CERT_FILE` points at `cacert`. xwin's ureq uses `rustls-platform-verifier`, which reads it on Linux. Two builds give the same output (`nix build --rebuild` passes), so the hash is stable.

- **Versions used: the doc's example.** CRT `14.44.17.14` and SDK `10.0.26100` are both in the current VS 17 manifest. The channel is `VisualStudio.17.Release/17.14.44+37827.9`, and `Win11SDK_10.0.26100` is package version `10.0.26100.15`. The manifest offers CRTs from 14.29.16.11 to 14.44.17.14, and the SDKs 10.0.19041, 10.0.22621 and 10.0.26100.
- **Hash** for `arches = [ "x86_64" "aarch64" ]`: `sha256-22dqk0tKSbC4bnfsnhhsG0aEJfUHb3JJNL3TnZGFVa0=`. The output is 252 MB, with 3533 symlinks and none dangling.
- **Layout** (xwin's splat): `crt/include`, `crt/lib/<arch>`, `sdk/include/{ucrt,um,shared,winrt,cppwinrt}` and `sdk/lib/{um,ucrt}/<arch>`, with `<arch>` in LLVM spelling (`x86_64`, `aarch64`). xwin adds relative symlinks for case-insensitive spellings, for example `windows.h -> Windows.h` and `kernel32.lib`, `Kernel32.lib` and `KERNEL32.lib -> kernel32.Lib`. It also adds `sdk/include/10.0.26100 -> .` (xwin 0.9.0 `src/splat.rs`).
- **passthru**: `includeDirs` (CRT first, then the SDK's ucrt, um, shared, winrt and cppwinrt), `libDirs.<arch>` (CRT, um, ucrt), and also `crtIncludeDir`, `sdkIncludeDirs`, `crtLibDir.<arch>` and `sdkLibDirs.<arch>`. The values are strings that contain the store path, so they carry the dependency.
- **Unfree scoping.** With `config = { }`, evaluation refuses (`Refusing to evaluate package 'xwin-sdk-…' … unfree license`). The flake builds the SDK from a separate nixpkgs instance with `allowUnfreePredicate = p: lib.getName p == "xwin-sdk"`, and everything else from the normal one. Note: `~/.config/nixpkgs/config.nix` with `allowUnfree = true` silently allows it in impure evaluation.

### Pinning, and how the hash can break

xwin reads `https://aka.ms/vs/<v>/release/channel`, which moves with Visual Studio updates. It then reads the package manifest that the channel names (xwin `src/manifest.rs`, `get_manifest` and `get_package_manifest`). The two pins behave differently:

- `--crt-version` selects `Microsoft.VisualStudio.Component.VC.<crt>.x86.x64` exactly (xwin `src/lib.rs`, `get_crt`).
- `--sdk-version` takes the first package id that *ends with* the string, for example `Win11SDK_10.0.26100` (`get_sdk`). Microsoft can update its payloads within the same line: this channel has `10.0.26100.15`.

xwin checks every payload against the sha256 in the package manifest, but it does not check the package manifest itself. Its source says that hash is never correct. If Microsoft updates the 26100 SDK, or drops CRT 14.44 from the VS 17 channel, a fresh build fails with a hash mismatch or a missing version. It does not drift silently. A substituted or cached SDK is unaffected.

For a stronger pin, `channelManifest` takes a fetched copy of the `.chman` file that `aka.ms` redirects to (here `https://download.visualstudio.microsoft.com/download/pr/6bd63d7f-…/VisualStudio.17.Release.chman`). It is passed as `--manifest`, which fixes the package manifest URL as well. This is not exercised by the checks.

## The env that works

For `<arch>-pc-windows-msvc`, with `$SDK` the `xwinSdk` output, `<A>` the arch, `<T>` the triple in `CARGO_TARGET_` form and `<t>` the triple with underscores. The tools are on `PATH` from `llvmPackages_23.{clang-unwrapped,llvm,lld}`. `clang-unwrapped` is needed on `PATH` because `llvm-rc` runs `clang` to preprocess (llvm `llvm/tools/llvm-rc/llvm-rc.cpp`, `findClang`: next to `llvm-rc`, then `PATH`). Unwrapped clang finds its resource directory in `clang-unwrapped.lib` (nixpkgs patches it), so no `-resource-dir` is needed.

```sh
incdirs="$SDK/crt/include $SDK/sdk/include/ucrt $SDK/sdk/include/um $SDK/sdk/include/shared $SDK/sdk/include/winrt $SDK/sdk/include/cppwinrt"
libdirs="$SDK/crt/lib/<A> $SDK/sdk/lib/um/<A> $SDK/sdk/lib/ucrt/<A>"

CARGO_TARGET_<T>_LINKER=lld-link              # through lld-link-stable-tmp.sh, see Determinism
CARGO_TARGET_<T>_RUSTFLAGS="-Lnative=<each libdir>"   # [+ -C target-feature=+crt-static]
CC_<t>=clang-cl  CXX_<t>=clang-cl  AR_<t>=llvm-lib
CFLAGS_<t>="--target=<triple> -imsvc <each incdir>"     # CXXFLAGS_<t> the same
BINDGEN_EXTRA_CLANG_ARGS_<t>="--target=<triple> -isystem <each incdir>"
LIBCLANG_PATH=${llvmPackages_23.libclang.lib}/lib
RC=llvm-rc
RCFLAGS="/I <each incdir>"
LIB="<libdirs joined by ;>"
INCLUDE="<incdirs joined by ;>"
```

`cc` 1.11.1 adds `--target=<triple>`, `-Brepro`, `-nologo` and `-MD`/`-MT` to `clang-cl` itself, so `--target` in `CFLAGS` is redundant but harmless. With `+crt-static`, cc switches to `-MT` and the `.exe` imports only `KERNEL32`, `ntdll` and `api-ms-win-core-synch`, with no `VCRUNTIME140` and no `api-ms-win-crt-*`. It also runs under wine. The dynamic CRT build imports `VCRUNTIME140.dll` and `api-ms-win-crt-*`, which wine provides as built-ins.

Wine runner: `wineWow64Packages.minimal`, with `HOME=$TMPDIR WINEPREFIX=$TMPDIR/wine WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="`, then `wineboot --init` and `wine prog.exe`. It works in the sandbox with no display.

### Which variables are needed

Each line removes variables from the full set and builds (x86\_64; "runs" means under wine):

| Removed | Result | Why |
| --- | --- | --- |
| nothing, `+crt-static` | runs | |
| `LIB` | runs | `-Lnative` becomes `/LIBPATH:` |
| `CARGO_TARGET_<T>_RUSTFLAGS` (`-Lnative`) | runs | lld-link reads `LIB` (lld `COFF/Driver.cpp`, `addLibSearchPaths`) |
| both | link fails: `could not open 'kernel32.lib'` | |
| `CFLAGS_<t>` | builds | clang-cl reads `INCLUDE` |
| `CFLAGS_<t>` and `INCLUDE` | cc fails: `'windows.h' file not found` | |
| `BINDGEN_EXTRA_CLANG_ARGS_<t>` | builds | clang's MSVC toolchain reads `INCLUDE`/`EXTERNAL_INCLUDE` for an msvc target in any driver mode (clang `lib/Driver/ToolChains/MSVC.cpp`, `AddClangSystemIncludeArgs`, unless `/winsysroot` and similar are given) |
| `BINDGEN_EXTRA_CLANG_ARGS_<t>` and `INCLUDE` | bindgen fails: `'windows.h' file not found` | |
| `RCFLAGS` | builds | llvm-rc passes `INCLUDE` on to its clang preprocessor (it clears it only for `/X`) |
| `RCFLAGS` and `INCLUDE` | rc fails: `'windows.h' file not found` | |
| `CFLAGS_<t>`, `BINDGEN_EXTRA_CLANG_ARGS_<t>` and `RCFLAGS`, keeping `INCLUDE` | builds | |

LLVM source references are at `llvmorg-23.1.3`. Recommendation: set all of them. The per-triple variables are what `cc` and bindgen document, and they keep working if a unit also sets `INCLUDE` for its own reasons. `INCLUDE` and `LIB` cover anything that runs `clang-cl`, `llvm-rc` or `lld-link` without those flags, for example a build script that calls the tools itself. None of `INCLUDE`, `LIB`, `RC` and `RCFLAGS` has a triple suffix, so the preset must set them on target units only.

## Determinism

With the plain env, `nix build --rebuild` of the `.exe` fails. Eight bytes differ: the first half of the PDB GUID in the debug directory. The file header's `TimeDateStamp` is already fixed, because lld-link honors `SOURCE_DATE_EPOCH` (lld `COFF/Driver.cpp`, `/timestamp` handling), and stdenv sets it to 1980-01-01.

The cause:

- rustc links from `<out-dir>/rustcXXXXXX/`, a random temp dir (rustc 1.99.1 `compiler/rustc_codegen_ssa/src/back/link.rs`, `TempDirBuilder::new().prefix("rustc").tempdir_in(output.parent())`). It passes `symbols.o` from there by absolute path. On msvc that object exists whenever there are linked symbols, as there are here.
- lld-link records every input path in the PDB's module list. Comparing the strings of the two PDBs shows only `…/deps/rustcLqWGdY/symbols.o` against `…/deps/rustcFPckMB/symbols.o`.
- When it writes a PDB, lld-link sets the build ID hash to the PDB's content hash (`COFF/Driver.cpp`: `config->buildIDHash = BuildIDHash::PDB` whenever `shouldCreatePDB`). `/Brepro` and `/build-id` do not change this. `writeBuildId` in `COFF/Writer.cpp` writes the hash into the PE's PDB GUID.

The fix in the spike is [`lld-link-stable-tmp.sh`](../../spikes/msvc/lld-link-stable-tmp.sh), set as `CARGO_TARGET_<T>_LINKER`. It copies any `…/rustcXXXXXX/<file>` input to `<output>.rustc-tmp/<file>` and passes the copy. With it, both the `.exe` and the `.pdb` are identical across `--rebuild`, on x86\_64 and aarch64. Limitation: it does not rewrite arguments inside an `@response` file, which rustc uses only when the command line is too long. ELF links are probably not affected, because ELF has no equivalent of the PDB module list and `symbols.o` carries no debug info. That was not tested here.

Other options were checked and rejected:

- No PDB (`-C debuginfo=0` plus `/DEBUG:NONE`) loses the PDB. The design's msvc default stages assume one ("PDBs are already separate").
- `-Z temps-dir` is unstable.
- No lld-link option remaps object paths in the PDB. `/pdbsourcepath` only makes relative source paths absolute.

## Notes for the preset

- **LLVM version.** `rustc -vV` reports LLVM 23.1.1. nixpkgs has `llvmPackages_23` (23.1.3), while its default `llvmPackages` is 21. The preset must pick `llvmPackages_<rustc's LLVM major>`. The design says `rustc.llvmPackages`: nixpkgs' `rustc` has that attribute (LLVM 21 at this pin, because nixpkgs builds rustc against its own LLVM), but rust-overlay's toolchains do not. For a bring-your-own toolchain, the major version must come from `rustc -vV`, which needs a build step or a table.
- **Toolchain.** rust-overlay `stable.latest.minimal.override { targets = [ "<arch>-pc-windows-msvc" ]; }` works. The host stdenv's `cc` links build scripts. Nothing on the target side touches the cc-wrapper.
- **xwin build log.** xwin draws progress bars even when its output is not a terminal, and `--log-level warn` does not stop them. The log is noisy but harmless.
- **aarch64 under wine.** Not attempted: `aarch64` Windows binaries need an aarch64 wine (or a Windows on Arm machine).
