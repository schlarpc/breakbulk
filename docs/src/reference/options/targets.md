<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Target options

`targets.<triple>`: a target's toolchain, for every workspace that builds it.

## `targets`

Toolchain specs per target triple, for every workspace that builds
the triple (` workspaces.<ws>.targets `)\. Each workspace’s spec is
these definitions together with its own
` workspaces.<ws>.targets.<triple> `, evaluated with that workspace’s
toolchain, so a preset uses each workspace’s rustc\. When the ` pkgs `
given to mkRepository is Linux, the native triple always has an
entry, with ` presets.linux ` (glibc) or ` presets.linuxStatic ` (musl)
by default\. Any other triple with no entry here or
in the workspace uses an empty spec (the toolchain as Cargo finds
it)\.

*Type:*
attribute set of module

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/targets\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/targets.nix)

## `targets.<name>.packageSet`

The nixpkgs package set for this platform: the target units’
env capture uses its stdenv, and ` packages.<name>.inputs `
functions are called with it for target units\. ` null `: ` pkgs `
itself for the native triple; for any other triple there is no
package set (msvc, wasm32-unknown-unknown), the env capture
comes from the build platform, and package inputs are an
error\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.ar`

The archiver build scripts use for this target (` AR_<triple> `)\.

*Type:*
null or string or absolute path or package

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.bindgen.extraClangArgs`

Extra libclang arguments for bindgen (` BINDGEN_EXTRA_CLANG_ARGS_<triple> `)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.cc`

The C compiler build scripts use for this target (` CC_<triple> `)\.

*Type:*
null or string or absolute path or package

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.cflags`

C and C++ flags for this target’s C code (` CFLAGS_<triple> `, ` CXXFLAGS_<triple> `)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks`

Checks on this target’s products: ` { on ? <the product>; run = { input, product, pkgs }: <derivation>; } `, where ` on ` names a
stage (` linked ` for the raw link output)\. Every product also
gets ` noSourceReferences ` and ` buildScriptFiles `: it fails when a build script
placed files next to the binaries (Cargo’s ` target/<profile> `,
where ` cargo run ` finds them; libraries sdl2-sys ` bundled ` copies,
Tauri’s resources) and the product does not include them, which
the ` stageHelpers.buildScriptFiles ` stage does (IFD mode; \#23)\.
` null ` removes a check\. Checks appear
in ` repo.checks ` as ` <ws>/<triple>/<pkg>/<name> `\.

*Type:*
attribute set of (null or raw value)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.cxx`

The C++ compiler build scripts use for this target (` CXX_<triple> `)\.

*Type:*
null or string or absolute path or package

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.debugInfo`

What this target’s products do with debug info,
for every package of the target, because the units are shared:

 - ` "split" `: the ` splitDebug ` stage, first after ` linked `, moves
   it to a ` debug ` output (` $debug/lib/debug/.build-id/… `); the
   target’s links get a GNU build ID, and shipped units remap
   source paths only in panic messages, ` file!() ` and diagnostics,
   so the debug info names the real sources\. ELF only\.
 - ` "keep" `: no stage; every source path is remapped, so the debug
   info stays in the file without naming store paths\. msvc’s
   ` .pdb ` is a separate file already and goes to the ` debug `
   output\.
 - ` "strip" `: the ` strip ` stage (` strip --strip-debug `), first
   after ` linked `; every source path is remapped\. ELF only\.

` null `: the target’s traits’ ` debugInfo `: ` "split" ` on Linux
ELF targets, ` "keep" ` elsewhere\.

*Type:*
null or one of “split”, “keep”, “strip”

*Default:*

```nix
null
```

*Example:*

```nix
"keep"
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.env`

Environment added to this target’s units only (layer 4 of the
unit environment contract; which units are on which
[side](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)),
never through Cargo’s ` [env] `, so build-script compiles and proc
macros (host units) do not see it\.
List-like variables (` PATH `, ` NIX_CFLAGS_COMPILE `, …) are
appended to the env capture’s value\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.host.env`

Environment added to host units of this target’s plans only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.host.linker`

The linker for host units of this target’s plans: given to
Cargo as ` target.<host triple>.linker ` when the triples
differ; when they are the same, host units’ ` -C linker ` and
` RUSTC_LINKER ` are rewritten to it\.

*Type:*
null or string or absolute path or package

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.host.stdenv`

The stdenv of the host units’ environment capture (build
scripts, proc macros and their dependencies) of this target’s
plans\. ` null `: the build machine’s (` buildPackages.stdenv ` of
the target’s package set)\. It must build for the build machine\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Example:*

```nix
pkgs.clangStdenv
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linker`

The linker for this target’s units (` target.<triple>.linker ` in
Cargo config)\. A store path\. The preset sets it from
` linkerKind `; a value here wins over both\.

*Type:*
null or string or absolute path or package

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKind`

Which kind of linker the preset builds for this target’s units,
and for host units (build scripts, proc macros) when this is the
build machine’s own triple\. ` null `: the linker rustc itself picks
for the triple and Rust release, always through nixpkgs’ wrapped
C compiler: ` lld ` on Linux where rustc links with its bundled
lld, ` cc ` (the C compiler’s default, GNU ld) on other Linux
targets; ` lld-link `, ` wasm-ld `, ` wasm-component-ld ` or
` mingw-lld ` on Windows and wasm\. A kind that cannot link for this
target, or with the preset’s other settings (` mold ` with
` crossLanguageLto `), is an evaluation error\. It needs a ` preset `
here; a target defined directly from a preset takes ` linkerKind `
as the preset’s argument\.

*Type:*
null or one of “cc”, “clang-lld”, “lld”, “lld-link”, “mingw-lld”, “mold”, “wasm-component-ld”, “wasm-ld”

*Default:*

```nix
null
```

*Example:*

```nix
"mold"
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.preset`

A toolchain preset (` breakbulk.presets.* `, or a preset with its
options bound, such as ` breakbulk.presets.windows { inherit sdk; } `)\.
It is called once per workspace that builds this triple, with
` pkgs `, the triple and the workspace’s ` toolchain `, whose rustc
it uses unless it was given ` rustc ` itself: the windows (msvc) and wasm presets
pick the LLVM tools and the wasi-sdk matching each workspace’s
compiler\. It sets the fields below at default priority, so
fields set here override the preset’s (lists concatenate; use
` lib.mkForce ` to replace one)\. Defining the target as
` breakbulk.presets.<name> { inherit pkgs; triple = …; } ` gives
the same fields, except that the preset then sees no workspace
toolchain (pass ` rustc ` there)\. Set ` null ` to use no preset on
the native target (rustc’s own linker choice and the C toolchain
Cargo finds)\.

*Type:*
null or breakbulk preset (function)

*Default:*
for the native triple, unless the target is defined directly from
a preset: ` breakbulk.presets.linux ` when the ` pkgs ` given to
mkRepository is Linux with glibc, ` breakbulk.presets.linuxStatic `
when it is Linux with musl (` pkgs.pkgsMusl `); ` null ` otherwise

*Example:*

```nix
breakbulk.presets.linuxStatic
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.runner`

The program that runs this target’s test binaries (wine,
wasmtime, qemu-user, …), invoked as ` <runner> <binary> <args…> `
like Cargo’s ` target.<triple>.runner `: a program, or a list of
the program and its first arguments\. ` null `: run directly\.
May be a function ` { lockfile, workspace }: <runner> ` for runners
that depend on the workspace (wasm-bindgen-test-runner must
match the locked wasm-bindgen)\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.rustflags`

Extra rustflags for this target’s units, passed to Cargo with
` --config ` under the key the project itself uses
(` build.rustflags ` or ` target.<triple>.rustflags `), so both sets
arrive\. Host units never get them\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stagePreset`

Which default stage chain this target’s products get
(` breakbulk.stages.defaultStageNames `: ` wasmWeb ` bindgen and
wasmOpt; ` wasmComponent ` wasmOpt and componentize)\. Presets set
it; ` null `: none\. Debug info is handled by ` debugInfo `, not by
the chain\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"wasmWeb"
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stages`

Post-link stages for this target’s products, merged over the
stage ` debugInfo ` inserts and the stage preset’s defaults
(` stagePreset `)\. A stage is ` { after ? null; before ? null; run = { input, product, target, pkgs }: <derivation>; } `; ` null `
removes one\. A stage runs before ` install ` and sees the flat link
output, unless it is ordered after ` install ` (` after = "install" `, or after such a stage); then it sees the installed
layout (` bin/ `, ` lib/ `, ` pkg/ `), the place for wrappers and
packaging\. Package settings (` packages.<name>.stages `) merge
over these\. Neither may remove the stage ` debugInfo ` inserts or
add ` splitDebug ` where it inserts none; set ` debugInfo ` instead\.

*Type:*
attribute set of (null or raw value)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  # Strip the symbol tables too, after debug info is split off.
  stripAll = { after = "splitDebug"; run = breakbulk.stageHelpers.strip { all = true; }; };
}

```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stdenv`

The stdenv whose setup hooks the target units’ environment
capture records (its C compiler, wrapper flags, hardening), for
the base capture and every package’s own\. ` null `: the package
set’s stdenv (` packageSet.stdenv `, or the build machine’s for a
target without a package set)\. It must build for this target\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Example:*

```nix
pkgs.clangStdenv
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.testSystem`

The Nix system that runs this target’s test runs, so Nix sends them to native builders\. ` null `: the build machine’s\.

*Type:*
null or string

*Default:*

```nix
null
```

*Example:*

```nix
"aarch64-linux"
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.traits`

Facts about this target platform that override or extend the
built-in ones breakbulk reads from the triple
(` breakbulk.targetTraits.resolve `)\. Every platform-dependent
decision reads the resulting traits: the linker kind, the default
debug handling, the install layout and file names, debuginfo side
files, the dynamic-library path of test processes, static linking\.
Base
fields (` arch `, ` vendor `, ` os `, ` env `, ` abi `, ` families `, as
rustc’s ` target_* ` cfg values) recompute the derived ones
(` isLinux `, ` objectFormat `, ` executableSuffix `, ` dylibPathVar `, …);
derived fields set here win over the computed ones\. A triple with
no built-in traits (a custom target, a ` .json ` target spec, an
uncommon OS) needs at least the base fields here; reading any
trait of it otherwise fails with a message naming this option\.

*Type:*
attribute set of anything

*Default:*

```nix
{ }
```

*Example:*

```nix
# A board breakbulk has no built-in traits for (a custom target
# spec): an ELF bare-metal target.
{ os = "none"; env = ""; abi = "eabihf"; }

```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)
