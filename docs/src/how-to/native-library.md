# Add a native library

A `-sys` crate's build script looks for a C library, usually with
`pkg-config`. In the Nix sandbox it finds only what you declare. This page
shows how to declare it for one package, so no other crate rebuilds.

## Check whether it is already covered

breakbulk ships settings for many common `-sys` crates (`openssl-sys`,
`libz-sys`, `libsqlite3-sys`, …), taken from nixpkgs'
`defaultCrateOverrides`. The list is in
[`sysDefaults.packages`](../reference/options/repository.md#sysdefaultspackages).
If your crate is one of them, it builds with no configuration.

Your own `packages.<name>` settings add to them. To drop or replace one,
assign it:

```nix
sysDefaults.packages.libsqlite3-sys = null;                    # drop
sysDefaults.packages.zstd-sys = _: { inputs = p: [ p.zstd ]; };  # replace
```

They apply only where nixpkgs has a package set: always for build
scripts, and for target units only when the target has one. On msvc or
`wasm32-unknown-unknown`, those crates build their bundled copies.

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

## Settings for one side only

[`packages.<name>.forHost`](../reference/options/packages.md#packagesnameforhostinputs)
(`inputs`, `nativeInputs`, `env`) reaches only the package's host units:
its build-script compile, or the package itself when it is a proc macro
or a build dependency.
[`forTarget`](../reference/options/packages.md#packagesnamefortargetinputs)
reaches only its target units, the build-script run included. The table
of which unit is on which side is in
[The configuration model](../explanation/configuration.md#host-and-target-sides).

```nix
packages.nettle-sys.forHost.nativeInputs = p: [ p.rustPlatform.bindgenHook ];
packages.ffmpeg-sys-next.target.x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpegWin;
```

## When the build still fails

When `pkg-config`, a C compiler tool, libclang, OpenSSL, `protoc` or
`cmake` is missing, the error includes a hint naming the input to add
([Failure hints](../reference/unit-builder.md#failure-hints)).

If a build script fails, or succeeds while it names a file that is missing
from its sandbox, the error names the file and the option to add it to
([`extraSources`](../reference/options/packages.md#packagesnameextrasources) for files outside the package directory). Every
per-package setting is in [Package options](../reference/options/packages.md).
