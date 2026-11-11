# Outputs and entry points

## `mkRepository`

```nix
repo = breakbulk.lib.mkRepository {
  inherit pkgs;
  root = self;                  # the repository: a flake's self, or ./. outside flakes
  modules = [ ./nix/rust.nix ]; # optional
};
```

- `pkgs`: the package set to build with.
- `root`: the repository root. A flake's `self` is turned into a path,
  because `lib.fileset` takes only paths.
- `modules`: breakbulk configuration, as NixOS-style modules (see
  [Module options](options.md)). Without any, a root that has a
  `Cargo.toml` is one workspace, `default`, at `"."`; declaring any
  [`workspaces`](options/workspaces.md#workspaces) turns that default off.
- `specialArgs`: extra module arguments.

Modules receive these arguments:

- `pkgs`;
- `root`, the repository root as a path, for reading project files;
- `repo`, the result itself, to use another workspace's product as an
  input (laziness makes the cycle harmless);
- `breakbulk`, the library: presets, stage helpers, `xwinSdk`.

`specialArgs` add to these and win.

## The flake-parts module

```nix
imports = [ inputs.breakbulk.lib.flakeModule ];
perSystem = { ... }: {
  breakbulk.modules = [ ./nix/rust.nix ];
};
```

`root` defaults to the flake's `self`. Per system it sets
`breakbulk.repo` (the `mkRepository` result) and adds `repo.checks` to
`checks`, the default target's products to `packages`, and each
workspace's dev shell to `devShells`.

## The result

`<ws>` is a workspace name, `<triple>` a target, `<v>` a variant,
`<pkg>` a package.

```nix
repo = {
  workspaces.<ws> = {
    # Shortcuts for the default target (defaultTarget) and variant:
    packages.<pkg>;          # a product: the build after the default stages
    tests.<pkg>.<test>;      # a test binary
    devShell;                # a shell matching the planner's Cargo invocation
    toolchain = { rustc; cargo; clippy; rustfmt; };   # resolved

    target.<triple> = {
      packages.<pkg>;        # products for this target
      tests.<pkg>.<test>;    # test binaries, e.g. for VM tests
      testRuns.<pkg>.<test>; # derivations that run them
      testApps.<pkg>.<test>; # the same, runnable outside the sandbox
      doctests.<pkg>;        # each library's doctests
      benches.<pkg>.<bench>; # bench binaries, from a bench variant
      variants.<v> = { packages; tests; };
      spec;                  # the resolved target spec
      traits;                # the target's traits
      canRunTests;           # false: no runner; runs not in checks
    };

    plans.<triple>.<v> = { build; test; };   # plan.json, for debugging
  };

  checks."<ws>/<triple>/<pkg>/<name>";   # everything to check, for checks.<system>
  sources.<crate>;                       # fetched crate sources
  explainSharing;                        # why two plans' units differ
  config; options; optionsDoc;           # the evaluated modules
};
```

### Products

A product such as `packages.<pkg>` is the package's built binaries and
libraries, passed through the target's post-link stages and installed
(`bin/`, `lib/`). It also has:

- `.stages.<name>`: every intermediate stage, e.g. `.stages.linked`;
- `.debug`: split debug information, where the target splits it;
- `.checks.<name>`: the product's checks.

### `checks`

All checks and test runs, flattened for a flake's `checks.<system>`:

| What | Default variant | Other variants |
|---|---|---|
| product | `<ws>/<triple>/<pkg>/build` | `<ws>/<triple>/variant-<v>/<pkg>/build` |
| product check | `…/<pkg>/<check>` | `…/variant-<v>/<pkg>/<check>` |
| test run | `…/<pkg>/test-<name>` | `…/variant-<v>/<pkg>/test-<name>` |
| doctest | `…/<pkg>/doctest` | `…/variant-<v>/<pkg>/doctest` |
| check or clippy variant | | `<ws>/<triple>/variant-<v>/check` |

The first four rows come from every build or coverage variant with
[`checks = true`](options/workspaces.md#workspacesnamevariantsnamechecks)
(the default for hand-written variants, not for the feature-matrix
helpers'). A product whose roots Cargo all skipped is left out.

### `explainSharing`

`repo.explainSharing { a; b; package; }` takes two plans (from `plans`)
and optionally a package name, and lists the inputs that make its units
(or every package's) differ between them.

### Not built yet

`target.<triple>.docs`, the `cargo doc` product
([#6](https://github.com/schlarpc/breakbulk/issues/6)).
