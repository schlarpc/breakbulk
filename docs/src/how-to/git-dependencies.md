# Use git dependencies

A git dependency needs no setting. breakbulk reads its URL and locked
revision from `Cargo.lock` and fetches it with `builtins.fetchGit` during
evaluation, because it must look inside the tree to find the crate. The
settings in
[`git`](../reference/options/repository.md#git) make that fetch
cacheable, replace it with a tree you already have, or skip the search
for the crate.

## Name a source

An entry of `git` is keyed by either:

- **The source string**, as in `Cargo.lock`:
  `"git+https://github.com/me/serde?branch=fix#0123abcd…"`. It names one
  locked revision.
- **The URL** alone: `"https://github.com/me/serde"`. It covers every
  revision of that repository in every lockfile of the repository.

A source uses the entry under its source string if there is one, and
else the one under its URL. The two entries are not merged: a source
string's entry replaces the URL's whole entry for that revision.

## Let a binary cache serve the tree

Without a hash, every machine that evaluates the flake clones the
repository, and evaluation fails when the remote cannot be reached. A NAR
hash makes the fetch fixed-output, so Nix can substitute the tree from a
binary cache instead:

```nix
{
  git."git+https://github.com/me/serde?branch=fix#0123abcd…".hash =
    "sha256-5mLf4B3zTZwv3wKgdixL/QJuTuouPlpm01rMFAZ8D6Y=";
}
```

A hash belongs to one revision, so key it by the source string. To find
it, set a wrong hash (`lib.fakeHash`) and copy the one Nix reports. It is
the hash of the fetched tree, not crane's `outputHashes` value.

## Use a tree you already have

`tree` replaces the fetch with a local checkout, a flake input, or any
other tree:

```nix
{
  # `inputs`: your flake's inputs
  git."https://github.com/me/serde".tree = inputs.serde-fork;
}
```

breakbulk does not check that the tree is the locked revision. Keyed by
URL, it serves every revision locked from that URL.

## Skip the search for a crate

breakbulk finds a crate in its tree as Cargo does: it walks the tree's
`Cargo.toml` files and takes the first package with the crate's name and
version. In a large repository, `subdirs` names the directory instead:

```nix
{
  git."https://github.com/me/monorepo".subdirs.mycrate = "crates/mycrate";
}
```

## Leave out submodules

Cargo checks out the submodules of a git dependency, so breakbulk fetches
them too. Turn that off for a repository whose crates do not need them:

```nix
{
  git."https://github.com/me/repo".submodules = false;
}
```

## Private repositories

`builtins.fetchGit` runs in the evaluating process, with your git
configuration and credentials (an SSH agent, a credential helper). With a
`hash`, a machine that substitutes the tree needs none.

## See also

- [Fetch from a mirror or a private registry](registries.md)
- [Supply or patch a crate's source](crate-sources.md), for example to
  patch a crate of a git dependency
- [Fetching and source views](../explanation/internals/sources.md)
