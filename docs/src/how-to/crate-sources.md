# Supply or patch a crate's source

By default, breakbulk downloads each registry crate in `Cargo.lock`
([Fetch from a mirror or a private registry](registries.md)) and fetches
each git dependency ([Use git dependencies](git-dependencies.md)).
[`crateSources`](../reference/options/repository.md#cratesources) puts
your own source in front of that: a directory of vendored crates, or a
crate with a patch.

`crateSources` is a list of functions. breakbulk calls them in order with
a lockfile entry, for every registry and git crate. A function returns
`null` to pass the crate on, or `{ path; subdir ? ""; }`: the crate is
the directory `subdir` of `path`. The first answer wins. When every
function passes, the built-in fetchers run.

The entry has `name`, `version`, `source` (the `Cargo.lock` source
string), `checksum` (null for git), `parsed.kind` (`"registry"` or
`"git"`) and `parsed.url`. It also has `defaultSource`, the
`{ path; subdir; }` that the built-in fetchers give. It is fetched only
if your function uses it.

## Use pre-vendored crates

For a `vendor/` directory that `cargo vendor` wrote, with one
`<name>-<version>` directory per crate:

```nix
{
  crateSources = [
    (entry:
      let dir = ./vendor + "/${entry.name}-${entry.version}"; in
      if builtins.pathExists dir then { path = dir; } else null)
  ];
}
```

Crates missing from `vendor/` are still downloaded. To fail instead, make
the function `throw` where it returns `null`.

## Patch a crate

Start from `defaultSource` and patch it:

```nix
{ pkgs, ... }:
{
  crateSources = [
    (entry:
      if entry.name == "itoa" && entry.version == "1.0.11" then {
        path = pkgs.applyPatches {
          name = "itoa-patched";
          src = entry.defaultSource.path;
          patches = [ ./patches/itoa.patch ];
        };
        inherit (entry.defaultSource) subdir;
      } else null)
  ];
}
```

The lockfile does not change. For a git crate, `defaultSource.path` is
the whole repository and `subdir` the crate's place in it, so the patch's
paths start at the repository root.

## What Cargo checks

Cargo compares a registry crate with the checksum in `Cargo.lock`.
breakbulk gives a supplied crate that checksum whatever its files are,
and drops the file list of a `.cargo-checksum.json` that `cargo vendor`
wrote. So a patched or vendored crate needs no new lockfile and no new
checksum file. The crate still has to be the package that the lockfile
names: the same name and version, and dependencies that resolve to the
locked ones.

## Compared with `[patch]`

Cargo's `[patch.crates-io]` table replaces a crate in the lockfile itself.
breakbulk reads such a patch as Cargo does: the crate becomes a path or
git dependency in `Cargo.lock`. Use `[patch]` when Cargo outside Nix
should use the change too, and `crateSources` for a change that only the
Nix build needs, such as a fix for the sandbox.

## See also

- [Fetching and source views](../explanation/internals/sources.md)
