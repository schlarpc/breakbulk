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
([`products`](../reference/options/workspaces.md#workspacesnametargetsnameproducts)):

```nix
workspaces.main.targets.x86_64-unknown-linux-gnu.products = [ "app" "cli" ];
```

Only those packages get `packages.<pkg>` and product checks on that
target. Test binaries, test runs and doctests are unchanged, so a helper
crate with tests is still built for them. `products = false` leaves out
every product.

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
