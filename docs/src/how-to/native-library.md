# Add a native library

A `-sys` crate's build script looks for a C library, usually with
`pkg-config`. In the Nix sandbox it finds only what you declare. This page
shows how to declare it for one package, so no other crate rebuilds.

## Check whether it is already covered

breakbulk ships settings for many common `-sys` crates (`openssl-sys`,
`libz-sys`, `libsqlite3-sys`, …), taken from nixpkgs'
`defaultCrateOverrides`. They are on by default ([`sysDefaults.enable`](../reference/options/repository.md#sysdefaultsenable)). If
your crate is one of them, it builds with no configuration.

## Declare the library and its tools

Set `inputs` (libraries for the platform being built) and `nativeInputs`
(tools that run on the build machine) on the package that needs them:

```nix
modules = [{
  packages.foo-sys = {
    nativeInputs = p: [ p.pkg-config ];
    inputs = p: [ p.foo ];
  };
}];
```

Write them as functions of a package set. breakbulk calls them with the
right set for each side: the build machine's for build scripts, the
target's for target units. This matters when you cross-compile.

Only `foo-sys`'s units see these inputs. The packages that link `foo-sys`
(your binaries and tests) also get its library search path, so a build
script that prints only `cargo:rustc-link-lib=foo` still links. Binaries
get a run-time path to the library.

## Use the system library instead of a bundled copy

Many `-sys` crates bundle the library's C source and build it themselves
unless told otherwise. breakbulk does not change that choice for you,
because it changes what gets built. To use the Nix library, set the
crate's own switch, for example:

```nix
packages.libsqlite3-sys.env.LIBSQLITE3_SYS_USE_PKG_CONFIG = "1";
```

## Settings for build scripts only

[`packages.<name>.host.inputs`](../reference/options/packages.md#packagesnamehostinputs), `.host.nativeInputs` and `.host.env` reach
only the package's host units (its build script, or the package itself
when it is a proc macro or a build dependency).

## When the build still fails

If a build script fails, or succeeds while it names a file that is missing
from its sandbox, the error names the file and the option to add it to
([`extraSources`](../reference/options/packages.md#packagesnameextrasources) for files outside the package directory). See the
[module options](../reference/options.md) for `packages.<name>`.
