# Rebuild less when unrelated files change

A package's source is its directory inside the repository you pass as
`root`. When the crate sits at the repository root, that is the whole
repository, so an edit to `flake.nix` or a README rebuilds it.

## Pass a filtered root

Keep only what the build reads:

```nix
repo = breakbulk.lib.mkRepository {
  inherit pkgs;
  root = nixpkgs.lib.fileset.toSource {
    root = ./.;
    fileset = nixpkgs.lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
};
```

Add everything the build reads: `.cargo/config.toml`, data files,
`include_str!` targets, and each package's [`extraSources`](../reference/options/packages.md#packagesnameextrasources).

## Files outside a package's directory

If a crate reads files outside its own directory (`include_str!("../../wit/x.wit")`,
shared assets), name them for that package, relative to the repository
root:

```nix
modules = [{
  packages.app.extraSources = [ "wit" "../shared/assets" ];
}];
```

They appear at their original relative paths, so the crate's paths work
unchanged, and only that package's units depend on them.
