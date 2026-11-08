# breakbulk: options

Generated from the module options (`repo.optionsDoc`). Do not edit.
Regenerate with `tests/loose-ends/update-options-doc.sh`.

## packages



Per-package overrides, by package name (or ` name@<version requirement> `)\. They apply in every workspace whose lockfile has a
matching package, and only to that package’s units\. An override that
matches nothing in any lockfile is an evaluation warning\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  openssl-sys = { nativeInputs = p: [ p.pkg-config ]; inputs = p: [ p.openssl ]; };
  app.env.GIT_REV = self.rev or "dirty";
  "libsqlite3-sys".env.LIBSQLITE3_SYS_USE_PKG_CONFIG = "1";  # opt in to the system SQLite
}

```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.checks



Checks on this package’s products, on every target\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.env



Environment for every unit of this package (compiles and build
script runs, host and target)\. Values may be derivations,
including another workspace’s products; they are passed by
reference\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.extraSources



Files and directories outside the package directory that its
units read (` include_str!("../../wit/x.wit") `, a sibling assets
directory, patches), at their original relative paths\. Strings
are relative to the repository root\.



*Type:*
list of (absolute path or string)



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "wit"
  "../shared/assets"
]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.host\.env



Environment for this package’s host units only (build scripts, proc macros, build dependencies)\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.host\.inputs



Libraries for this package’s host units only\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.host\.nativeInputs



Tools for this package’s host units only\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.inputs



Libraries for the platform being built (` openssl `)\. A function of
a package set (` p: [ p.openssl ] `), called with the build
machine’s set for host units and with the target’s set for
target units; or a list used as given\. Their library search
paths (` NIX_LDFLAGS `, not compiler flags or ` PATH `) also reach
the link steps of the packages that link this one (bins, tests,
cdylibs, doctests of dependents), on the same platform, so a
` -sys ` crate may print ` rustc-link-lib ` without a search path;
binaries get an rpath to the library\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.nativeInputs



Tools that run on the build machine (` pkg-config `, ` cmake `,
` protoc `)\. A function of the build platform’s package set, or a
list\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.pipelining



Opt this package in or out of the pipelined split\.

Not implemented yet (M6): setting it only gives an evaluation warning\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.stages



Post-link stages for this package’s products, on every target\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.strictSources



Override the repository’s ` strictSources ` for this package’s build scripts\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target



Settings for this package’s target units on one target triple\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target\.\<name>\.checks



Checks on this package’s products on this target\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target\.\<name>\.env



Environment for this package’s units on this target (target units only)\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target\.\<name>\.inputs



Libraries for this package’s units on this target (target units only)\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target\.\<name>\.nativeInputs



Build-machine tools for this package’s units on this target (target units only)\.



*Type:*
(function that evaluates to a(n) list of package) or (list of package) convertible to it



*Default:*

```nix
[ ]
```



*Example:*

```nix
p: [ p.openssl ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.target\.\<name>\.stages



Post-link stages for this package’s products on this target\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.args



libtest arguments for every test binary of this package\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "--skip"
  "net::"
]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.binaries



Per test binary settings\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.binaries\.\<name>\.enable



Whether this binary’s test run is part of ` repo.checks ` (it is built either way)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.binaries\.\<name>\.args



libtest arguments for this test binary\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.env



Environment for this package’s test runs\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.includeIgnored



Also run ` #[ignore] ` tests\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.nextest\.package



cargo-nextest to run with (` null `: the test platform’s ` cargo-nextest `)\.



*Type:*
null or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.nextest\.configFile



nextest configuration file\. ` null `: the repository’s
` .config/nextest.toml ` when it exists, else nextest’s
defaults\.



*Type:*
null or absolute path



*Default:*

```nix
null
```



*Example:*

```nix
./.config/nextest.toml
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.nextest\.profile



nextest profile for this package’s test runs (` null `: the workspace’s ` test.nextest.profile `, else ` default `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"ci"
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.path



Packages added to ` PATH ` in this package’s test runs\.



*Type:*
list of package



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.runFiles



Narrow what this package’s test runs see: their working
directory (and runtime ` CARGO_MANIFEST_DIR `) is a view holding
only these paths, relative to the package directory, at their
usual places; ` [ ] ` gives an empty directory\. Editing any other
file of the package then leaves the test run’s own inputs
unchanged, so with content addressing (` ca `) a byte-identical
test binary is not re-run\. A test that reads a file not listed
fails\. ` null `: the package’s whole source view (or its
` test.sourceScope ` view), as ` cargo test ` sees it\. Test apps
keep the whole view\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "tests/fixtures"
]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.runner



How this package’s test binaries run: ` libtest ` (the binary
itself, as ` cargo test ` runs it) or ` nextest ` (cargo-nextest’s
reuse-build mode over the one binary, with the project’s
nextest configuration: retries, timeouts, default filter, test
groups)\. Each binary is still its own test run\. ` null `: the
workspace’s ` test.runner `, else ` libtest `\.



*Type:*
null or one of “libtest”, “nextest”



*Default:*

```nix
null
```



*Example:*

```nix
"nextest"
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.sourceScope



Extra repository paths (paths, or strings relative to the
repository root) in the source view of this package’s test
units: its test harnesses (` --test ` compiles), doctests and
test runs, whose working directory is the package directory
of that view\. Other units keep the package’s normal view, so
editing these paths re-runs only this package’s tests\.



*Type:*
list of (absolute path or string)



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "testdata"
]
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.test\.stripForRun



Run a copy of each test binary with its debug info (and build
ID) stripped, content-addressed when ` ca ` is on\. Workspace
libraries keep real source paths in their debug info, so an
edit to any file of such a library (a README) changes the bytes
of every test binary that links it; the stripped copy does not
change, and the test is not re-run\. Backtraces still name
functions, but not files and lines\. The unstripped binary stays
in ` tests.<pkg>.<binary> ` for debugging\. ` null `: the
workspace’s ` test.stripForRun `\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## packages\.\<name>\.version



A version requirement in Cargo’s syntax (` 1.2 `, ` ^1.2 `, ` ~1.2 `,
` =1.2.3 `, ` >=1, <2 `, ` * `)\. The override applies to the
package’s locked versions that match\. ` null ` matches every
version\. The attribute name may also carry the requirement:
` packages."aws-lc-sys@>=0.42" `\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
">=0.42, <0.50"
```

*Declared by:*
 - [lib/modules/packages\.nix](../lib/modules/packages.nix)



## ca

Content-address post-link stages, checks and test runs, so that an
unchanged input does not re-run them\. Needs Nix’s ` ca-derivations `
experimental feature in the evaluator and the daemon\. ` null ` turns
it on exactly when the evaluator has ` dynamic-derivations ` (which
needs ` ca-derivations ` too), and off otherwise (decision 52)\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## gitHashes



NAR hashes of git sources, keyed by the full ` Cargo.lock ` source
string\. Optional: with a hash, the fetch is fixed-output and a
binary cache can serve it; without one, every fresh machine clones
the source during evaluation\. The hash is that of the fetched tree
(` builtins.fetchGit `’s ` narHash `), not crane’s ` outputHashes `
(decision 14)\.



*Type:*
attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "git+https://github.com/me/serde?rev=abc#abc0123" = "sha256-…";
}
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## gitSubdirs



Where a crate lives inside a git source, keyed by source string or
URL, then by crate name\. Skips the walk over the tree’s
` Cargo.toml ` files\.



*Type:*
attribute set of attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "https://github.com/me/repo" = {
    mycrate = "crates/mycrate";
  };
}
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## gitSubmodules



Per git URL: whether to fetch submodules\. Cargo checks out
submodules of git dependencies, so the default is true\.



*Type:*
attribute set of boolean



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## gitTrees



Use a local tree instead of fetching a git source\. Keyed by the
` Cargo.lock ` source string or by URL\.



*Type:*
attribute set of absolute path



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## mode



How unit derivations reach Nix\. ` ifd `: breakbulk-instantiate writes
units\.json, which Nix imports (import-from-derivation)\. ` dynamic `:
an outer derivation writes the unit derivations through Nix’s
` builder-rpc-v0 ` interface and products reach them with
` builtins.outputOf ` (needs Nix 2\.36 or later with the
` dynamic-derivations ` and ` ca-derivations ` experimental features)\.
` auto ` picks ` dynamic ` when the evaluator has ` builtins.outputOf `
and is Nix 2\.36 or later, and ` ifd ` otherwise\. A daemon or builder
older than the evaluator fails with Nix’s own “missing system
features” error naming ` builder-rpc-v0 `; set ` ifd ` then\. Unit
derivations are identical in both modes; products are not (they are
resolved at build time in ` dynamic `), so teams that mix Nix versions
should pin the mode\.



*Type:*
one of “auto”, “ifd”, “dynamic”



*Default:*

```nix
"auto"
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## registries



Alternative registries, by name\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## registries\.\<name>\.dl



Download URL template, as in the registry’s ` config.json `
(` {crate} `, ` {version} `, ` {prefix} `, ` {lowerprefix} `,
` {sha256-checksum} `)\. ` Cargo.lock ` records only the index,
and reading ` config.json ` would need a fetch during
evaluation\.



*Type:*
string



*Example:*

```nix
"https://my-registry.example/api/v1/crates/{crate}/{version}/download"
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## registries\.\<name>\.index



The registry’s index URL as it appears in ` Cargo.lock `
(with or without the ` registry+ ` prefix; sparse registries
keep ` sparse+ `)\.



*Type:*
string



*Example:*

```nix
"sparse+https://my-registry.example/index/"
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## strictSources



Fail a build-script run that succeeds while declaring a
` rerun-if-changed ` path missing from its sandbox\. When false, such
paths are warnings that name the option to add them to\.
` packages.<name>.strictSources ` overrides it per package\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## sysDefaults\.enable



Apply breakbulk’s curated overrides for common ` -sys ` crates
(seeded from nixpkgs’ ` defaultCrateOverrides `)\. Your own
` packages.<name> ` values merge with them: lists concatenate, env
attributes merge, and ` lib.mkForce ` replaces a default\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/top\.nix](../lib/modules/top.nix)



## targets



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
 - [lib/modules/targets\.nix](../lib/modules/targets.nix)



## targets\.\<name>\.packageSet



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.ar



The archiver build scripts use for this target (` AR_<triple> `)\.



*Type:*
null or string or absolute path or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.bindgen\.extraClangArgs



Extra libclang arguments for bindgen (` BINDGEN_EXTRA_CLANG_ARGS_<triple> `)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.cc



The C compiler build scripts use for this target (` CC_<triple> `)\.



*Type:*
null or string or absolute path or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.cflags



C and C++ flags for this target’s C code (` CFLAGS_<triple> `, ` CXXFLAGS_<triple> `)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.checks



Checks on this target’s products: ` { on ? <the product>; run = { input, product, pkgs }: <derivation>; } `, where ` on ` names a
stage (` linked ` for the raw link output)\. Every product also
gets ` noSourceReferences `; ` null ` removes a check\. Checks appear
in ` repo.checks ` as ` <ws>/<triple>/<pkg>/<name> `\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.cxx



The C++ compiler build scripts use for this target (` CXX_<triple> `)\.



*Type:*
null or string or absolute path or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.debugInfo



What this target’s products do with debug info (decision 137),
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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.env



Environment added to this target’s units only (layer 4 of the
unit environment contract), never through Cargo’s ` [env] `, so
build scripts and proc macros (host units) do not see it\.
List-like variables (` PATH `, ` NIX_CFLAGS_COMPILE `, …) are
appended to the env capture’s value\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.host\.env



Environment added to host units of this target’s plans only\.



*Type:*
attribute set of (string or absolute path or package or signed integer or boolean)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.host\.linker



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.host\.stdenv



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.linker



The linker for this target’s units (` target.<triple>.linker ` in Cargo config)\. A store path\.



*Type:*
null or string or absolute path or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.preset



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.runner



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.rustflags



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.stagePreset



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.stages



Post-link stages for this target’s products, merged over the
stage ` debugInfo ` inserts and the stage preset’s defaults
(` stagePreset `)\. A stage is ` { after ? null; before ? null; run = { input, product, target, pkgs }: <derivation>; } `; ` null `
removes one\. Package settings (` packages.<name>.stages `) merge
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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.stdenv



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.testSystem



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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## targets\.\<name>\.traits



Facts about this target platform that override or extend the
built-in ones breakbulk reads from the triple
(` breakbulk.targetTraits.resolve `, “Target traits” in
docs/implementation\.md)\. Every platform-dependent decision reads
the resulting traits: the linker kind, the default debug handling,
the install layout and file names, debuginfo side files, the
dynamic-library path of test processes, static linking\. Base
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
 - [lib/modules/target-spec\.nix](../lib/modules/target-spec.nix)



## workspaces



The Cargo workspaces of the repository, by a name of your choice\.
Without any definition, a repository whose root has a ` Cargo.toml `
gets one workspace, ` default `, at the root, so ` mkRepository ` needs
no modules; declaring any workspace turns that default off\.



*Type:*
attribute set of (submodule)



*Default:*
` { default.path = "."; } ` when the repository root has a ` Cargo.toml `,
else ` { } `

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.benchSmoke



Run each bench binary of ` target.<triple>.benches ` once in test
mode (` --test `) as a check (` <ws>/<triple>/<pkg>/bench-<name> `
in ` repo.checks `)\. Timed runs never happen inside Nix\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.cargoTrimPaths



Who hides source paths in Rust code when Cargo has
` trim-paths ` (1\.101 and later: the toolchain’s ` trimPaths `
capability; decision 121)\. ` null `: breakbulk turns it on
(` --config profile.<p>.trim-paths="all" `) unless the project
declares ` trim-paths ` in any profile of the workspace root’s
` Cargo.toml ` or of its ` .cargo/config.toml ` files (any profile,
package override or value counts; the files are read, not
merged as Cargo would), and leaves it to the project then\.
` true `: always on, replacing the project’s own setting (an
error without the capability)\. ` false `: never turned on by
breakbulk, which then hides paths with its own remaps; a
project that sets it itself still gets Cargo’s\. Under Cargo’s
trim-paths, breakbulk’s own C prefix maps use Cargo’s names, as
cc-rs does\. A variant’s own setting wins\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.defaultVariant



The variant whose products are ` packages.<pkg> ` and
` target.<triple>.packages.<pkg> `\. Every variant’s products are
also under ` target.<triple>.variants.<variant> `\.



*Type:*
string



*Default:*

```nix
"default"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.devShell\.setTarget



Export ` CARGO_BUILD_TARGET=<native triple> ` in the dev shell, so
local Cargo behaves as the planner’s (which always passes
` --target `): rustflags stay off build scripts, and ` -C metadata `
matches\. Binaries then go to ` target/<triple>/… `\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.docs\.noDeps



Document only workspace members (` cargo doc --no-deps `)\.

Not implemented yet (M6): setting it only gives an evaluation warning\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.path



The workspace root, relative to the repository root\. Its
` Cargo.lock ` is used\.



*Type:*
string



*Default:*

```nix
"."
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.roots



Replace the predicted root names\. The escape hatch for a bug in
breakbulk’s target auto-discovery\.

Not implemented yet (M2, later): setting it only gives an evaluation warning\.



*Type:*
null or raw value



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.sourcePaths



Whether source paths are hidden in what this workspace builds
(decision 121)\. ` hide `: as ` cargoTrimPaths ` says, through
Cargo’s trim-paths or breakbulk’s own remaps, and every product
gets the ` noSourceReferences ` check\. ` keep `: breakbulk neither
turns Cargo’s trim-paths on nor adds remaps of its own (Rust or
C), and products get no default ` noSourceReferences ` check;
binaries then reference their sources’ store paths\. A project
that sets ` trim-paths ` itself still gets Cargo’s remaps\. A
variant’s own setting wins\.



*Type:*
one of “hide”, “keep”



*Default:*

```nix
"hide"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.targets



The triples this workspace is built for\. Each is planned on its
own (` --target <triple> `)\. Besides ` packages `, an entry takes
every option of ` targets.<triple> `: they are merged with the
repository-wide ` targets.<triple> ` for this workspace only, as
two definitions of the same options merge (lists concatenate,
attribute sets merge, and a single value such as ` preset ` or
` linker ` set in both places needs ` lib.mkForce ` on the one that
should win)\. The spec is evaluated with this workspace’s
toolchain, so presets pick tools for its rustc\. The default is
the native triple only\.



*Type:*
attribute set of module



*Default:*

```nix
{ ${pkgs.stdenv.hostPlatform.rust.rustcTarget} = { }; }
```



*Example:*

````nix
{
  wasm32-unknown-unknown = {
    packages = [ "ui" ];
    # Any `targets.<triple>` option, for this workspace only.
    rustflags = [ "--cfg" "getrandom_backend=\"wasm_js\"" ];
  };
}

````

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.targets\.\<name>\.packages



The packages to plan for this target, each traced with ` -p `, in
the build and the test plan\. ` null ` traces ` --workspace `\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.targets\.\<name>\.tests



Test binaries, test runs, test apps and doctests on this target\.
` false `: none (a target that is only built, such as a wasm
component whose tests run natively); the test plan is then not
traced, except for a check or clippy variant with ` allTargets `\. A
list of packages: the test plan is ` cargo test --no-run -p <pkg> … `
for those packages only, and only their tests are run\. ` true `: the
variant’s or target’s package selection\.



*Type:*
boolean or list of string



*Default:*

```nix
true
```



*Example:*

```nix
[
  "my-lib"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.test\.nextest\.package



The default cargo-nextest for this workspace’s test runs; a package’s ` test.nextest.package ` wins\.



*Type:*
null or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.test\.nextest\.configFile



The default nextest configuration file for this workspace’s
test runs; a package’s ` test.nextest.configFile ` wins\.
` null `: the workspace’s ` .config/nextest.toml ` when it
exists\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.test\.nextest\.profile



The default nextest profile for this workspace’s test runs; a package’s ` test.nextest.profile ` wins (` null `: ` default `)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"ci"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.test\.runner



The default ` packages.<name>.test.runner ` for this
workspace’s packages: ` libtest ` or ` nextest `\. A package’s own
setting wins\. ` null ` means ` libtest `\.



*Type:*
null or one of “libtest”, “nextest”



*Default:*

```nix
null
```



*Example:*

```nix
"nextest"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.test\.stripForRun



The default ` packages.<name>.test.stripForRun ` for this
workspace’s packages: test runs consume a debug-stripped copy
of each test binary\. A package’s own setting wins\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain



The toolchain this workspace is planned and built with\. Any
rustc/cargo pair works: nixpkgs, rust-overlay, fenix\. A single
package that provides both may be given for both\.



*Type:*
submodule



*Default:*

```nix
{ }
```



*Example:*

```nix
let tc = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
in { rustc = tc; cargo = tc; }

```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.capabilities



What this toolchain can do, where breakbulk would otherwise
decide it from the rustc and cargo versions (or, for a
toolchain whose ` version ` attribute is missing or not a
Rust release, such as fenix’s, by asking them
through import-from-derivation)\. Set one only for a
forked or patched toolchain whose version says otherwise;
` null ` keeps breakbulk’s own answer\. The planner and the
instantiator read nothing else
(` breakbulk.toolchainFacts.of `, “Toolchain capabilities”
in docs/implementation\.md)\.



*Type:*
submodule



*Default:*

```nix
{ }
```



*Example:*

```nix
{ remapPathScope = false; }
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.capabilities\.nightly



Cargo allows unstable features (default: a ` -nightly ` or ` -dev `
Cargo release)\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.capabilities\.remapPathScope



rustc takes ` --remap-path-scope ` (default: rustc 1\.95 or later)\.
Without it, every unit remaps every path scope, so debug info names
no real source paths even where it is split off\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.capabilities\.trimPaths



Cargo has the ` trim-paths ` profile setting (default: Cargo 1\.101 or
later, nightly 1\.101 included)\. The planner then turns it on when the
project has not\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.cargo



cargo (with ` bin/cargo `)\.



*Type:*
package



*Default:*

```nix
pkgs.cargo
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.clippy



clippy (with ` bin/clippy-driver `), for ` clippy ` variants\.
It must be built for the same rustc: planning compares
` clippy-driver --rustc --print sysroot ` with rustc’s and
fails naming this option when they differ\. The default is
nixpkgs’ clippy with nixpkgs’ rustc, and ` rustc ` itself
otherwise, as a rustup-style toolchain with the clippy
component (rust-overlay’s default profile, fenix’s
` toolchain `) has ` bin/clippy-driver `\.



*Type:*
package



*Default:*

```nix
if rustc == pkgs.rustc then pkgs.clippy else rustc
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.toolchain\.rustc



rustc (with ` bin/rustc ` and ` bin/rustdoc `)\.



*Type:*
package



*Default:*

```nix
pkgs.rustc
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants



Plan parameters\. Each variant is a separate pair of plans (build
and test) per target; units that come out identical are shared\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{
  default = { };
}
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.packages



The packages this variant plans, each traced with ` -p `, in
place of the target’s ` packages ` (` workspaces.<ws>.targets.<triple>.packages `)\.
` null `: the target’s selection\. Features then name the
selected package’s own features, as with ` cargo build -p <pkg> --features <f> `; ` breakbulk.variants.packageFeaturePowerset `
makes such variants\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "my-lib"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.allFeatures



Pass ` --all-features `\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.allTargets



For ` check ` and ` clippy ` variants: also check every target,
as ` cargo check --all-targets ` does (tests, examples, benches
in test mode, through the test plan)\. ` false `: plain ` cargo check ` (libraries and bins, the build plan only), for gates
that do not check test code\. Only check and clippy variants
take ` false `\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.benches



Also trace ` cargo bench --no-run ` with this variant’s settings
(use ` profile = "bench" `): bench binaries, and lib and bin
harnesses in bench mode, at
` target.<triple>.variants.<v>.benches.<pkg>.<bench> `\.
` target.<triple>.benches ` is the default variant’s when it has
benches, else the one variant with ` benches = true `\. The test
plan builds no benches (` cargo test --no-run ` does not)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.cargoTrimPaths



This variant’s ` workspaces.<ws>.cargoTrimPaths `\.



*Type:*
null or boolean



*Default:*

```nix
workspaces.<ws>.cargoTrimPaths
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.checks



Put this variant’s enabled test runs and doctests in
` repo.checks `: the default variant’s as
` <ws>/<triple>/<pkg>/test-<name> ` and ` …/<pkg>/doctest `, any
other build or coverage variant’s as
` <ws>/<triple>/variant-<v>/<pkg>/test-<name> ` and
` …/variant-<v>/<pkg>/doctest `\. Check and clippy variants have
no test runs; their ` check ` is in ` repo.checks ` regardless\.
Variants made by ` breakbulk.variants.featurePowerset ` and
` packageFeaturePowerset ` set this to ` false ` unless their
arguments set it (decision 133)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.clippyArgs



Clippy’s own arguments, as in ` cargo clippy -- ARGS `
(` CLIPPY_ARGS `), for a ` clippy ` variant\. They reach only the
units clippy-driver compiles (workspace members)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "-D"
  "warnings"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.features



Features to enable (` --features `), as Cargo spells them (` pkg/feat ` is allowed)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.mode



What the variant compiles\. ` build `: products and test binaries
(` cargo build `, ` cargo test --no-run `)\. ` check `: ` cargo check `
and ` cargo check --all-targets `, metadata only, no products or
test runs; ` target.<triple>.variants.<v>.check ` builds every
unit and is in ` repo.checks `\. ` clippy `: as ` check `, with
clippy-driver as ` RUSTC_WORKSPACE_WRAPPER ` (workspace members
only, so dependencies are shared with ` check `)\. ` coverage `:
` build ` with ` -C instrument-coverage ` on target units\.
Use the same profile as the build variant to share host units;
Cargo’s own ` clippy ` uses the dev profile\.



*Type:*
one of “build”, “check”, “clippy”, “coverage”



*Default:*

```nix
"build"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.noDefaultFeatures

Pass ` --no-default-features `\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.profile



The Cargo profile (` --profile `)\. Units are shared between
variants whose profiles have the same settings, whatever their
names\.



*Type:*
string



*Default:*

```nix
"release"
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.sourcePaths



This variant’s ` workspaces.<ws>.sourcePaths `\.



*Type:*
one of “hide”, “keep”



*Default:*

```nix
workspaces.<ws>.sourcePaths
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)



## workspaces\.\<name>\.variants\.\<name>\.targets



The workspace’s targets (` workspaces.<ws>.targets `) this
variant is planned for\. ` null `: every target\. A target left
out has no ` target.<triple>.variants.<v> `, and nothing of the
variant in ` repo.checks `; when the default variant is left
out, the target’s ` packages `, ` tests ` and test runs are empty\.
Use it for gates that apply to one target only (clippy
natively, a ` cargo check ` gate for wasm)\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "x86_64-unknown-linux-gnu"
]
```

*Declared by:*
 - [lib/modules/workspaces\.nix](../lib/modules/workspaces.nix)


