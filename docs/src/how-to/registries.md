# Fetch from a mirror or a private registry

breakbulk downloads every registry crate in `Cargo.lock` as a
fixed-output derivation, checked against the lockfile's checksum. Each
registry is an entry of
[`registries`](../reference/options/repository.md#registries). An entry
says which lockfile entries it serves (`index`), where to download them
(`dl`), and how (`fetch`). crates.io is the entry `registries.crates-io`.

This page shows how to download crates.io crates from a mirror, how to
add a private registry, and how to give a registry credentials.

## Use a mirror of crates.io

Set the download URL template of the `crates-io` entry:

```nix
{
  registries.crates-io.dl = "https://crates-mirror.example/{crate}/{crate}-{version}.crate";
}
```

The template takes the markers of a registry's `config.json`: `{crate}`,
`{version}`, `{prefix}`, `{lowerprefix}` and `{sha256-checksum}`. A
template without any marker gets `/{crate}/{version}/download` appended,
as in Cargo.

The `index` stays crates.io's. It matches the lockfile entries, which
still name crates.io. The mirror changes only where breakbulk downloads
them from, and the checksum still has to match.

## Add a private registry

`Cargo.lock` records a registry crate's index URL, but not where to
download it. That is in the registry's `config.json`, which breakbulk
would have to fetch during evaluation to read. So give both:

```nix
{
  registries.my = {
    index = "sparse+https://my-registry.example/index/";
    dl = "https://my-registry.example/api/v1/crates/{crate}/{version}/download";
  };
}
```

Write `index` as it appears in `Cargo.lock`, with or without the
`registry+` prefix; a sparse index keeps `sparse+`. Copy `dl` from the
`dl` field of the index's `config.json`. The name (`my`) is free: it
labels the registry in the Cargo configuration that points the registry
at its vendored crates. A lockfile entry from a registry that no entry
serves is an evaluation error that names the index.

## Give a registry credentials

breakbulk does not handle secrets. It never reads a token, and a value
in your Nix code is copied into the world-readable Nix store. A
credential reaches a download in one of two ways, both outside Nix code:

- **A netrc file the Nix daemon reads.** Nix's built-in fetcher
  (`<nix/fetchurl.nix>`, the `builtin:fetchurl` builder) uses the
  daemon's netrc file: the
  [`netrc-file`](https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-netrc-file)
  setting, `/etc/nix/netrc` by default. Make the registry's downloads
  use that fetcher:

  ```nix
  {
    registries.my.fetch = _: { name, url, sha256 }:
      import <nix/fetchurl.nix> { inherit name url sha256; };
  }
  ```

  Put a line for the registry's host into the netrc file:

  ```text
  machine my-registry.example login token password <token>
  ```

- **An environment variable the Nix daemon has.** A fixed-output
  derivation gets the variables that it lists in `impureEnvVars`, with
  the values from the environment of the process that builds it. With a
  Nix daemon, that is the daemon's environment (for example a systemd
  `Environment=` line), or Nix's `impure-env` setting (the experimental
  feature `configurable-impure-env`), not your shell's. nixpkgs'
  `fetchurl` can build a netrc file from such a variable:

  ```nix
  {
    registries.my.fetch = p: args: p.fetchurl (args // {
      netrcImpureEnvVars = [ "MY_REGISTRY_TOKEN" ];
      netrcPhase = ''
        echo "machine my-registry.example login token password $MY_REGISTRY_TOKEN" > netrc
      '';
    });
  }
  ```

`fetch` is a function of the build machine's package set. It returns a
fetcher with `fetchurl`'s interface, which breakbulk calls with `name`,
`url` (from `dl`) and `sha256` (the lockfile's checksum). The default is
`pkgs: pkgs.fetchurl`. The download is fixed-output, so the result does
not depend on the credential: once a crate is in a binary cache, a
machine without the credential can substitute it.

The same applies to the `crates-io` entry, for a mirror that needs
credentials.

## See also

- [Use git dependencies](git-dependencies.md)
- [Supply or patch a crate's source](crate-sources.md), for a crate that
  no registry serves
- [Fetching and source views](../explanation/internals/sources.md)
