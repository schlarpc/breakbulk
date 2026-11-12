<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Package options

`packages.<name>`: settings for one package's units.

## `packages`



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
 - [lib/modules/packages\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/packages.nix)



## `packages.<name>.checks`



Checks on this package’s products, as ` targets.<triple>.checks `\.
They are added to the target’s checks and to the default checks
(` noSourceReferences `, ` buildScriptFiles `)\. ` null ` removes a check
from this package only\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```



*Example:*

```nix
{ noSourceReferences = null; }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.env`



Environment for every unit of this package, on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)
(compiles and build-script runs)\. Values may be derivations,
including the products of other packages, in this workspace or
another, on any target; they are passed by reference, and only
this package’s units read them\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.extraSources`



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forHost.env`



Environment for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forHost.inputs`



Libraries for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forHost.nativeInputs`



Build-machine tools for this package’s host units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forTarget.env`



Environment for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forTarget.inputs`



Libraries for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.forTarget.nativeInputs`



Build-machine tools for this package’s target units only ([sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides))\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.inputs`



Libraries for the platform being built (` openssl `), for this
package’s units on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)\. A function of a package set
(` p: [ p.openssl ] `), called with the build machine’s set for host
units and with the target’s set for target units; or a list used
as given\. Elements may be the products of other packages, as in
` env `\. Their library search paths (` NIX_LDFLAGS `, not compiler
flags or ` PATH `) also reach the link steps of the packages that
link this one (bins, tests, cdylibs, doctests of dependents), on
the same platform, so a ` -sys ` crate may print ` rustc-link-lib `
without a search path; binaries get an rpath to the library\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.nativeInputs`



Tools that run on the build machine (` pkg-config `, ` cmake `,
` protoc `), for this package’s units on both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides)\. A function of
the build platform’s package set, or a list\. Elements may be the
products of other packages, as in ` env `\.

The list’s length is read before its elements, so ` lib.mkIf ` goes
around the whole list or function: on one element it does not remove
the element, and reading it is an error\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.pipelining`



Opt this package in or out of the pipelined split\.

Not implemented yet ([\#14](https://github\.com/schlarpc/breakbulk/issues/14)): setting it only gives an evaluation warning\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/packages\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/packages.nix)



## `packages.<name>.stages`



Post-link stages for this package’s products, as ` targets.<triple>.stages ` (` after = "install" ` for wrappers and packaging)\.



*Type:*
attribute set of (null or raw value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.strictSources`



Override the repository’s ` strictSources ` for this package’s build scripts\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.target`



Settings for this package on one target triple, with every option
of the package level (` env `, ` forHost `, ` forTarget `, ` stages `,
` test `, …)\. They apply to the plans for that triple, on top of the
package-level settings of the same definition: ` env ` still means
both [sides](\.\./\.\./explanation/configuration\.md\#host-and-target-sides) (the build-script compile of a plan for this triple
included), ` forTarget.env ` the target side only\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpegWin;
  x86_64-pc-windows-msvc.stages.sign = { after = "install"; run = sign; };
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.args`



libtest arguments for every test binary of this package, and
for its doctests: each is passed to ` rustdoc --test ` as
` --test-args `, so ` [ "--skip" "src/lib.rs - net" ] ` skips a
doctest by name\. ` test.binaries.<binary>.args ` do not reach
doctests\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.binaries`



Settings for one test binary of this package, by its key (and
the name of its check, ` <ws>/<triple>/<pkg>/… `):

 - an integration test (` [[test]] `, ` tests/cli.rs `): its name,
   ` cli ` (check ` test-cli `);
 - the library’s unit tests: ` lib/ ` and the library’s crate
   name, ` lib/my_crate ` (check ` test-lib `);
 - a bin’s unit tests: ` bin/ ` and the bin’s name, ` bin/my-tool `
   (check ` test-bin-my-tool `);
 - an example or bench with ` test = true `: ` example/<name> `,
   ` bench/<name> ` (check ` test-example-<name> `,
   ` test-bench-<name> `)\.

A key that names no test binary of the package is an evaluation
error listing the package’s keys\. The keys come from the
package’s manifest, so a test binary that only some targets or
variants build (` required-features `) has its key on all of
them\. Under ` memberDefaults `, a key must name a test binary of
some member\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  net.args = [ "--skip" "needs_network" ];
  "lib/my_crate".env.RUST_LOG = "debug";
  "bin/my-tool".enable = false;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.binaries.<name>.enable`



Whether this binary’s test run is part of ` repo.checks ` and the
check groups; the binary is built either way\. A more specific
layer’s value wins over the layers it refines
([layer order](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order)):
` memberDefaults.test.binaries.<key>.enable = false ` with ` true `
for a few packages runs only theirs\. ` null `: ` true `\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.binaries.<name>.args`



libtest arguments for this test binary’s run, after ` test.args `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.binaries.<name>.env`



Environment for this test binary’s run, over ` test.env `\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.binaries.<name>.postRun`



A shell snippet run after this test binary’s run passes, after the package’s ` test.postRun ` (see there)\.



*Type:*
strings concatenated with “\\n”



*Default:*

```nix
""
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.doctest`



Settings for the package’s doctest run (` doctests.<pkg> `, check
` <ws>/<triple>/<pkg>/doctest `), as ` test.binaries.<key> ` has
for a test binary’s\.



*Type:*
submodule



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  enable = false;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.doctest.enable`



Whether the package’s doctest run is part of ` repo.checks ` and
the check groups\. A doctest compiles and runs in one rustdoc
process, so with ` false ` the checks build nothing of it; it
stays buildable as ` doctests.<pkg> `\. A more specific layer’s
value wins over the layers it refines
([layer order](\.\./\.\./explanation/configuration\.md\#shared-settings-and-layer-order)):
` memberDefaults.test.doctest.enable = false ` with ` true ` for a
few packages runs only theirs\. For a
library whose manifest sets ` doctest = false `, there is no
doctest run to enable\. ` null `: ` true `\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.doctest.args`



libtest arguments for the package’s doctest run, after ` test.args `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.doctest.env`



Environment for the package’s doctest run, over ` test.env `\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.doctest.postRun`



A shell snippet run after the package’s doctest run passes, after the package’s ` test.postRun ` (see there)\.



*Type:*
strings concatenated with “\\n”



*Default:*

```nix
""
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.env`



Environment for this package’s test runs and doctests\. They get
a fresh, empty ` HOME ` in their temporary directory by default;
` HOME = "/homeless-shelter" ` makes a test that writes to its home
fail, as compiles and build-script runs do\.

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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.includeIgnored`



Also run ` #[ignore] ` tests\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.keepLog`



Keep each test run’s and doctest run’s raw output in
` $out/log `, as a ` postRun ` of ` cp "$log" "$out/log" `\. For a
binary cache that does not store build logs, or a CI that keeps
them as artifacts\. The output holds timings and, with more than
one test thread, lines in a varying order, so such a run is
not reproducible under ` nix build --rebuild `\. ` null `: off\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.nextest.package`



cargo-nextest to run with (` null `: the test platform’s ` cargo-nextest `)\.



*Type:*
null or package



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.nextest.configFile`



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.nextest.profile`



nextest profile for this package’s test runs (` null `: ` default `)\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.path`



Packages added to ` PATH ` in this package’s test runs\.



*Type:*
list of package



*Default:*

```nix
[ ]
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.postRun`



A shell snippet run inside each passing test run and doctest
run of this package, after the tests: ` $log ` is the run’s raw
output and ` $out ` the run’s output directory, empty otherwise\.
With ` test.runner = "nextest" `, ` $nextestDir ` is nextest’s
store (JUnit reports)\. The package’s snippet runs first, then
the binary’s (` test.binaries.<binary>.postRun `) or the doctest
run’s (` test.doctest.postRun `), then ` keepLog `’s\. Whatever a
snippet puts in ` $out ` decides whether the run is
reproducible: breakbulk keeps ` $out ` empty so that ` nix build --rebuild ` of a passing run succeeds, and the output stays in
the build log (` nix log `)\.



*Type:*
strings concatenated with “\\n”



*Default:*

```nix
""
```



*Example:*

```nix
"cp -r \"$nextestDir/ci\" \"$out/junit\""
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.runFiles`



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.runner`



How this package’s test binaries run: ` libtest ` (the binary
itself, as ` cargo test ` runs it) or ` nextest ` (cargo-nextest’s
reuse-build mode over the one binary, with the project’s
nextest configuration: retries, timeouts, default filter, test
groups)\. Each binary is still its own test run\. ` null `:
` libtest `\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.scopeTestsDir`



Whether the package’s ` tests/ ` directory is test-only, as if
listed in ` sourceScope `: only the package’s test units see it
(integration tests, with or without the libtest harness,
benches, examples, test harnesses, doctests and test runs), so
a fixture edit there rebuilds no library, bin or product\. Set
it to ` false ` when the library, a bin or the build script
reads from ` tests/ ` at compile time
(` include_str!("../tests/…") `, a build script that generates
tests from fixtures); such a unit fails with a hint naming
this option\. ` null `: ` true `\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.sourceScope`



Repository paths (paths, or strings relative to the
repository root) that only this package’s test units see: the
units Cargo builds with its dev-dependencies (test harnesses,
integration tests and benches with or without the libtest
harness, examples), its doctests and its test runs, whose
working directory is the package directory of their view\. A
path outside the package is added to the test view\. A path
inside the package is also removed from the view of its other
units (the library, bins, build script)\. Either way, editing
it rebuilds only this package’s test units and re-runs its
tests\. The package’s ` tests/ ` directory is in this scope too
(` scopeTestsDir `)\.



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
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.test.stripForRun`



Run a copy of each test binary with its debug info (and build
ID) stripped, content-addressed when ` ca ` is on\. Workspace
libraries keep real source paths in their debug info, so an
edit to any file of such a library (a README) changes the bytes
of every test binary that links it; the stripped copy does not
change, and the test is not re-run\. Backtraces still name
functions, but not files and lines\. The unstripped binary stays
in ` tests.<pkg>.<binary> ` for debugging\. ` null `: off\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.variant`



Settings for this package in the plans of one variant
(` workspaces.<ws>.variants.<v> `), with every option of the
package level, ` target.<triple> ` included\. They apply on top of
the package-level settings and their ` target.<triple> ` layer of
the same definition, and leave the units of other variants
unchanged: a lint setting for a ` clippy ` variant does not
rebuild the release variant\. A variant layer’s
` target.<triple> ` applies to that variant on that triple only\.
The layer applies in every workspace that has a variant of that
name; a name that no workspace has is an evaluation warning\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  coverage.test.env.RUST_LOG = "debug";
  full.inputs = p: [ p.openssl ];
  full.target.x86_64-pc-windows-msvc.forTarget.env.OPENSSL_DIR = opensslWin;
}

```

*Declared by:*
 - [lib/modules/package-settings\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/package-settings.nix)



## `packages.<name>.version`



A version requirement in Cargo’s syntax (` 1.2 `, ` ^1.2 `, ` ~1.2 `,
` =1.2.3 `, ` >=1, <2 `, ` * `)\. The override applies to the
package’s locked versions that match\. ` null ` matches every
version\. The attribute name may also carry the requirement:
` packages."aws-lc-sys@>=0.42" `\.



*Type:*
null or Cargo version requirement



*Default:*

```nix
null
```



*Example:*

```nix
">=0.42, <0.50"
```

*Declared by:*
 - [lib/modules/packages\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/packages.nix)



