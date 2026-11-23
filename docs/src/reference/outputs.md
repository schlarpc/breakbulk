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
`checks`, the default target's products to `packages`, each
workspace's `docs` to `packages` as `<ws>-docs`, `repo.apps` to `apps`,
and each workspace's dev shell to `devShells`. Each of these
has a switch under `breakbulk.expose`, `true` by default: `checks`,
`packages`, `apps`, `devShells`.

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
    docs;                    # `cargo doc`'s folder, or null
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
        benchRuns.<pkg>.<binary>;    # each bench binary run once in test mode
        namedBenchRuns.<pkg>.<bench>;  # the same, named as in benches; .enabled
        docs;                        # `cargo doc`'s folder
        buildScriptPaths.<plan>;     # each plan's check (build, test)
        check;                       # check and clippy variants only
      };
      # The default variant's, as above:
      packages; tests; testRuns; namedTestRuns; testApps; doctests; docs;
      buildScriptPaths;
      # The bench variant's (the default variant, or the only one with benches):
      benches; benchRuns; namedBenchRuns;
      runner;                # the runner (a list), or null
      testSystem;            # the system test runs build on, or null
      spec;                  # the resolved target spec
      traits;                # the target's traits
      canRunTests;           # false: no runner; its runs not in checks, its apps not in apps
    };

    plans.<triple>.<v> = { build; test; doc; };   # plan.json, for debugging
    vendor = { dir; configFile; cargoHome; };  # Cargo.lock's dependencies, for Cargo offline
  };

  checks."<ws>/<triple>/<pkg>/<name>";   # everything to check, for checks.<system>
  checks.all; checks."<prefix>";         # groups: every check, everything under a prefix
  apps."<ws>/<triple>/<pkg>/test-<name>";  # every test app, for apps.<system>
  sources.<crate>;                       # fetched crate sources
  explainSharing;                        # why two plans' units differ
  nixFeatures;                           # the Nix features this evaluation may use
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

### Documentation

`docs` is the folder `cargo doc` writes, for the variant's packages on
the target: a directory per documented crate (`<crate>/index.html`),
`crates.js`, `search.index/`, `src/`, `static.files/`, `trait.impl/`.
[`docs.noDeps`](options/workspaces.md#workspacesnamedocsnodeps) (`true`
by default) documents the planned packages only (`cargo doc --no-deps`);
`false` documents their dependencies too. Proc macros are in the same
folder. The doc plan (`plans.<triple>.<v>.doc`) is traced only when
`docs` is used. A variant's docs are in `checks` only with
[`docs.check`](options/workspaces.md#workspacesnamevariantsnamedocscheck)
(`false` by default), as `<ws>/<triple>/docs` for the default variant.
See
[Documentation](../explanation/products.md#documentation).

### `checks`

All checks and test runs, flattened for a flake's `checks.<system>`:

| What | Default variant | Other variants |
|---|---|---|
| product | `<ws>/<triple>/<pkg>/build` | `<ws>/<triple>/variant-<v>/<pkg>/build` |
| product check | `…/<pkg>/<check>` | `…/variant-<v>/<pkg>/<check>` |
| test run | `…/<pkg>/test-<name>` | `…/variant-<v>/<pkg>/test-<name>` |
| doctest | `…/<pkg>/doctest` | `…/variant-<v>/<pkg>/doctest` |
| bench run, with `benches` | `…/<pkg>/bench-<name>` | `…/variant-<v>/<pkg>/bench-<name>` |
| plan check | `…/buildScriptPaths/<plan>` | `…/variant-<v>/buildScriptPaths/<plan>` |
| check or clippy variant | | `<ws>/<triple>/variant-<v>/check` |
| docs, with `docs.check` | `<ws>/<triple>/docs` | `<ws>/<triple>/variant-<v>/docs` |

The first six rows come from every build or coverage variant with
[`checks = true`](options/workspaces.md#workspacesnamevariantsnamechecks)
(the default for hand-written variants, not for the feature-matrix
helpers'). A product whose roots Cargo all skipped is left out, and so
is a run turned off with its `enable`
([run settings](../explanation/configuration.md#run-settings):
[`test.binaries.<key>.enable`](options/packages.md#packagesnametestbinariesnameenable),
[`test.doctest.enable`](options/packages.md#packagesnametestdoctestenable),
[`bench.enable`](options/packages.md#packagesnamebenchenable)).
A plan check is
[`buildScriptPaths`](../explanation/configuration.md#missing-build-script-paths)
of the build plan (`<plan>` is `build`), unless the target has no
products, and of the test plan (`test`), unless it has no tests. Check
and clippy variants have the plan checks of the plans their `check`
builds.

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

A binary that uses `CARGO_TARGET_TMPDIR` runs in a private working
directory, which the app removes when the binary exits. That app waits
for the binary and passes INT and TERM on to it; any other app replaces
its own process with the binary.

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

### `vendor`

`workspaces.<ws>.vendor` holds every dependency in the workspace's
`Cargo.lock` that is not a path dependency, unpacked, one directory per
source. It is the directory the planner uses. Use it for
anything that runs Cargo in a derivation, offline, against the locked
dependencies: a build script or a test that runs Cargo
([A build script runs Cargo](../how-to/nested-cargo.md)), or your own
derivation.

- `dir`: the vendor directory.
- `configFile`: Cargo configuration that replaces each source of the
  lockfile (crates.io, other registries, git repositories) with its
  directory in `dir`. Pass it as `cargo --config <file>`.
- `cargoHome`: a directory to use as `CARGO_HOME`. Its `config.toml` is
  `configFile` with `net.offline = true`. The sandbox's `HOME` does not
  exist, so a Cargo in a derivation needs a `CARGO_HOME` anyway.

It depends only on `Cargo.lock` and the fetch settings
([`registries`](options/repository.md#registries),
[`git`](options/repository.md#git), [`crateSources`](options/repository.md#cratesources)), not
on any plan or package setting. So a package setting can name the
vendor directory of its own workspace without an infinite recursion, in
both delivery modes.

### `explainSharing`

`repo.explainSharing { a; b; package; }` takes two plans (from `plans`)
and optionally a package name, and lists the inputs that make its units
(or every package's) differ between them. Units are paired by package,
crate name, crate types, platform and test mode; where several units of
a plan share these (a check plan checks a proc macro that is a member,
and builds it for its dependents), identical units are paired first,
then units with the same outputs. With `b` a check variant's build plan,
`a` a doc plan shows which of the docs' units the check variant shares.

### `nixFeatures`

`repo.nixFeatures` says what Nix must allow for this evaluation, under
Nix's own names: each feature is `true` when some part of the
repository's outputs may use it, including parts that are evaluated only
when asked for. It is read-only. What breakbulk chose is in
`repo.config`: `repo.config.mode` and `repo.config.ca` (and
`repo.options.mode.highestPrio` says whether `mode` is at its default).
On a Nix without dynamic derivations, with both at their defaults, it is:

```nix
{ caDerivations = false; dynamicDerivations = false; importFromDerivation = true; }
```

- `caDerivations`: the `ca-derivations` experimental feature. On when
  [`ca`](options/repository.md#ca) is on, and always in dynamic mode,
  whose outer derivations are content-addressed whatever `ca` says.
- `dynamicDerivations`: the `dynamic-derivations` experimental feature,
  in dynamic mode ([`mode`](options/repository.md#mode)).
- `importFromDerivation`: `allow-import-from-derivation`. Always in IFD
  mode. In dynamic mode, only when a workspace's toolchain may be asked
  for its version or LLVM (a `rustc` or `cargo` whose `version` is not a
  Rust release, or a Rust release newer than breakbulk's LLVM table), a
  workspace's `defaultTarget` default may read the project's
  `build.target` (several targets, none native, and a Cargo config file),
  or a workspace has a dev shell (its Cargo env is read at evaluation
  time; `devShell.target = null` turns it off).

breakbulk uses each feature in one place (`lib/nix-features.nix`), which
fails with an error naming what needed it when the record says the
feature is off. So with `experimental-features` set to exactly the
listed features, and `allow-import-from-derivation` matching, the
repository's outputs evaluate and build. Two things are outside the
record: `explainSharing`, which always imports from derivations, and a
preset given a `rustc` other than its workspace's, whose toolchain may
be probed.
