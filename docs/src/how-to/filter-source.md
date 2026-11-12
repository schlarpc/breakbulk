# Rebuild less when unrelated files change

Each package's units see only that package's directory (plus its
`extraSources`), so an edit elsewhere in the repository does not rebuild
them. The exception is a package whose directory is the repository root:
a single-crate repository, or a workspace whose root `Cargo.toml` is also
a package. That package's directory is the whole repository, so editing
`flake.nix`, a README or CI configuration rebuilds it and everything that
depends on it.

Members in subdirectories (`crates/foo`) need nothing on this page.

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

A build script that checks whether a file exists (`Path::exists()`) and
does something else when it does not gets no warning for a missing file:
it does not fail, and it names no `rerun-if-changed` path. Read the build
script, and add such files to `extraSources` too.
