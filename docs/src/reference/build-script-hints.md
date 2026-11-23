<!-- Generated from lib/build-script-hints.json by docs/build-script-hints.nix;
     run `nix run .#update-docs-options` after changing either. -->

# Build-script failure hints

The curated entries of
[`sysDefaults.buildScriptHints`](options/repository.md#sysdefaultsbuildscripthints):
what a failed build-script run's output is searched for, to add hints
after it ([Failure hints](unit-builder.md#failure-hints)). Patterns: `*`
matches any text and `{}` any non-empty text, which a hint names as
`{0}`; variable patterns also match after a `HOST_` or `TARGET_` prefix.
In a hint, `{opt}` is the package's option prefix (`packages.<name>`).

## Crates

A hint is added when the script printed the crate's error and the crate
left its fingerprint (either part is enough). The first error pattern a
line matches decides its hint.

| Crate | Fingerprint | Error | Hint |
| --- | --- | --- | --- |
| `bindgen/clang-sys` | declares `BINDGEN_EXTRA_CLANG_ARGS*`, `LIBCLANG_PATH`; prints `` *could not execute `llvm-config` one or more times* ``, `*Unable to find libclang*`, `` *couldn't find any valid shared libraries matching:*`LIBCLANG_PATH`* `` | `*Unable to find libclang*` | `` libclang is not in the sandbox; add `{opt}.nativeInputs = p: [ p.rustPlatform.bindgenHook ];` `` |
| `bindgen/clang-sys` | declares `BINDGEN_EXTRA_CLANG_ARGS*`, `LIBCLANG_PATH`; prints `` *could not execute `llvm-config` one or more times* ``, `*Unable to find libclang*`, `` *couldn't find any valid shared libraries matching:*`LIBCLANG_PATH`* `` | `` *couldn't find any valid shared libraries matching:*`LIBCLANG_PATH`* `` | `` libclang is not in the sandbox; add `{opt}.nativeInputs = p: [ p.rustPlatform.bindgenHook ];` `` |
| `cc` | declares `CC*`, `CFLAGS*`, `CXX*` | `*failed to find tool "{}"*` | `` the `cc` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs` `` |
| `cc` | declares `CC*`, `CFLAGS*`, `CXX*` | `` *Failed to find tool. Is `{}` installed?* `` | `` the `cc` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs` `` |
| `cmake` | prints `*CMAKE* = *` | `` *is `cmake` not installed?* `` | `` `cmake` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.cmake ];` `` |
| `cmake` | prints `*CMAKE* = *` | `` *is `{}` not installed?* `` | `` the `cmake` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs` `` |
| `openssl-sys` | declares `*OPENSSL_*` | `*Could not find directory of OpenSSL installation*` | `` OpenSSL is not in the sandbox; add `{opt}.inputs = p: [ p.openssl ];` and `{opt}.nativeInputs = p: [ p.pkg-config ];` `` |
| `pkg-config` | declares `PKG_CONFIG*`, `*_NO_PKG_CONFIG` | `*The pkg-config command could not be found.*` | `` `pkg-config` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.pkg-config ];` `` |
| `pkg-config` | declares `PKG_CONFIG*`, `*_NO_PKG_CONFIG` | `` *Failed to run `*pkg-config*`: No such file or directory* `` | `` `pkg-config` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.pkg-config ];` `` |
| `pkg-config` | declares `PKG_CONFIG*`, `*_NO_PKG_CONFIG` | `` *The system library `{}` required by crate*was not found* `` | `` pkg-config found no `{0}.pc`; add the package that provides `{0}` to `{opt}.inputs` (`inputs = p: [ p.<package> ];`) `` |
| `pkg-config` | declares `PKG_CONFIG*`, `*_NO_PKG_CONFIG` | `*Package {} was not found in the pkg-config search path*` | `` pkg-config found no `{0}.pc`; add the package that provides `{0}` to `{opt}.inputs` (`inputs = p: [ p.<package> ];`) `` |
| `prost-build` | prints `*docs.rs/prost-build/#sourcing-protoc*` | `` *Could not find `protoc`* `` | `` `protoc` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.protobuf ];` `` |

After a crate's failure is recognized, the unset variables it declares
are counted rather than listed:

| Crate | Variables |
| --- | --- |
| `bindgen/clang-sys` | `BINDGEN_EXTRA_CLANG_ARGS*`, `LIBCLANG_PATH`, `LIBCLANG_STATIC_PATH`, `LLVM_CONFIG_PATH` |
| `cc` | `CC`, `CC_*`, `CFLAGS`, `CFLAGS_*`, `CXX`, `CXX_*`, `CXXFLAGS`, `CXXFLAGS_*`, `CXXSTDLIB*`, `AR`, `AR_*`, `ARFLAGS`, `ARFLAGS_*`, `RANLIB`, `RANLIB_*`, `RANLIBFLAGS`, `RANLIBFLAGS_*`, `CRATE_CC_NO_DEFAULTS`, `CROSS_COMPILE`, `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`, `OBJC_INCLUDE_PATH`, `OBJCPLUS_INCLUDE_PATH`, `COMPILER_PATH`, `GCC_EXEC_PREFIX`, `CCC_OVERRIDE_OPTIONS`, `CLANG_NO_DEFAULT_CONFIG` |
| `openssl-sys` | `*OPENSSL_*` |
| `pkg-config` | `PKG_CONFIG*`, `*_NO_PKG_CONFIG` |

## Tools not found

A line that says a program was not found (it contains one of
`NotFound`, `os error 2`, `No such file or directory`, `command not found`, `: not found`) and names one of these tools gets
`` `{tool}` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.{attr} ];` ``. The tool must be quoted, end a path, or come
before a `:`, as in ``failed to spawn `cmake` `` or
`sh: 1: nasm: not found`.

| Program | Package |
| --- | --- |
| `autoconf` | `autoconf` |
| `automake` | `automake` |
| `autoreconf` | `autoconf` |
| `bison` | `bison` |
| `clang` | `clang` |
| `cmake` | `cmake` |
| `curl` | `curl` |
| `flex` | `flex` |
| `gcc` | `gcc` |
| `git` | `git` |
| `glslc` | `shaderc` |
| `go` | `go` |
| `gperf` | `gperf` |
| `libtool` | `libtool` |
| `m4` | `m4` |
| `make` | `gnumake` |
| `meson` | `meson` |
| `nasm` | `nasm` |
| `ninja` | `ninja` |
| `node` | `nodejs` |
| `npm` | `nodejs` |
| `patch` | `patch` |
| `perl` | `perl` |
| `pkg-config` | `pkg-config` |
| `protoc` | `protobuf` |
| `python` | `python3` |
| `python3` | `python3` |
| `swig` | `swig` |
| `tar` | `gnutar` |
| `unzip` | `unzip` |
| `wget` | `wget` |
| `yasm` | `yasm` |

## Downloads

A line that shows the script downloading gets `` the build script seems to download; the sandbox has no network. If the crate can use a local copy, pass it in, usually through a variable it reads (`{opt}.env.<NAME>`, a `fetchurl` path) ``.
It does when, lowercased, it contains one of `downloading http`, `failed to download`, `could not resolve host`, `temporary failure in name resolution`, `name or service not known`, `failed to lookup address information`, `dns error`, `network is unreachable`, `urlopen error`, or
names one of `curl`, `wget` as a word outside a `cargo:`
directive.
