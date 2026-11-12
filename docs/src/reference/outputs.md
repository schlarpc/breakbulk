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
`checks`, the default target's products to `packages`, `repo.apps` to
`apps`, and each workspace's dev shell to `devShells`. Each of these
has a switch under `breakbulk`, `true` by default: `exposeChecks`,
`exposePackages`, `exposeApps`, `exposeDevShells`.

## The result

`<ws>` is a workspace name, `<triple>` a target, `<v>` a variant,
`<pkg>` a package.

```nix
repo = {
  workspaces.<ws> = {
    # Shortcuts for the default target (defaultTarget) and variant:
    packages.<pkg>;          # a product: the build after the default stages
    tests.<pkg>.<test>;      # a test binary
    testRuns.<pkg>.<binary>; # a test run
    devShell;                # a shell matching the planner's Cargo invocation
    toolchain = { rustc; cargo; clippy; rustfmt; };   # resolved

    target.<triple> = {
      variants.<v> = {
        packages.<pkg>;              # products for this target
        tests.<pkg>.<test>;          # test binaries, e.g. for VM tests
        testRuns.<pkg>.<binary>;     # derivations that run them
        namedTestRuns.<pkg>.<test>;  # the same, named as in tests; .enabled
        testApps.<pkg>.<binary>;     # the same, for nix run outside the sandbox
        doctests.<pkg>;              # each library's doctests
        benches.<pkg>.<bench>;       # bench binaries, in a bench variant
        benchRuns.<pkg>.<binary>;    # each bench run once in test mode
        namedBenchRuns.<pkg>.<bench>;  # the same, named as in benches; .enabled
        check;                       # check and clippy variants only
      };
      # The default variant's, as above:
      packages; tests; testRuns; namedTestRuns; testApps; doctests;
      # The bench variant's (the default variant, or the only one with benches):
      benches; benchRuns; namedBenchRuns;
      runner;                # the runner (a list), or null
      testSystem;            # the system test runs build on, or null
      spec;                  # the resolved target spec
      traits;                # the target's traits
      canRunTests;           # false: no runner; its runs not in checks, its apps not in apps
    };

    plans.<triple>.<v> = { build; test; };   # plan.json, for debugging
  };

  checks."<ws>/<triple>/<pkg>/<name>";   # everything to check, for checks.<system>
  checks.all; checks."<prefix>";         # groups: every check, everything under a prefix
  apps."<ws>/<triple>/<pkg>/test-<name>";  # every test app, for apps.<system>
  sources.<crate>;                       # fetched crate sources
  explainSharing;                        # why two plans' units differ
  nixFeatures;                           # the Nix features this evaluation uses
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
helpers'). A product whose roots Cargo all skipped is left out, and so
is a test run or doctest turned off with
[`test.binaries.<key>.enable`](options/packages.md#packagesnametestbinariesnameenable)
or [`test.doctest.enable`](options/packages.md#packagesnametestdoctestenable).

Groups are checks too, each an aggregate (a `linkFarm` of the checks it
holds) that builds them as one installable
([Run the checks in CI](../how-to/ci.md)):

- every proper prefix of a check name: `<ws>`, `<ws>/<triple>`,
  `<ws>/<triple>/<pkg>`, `<ws>/<triple>/variant-<v>`, and so on;
- `all`, every check (so a workspace may not be named `all`);
- each of [`checkGroups`](options/repository.md#checkgroups).

They add about one name per distinct prefix to `nix flake check`'s list,
and build nothing the checks themselves do not. A group has
`breakbulkCheckGroup = true`, which tells it from a leaf check.

### Test apps and `apps`

A test app (`testApps.<pkg>.<binary>`) is a derivation whose
`meta.mainProgram` runs the test binary with its test run's working
directory, environment and runner, on your machine, so `nix run` takes
it at its attribute path. `<binary>` is the test binary's key, as in
`testRuns`: an integration test by its name, the others as
`<kind>/<name>` (`lib/<crate>`, `bin/<name>`).

`repo.apps` has every test app of every build or coverage variant, in
the shape of a flake's `apps` output (`{ type = "app"; program; meta; }`),
for `apps.<system> = repo.apps;`. Each is named as its test run's check
in the table above (`…/<pkg>/test-<name>`,
`…/variant-<v>/<pkg>/test-<name>`), also when the variant has
`checks = false` or the run is disabled. A target with
`canRunTests = false` has none.

```
nix run .#default/x86_64-unknown-linux-gnu/app/test-e2e -- --nocapture
```

### `explainSharing`

`repo.explainSharing { a; b; package; }` takes two plans (from `plans`)
and optionally a package name, and lists the inputs that make its units
(or every package's) differ between them.

### `nixFeatures`

`repo.nixFeatures` says which Nix features breakbulk uses in this
evaluation, under Nix's own names. It is read-only: it shows what
[`mode`](options/repository.md#mode) and
[`ca`](options/repository.md#ca) came out as, which with `mode = "auto"`
and `ca = null` depends on the evaluator. On a Nix without dynamic
derivations, with both at their defaults, it is:

```nix
{ caDerivations = false; dynamicDerivations = false; importFromDerivation = true; }
```

- `importFromDerivation`: `mode` came out as `ifd`.
- `dynamicDerivations`: `mode` came out as `dynamic`.
- `caDerivations`: `ca` came out as on, so stages, checks and test runs
  are content-addressed and an unchanged input does not re-run them
  ([Content addressing at the edges](../explanation/caching.md#content-addressing-at-the-edges)).
  When it is `false`,
  [`test.runFiles`](options/packages.md#packagesnametestrunfiles) and
  [`test.stripForRun`](options/packages.md#packagesnameteststripforrun)
  do not save test runs.

### Not built yet

`target.<triple>.docs`, the `cargo doc` product
([#6](https://github.com/schlarpc/breakbulk/issues/6)).
