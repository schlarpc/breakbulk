# Use a workspace binary in another package's build

A member's build sometimes needs another member's product: a code
generator its build script runs, a binary it embeds, a library it links.
Take that product from the workspace's tools variant, not from the
workspace's own `packages`.

## Declare the tools

Import `breakbulk.variants.tools` in the workspace, with the packages
other builds use:

```nix
workspaces.main.imports = [
  (breakbulk.variants.tools { packages = [ "codegen" ]; })
];
```

This defines a variant, `tools`, that plans `cargo build -p codegen` on
the build machine's triple
([`host.triple`](../reference/options/workspaces.md#workspacesnamehosttriple)),
and only there. It is planned there even when the workspace does not
target that triple (a workspace built only for wasm), and then nothing
else is. Its products, test runs and benches are not in `repo.checks`,
and it has no test plan: the default variant builds and tests the same
packages.

## Use them in settings

The products are `repo.workspaces.<ws>.tools.<pkg>`:

```nix
{ repo, ... }:
let
  tools = repo.workspaces.main.tools;
in
{
  packages.app = {
    # The build script runs it.
    nativeInputs = _: [ tools.codegen ];
    # The program embeds it (`include_bytes!(env!("CODEGEN"))`).
    env.CODEGEN = "${tools.codegen}/bin/codegen";
  };
}
```

`inputs` takes a library product the same way. Only `app`'s units, and
what depends on them, wait for the product. The rest of the build starts
at once.

## Why not the workspace's own product

`repo.workspaces.main.packages.codegen` comes from the plan that also
builds `app`. That plan's units depend on `app`'s settings, so a setting
that names a product of the same plan makes the plan depend on itself:
an infinite recursion in dynamic-derivation mode. The tools variant is
another plan, which does not take `app`'s settings (it selects only
`codegen` and what it depends on).

## Differences from the workspace's build

The tools variant runs `cargo build -p codegen`. Cargo turns on a
dependency's features for the packages it builds, so a dependency that
another member uses with more features can be built with fewer here
([F11](../reference/assumptions.md#f11-a--p-plan-unifies-features-over-the-selected-packages)).
The tool can then differ from the default variant's `codegen`, as it
does with `cargo run -p codegen`. Units that come out the same in both
variants are shared.

The variant uses the `release` profile, as every variant does. Change it,
or any other variant setting, with `variant`:

```nix
(breakbulk.variants.tools {
  packages = [ "codegen" "fixtures-server" ];
  variant.profile = "dev";
})
```

`name` renames the variant (default `tools`). The workspace's
[`toolsVariant`](../reference/options/workspaces.md#workspacesnametoolsvariant)
names the variant whose products `tools.<pkg>` are; the module sets it.
The products are also at
`repo.workspaces.<ws>.target.<host triple>.variants.tools.packages.<pkg>`.

## Products of other plans

A product of another workspace, another target or another variant needs
nothing of this: it is never built by the plan that uses it. A wasm
member embedded in a native server is
`repo.workspaces.<ws>.target.wasm32-unknown-unknown.packages.<pkg>`
([Products as inputs](../explanation/configuration.md#products-as-inputs)).
