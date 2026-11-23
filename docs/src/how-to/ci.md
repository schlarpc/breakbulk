# Run the checks in CI

Build one aggregate check instead of listing checks by name:

```sh
nix build .#checks.x86_64-linux.all
```

`all` holds every check in `repo.checks`. A smaller group works the same
way:

| Installable | What it builds |
| --- | --- |
| `checks.<system>.all` | every check |
| `checks.<system>.<ws>` | every check of one workspace |
| `checks.<system>."<ws>/<triple>"` | one target's checks |
| `checks.<system>."<ws>/<triple>/<pkg>"` | one package's checks |
| `checks.<system>."<ws>/<triple>/variant-<v>"` | one variant's checks |
| `checks.<system>.<name>` | a group you define in [`checkGroups`](../reference/options/repository.md#checkgroups) |

## Leave out products you do not ship

By default every package's product is a check, including helper and
bench crates that nothing ships. A product whose build script needs the
network fails in the sandbox, often late in a long build. List the
packages whose products you want instead
([`products`](../reference/options/workspaces.md#workspacesnamevariantsnameproducts)),
for every variant through the workspace's or a target's
`variantDefaults`:

```nix
workspaces.main.targets.x86_64-unknown-linux-gnu.variantDefaults.products = [ "app" "cli" ];
```

Only those packages get `packages.<pkg>` and product checks on that
target. Test binaries, test runs and doctests are unchanged, so a helper
crate with tests is still built for them. `products = false` leaves out
every product.

## Your own checks

A check of your own, such as a license audit, becomes a leaf of
`repo.checks` with
[`checks`](../reference/options/repository.md#checks), in the same
groups as breakbulk's:

```nix
checks."lint/deny" = pkgs.runCommand "deny" { } "…; touch $out";
```

`nix build .#checks.x86_64-linux.lint` then builds every check under
`lint/`, and `all` holds it too.

## Why one installable

With the evaluation cache off (`--no-eval-cache`, or a CI runner without
one), Nix evaluates the flake once per installable on the command line.
A project with one check per test binary can have hundreds, so building
them by name spends most of its time evaluating the same flake again.
One group is one evaluation.

## Your own groups

`checkGroups` names a list of glob patterns over check names (`*` within
one `/`-separated segment, `**` across any number) and derivations:

```nix
{
  checkGroups = {
    clippy = [ "*/*/variant-clippy/**" ];
    fmt = [ "*/fmt" ];
  };
}
```

`nix build .#checks.x86_64-linux.clippy` then builds every clippy
variant's check. A pattern that matches no check is an evaluation error,
since it is most likely a typo.

## Keep test output as an artifact

A test run's output goes to the build log, and the run's `$out` is
empty. If your binary cache does not store build logs, or your CI keeps
logs as artifacts, copy the raw output into `$out` with a
[`test.postRun`](../reference/options/packages.md#packagesnametestpostrun)
snippet:

```nix
workspaces.main.memberDefaults.test.postRun = ''cp "$log" "$out/log"'';
```

Every test run and doctest run then has its output in `log`. The output
holds timings and, with several test threads, lines in a varying order,
so such a run is not reproducible: `nix build --rebuild` of it fails.

## A clippy check fails where `cargo clippy` passes

A clippy variant lints a workspace member twice when the member is also
a build-dependency: once for the target, and once for the build
machine. The host copy does not get the project's rustflags, so it is
linted without a `--cfg` the project sets
([Cargo with `--target`](../explanation/trade-offs.md#cargo-with---target)).
Code that only the cfg uses then gives warnings, which `-D warnings`
turns into errors. The failed unit is the member's library on the host
side; its log has no `--target` in the clippy-driver command line.

Give that member's host units their own clippy arguments, in the clippy
variant only:

```nix
workspaces.main.imports = [
  (breakbulk.variants.clippy { args = [ "-D" "warnings" ]; })
];
# `runtime` is a dependency and a build-dependency of `app`.
packages.runtime.variant.clippy.forHost.env.CLIPPY_ARGS =
  lib.concatMapStrings (a: a + "__CLIPPY_HACKERY__") [
    "-D" "warnings"
    "-A" "unused_variables"
  ];
```

`CLIPPY_ARGS` is how clippy-driver gets its arguments, each followed by
`__CLIPPY_HACKERY__`. The value replaces the preset's `args` for the
host copy only. The target copy is still linted with `args`, and no
other variant's units rebuild.

## Read a failed `--keep-going` build

With `--keep-going`, Nix builds everything it can and reports every
failure at the end. Most of the failures are only consequences: a check
or product whose input failed reports that some of its dependencies
failed. Look for the root failures, those whose own builder failed. Nix
2.34 prints them so:

```text
error: Cannot build '/nix/store/…-mylib-sys-0.1.0-build-run.drv'.
       Reason: builder failed with exit code 1.
       Last 25 log lines:
       > …
       For full logs, run:
         nix log /nix/store/…-mylib-sys-0.1.0-build-run.drv
```

A dependent's reason reads `1 dependency failed` instead; skip those.
Older Nix versions print `builder for '…' failed` for a root failure and
`dependencies of derivation '…' failed to build` for a dependent.

`nix log <drv>` prints a root failure's whole log. A failed unit's
error, with breakbulk's hints (the option to set, the path to add), is
near its end. The `log-lines` setting (default 25) makes the tail in the
summary longer.

[nix-output-monitor](https://github.com/maralorn/nix-output-monitor)
shows the failures as they happen: run `nom build` with the same
arguments as `nix build`. Its tree shows each failed build (`⚠`, red)
below the derivations that need it, so the lowest failed entry is a
root failure.

Checks fail without stopping the products: when a plan's
[`buildScriptPaths`](../explanation/configuration.md#missing-build-script-paths)
check fails, its products still build, and the check's log names every
path to add.
