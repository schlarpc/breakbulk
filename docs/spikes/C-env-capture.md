# Spike C: environment capture

Nov 7, 2026

## Result

**Go.** A small derivation can run a real nixpkgs stdenv with a package's inputs and record what its setup hooks produce as `env.json`. A plain builder that replays that file gets the same behavior from nixpkgs' cc-wrapper, bintools-wrapper and pkg-config wrapper as a live stdenv shell.

The end-to-end test is stronger than the question asked. Cargo built `openssl-sys` (pkg-config + openssl), `ring` (cc-rs, C and assembly) and `zstd-sys` (bindgen + libclang + pkg-config). Every unit got only the replayed capture for its own (platform, package). The result was **byte-identical** to `buildRustPackage` with all inputs in one live stdenv: the final binary, every build-script executable, ring's C archives and the generated bindings. This held natively (x86_64) and for `pkgsCross.aarch64-multiplatform`. One difference is deliberate (see the next paragraph). The control build that removes it matches byte for byte.

The capture function needs four rules that the implementation doc does not mention yet:

- `strictDeps = true`.
- Drop stdenv's `-rpath $out/lib`.
- Drop the capture's own `-frandom-seed`, and have each unit add its own.
- Drop any value that names the capture's own `$out`.

A draft is in [`lib/env-capture.nix`](../../lib/env-capture.nix). The end-to-end test uses this draft.

Confidence: high for Linux gnu targets, native and cross, with the hooks tested. Medium for hooks not tested here (see [Limits](#limits)).

Pinned nixpkgs: `1d060086d60cb76a40cf37109f979d88a5bd6396` (the repository's `flake.lock`). Every path below is relative to `pkgs/` in that tree.

## How to reproduce

```sh
cd spikes/env-capture
nix-build -A captures.openssl            # a capture, with a survey of non-env state
bash compare.sh                          # wrapper probe: live stdenv vs replay, 5 cases
bash compare-e2e.sh native               # end to end, x86_64
bash compare-e2e.sh cross                # end to end, aarch64-unknown-linux-gnu
```

Saved output: [`spikes/env-capture/results/`](../../spikes/env-capture/results/).

| File | What it is |
| --- | --- |
| `capture.nix`, `capture.sh` | Spike capture (with a survey of non-exported shell state) |
| `../../lib/env-capture.nix` | Draft library function (used by the e2e test) |
| `replay.sh`, `probe.sh` | Plain builder that exports `env.json`, and a probe that runs the wrappers with `NIX_DEBUG=1` |
| `fixture/` | A crate depending on `openssl-sys`, `ring`, `zstd-sys` (features `bindgen`, `pkg-config`), with a `build.rs` that dumps its env |
| `driver/` | Minimal hand-written driver: real cargo in a plain derivation. A `RUSTC_WRAPPER` overlays the capture for each compile unit by platform and package. It also replaces each build-script binary with a script that overlays the capture for the script's `TARGET` and package. This is the per-unit layering `breakbulk-unit` will do. |

## 1. Capturing

The capture is `stdenv.mkDerivation` with `nativeBuildInputs = nativeInputs` and `buildInputs = inputs`. It sets `args = [ "-e" capture.sh ]`, so stdenv's own `source-stdenv.sh` does not run first (`stdenv/generic/make-derivation.nix:692-703`). The builder runs these steps:

1. It records `env -0` as Nix gave it to the builder.
2. It runs `source "$stdenv/setup"`. This runs `findInputs`, `_activatePkgs` (each input's setup hook), `_addToEnv` (env hooks), `_addRpathPrefix` and `runHook postHook` (`stdenv/generic/setup.sh:703-956, 1825`).
3. It records `env -0` again.
4. It keeps a variable when the variable is exported after setup, and either setup created or changed it, or the name starts with `NIX_`.

The `NIX_*` exception matters. Some wrapper inputs arrive as derivation attributes, and the hooks leave them unchanged. `mkDerivation` sets `NIX_HARDENING_ENABLE` as an attribute for musl, or when `hardeningDisable`/`hardeningEnable` are set (`make-derivation.nix:762-767`). The hooks only fill it in when it is unset (`cc-wrapper/setup-hook.sh:123-124`). Stdenv adapters set `NIX_CFLAGS_LINK` the same way. A pure diff would drop these. Without `NIX_HARDENING_ENABLE` the wrappers apply **no hardening at all**, because `add-hardening.sh:9` reads only the salted copy.

It drops:

| Dropped | Why |
| --- | --- |
| `NIX_BUILD_TOP`, `TMPDIR`, `TMP`, `TEMP`, `TEMPDIR`, `PWD`, `OLDPWD`, `SHLVL`, `_`, `HOME`, `TERM`, `NIX_LOG_FD`, `NIX_BUILD_CORES`, `NIX_STORE`, `NIX_ATTRS_*` | Nix sets these for every builder, per build. Nix sets them again in each unit. The wrappers need `NIX_STORE`, `NIX_BUILD_TOP` and `TMPDIR` (`wrapper-common/utils.bash`, `badPath`), and the unit's own values are the correct ones. |
| Output names and paths, `outputs` | The capture's identity |
| `-frandom-seed=<first 10 chars of $out>` inside any value | `setup-hooks/reproducible-builds.sh` adds it to `NIX_CFLAGS_COMPILE`. `rust-bindgen-hook.sh` then copies `NIX_CFLAGS_COMPILE` into `BINDGEN_EXTRA_CLANG_ARGS`. It is the capture's identity, not the unit's. |
| Any variable whose value contains the capture's own `$out` (listed in `dropped-self-refs.txt`) | Found in the broad survey: gobject-introspection exports `NIX_GOBJECT_INTROSPECTION_DEFAULT_FALLBACK_LIBPATH=${!outputLib}` (`development/libraries/gobject-introspection/setup-hook.sh:13-23`) |
| `BASH_FUNC_*` | Exported functions. None were seen, and they are dropped anyway. |
| `SOURCE_DATE_EPOCH` | setup.sh defaults it to 315532800 (`setup.sh:590-591`). It belongs in the fixed base layer, so per-package stamps override it in one place. |
| Capture bookkeeping (`jq`, `envTool`, ...) | Not part of any hook's output |

The capture derivation also sets two attributes:

- **`strictDeps = true`.** Without it, setup.sh puts every input's `bin/` on `PATH` (`setup.sh:855`). It also runs every env hook for every package at every offset (`setup.sh:911-933`). Each `-isystem` and `-L` then appears twice, and openssl's own `bin/` lands on `PATH`. `buildRustPackage` sets `strictDeps`, and cross stdenvs default to it. Compare `captures.opensslNoStrict` with `captures.openssl`.
- **`NIX_NO_SELF_RPATH = 1`.** Otherwise `_addRpathPrefix "$out"` puts `-rpath <capture>/lib` into `NIX_LDFLAGS` (`setup.sh:505-509, 956`). Every binary linked in a unit would then carry a runtime path to the capture.

Captures are input-addressed. `env.json` names the inputs' store paths, so Nix's reference scan makes them runtime references of the capture. A unit that depends on the capture therefore realises the inputs. Substituting a unit does not.

## 2. Does replay behave like a live stdenv?

### Why it can work

Only exported variables can reach a build script, in a live stdenv as much as in replay. Cargo starts build scripts and rustc as child processes. Arrays, functions and unexported shell variables never cross `exec`. So the question becomes: does anything that a live `buildRustPackage` *exports* before cargo runs come from outside setup.sh? Also, do the wrappers depend on anything other than their environment?

**The wrappers are fully driven by exported variables.** The wrappers are cc-wrapper, bintools-wrapper and pkg-config-wrapper.

- **Role.** Each wrapper derivation learns its role from `NIX_<WRAPPER>_TARGET_{BUILD,HOST,TARGET}_<suffixSalt>=1`, which setup hooks export (`setup-hooks/role.bash:55-71`, called from `cc-wrapper/setup-hook.sh:91`).
- **Flags.** Hooks accumulate flags into relative-role variables: `NIX_CFLAGS_COMPILE`, `NIX_CFLAGS_COMPILE_FOR_BUILD`, `NIX_LDFLAGS`, `PKG_CONFIG_PATH`, and so on (`cc-wrapper/setup-hook.sh:66-85`, `bintools-wrapper/setup-hook.sh:11-30`, `pkg-config-wrapper/setup-hook.sh:11-18`). Each is written with `export`, or with `addToSearchPath`, which exports (`setup.sh:338-350`).
- **Run time.** At run time, each wrapper turns the relative-role variables into salted variables. `accumulateRoles` and `mangleVarList` in `wrapper-common/utils.bash` do this, sourced by `cc-wrapper/add-flags.sh:21`, `bintools-wrapper/add-flags.sh:16` and `pkg-config-wrapper/add-flags.sh`. This happens on every invocation unless `NIX_<WRAPPER>_WRAPPER_FLAGS_SET_<salt>` is already set. No capture contains that variable (setup does not run a wrapper).
- **No role variable.** If no role variable is set for a wrapper's salt, the wrapper uses no `NIX_*` flags and no hardening.

**Hooks do use non-environment state, but only during setup.** The survey of `captures.broad` covers pkg-config, cmake, perl, python3, protobuf, nasm, autotools, gettext, bindgenHook, gobject-introspection, glib, makeWrapper, meson, ninja, plus openssl, zstd, sqlite, glib and dbus. It found these kinds of state:

- **Hook arrays:** `envHostTargetHooks` and the like, filled by `addEnvHooks` (`setup.sh:665-673`); `pkgsBuildHost` and friends; `preConfigureHooks` (`ProtobufCMakeFlags`, `_multioutConfig`); `postUnpackHooks`; `postHooks` (`makeCmakeFindLibs`).
- **Phase overrides:** `configurePhase=cmakeConfigurePhase`, `buildPhase=ninjaBuildPhase`, and so on.
- **Unexported shell variables:** `role_post`, `prefix`, `outputDev`, and so on.

None of these is visible to a process cargo starts. Results that hooks compute from that state at `postHook` time *are* captured, because `postHook` runs inside setup.sh (`setup.sh:1825`). Examples: `BINDGEN_EXTRA_CLANG_ARGS` (`rust/hooks/rust-bindgen-hook.sh`) and `CMAKE_INCLUDE_PATH`/`CMAKE_LIBRARY_PATH` (`cmake/setup-hook.sh`, `makeCmakeFindLibs`). Full list of kept names: [`results/broad-env.json`](../../spikes/env-capture/results/broad-env.json). Unexported state: [`results/broad-unexported-vars.txt`](../../spikes/env-capture/results/broad-unexported-vars.txt).

`appendToVar`/`prependToVar` (`setup.sh:360-420`) do not export a new variable. No hook in the survey used them for an environment variable that a child process needs.

**What a live `buildRustPackage` exports outside setup.sh** (and so a capture does not have):

| Variable | Set by | Where it belongs in breakbulk |
| --- | --- | --- |
| `GZIP_NO_TIMESTAMPS=1` | `genericBuild` (`setup.sh:1801`) | Fixed base, if wanted |
| `SOURCE_DATE_EPOCH` update | postUnpack `_updateSourceDateEpochFromSourceRoot` (`setup-hooks/set-source-date-epoch-to-latest.sh`). It had no effect in the e2e test: both builds saw 315532800. | Fixed base / package stamps |
| `CC_<triple>`, `CXX_<triple>`, `HOST_CC`, `HOST_CXX`, `CARGO_TARGET_<T>_LINKER`, `CARGO_BUILD_TARGET` | `cargoBuildHook` via `rust.envVars.setEnv` (`rust/lib/default.nix`) | Toolchain spec |
| `CARGO_PROFILE_<P>_STRIP=false` | `cargoBuildHook` | Not needed (breakbulk never strips implicitly) |
| `PKG_CONFIG_ALLOW_CROSS`, `RUST_LOG` | `buildRustPackage` `env` (`rust/build-rust-package/default.nix:81-94`) | Not needed (see the cross section) |
| `CTEST_*`, `CMAKE_BUILD_PARALLEL_LEVEL` | `cmakeConfigurePhase` | Never runs in `buildRustPackage` either (it overrides `configurePhase`) |
| Derivation attributes (`buildInputs`, `cargoDeps`, `pname`, ...) | Nix | Bookkeeping; not wanted |

### Wrapper probe: live stdenv vs replay

`probe.sh` runs as a child process in both settings. It prints the tools, the role variables and `pkg-config --cflags --libs`. It compiles and links a C program with `NIX_DEBUG=1`, so cc-wrapper and ld-wrapper print every flag they add. It also prints the binary's `NEEDED`, `RUNPATH`, `RELRO`, `BIND_NOW` and PIE status. The cases are base, openssl, bindgen + zstd, cross base and cross openssl.

After normalising gcc's random temp file names, the **only** difference in every case is the live shell's `-rpath <live $out>/lib`. It appears in `NIX_LDFLAGS`, in the wrapper's extra flags and in `RUNPATH`. Hardening flags, include and library flags, dynamic linker, pkg-config output and role variables are identical. See [`results/probes-live-vs-replay.txt`](../../spikes/env-capture/results/probes-live-vs-replay.txt).

## 3. End to end: openssl-sys, ring, zstd-sys with bindgen

**Live:** `rustPlatform.buildRustPackage` with `nativeBuildInputs = [ pkg-config rustPlatform.bindgenHook ]` and `buildInputs = [ openssl zstd ]`, all in one stdenv. `auditable = false` and `dontFixup = true` keep the bytes comparable.

**Replay:** real cargo 1.99 in a `derivation` with `builder = bash` and no stdenv. The outer environment has only `cargo`, `rustc`, `bash`, `coreutils`, the toolchain-spec variables that `cargoBuildHook` passes, and `SOURCE_DATE_EPOCH`. Each unit gets:

- compile units: the capture for (platform from `--target`, package);
- build-script runs: the capture for (platform from `TARGET`, package);
- captures: `openssl-sys` gets pkg-config + openssl, `zstd-sys` gets bindgenHook + pkg-config + zstd, and everything else gets the base capture for its platform.

| Compared | Native x86_64 | Cross aarch64 |
| --- | --- | --- |
| Directives of every build script (`output`) | identical | identical, except 4 extra `rerun-if-env-changed=PKG_CONFIG*` lines (see the cross section) |
| bindgen output (`zstd-sys` `bindings.rs`) | byte-identical | byte-identical |
| ring's cc-rs archives (`libring_core_*.a`) | byte-identical | byte-identical |
| Build-script executables (9) | differ only by the live `-rpath $out/lib`; byte-identical to the control | byte-identical |
| Final binary | differs only by the live `-rpath $out/lib`; byte-identical to the control | same |
| Control: live with `NIX_NO_SELF_RPATH=1` vs replay | **all byte-identical** | **all byte-identical** |

Two details, so they are not mistaken for capture problems:

- **Order of ring's `rerun-if-changed` lines.** ring walks directories with `read_dir`, so the order of these lines depends on the file system. The comparison treats them as a set.
- **ring's archives and build directory names.** ring always compiles C with `-g3` (`ring-0.17.14/build.rs:580`), so its objects embed absolute source paths in DWARF. The first attempt differed only because `buildRustPackage` copies the vendor directory to `/build/cargo-vendor-dir`. The driver now uses the same layout. See [Side findings](#side-findings).

## 4. Cross, and host-versus-target separation

The captures used:

- **Target units:** `pkgsCross.aarch64-multiplatform.stdenv`, with `nativeInputs` taken from `pkgs.buildPackages` and `inputs` taken from the cross set.
- **Host units:** the build platform's stdenv.

The target capture (`openssl-sys`) contains only target-role values:

- `CC=aarch64-unknown-linux-gnu-gcc` and `PKG_CONFIG=aarch64-unknown-linux-gnu-pkg-config`;
- `NIX_{CC,BINTOOLS,PKG_CONFIG}_WRAPPER_TARGET_HOST_aarch64_unknown_linux_gnu=1`;
- unsalted `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS` and `PKG_CONFIG_PATH` pointing at the aarch64 openssl;
- a `PATH` with no build-platform compiler and no plain `cc`.

The cross bindgen capture has `--target=aarch64-unknown-linux-gnu` and the aarch64 glibc headers in `BINDGEN_EXTRA_CLANG_ARGS`.

In the cross run, every host unit got the host base capture and every target unit got its target capture. See [`results/cross-captures-applied.txt`](../../spikes/env-capture/results/cross-captures-applied.txt). For example, `run openssl-sys TARGET=aarch64…` got the target openssl capture, and `run proc-macro2 TARGET=x86_64…` got the host base. The bytes matched, as shown above.

Findings:

- **Exactly one capture per unit; never merge two.** The role variables a hook writes are *relative*. In both a native capture and a cross target capture, `NIX_CFLAGS_COMPILE` (no suffix) means "flags for this stdenv's host platform". `CC`, `PKG_CONFIG` and `PATH` collide the same way. Merging a host and a target capture would give the aarch64 compiler x86 include paths, or the reverse. Platform scoping per unit, as the design says, is required, not optional. The same applies to the dev shell's "union of the packages' env captures" (implementation doc, Dev shell). A union is only safe for captures of the same platform.
- **Host C code: breakbulk gives hardening that `buildRustPackage` does not.** In a live cross stdenv the build platform's cc has no role variable set, because nothing puts it in `depsBuildBuild`. So `HOST_CC` gets no `NIX_*` flags and *all hardening disabled*. Test: `hostCcInCrossLive` prints `HARDENING: disabled flags: pacret pic stackclashprotection fortify3 …`. A breakbulk host unit gets the host capture, with `NIX_CC_WRAPPER_TARGET_HOST_x86_64…=1`, so host-side C code is compiled with hardening. The fixture has no host-side C code, so this did not show in the bytes. Build-script *links* are PIE + RELRO + BIND_NOW either way, because rustc requests that for x86_64 Linux itself. This is an intended difference from `buildRustPackage`.
- **pkg-config cross needs no `PKG_CONFIG_ALLOW_CROSS`.** The target capture exports `PKG_CONFIG=aarch64-unknown-linux-gnu-pkg-config` (`pkg-config-wrapper/setup-hook.sh:26`). pkg-config-rs 0.3.34 treats a customised `PKG_CONFIG` as permission to cross-compile (`src/lib.rs:640-650`). That check is where the 4 extra `rerun-if-env-changed=PKG_CONFIG*` lines come from. `buildRustPackage` sets `PKG_CONFIG_ALLOW_CROSS=1` and so never reaches that check.
- **A library given as a native input gets no flags.** With `strictDeps`, cc-wrapper, bintools-wrapper and pkg-config register their env hooks with `addEnvHooks "$targetOffset"` (`cc-wrapper/setup-hook.sh:95`, `bintools-wrapper/setup-hook.sh:36`, `pkg-config-wrapper/setup-hook.sh:24`). Only dependencies at host offset 0 (`buildInputs`) then contribute `-isystem`, `-L` or `PKG_CONFIG_PATH`. `captures.opensslAsNative` has `pkg-config` and `openssl` as native inputs and gets none of them. So the implementation doc's phrase for host units, "both input lists count as native there", is wrong as written. For host units, tools stay `nativeBuildInputs` and libraries become `buildInputs` of `pkgs.buildPackages.stdenv`, as build-platform packages.

## 5. The base capture

The base capture has no inputs. Its full contents for the host platform, x86_64:

```
AR=ar AS=as CC=gcc CXX=g++ LD=ld NM=nm OBJCOPY=objcopy OBJDUMP=objdump RANLIB=ranlib READELF=readelf SIZE=size STRINGS=strings STRIP=strip
CONFIG_SHELL=SHELL=shell=<bash>
NIX_CC=<gcc-wrapper>  NIX_BINTOOLS=<binutils-wrapper>
NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1  NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1
NIX_CFLAGS_COMPILE=   NIX_ENFORCE_NO_NATIVE=1  NIX_ENFORCE_PURITY=1
NIX_HARDENING_ENABLE=bindnow format fortify fortify3 libcxxhardeningfast pic relro stackclashprotection stackprotector strictflexarrays1 strictoverflow zerocallusedregs
NIX_SSL_CERT_FILE=SSL_CERT_FILE=/no-cert-file.crt  TZ=UTC
PATH=patchelf, gcc-wrapper, gcc, glibc-bin, coreutils, binutils-wrapper, binutils, findutils, diffutils, sed, grep, awk, tar, gzip, bzip2, make, bash, patch, xz, file
XDG_DATA_DIRS=<patchelf>/share
```

The fixture package declares no inputs. Its build script dumps its environment, once under `buildRustPackage` and once under the base capture. The results are in [`results/e2e-native.txt`](../../spikes/env-capture/results/e2e-native.txt), section "environment of a build script with no inputs".

- **Present in both:** the same compiler, binutils, coreutils, make and bash on `PATH`; the same `CC`/`AR`/… names; the same hardening, purity and certificate variables; `TZ`; Cargo's own variables.
- **Only in `buildRustPackage`:** the package's whole input set (`PKG_CONFIG*`, `LIBCLANG_PATH`, `BINDGEN_EXTRA_CLANG_ARGS`, `NIX_LDFLAGS`, the include flags in `NIX_CFLAGS_COMPILE`). These leak to every build script there. In breakbulk only the declaring package gets them, which is the point of per-package captures. Also only in `buildRustPackage`: the `setEnv` toolchain variables, `PKG_CONFIG_ALLOW_CROSS`, `RUST_LOG`, `GZIP_NO_TIMESTAMPS`, and derivation attributes (`cargoDeps`, `stdenv`, `pname`, ...).
- **Only in the base capture:** nothing. In the spike, only the driver's own variables were extra.

So yes: the base capture gives build scripts the same baseline as `buildRustPackage`, minus the things that belong to other layers.

## Recommended capture design

The draft is in [`lib/env-capture.nix`](../../lib/env-capture.nix).

- **Interface:** `capture { pkgs; platform = "target" | "host"; name; nativeInputs; inputs; debug ? false; }`. Both input lists may be functions of a package set (`p: [ p.openssl ]`):
  - `target`: `stdenv = pkgs.stdenv`, `nativeInputs` taken from `pkgs.buildPackages`, `inputs` from `pkgs`;
  - `host`: `stdenv = pkgs.buildPackages.stdenv`, `nativeInputs` from `pkgs.buildPackages.buildPackages`, `inputs` from `pkgs.buildPackages`.
- **Builder:** its own `args = [ "-e" script ]`. The script records `env -0`, sources `$stdenv/setup`, and records `env -0` again. It reaches jq and env by absolute path from the build platform, never through `PATH`.
- **Derivation settings:** `strictDeps = true`, `NIX_NO_SELF_RPATH = 1`, `preferLocalBuild`, `allowSubstitutes = false`. No `__structuredAttrs`: with structured attributes, `mkDerivation` attributes are not exported, and `buildRustPackage` does not use them.
- **Keep:** exported after setup, and (new or changed, or a `NIX_*` name).
- **Drop:** the list in section 1. Write any self-referencing names to `dropped-self-refs.txt`.
- **Output:** `$out/env.json` (sorted, flat strings). Optionally `$out/debug/` with the before and after env, unexported variables and functions.

What `breakbulk-unit` must do when it replays a capture:

1. **Start from Nix's builder environment.** The wrappers need `NIX_STORE`, `NIX_BUILD_TOP` and `TMPDIR` to accept paths (`badPath`), and `NIX_ENFORCE_PURITY=1` is in every capture. Any path the unit passes to a linker or compiler, such as `-L $TMPDIR/deps`, must therefore lie under the store, `NIX_BUILD_TOP`, `TMPDIR` or `/tmp`.
2. **Add its own seed.** Prepend ` -frandom-seed=<first 10 chars of the unit's $out basename>` to `NIX_CFLAGS_COMPILE`, the same value and position as `reproducible-builds.sh`. With this rule, C objects from cc-rs were byte-identical to `buildRustPackage`'s.
3. **Merge `PATH`, do not replace it.** If the toolchain-spec or override layers need tools on `PATH`, they append to the capture's `PATH`. Layers that "win" for `PATH` would drop the compiler. The same applies to `NIX_CFLAGS_COMPILE` (rule 2) and any `NIX_LDFLAGS` a spec adds.
4. **Apply exactly one capture**, chosen by the unit's platform and package.
5. **Set the base layer.** `SOURCE_DATE_EPOCH=315532800` goes there, now that the capture no longer carries it. Optionally `GZIP_NO_TIMESTAMPS=1`.

## Limits

- **Hooks tested:** only the hooks listed in the broad survey, plus the e2e set. Hooks that export values derived from `$out`/`$prefix` are caught by the self-reference rule, but their variable is then *missing*, not rewritten. A hook that needs a writable directory, or that runs a program at setup time, would also misbehave. None was found.
- **Platforms:** Darwin (`SDKROOT`, `xcrun`, `darwin-sdk-setup.bash`), musl and static stdenvs, Windows and wasm presets were not tested. musl is where the `NIX_*` keep rule matters, because `NIX_HARDENING_ENABLE` arrives as a derivation attribute there.
- **cmake-based `-sys` crates:** the cmake crate does not get nixpkgs' `cmakeFlags`, such as the `CMAKE_SYSTEM_*` cross settings, which `cmakeConfigurePhase` passes on the command line. That is the same as `buildRustPackage`.
- **The driver** emulates per-unit layering inside one cargo run. It is not `breakbulk-unit`. It shows that per-unit captures give the same bytes, not that the final splice and argfile code will.

## Side findings

- **cc-rs objects can embed crate source paths.** ring forces `-g3` (`build.rs:580`), so `libring_core_*.a` carries DWARF with the vendored crate's absolute path. In breakbulk that path is a crate-source store path. This is the same issue the design solves for rustc with `--remap-path-scope`, but rustc remapping does not touch C objects. `splitDebug` moves the DWARF to the `debug` output, so shipped binaries are fine. The rlib units do reference crate sources. Consider `-ffile-prefix-map=<crate src>=<name>-<version>` in `NIX_CFLAGS_COMPILE` at unit time, so C debug info uses the same stable names as Rust's.
- **Directive order:** ring's `rerun-if-changed` order depends on `read_dir` order. That is harmless, but any golden test of directives must compare those lines as a set.

## Changes to the design docs

- implementation.md, Environment capture: add `strictDeps = true`, `NIX_NO_SELF_RPATH`, the `-frandom-seed` rule, the `NIX_*` keep rule, self-reference dropping, and `SOURCE_DATE_EPOCH` moving to the base layer.
- implementation.md, "host units use the build platform's stdenv, and both input lists count as native there": libraries must be *build-platform* `buildInputs` of `pkgs.buildPackages.stdenv`, not native inputs.
- implementation.md, Environment contract: `PATH` and `NIX_CFLAGS_COMPILE` need merge rules, not "later layers win". The unit adds the random seed.
- implementation.md, Dev shell: a union of captures is only valid within one platform.
- design.md, Per-package overrides and Static and musl: the claim that captures give "the same baseline tools and hardening flags as `buildRustPackage`" holds natively. Cross host units get *more* hardening than `buildRustPackage` gives `HOST_CC`.
- The "verify in a spike" note under Environment capture can be replaced by a link to this document.
