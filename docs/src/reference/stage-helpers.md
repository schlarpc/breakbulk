<!-- Generated from lib/stage-helpers by `nix run .#update-docs-options`; edit the helper declarations there. -->

# Stage helpers

`breakbulk.stageHelpers` holds ready-made stages and checks. A helper
is the `run` of a stage or check. Use it as it is, or call it with
options first:

```nix
packages.app.stages.rpath = {
  run = breakbulk.stageHelpers.patchelfRpath { libs = [ pkgs.vulkan-loader ]; };
};
packages.app.checks.selfContained.run = breakbulk.stageHelpers.noStorePaths;
```

The options are module options. An unknown option fails at
evaluation and lists the helper's options. A value of the wrong type
fails at evaluation and names the option. A configured helper called
with more options sets them over the earlier ones.

The stage helpers that change binaries expect the flat link output,
so run them before `install`; `deterministicZip` packs any tree and
can follow it. What a stage or check function receives, `product`
included, is in [Stage and check functions](stage-functions.md).

## Stages

### `bindgen`

Runs `wasm-bindgen` on the input's single `.wasm` file and
writes its JavaScript glue and processed module to `pkg/`,
which `install` keeps. The `wasmWeb` preset's first stage.

#### `bindgen.extraArgs`

More arguments for `wasm-bindgen`, before the input file.

*Type:* list of string

*Default:* `[ ]`

*Example:* `[ "--no-typescript" ]`

#### `bindgen.target`

wasm-bindgen's `--target`: the kind of JavaScript to
generate (`web`, `bundler`, `nodejs`, `deno`,
`no-modules`, `module`, `experimental-nodejs-module`).

*Type:* string

*Default:* `"web"`

*Example:* `"nodejs"`

#### `bindgen.wasmBindgen`

The wasm-bindgen CLI. It must be the version of the
`wasm-bindgen` crate the module was built with.

`null` finds it from the product's Cargo.lock
(`product.lockfile`, or `product.lockEntries` for a
product made with `mkProduct` that passes parsed entries):

1. The version, X.Y.Z, is the lockfile's `wasm-bindgen`
   package from a registry. Evaluation fails when the
   lockfile has none, several versions, or one from git or
   a path.
2. nixpkgs' `wasm-bindgen-cli_X_Y_Z` from the stage's
   `pkgs`, when it has that attribute.
3. Otherwise wasm-bindgen-cli X.Y.Z from crates.io, built
   with the stage's `pkgs.rustPlatform`, when breakbulk's
   table `lib/wasm-bindgen-hashes.nix` has its hashes.
4. Otherwise evaluation fails, naming the version. Pass
   the CLI here, for example
   `breakbulk.wasmBindgen.forVersion { inherit pkgs;
   version = "X.Y.Z"; hashes."X.Y.Z" = { hash = …;
   cargoHash = …; }; }`.

*Type:* null or package

*Default:* `null`

*Example:* `pkgs.wasm-bindgen-cli_0_2_100`

### `buildScriptFiles`

Copies the files the build scripts of the product's target
placed next to the binaries (Cargo's `target/<profile>`, where
`cargo run` and a Windows loader find them: shared libraries that
sdl2-sys `bundled` or ort-sys `copy-dylibs` copy there, Tauri's
external binaries and resources) into the product, beside its own
files. `install` then lays them out with them: a DLL next to the
`.exe` in `bin/`, a `.so` in `lib/`, where on Linux the binary
needs a run path to find it (`patchelfRpath`). Symlinks are
resolved. A file name the product already has fails the stage.
Run it before `install`.

It has no options.

### `buildScriptPath`

Copies a file or directory that a build script of the
product's target made into the product, at `to`. Name it one
of two ways:

- `links` and `key`: the path a script publishes as `links`
  metadata (`cargo::metadata=<key>=<path>`), which a
  dependent's build script sees as `DEP_<LINKS>_<KEY>`. Cargo
  defines this interface, so prefer it where the script has
  one. wasmtime's C API publishes its headers so:
  `{ links = "wasmtime-c-api"; key = "include"; to = "include"; }`.
- `package` and `from`: a path in the `OUT_DIR` of the
  package's build-script run, for a script without `links`.
  When the product's roots depend on two versions of the
  package, `version` says which; without it the stage fails
  naming them.

The run is one of those the product's roots depend on
([Build-script runs](stage-functions.md#build-script-runs)).
Symlinks are resolved. A path the product already has fails
the stage. `install` keeps a top-level directory as it is, so
the stage can run before `install` or after it.

#### `buildScriptPath.from`

The path relative to the run's `OUT_DIR`; `.` is the whole directory.

*Type:* null or relative path without `..`

*Default:* `null`

*Example:* `"include"`

#### `buildScriptPath.key`

The metadata key whose value is the path, as the script
prints it. When it prints the key more than once, the last
value counts, as for `DEP_<LINKS>_<KEY>`.

*Type:* null or string

*Default:* `null`

*Example:* `"include"`

#### `buildScriptPath.links`

The `links` name of the package whose build script publishes the path. Set `key` with it.

*Type:* null or string

*Default:* `null`

*Example:* `"wasmtime-c-api"`

#### `buildScriptPath.package`

The name of the package whose build script made the path. Set `from` with it.

*Type:* null or string

*Default:* `null`

*Example:* `"wasmtime-c-api-impl"`

#### `buildScriptPath.to`

Where the path goes, relative to the top of the product.

*Type:* relative path without `..`

*Default:* none; the option must be set

*Example:* `"include"`

#### `buildScriptPath.version`

The version of `package`. `null`: the one version the product's roots depend on.

*Type:* null or string

*Default:* `null`

*Example:* `"50.0.1"`

### `componentize`

Makes a WebAssembly component from the input's single core
module with `wasm-tools component new`, then adds metadata
with `wasm-tools metadata add`, as `wasmMetadata` does: by
default the fields of the package's `Cargo.toml`
(`cargoMetadata`), with `metadata` over them. With nothing to
add it runs no `metadata add`. The module keeps its file
name. The `wasmComponent` preset's last stage before
`install`.

#### `componentize.adapter`

An adapter module (`--adapt`) that implements imports of
the core module not bound to WIT interfaces, such as
`wasi_snapshot_preview1`. Either a module file, whose file
name wasm-tools takes as the import module's name, or
`{ name; module; }`, where `name` is the import module it
implements.

*Type:* null or package or absolute path or (submodule)

*Default:* `null`

*Example:* `{ name = "wasi_snapshot_preview1"; module = ./wasi_snapshot_preview1.reactor.wasm; }`

#### `componentize.cargoMetadata`

Fill the `metadata` fields that are not set from the package's
`Cargo.toml` (`product.package`), as cargo-component does:
`name`, `authors` (joined with `,`), `description`, `licenses`
(from `license`), `source` (from `repository`), `homepage` and
`version`, each when the manifest has it. `false` adds only what
`metadata` sets. A product without `package` (made with
`mkProduct` directly) gets no defaults.

*Type:* boolean

*Default:* `true`

#### `componentize.metadata`

Metadata for `wasm-tools metadata add`, which works on core
modules and on components. Each field is passed as the flag of
its name in kebab case: `processedBy` is `--processed-by`.

- A string is passed as it is.
- A derivation or a path is read when the stage runs: the flag
  gets its file's content, without one trailing newline. A string
  such as `"${drv}"` is not read: it is passed as the store path
  it names.
- A list is passed once per element.
- An attribute set is passed once per entry, as `NAME=VERSION`.
- `null` leaves the field out.

Fields not listed here are passed the same way, for the flags of
later wasm-tools versions. With `cargoMetadata`, each string field
that has a `Cargo.toml` field and is not set here, not even to
`null`, comes from the package's manifest.

*Type:* open submodule of attribute set of (null or string or package or absolute path or list of (string or package or absolute path) or attribute set of (string or package or absolute path))

*Default:* `{ }`

*Example:*

```nix
{
  name = "app:core";
  revision = revisionFile;   # a derivation: its file's content
  processedBy.breakbulk = "0.1.0";
  homepage = null;           # not from Cargo.toml
}
```

#### `componentize.metadata.authors`

The people or organisation responsible, a free-form string. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `authors` from `Cargo.toml`, joined with `,`, with `cargoMetadata`; else `null`

#### `componentize.metadata.description`

A description. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `description` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.metadata.homepage`

A URL with more information; wasm-tools fails on a string that is not a URL. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `homepage` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.metadata.language`

Source languages, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ Rust = "1.99.0"; }`

#### `componentize.metadata.licenses`

The licenses, as an SPDX expression; wasm-tools fails on any other string. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `license` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.metadata.name`

The module's or component's name, in the names section. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `name` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.metadata.processedBy`

Tools that processed the module, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ breakbulk = "0.1.0"; }`

#### `componentize.metadata.revision`

The source control revision. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* `null`

#### `componentize.metadata.sdk`

SDKs, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ wasi-sdk = "25"; }`

#### `componentize.metadata.source`

A URL of the source code; wasm-tools fails on a string that is not a URL. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `repository` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.metadata.version`

The version of the packaged software. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `version` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `componentize.wasmTools`

The package to run instead of `wasm-tools` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `deterministicZip`

Packs the input's files into one zip file whose bytes depend
only on the files' contents, names and execute bits: entries
in byte order of their paths, every time 1980-01-01 00:00 UTC,
modes 0644 or 0755, no owners, extra timestamps or directory
entries. The output is a directory holding the zip file.

#### `deterministicZip.name`

The zip file's name. `null`: `<product name>.zip`.

*Type:* null or string

*Default:* `null`

*Example:* `"app-linux-x86_64.zip"`

#### `deterministicZip.zip`

The package to run instead of `zip` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `install`

Lays the flat link output out as an installed tree. Every product
has this stage unless `install = null` removes it.

A root's file (`product.rootFiles`) goes by its kind: a bin to
`bin/`, a staticlib to `lib/`, a cdylib or dylib to the target
traits' `sharedLibraryDir` (`bin/` on Windows and Cygwin, where
DLLs are found beside the executable; `lib/` elsewhere). Other
files (renamed or added by a stage, import libraries) go by the
traits' suffixes: static libraries and `.rlib` to `lib/`, shared
libraries to `sharedLibraryDir`, executables to `bin/`. Where
executables have no suffix, an executable file goes to `bin/`. A
suffix that executables and shared libraries share (`.wasm`)
decides nothing. A debug side file (`.pdb`) goes next to the file
of the same stem, else to `bin/`. Anything else stays at the top.
Top-level directories are copied as they are, so `bindgen`'s
`pkg/` and a stage's `share/` are kept.

The link units' debuginfo side files (`product.linkedDebug`:
`.pdb`, `.dwp`, `.dwo`) go to a `debug` output in the same layout,
so a `.pdb` sits in `$debug/bin` as its `.exe` does in `$out/bin`.
Not when an earlier stage split debug information
(`product.debugSplit`), whose `debug` output holds them, and not
for wasm.

It has no options.

### `patchelfRpath`

Adds run paths to every dynamically linked ELF file, so that it
finds shared libraries loaded at run time (`dlopen`, or a
library a build script placed next to it). Nothing shrinks the
run paths afterwards.

#### `patchelfRpath.libs`

The run paths to add, in order. A package or a path adds its
`lib` directory; a string is added as it is.

*Type:* non-empty (list of (string or absolute path or package))

*Default:* none; the option must be set

*Example:* `[ pkgs.vulkan-loader "$ORIGIN/../lib" ]`

#### `patchelfRpath.patchelf`

The package to run instead of `patchelf` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `removeSourceReferences`

Replaces the hash of every source store path in the product's
files with `e`s of the same length, as nixpkgs'
`remove-references-to` does, and changes nothing else. The
product then no longer references its sources, and
`noSourceReferences` passes. The usual cause of such a
reference is `env!("CARGO_MANIFEST_DIR")` kept in a string:
rustc's path remapping rewrites panic locations, `file!()` and
debug information, not `env!` values.

Use it only when the program never reads the path: a program
that opens `CARGO_MANIFEST_DIR/assets/…` at run time finds it
only while the source is in its closure. It is never added on
its own; add it per package, where `noSourceReferences`'s
failure says (here, on Linux with `debugInfo = "split"`):

```nix
packages.app.stages.removeSourceReferences = {
  after = "splitDebug";
  run = breakbulk.stageHelpers.removeSourceReferences;
};
```

It edits bytes, so it breaks a code signature made before it
(the linker signs every binary for Apple's arm64 targets):
sign again after it.

#### `removeSourceReferences.sources`

The store paths whose hashes are replaced. `null`: the
product's `sourcePaths` (its source views and crate sources),
which `noSourceReferences` checks.

*Type:* null or (list of (string or absolute path or package))

*Default:* `null`

### `splitDebug`

Moves the debug information of every ELF file into the stage's
`debug` output, at `lib/debug/.build-id/<xx>/<rest>.debug` (from
the file's GNU build ID), where gdb and debuginfod look for it.
The file keeps its symbol table and gets a `.gnu_debuglink`.
A file without debug information is left as it is; one with debug
information but no build ID fails the stage.

The `.dwo` files a binary names (`split-debuginfo = "unpacked"`)
are packed into `<binary>.dwp` with `llvm-dwp`; a `<binary>.dwp`
(`"packed"`) moves next to the `.debug` file, where gdb finds it,
with a symlink at its place in the install layout.
`targets.<triple>.debugInfo = "split"` inserts this stage.

#### `splitDebug.binutils`

The package to run instead of `binutils-unwrapped-all-targets` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

#### `splitDebug.llvm`

The package to run instead of `llvm` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `strip`

Runs `strip` on every ELF file: `--strip-debug`, or
`--strip-all` with `all`. `targets.<triple>.debugInfo = "strip"`
inserts this stage.

#### `strip.all`

Also remove the symbol tables (`--strip-all`), not only the debug information.

*Type:* boolean

*Default:* `false`

#### `strip.binutils`

The package to run instead of `binutils-unwrapped-all-targets` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `wasmMetadata`

Adds `metadata` to every `.wasm` file in place with
`wasm-tools metadata add`, which works on core modules and on
components (on a component's outermost level). With
`cargoMetadata`, the default, the fields not set come from the
package's `Cargo.toml`. `componentize` adds metadata in the
same way; use this stage for a core module, or after
`componentize` for values it should not add. With nothing to
add it copies its input. It fails when the input has no
`.wasm` file.

#### `wasmMetadata.cargoMetadata`

Fill the `metadata` fields that are not set from the package's
`Cargo.toml` (`product.package`), as cargo-component does:
`name`, `authors` (joined with `,`), `description`, `licenses`
(from `license`), `source` (from `repository`), `homepage` and
`version`, each when the manifest has it. `false` adds only what
`metadata` sets. A product without `package` (made with
`mkProduct` directly) gets no defaults.

*Type:* boolean

*Default:* `true`

#### `wasmMetadata.metadata`

Metadata for `wasm-tools metadata add`, which works on core
modules and on components. Each field is passed as the flag of
its name in kebab case: `processedBy` is `--processed-by`.

- A string is passed as it is.
- A derivation or a path is read when the stage runs: the flag
  gets its file's content, without one trailing newline. A string
  such as `"${drv}"` is not read: it is passed as the store path
  it names.
- A list is passed once per element.
- An attribute set is passed once per entry, as `NAME=VERSION`.
- `null` leaves the field out.

Fields not listed here are passed the same way, for the flags of
later wasm-tools versions. With `cargoMetadata`, each string field
that has a `Cargo.toml` field and is not set here, not even to
`null`, comes from the package's manifest.

*Type:* open submodule of attribute set of (null or string or package or absolute path or list of (string or package or absolute path) or attribute set of (string or package or absolute path))

*Default:* `{ }`

*Example:*

```nix
{
  name = "app:core";
  revision = revisionFile;   # a derivation: its file's content
  processedBy.breakbulk = "0.1.0";
  homepage = null;           # not from Cargo.toml
}
```

#### `wasmMetadata.metadata.authors`

The people or organisation responsible, a free-form string. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `authors` from `Cargo.toml`, joined with `,`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.description`

A description. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `description` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.homepage`

A URL with more information; wasm-tools fails on a string that is not a URL. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `homepage` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.language`

Source languages, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ Rust = "1.99.0"; }`

#### `wasmMetadata.metadata.licenses`

The licenses, as an SPDX expression; wasm-tools fails on any other string. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `license` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.name`

The module's or component's name, in the names section. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `name` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.processedBy`

Tools that processed the module, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ breakbulk = "0.1.0"; }`

#### `wasmMetadata.metadata.revision`

The source control revision. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* `null`

#### `wasmMetadata.metadata.sdk`

SDKs, by name, as `NAME=VERSION` in the producers section.

*Type:* attribute set of (string or package or absolute path)

*Default:* `{ }`

*Example:* `{ wasi-sdk = "25"; }`

#### `wasmMetadata.metadata.source`

A URL of the source code; wasm-tools fails on a string that is not a URL. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `repository` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.metadata.version`

The version of the packaged software. `null` leaves it out.

*Type:* null or string or package or absolute path

*Default:* the package's `version` from `Cargo.toml`, with `cargoMetadata`; else `null`

#### `wasmMetadata.wasmTools`

The package to run instead of `wasm-tools` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

### `wasmOpt`

Runs binaryen's `wasm-opt` on every `.wasm` file, in place. In
the `wasmWeb` and `wasmComponent` presets.

#### `wasmOpt.binaryen`

The package to run instead of `binaryen` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

#### `wasmOpt.features`

The wasm features `wasm-opt` may assume, each passed as
`--enable-<feature>`. The default is what rustc enables on
`wasm32-unknown-unknown` since 1.87. wasm-opt's own default
is the MVP, which rejects a Rust module that uses
`memory.copy`.

*Type:* list of string

*Default:*

```nix
[
  "bulk-memory"
  "multivalue"
  "mutable-globals"
  "nontrapping-float-to-int"
  "reference-types"
  "sign-ext"
]
```

#### `wasmOpt.flags`

The optimisation arguments for `wasm-opt`.

*Type:* list of string

*Default:* `[ "-Oz" ]`

*Example:* `[ "-O3" ]`

## Checks

Use these as `checks.<name>.run`.

### `buildScriptFilesIncluded`

Fails when a build script of the product's target placed files
next to the binaries (Cargo's `target/<profile>`, where `cargo run`
and a Windows loader find them) and the product holds no file of
that name. The message names the files, the `buildScriptFiles`
stage that includes them, at its place in this product's stage
order, and how to remove the check. Every product has it as the
check `buildScriptFiles`; it passes when no build script placed
anything.

It has no options.

### `buildScriptPaths`

Fails when a build script of the product's target declared a
`rerun-if-changed` path that was not in its view when it ran.
Such a script often skips work without saying so: it finds no
file and reads nothing. The run lists the missing paths in its
`flags` output (`missing-paths.json`). The message names each
path, the package that declared it and the option to add it to:
`extraSources` for a path in the repository, `inputs` (or
`nativeInputs`) for one outside it. It ends with the `allow`
setting for the paths and how to remove the check. Every
product has it; it passes when no script declared a missing
path. It reads the runs below the product's roots
([Build-script runs](stage-functions.md#build-script-runs)):
the runs of build scripts for the build machine, and runs that
only tests depend on, are not checked; their build logs warn.

#### `buildScriptPaths.allow`

Missing paths the scripts do not need: a package name (every
path its build script declares), or `{ package; path; }`,
where `path` is a shell glob pattern matched against the path
as the script printed it (default `*`). A registry crate
that declares a path it never reads is allowed once here, for
the product.

*Type:* list of (string or (submodule))

*Default:* `[ ]`

*Example:* `[ "gdbstub" { package = "deno"; path = "../Cargo.lock"; } ]`

### `neededLibraries`

Fails when an ELF file in the checked output names in `NEEDED`
(the shared libraries the dynamic loader loads for it) a
library that `allowed` does not match, naming the file, the
library and `why`. It reads the files, as auditwheel reads a
wheel, so it holds wherever the library is found at run time.
`linuxPortable`'s `portableLibraries` check.

#### `neededLibraries.allowed`

Shell glob patterns of the sonames a file may need.
`breakbulk.stageHelpers.glibcLibraries` lists glibc's own
libraries in every release since 2.17 and its dynamic
loaders; `gccRuntimeLibraries` lists `libgcc_s.so.1` and
`libstdc++.so.6`, which manylinux's policy also allows.

*Type:* list of string

*Default:* `breakbulk.stageHelpers.glibcLibraries`

*Example:* `breakbulk.stageHelpers.glibcLibraries ++ breakbulk.stageHelpers.gccRuntimeLibraries ++ [ "libz.so.1" ]`

#### `neededLibraries.binutils`

The package to run instead of `binutils-unwrapped-all-targets` from the stage's `pkgs`.

*Type:* null or package

*Default:* `null`

#### `neededLibraries.why`

Why other libraries are not allowed, for the failure message.

*Type:* string

*Default:* `""`

*Example:* `"a portable Linux binary loads only glibc's libraries"`

### `noSourceReferences`

Fails when the closure of the checked output (by default the
product's main output) contains a source path or a Rust toolchain
path: a std panic location that names rust-src, or an embedded
`CARGO`, makes the whole toolchain a run-time dependency. A
separate `debug` output is not checked. Every product has this
check unless it is removed.

A source named only by files matching `sourcesAllowedIn` is
allowed. One toolchain reference is allowed: a toolchain path
holding a shared library the checked output loads (read from its
files' ELF `NEEDED` entries and PE imports, looked up in the
path's `lib`, `bin` and `lib/rustlib/<target>/{lib,bin}`). So a
binary linked with `-C prefer-dynamic` may reference the sysroot
whose `libstd-*.so` it loads; rustc's own component, cargo and
rust-src never are. A rust-overlay toolchain's joined sysroot
brings its rustc and cargo components along, so such a binary
still fails there.

When a source is referenced, the failure says that
`env!("CARGO_MANIFEST_DIR")` kept in a string is the usual cause,
and names the `removeSourceReferences` stage, at its place in the
product's stage order, besides narrowing and removing the check.

#### `noSourceReferences.sources`

The source store paths. `null`: the product's `sourcePaths` (its source views and crate sources).

*Type:* null or (list of (string or absolute path or package))

*Default:* `null`

#### `noSourceReferences.sourcesAllowedIn`

File name globs (in any directory) whose own references to
sources are allowed; a source another file names still
fails. `null`: the product's `sourcesAllowedIn` (each
staticlib root's archive, whose objects keep their debug
information for the final link).

*Type:* null or (list of string)

*Default:* `null`

*Example:* `[ "libapp-*.a" ]`

#### `noSourceReferences.toolchain`

The Rust toolchain store paths. `null`: the product's `toolchainPaths` (rustc, its sysroot, cargo, rust-src). `[ ]` checks sources only.

*Type:* null or (list of (string or absolute path or package))

*Default:* `null`

### `noStorePaths`

Fails when a file in the checked output names a Nix store
path anywhere in its bytes (any `<storeDir>/<32
characters>-<name>` string), naming every file and path. A
program for other systems must not look for a file in a store
that is not there: a statically linked OpenSSL's `OPENSSLDIR`,
a run path, an embedded tool path. `linuxPortable`'s
`portableNoStorePaths` check.

#### `noStorePaths.allow`

The store paths a file may name: shell glob patterns
matched against each whole path found
(`/nix/store/<hash>-<name>…`, cut at the first character
that cannot be in a store path name), or derivations and
store paths, each matching itself and what lies below it.

*Type:* list of (string or absolute path or package)

*Default:* `[ ]`

*Example:* `[ "*-openssl-*-etc" ]`

#### `noStorePaths.why`

Why store paths are not allowed, for the failure message.

*Type:* string

*Default:* `""`
