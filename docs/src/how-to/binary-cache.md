# Use a binary cache

breakbulk's units are ordinary input-addressed derivations, so any Nix
binary cache serves them. This page covers pushing, pulling, and the
settings that matter for many small derivations.

## Push

Push what you built, including the realisations of content-addressed
stages and test runs:

```sh
nix copy --to <cache> .#default
```

Or push every output of a derivation in a `post-build-hook`:

```sh
nix copy --to <cache> "$DRV_PATH^*"
```

Plain `nix copy` of store paths uploads no realisations. Units do not need
them, but content-addressed stages and test runs do; without them those
re-run on other machines.

In dynamic-derivation mode, pushing the instantiation step with
`"$DRV_PATH^*"` also uploads the workspace's source views. Keep that in
mind for private code on a public cache.

## Choose a cache

- **A `nix copy` S3 or HTTP cache** stores realisations (under
  `build-trace-v2/`): units substitute, and content-addressed stages and
  test runs cut off.
- **FlakeHub Cache and Attic** store paths only: units substitute;
  content-addressed stages and test runs re-run.
- **No remote cache:** the local store does everything, including cutoff.

## Use fewer substituters

Before it builds a derivation, Nix asks every configured cache whether it
has it. breakbulk makes many small derivations, so each extra cache adds
time: about 7 s per 300 crates with four caches. Keep only the caches you
need:

```sh
nix build --option substituters "https://cache.nixos.org https://your-cache.example"
```

This needs a trusted user, or the caches listed in `trusted-substituters`.
