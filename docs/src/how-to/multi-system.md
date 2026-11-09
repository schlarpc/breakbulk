# Use a flake with several systems

Many flakes define outputs for several systems, for example with the
`nix-systems/default` input, which includes macOS. In IFD mode (the
default on stable Nix), breakbulk can only list the checks and packages
of systems you can build on.

## Why

In IFD mode, check and package names come from the plans. Planning runs
Cargo with the target system's rustc as the host compiler, so it must run
on that system. A command that evaluates every system's outputs therefore
needs a builder for each one:

| Command | IFD mode | Dynamic-derivation mode |
| --- | --- | --- |
| `nix flake check`, `nix flake show` | fine: other systems are left out | fine |
| `nix flake check --all-systems`, `nix flake show --all-systems` | fails with `Required system: 'aarch64-darwin'` while planning for that system | other systems' check names and `drvPath`s evaluate |

## What to do

- In IFD mode, list only the systems you can build on. Use your own list
  instead of `nix-systems/default`, or a list without the systems you have
  no builder for.
- Or use dynamic-derivation mode (`mode = "dynamic"`, or `"auto"` on a Nix
  with dynamic derivations), where evaluating another system's outputs
  needs no builder for it.

See [`mode`](../reference/options/repository.md#mode).
