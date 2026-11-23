# Check feature combinations

`cargo hack check --workspace --feature-powerset` checks each package
with every combination of its features. breakbulk makes the same runs as
variants, one plan each. Units that come out identical between runs are
shared, so a run costs only the crates whose features differ.

## Per package, as cargo-hack

Import the generator's module in the workspace:

```nix
workspaces.main.imports = [
  (breakbulk.variants.featurePowerset {
    scope = "package";
    variant = {
      mode = "check";
      profile = "dev";
    };
  })
];
```

Each package gets these runs, each with `-p <pkg>`:

- `hack-<pkg>.all-features`: `--all-features`. Only for a package with an
  optional dependency that no feature names as `dep:<name>` (an implicit
  feature), and with `eachFeature` also for a package with two features
  or more.
- `hack-<pkg>.no-default-features`: `--no-default-features`.
- `hack-<pkg>.<f1>+<f2>`: `--no-default-features --features f1,f2`, for
  each non-empty set of the package's `[features]`. A set in which one
  feature already turns on another is left out.

A package with no features and no implicit features gets one run,
`hack-<pkg>`, with its default features. Optional dependencies are not in
the sets, as in cargo-hack without `--optional-deps`. The package's
features come from
[`workspaces.<ws>.members`](../reference/options/workspaces.md#workspacesnamemembers).

## One feature list for the workspace

`scope = "workspace"` combines a list of your own, for the whole
workspace:

```nix
workspaces.main.imports = [
  (breakbulk.variants.featurePowerset {
    scope = "workspace";
    features = [ "json" "tls" "core/simd" ];
    variant.mode = "check";
  })
];
```

Each subset is one variant with `noDefaultFeatures = true`:
`features-none`, `features-json`, `features-json+tls`,
`features-core_simd` (a `/` becomes `_` in the name), and so on.

## Arguments

Both scopes take the same arguments:

| Argument | Default | Meaning |
| --- | --- | --- |
| `scope` | (required) | `"package"` or `"workspace"`. |
| `features` | `null` | Workspace scope only, required there: the features to combine. |
| `packages` | `null` | Package scope: the packages that get runs; `null` is every member, or a list, or `{ exclude = [ … ]; }`. Workspace scope: each variant's `packages`. |
| `eachFeature` | `false` | Each feature alone instead of every combination (`--each-feature`). |
| `depth` | `null` | At most this many features in a set (`--depth`). Not with `eachFeature`. |
| `excludeFeatures` | `[ ]` | Features in no set (`--exclude-features`). In the package scope, any entry also removes the `--all-features` run, as in cargo-hack. |
| `excludeSets` | `[ ]` | Sets to leave out, each a list of features in any order. |
| `excludeNoDefaultFeatures` | `false` | No run without any features (`--exclude-no-default-features`; `features-none` in the workspace scope). |
| `excludeAllFeatures` | `false` | Package scope only: no `--all-features` run (`--exclude-all-features`). |
| `prefix` | `"hack"` or `"features"` | The start of each variant's name: `"hack"` for the package scope, `"features"` for the workspace scope. |
| `variant` | `{ }` | A module for each generated variant: any [`variants.<v>`](../reference/options/workspaces.md#workspacesnamevariants) setting. |

## Your settings on generated variants

The generator sets only what a run needs: its `features`, `packages`,
and `noDefaultFeatures = true` or `allFeatures = true`. Your settings,
in `variant` or in `variants.<name>` elsewhere, apply as they do to any
variant:

- `features` add to the run's. To add a feature to every run, set
  `variant.features`, and if it is one of the package's own, also put it
  in `excludeFeatures` so that no set repeats it.
- `variant.noDefaultFeatures = true` turns off the default features of the
  runs that keep them, such as the `all-features` run.
- A setting that contradicts a run, such as `noDefaultFeatures = false`
  on a `--no-default-features` run, is an evaluation error.
- The `variantDefaults` apply too, their `features` included, which
  Cargo rejects on a package-scope run of a package that does not accept
  them. A function module can give each run only the features its
  package accepts
  ([Features and package selections](targets.md#features-and-package-selections)).

## Put the runs in `repo.checks`

A generated variant has `checks.products`, `checks.tests` and
`checks.benches` set to `false` at `lib.mkDefault` priority, so the
runs and products of a large matrix stay out of `repo.checks`. A check variant's
`check` derivation is in `repo.checks` anyway (`checks.check`). To add
the test runs too, set `variant.checks.tests = true`.
