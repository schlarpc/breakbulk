<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Target options

`targets.<triple>`: a target's toolchain, for every workspace that builds it.

## `targets`

Toolchain specs per target triple, for every workspace that builds
the triple (` workspaces.<ws>.targets `)\. Each workspace’s spec is
these definitions together with its own
` workspaces.<ws>.targets.<triple> `, evaluated with that workspace’s
toolchain, so a preset uses each workspace’s rustc\. A triple whose
preset needs no arguments gets it without an entry here, and with
entries that set other fields: the native triple, when the ` pkgs `
given to mkRepository is Linux, gets ` presets.linux ` (glibc) or
` presets.linuxStatic ` (musl); another Linux ` -gnu ` triple
` presets.linux `, a ` -musl ` one ` presets.linuxStatic `, a Windows
` -gnu ` or ` -gnullvm ` one ` presets.windows `, ` wasm32-wasip2 `
` presets.wasmComponent `, a UEFI triple ` presets.uefi `, and a
bare-metal triple that rustc links with lld ` presets.bareMetal `\. A triple
whose preset needs arguments or a choice (` -msvc `, macOS,
wasm32 without WASI) fails at evaluation, naming the preset, unless
the target sets a ` preset `, a ` linker `, or ` preset = null `\. Any
other triple, and one with ` preset = null `, uses an empty spec (the
toolchain as Cargo finds it)\.

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

Flags for this target’s C code (` CFLAGS_<triple> `)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks`

Checks on this target’s products, where ` on ` names a stage
(` linked ` for the raw link output)\. They merge over the default
checks every product gets: ` noSourceReferences ` (unless the
variant’s ` sourcePaths ` is ` "keep" `) and ` buildScriptFiles `\.
` buildScriptFiles ` fails when a build script
placed files next to the binaries (Cargo’s ` target/<profile> `,
where ` cargo run ` finds them; libraries sdl2-sys ` bundled ` copies,
Tauri’s resources) and the product does not include them, which
the ` stageHelpers.buildScriptFiles ` stage does (\#23)\.
` null ` removes a check\. Checks appear
in ` repo.checks ` as ` <ws>/<triple>/<pkg>/<name> `\.

*Type:*
attribute set of (null or submodule)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks.<name>.enable`

Whether the check exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks.<name>.ca`

false: the check’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks.<name>.on`

The stage whose output the check reads (` linked ` for the raw link output); null: the product\.

*Type:*
null or string

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.checks.<name>.run`

` { input, product, target, pkgs }: <derivation> `, which fails when the check does\.

*Type:*
raw value

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

## `targets.<name>.cxxflags`

Flags for this target’s C++ code (` CXXFLAGS_<triple> `)\.

*Type:*
list of string

*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.debugInfo`

What this target’s products do with debug info,
for every package of the target, because the units are shared\.
The stages each value puts first after ` linked ` are the traits’
` debugStages ` entry for it; a value the traits have no entry for
is an evaluation error\. A target of another format (wasm) gets
“split” or “strip” by giving the entry, as
` traits.debugStages.strip = [ { name = "strip"; run = …; } ] `\.
The built-in entries:

 - ` "split" `: the ` packDwo ` and ` splitDebug ` stages, first after
   ` linked `; ` splitDebug ` moves it to a ` debug ` output (` $debug/lib/debug/.build-id/… `); the
   target’s links get a GNU build ID, and shipped units remap
   source paths only in panic messages, ` file!() ` and diagnostics,
   so the debug info names the real sources\. ELF and Mach-O (no
   ` packDwo `): on Apple targets the debug info is the link’s
   ` .dSYM `, which goes to the ` debug ` output, and the binary’s
   debug map is removed\.
 - ` "keep" `: the ` packDwo ` stage on an ELF target, else none;
   every source path is remapped, so the debug info stays in the
   file without naming store paths\. msvc’s ` .pdb ` is a separate
   file already and goes to the ` debug ` output\.
 - ` "strip" `: the ` strip ` stage (` strip --strip-debug `), first
   after ` linked `; every source path is remapped, and no ` .dwo `
   file or packed ` .dwp ` ships\. ELF and Mach-O\. The stage still
   has a ` debug ` output whenever ` linked ` has one, which may be
   empty\.

` packDwo ` packs the ` .dwo ` files of ` split-debuginfo = "unpacked" ` into ` <file>.dwp ` in the ` debug ` output\.

` null `: the target’s traits’ ` debugInfo `: ` "split" ` on Linux
ELF targets and Apple targets, ` "keep" ` elsewhere\.

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
A string (or path, package, number, boolean) replaces the
variable’s value from the layers below, the env capture’s included; a
list of them is appended to it, joined with the variable’s separator
(` envSeparators `; by default ` : ` for search paths and unknown names, a
space for flag lists such as ` NIX_CFLAGS_COMPILE `; see
[the table](\.\./unit-builder\.md\#list-variables))\. Lists from every
layer concatenate; ` lib.mkForce ` keeps only its own definition\.

The variables’ names are read before their values, so ` lib.mkIf `
goes around the whole set (` env = lib.mkIf cond { FOO = "x"; } `): on
one value (` env.FOO = lib.mkIf false "x" `) it does not remove the
variable, and reading it is an error\.

*Type:*
lazy attribute set of (string or absolute path or package or signed integer or boolean) (replaces) or list of them (appends)

*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.envSeparators`

The separator a variable’s lists are joined with, by name, for
this target’s ` env `\. Without an entry, the built-in
table’s ([list variables](\.\./unit-builder\.md\#list-variables)),
else ` : `\.

*Type:*
lazy attribute set of string

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  CMAKE_PREFIX_PATH = ":";
}
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

Which kind of linker the preset builds for this target’s units
only: host units (build scripts, proc macros) take theirs from
[` workspaces.<ws>.host `](workspaces\.md\#workspacesnamehost), even
on the build machine’s own triple\. ` null `: the linker rustc itself picks
for the triple and Rust release, always through nixpkgs’ wrapped
C compiler: ` lld ` on Linux where rustc links with its bundled
lld, ` cc ` (the C compiler’s default, GNU ld) on other Linux
targets; ` lld-link `, ` wasm-ld `, ` wasm-component-ld ` or
` mingw-lld ` on Windows, UEFI and wasm; on macOS from a Linux
machine, ` rust-lld ` (the toolchain’s own) or ` ld64.lld ` (nixpkgs’,
for a toolchain without one)\. A kind that cannot link for this
target, or with the preset’s other settings (` mold ` with
` crossLanguageLto `), is an evaluation error\. The preset reads it,
so it needs a ` preset `\. A name in ` linkerKinds `\.

*Type:*
null or string

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

## `targets.<name>.linkerKinds`

The linker kinds ` linkerKind ` may name: breakbulk’s own
(` breakbulk.presetHelpers.builtinKinds `: ` cc `, ` lld `, ` mold `,
` clang-lld `, ` zig `, ` lld-link `, ` wasm-ld `, ` wasm-component-ld `,
` mingw-lld `, ` rust-lld `, ` ld64.lld `, ` ld.lld `), whose fields are set with
` lib.mkDefault `, and any added here or by a preset\. A kind is
chosen only by name; the default kind for a target is
breakbulk’s rule (` breakbulk.presetHelpers.linkerKind `)\.

*Type:*
attribute set of (submodule)

*Default:*

```nix
{ }
```

*Example:*

```nix
{
  wild = {
    on = traits: traits.isLinux;
    what = "Linux";
    build = { packageSet, ... }: breakbulk.presets.ccDriverLinker {
      inherit packageSet;
      cc = (packageSet.stdenvAdapters.useWildLinker packageSet.stdenv).cc;
      flag = "-fuse-ld=wild";
    };
  };
}

```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.bitcode`

Whether the linker reads rustc’s LLVM bitcode, as ` crossLanguageLto ` (` -C linker-plugin-lto `) needs\.

*Type:*
boolean

*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.build`

` args: path `: the linker\. ` args ` is ` { pkgs; packageSet; llvm; lld; zig; triple; traits; } `: mkRepository’s
` pkgs `, the package set whose C toolchain drives the link,
nixpkgs’ LLVM packages of rustc’s major release (the
toolchain’s facts), an ` lld ` package a preset passes, or
null, and linuxPortable’s ` zig cc `\. A C compiler driver
with a flag is ` breakbulk.presets.ccDriverLinker { packageSet; flag; } `\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.incompatible`

` ctx: null or message `: why the kind cannot link in this
context, which is an evaluation error naming the kind\.
` ctx ` is ` { triple; traits; lto; staticNonPie; zig; } `
(` staticNonPie `: the link makes non-PIE static glibc
executables; ` zig `: linuxPortable’s ` zig cc `, or null)\.

*Type:*
raw value

*Default:*

```nix
_: null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.lld`

` args: { name; version; patches; } `, the LLD the kind links
with, for the macOS SDK’s linker requirements (` args `:
` { rustc; llvm; } `), or null for a kind that is not an
Apple linker\.

*Type:*
null or raw value

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.on`

` traits: bool `: whether the kind links for a target with these [traits](\.\./\.\./explanation/internals/toolchains\.md\#target-traits)\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.linkerKinds.<name>.what`

The targets ` on ` accepts, as messages name them (` "Linux" `)\.

*Type:*
string

*Default:*

```nix
"some"
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.preset`

A toolchain preset: a module of this target spec, which the spec
imports (` breakbulk.presets.* `, a preset with its options bound,
such as ` breakbulk.presets.windows { inherit sdk; } `, or a module
of your own)\. It is evaluated once per workspace that builds this
triple, with the module arguments ` pkgs `, ` name ` (the triple) and
` toolchain ` (the workspace’s), and reads the target’s other
options (` config.traits `, ` config.linkerKind `, …)\. The built-in
presets set their fields with ` lib.mkDefault ` (lists
concatenate; use ` lib.mkForce ` to replace one), so fields set
here override them, and their ` stages ` field by field\. Set
` null ` to use no preset on a target that has a default one, or
that would need one (rustc’s own linker choice and the C
toolchain Cargo finds)\. The preset is chosen before it is
imported, so a preset cannot choose another one\.

*Type:*
null or module

*Default:*
for the native triple, ` breakbulk.presets.linux ` when the ` pkgs `
given to mkRepository is Linux with glibc,
` breakbulk.presets.linuxStatic ` when it is Linux with musl
(` pkgs.pkgsMusl `); for another Linux ` -gnu ` triple
` breakbulk.presets.linux `, a Linux ` -musl ` triple
` breakbulk.presets.linuxStatic `, a Windows ` -gnu ` or ` -gnullvm `
triple ` breakbulk.presets.windows `, ` wasm32-wasip2 `
` breakbulk.presets.wasmComponent `, a UEFI triple
` breakbulk.presets.uefi `, a bare-metal triple whose rustc spec
links with lld ` breakbulk.presets.bareMetal `; ` null ` otherwise, which is an
evaluation error for ` -msvc `, macOS and wasm32 without WASI unless
` linker ` is set

*Example:*

```nix
breakbulk.presets.windows { inherit sdk; }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.runner`

The target runner: the program that runs this target’s test
binaries (wine, wasmtime, qemu-user, …), invoked as ` <runner> <binary> <args…> ` like Cargo’s ` target.<triple>.runner `: a
program, or a list of the program and its first arguments\.
` null `: run directly\. Not the test runner
([` packages.<name>.test.runner `](packages\.md\#packagesnametestrunner)),
which starts a binary in its run, under this one\.
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

## `targets.<name>.rustcTarget`

What rustc and Cargo are given as ` --target `: the target’s name (a
triple rustc knows), or a ` .json ` target spec whose file is named
after the target (` targets.my-board.rustcTarget = ./boards/my-board.json `)\. Cargo names a ` .json ` target by its file
stem: it reads the target’s configuration from
` [target.my-board] ` and ` CARGO_TARGET_MY_BOARD_* `, and build
scripts get ` TARGET=my-board `\. Everything breakbulk derives from
the target (derivation names, ` CC_<name> ` and the other per-target
variables, the Cargo config of ` linker ` and ` rustflags `) uses the
name, so a file with another stem is an error\. Cargo gets a copy
of the file named ` <name>.json `\. A ` .json ` target has no built-in
traits; set ` traits `\.

*Type:*
absolute path or string

*Default:*
the target’s name

*Example:*

```nix
./boards/my-board.json
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

## `targets.<name>.stages`

Post-link stages for this target’s products, merged over the
stages ` debugInfo ` inserts; a preset may define some (the wasm
presets’ wasm-bindgen and componentize chains, the darwin
preset’s ` adhocSign `)\. Definitions merge field by field, as
submodules do: ` stages.wasmOpt.after = "mine" ` keeps the preset’s
` run `\. ` null ` removes a stage (` enable = false `)\. A stage runs
before ` install ` and sees the flat link
output, unless it is ordered after ` install ` (` after = "install" `, or after such a stage); then it sees the installed
layout (` bin/ `, ` lib/ `, ` pkg/ `), the place for wrappers and
packaging\. A stage with no ` after ` runs after the stages
` debugInfo ` inserts, unless it is ordered before one of them\.
Package settings (` packages.<name>.stages `) merge
over these, a package’s values winning at equal priority\. Neither
may remove the ` splitDebug ` or ` strip ` stage
` debugInfo ` inserts or add ` splitDebug ` where it inserts none; set
` debugInfo ` instead\. ` packDwo ` is an ordinary stage: ` null `
removes it\.

*Type:*
attribute set of (null or submodule)

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

## `targets.<name>.stages.<name>.enable`

Whether the stage exists\. A definition ` null ` sets it to false\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stages.<name>.after`

The stage or stages this one runs after\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stages.<name>.before`

The stage or stages this one runs before\.

*Type:*
null, stage name or list of stage names

*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stages.<name>.ca`

false: the stage’s derivation stays input-addressed when the
repository’s ` ca ` is on, and its ` run ` may return something that
is not a derivation (which cannot be made content-addressed)\.

*Type:*
boolean

*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stages.<name>.run`

` { input, product, target, pkgs }: <derivation> `: the stage’s output from its input, the previous stage’s\.

*Type:*
raw value

*Declared by:*
 - [lib/modules/target-spec\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/target-spec.nix)

## `targets.<name>.stdenv`

The stdenv whose setup hooks the target units’ environment
capture records (its C compiler, wrapper flags, hardening), for
the base capture and every package’s own\. ` null `: the package
set’s stdenv (` packageSet.stdenv `, or the build machine’s for a
target without a package set)\. It must build for this target\.
` presets.darwin ` sets it, unless given ` deploymentTarget `, to
the build machine’s with a hook that exports rustc’s
` MACOSX_DEPLOYMENT_TARGET `; a stdenv set here replaces that\.

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
(` breakbulk.targetTraits.resolve `); the option’s value is the
resolved traits, which presets read as ` config.traits `\. Every
platform-dependent decision reads them: the linker kind, the
default debug handling, the install layout and file names,
debuginfo side files, the dynamic-library path of test processes,
static linking\. Base
fields (` arch `, ` vendor `, ` os `, ` env `, ` abi `, ` families `, as
rustc’s ` target_* ` cfg values) recompute the derived ones
(` isLinux `, ` objectFormat `, ` executableSuffix `, ` dylibPathVar `, …);
derived fields set here win over the computed ones\. The names
tools give the target are derived fields too: ` nixpkgsSystem `
(the nixpkgs platform the presets import the target’s package set
for: a ` pkgsCross ` attribute name, or a ` crossSystem ` such as
` { config = "armv7l-unknown-linux-musleabihf"; } `), ` zigArch `
(` zig cc -target `), ` qemuArch ` (qemu-user) and ` xwinArch ` (the
msvc SDK’s library directories); set one where a tool spells
the target otherwise\. A triple with
no built-in traits (a custom target, a ` .json ` target spec given
as ` rustcTarget `, an uncommon OS) needs at least the base fields here; reading any
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
