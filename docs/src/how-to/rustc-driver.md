# Run a rustc driver

A rustc driver is a program that runs rustc's front end with its own
analysis: a lint tool, a verifier (Verus, Kani, Prusti, Creusot, Flux),
a model checker. Cargo runs one through its wrappers, and breakbulk does
the same, per unit. An edit then reruns the driver only on the crates it
changes and on their dependents, in parallel, and the rest comes from the
store.

## Choose the wrapper

A variant takes Cargo's two wrappers:

- [`rustcWrapper`](../reference/options/workspaces.md#workspacesnamevariantsnamerustcwrapper)
  is `build.rustc-wrapper`. Every rustc invocation goes through it:
  dependencies, build scripts and Cargo's own queries (`rustc -vV`,
  `--print cfg`). Build-script runs get it as `RUSTC_WRAPPER`.
- [`rustcWorkspaceWrapper`](../reference/options/workspaces.md#workspacesnamevariantsnamerustcworkspacewrapper)
  is `build.rustc-workspace-wrapper`. Only workspace members go through
  it, so the dependency units stay the same derivations as those of a
  variant without it.

Cargo starts the wrapper as `<wrapper> <path to rustc> ARGS…`. Use a
check variant when the driver needs only metadata:

```nix
workspaces.main.variants.lint = {
  mode = "check";
  profile = "dev";
  rustcWorkspaceWrapper = "${my-lints}/bin/my-lint-driver";
};
```

`target.<triple>.variants.lint.check` builds every unit and is in
`repo.checks`. [`breakbulk.variants.clippy`](../reference/presets.md#clippy)
is this setup with clippy-driver as the workspace wrapper, plus clippy's
arguments and configuration files, made of the options below.

A driver built on `rustc_driver` has the sysroot of the rustc it was
built with. Use that rustc as the workspace's toolchain
(`workspaces.<ws>.toolchain`). Before tracing, the planner runs each
wrapper as Cargo would, `<wrapper> <rustc> --print sysroot`, and fails
naming the option when the answer is not rustc's sysroot: otherwise the
units would name crates from the driver's sysroot, which instantiation
rejects as undeclared inputs.

## Give the driver its settings

Drivers read their settings from the environment and from files:

- [`wrapperEnv`](../reference/options/workspaces.md#workspacesnamevariantsnamewrapperenv)
  reaches the units the workspace wrapper runs on, and no other, so the
  dependency units stay shared (clippy's `CLIPPY_ARGS`).
- [`cargoConfig.env`](../reference/options/workspaces.md#workspacesnamevariantsnamecargoconfig)
  reaches every process Cargo starts, Cargo's queries too, and every unit
  of the variant: for a `rustcWrapper`, which sees every crate.
- [`packages.<name>.variant.<v>.env`](../reference/options/packages.md)
  reaches one package's units in one variant.
- [`wrapperConfig`](../reference/options/workspaces.md#workspacesnamevariantsnamewrapperconfig)
  names the workspace wrapper's config files: `search` and `dirVar` for
  files it looks for from the member's directory upwards (clippy's
  `clippy.toml`, through `CLIPPY_CONF_DIR`), `workingDirFiles` for files
  it reads from the compile's working directory (the workspace's
  `Cargo.toml`).

## Keep the files the driver writes

rustc writes into a directory of its own, and a unit keeps only the
outputs the plan names (`.rmeta`, `.rlib`, binaries) and debug info.
[`sideFiles`](../reference/options/workspaces.md#workspacesnamevariantsnamesidefiles)
keeps more. A string keeps the files that end in it beside the output
file of the same stem:

```nix
sideFiles = [ ".vir" ];   # lib<crate>-<hash>.vir beside lib<crate>-<hash>.rmeta
```

The side file is in the dependency's output, beside the crate file. A
dependent's compile sees crates through links in its dependency
directory (`-L dependency=`), and breakbulk links the side file next to
the crate file's link there too. A driver that looks beside a crate file
finds the side file either way: beside the real path, or beside the path
rustc loaded the crate from. The rules apply only to units that a
wrapper runs on.

## Verus

Verus's `cargo verus verify` runs `cargo check` with its driver as
`RUSTC_WRAPPER`. The driver takes per-crate settings from environment
variables that `cargo verus` computes from `cargo metadata`:

- `__VERUS_DRIVER_VIA_CARGO__=1`, set for every process.
- `__VERUS_DRIVER_VERIFY_<id>` and `__VERUS_DRIVER_ARGS_FOR_<id>`, for
  each crate to verify. `<id>` is the package's name and version and a
  hash of its `CARGO_MANIFEST_DIR`.
- `--VIA-CARGO import-dep-if-present=<crate>` in those arguments, for
  each verified dependency.

The driver writes `<stem>.vir` beside the crate's `.rmeta`. It reads a
dependency's `.vir` beside the real path of each `--extern`, and beside
the path rustc loaded each other verified crate from, which is its link
in the dependency directory. A variant for it looks like this:

```nix
workspaces.main.variants.verus = {
  mode = "check";
  rustcWrapper = "${verus-wrapper}";
  sideFiles = [ ".vir" ];
  cargoConfig.env = {
    __VERUS_DRIVER_VIA_CARGO__ = "1";
    RUSTC_BOOTSTRAP = "1";
  };
};
```

In a unit, `CARGO_MANIFEST_DIR` is the package's source view, a store
path that changes when the package changes. So the `<id>` variables
cannot be fixed values in `env`. Use `verus-wrapper`, a small script in
your project, to compute them when the unit runs: for example, from
`CARGO_PKG_NAME`, `CARGO_PKG_VERSION`, `CARGO_MANIFEST_DIR` and a plain
`VERUS_ARGS` that you set with `packages.<name>.variant.verus.env`. The
script then runs the real driver. breakbulk has no Verus-specific
settings, and this setup is not tested in breakbulk's own suite. The
mechanism under it is tested, with a toy driver, by
`products-variants-driver`.
