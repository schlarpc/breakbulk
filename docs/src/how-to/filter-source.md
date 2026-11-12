# Rebuild less when unrelated files change

Each package's units see only that package's directory (plus its
`extraSources`), so an edit elsewhere in the repository does not rebuild
them. The exception is a package whose directory is the repository root:
a single-crate repository, or a workspace whose root `Cargo.toml` is also
a package. That package sees the whole repository except the directories
of its workspace's other members, so editing `flake.nix`, a README or CI
configuration rebuilds it and everything that depends on it. The members
do not see those files.

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

The same applies to a path from Cargo config, such as an `[env]` entry
with `relative = true`:

```toml
# .cargo/config.toml
[env]
ASSETS_DIR = { value = "assets", relative = true }
```

Every unit gets the variable, but each sees the path in its own view. A
crate that reads the files through it
(`include_str!(concat!(env!("ASSETS_DIR"), "/logo.svg"))`) lists the
directory in its `extraSources`, also when the directory belongs to
another package. Crates that never read it need nothing, and do not
depend on it. Registry and git crates see such a path in an empty
directory.

A build script that checks whether a file exists (`Path::exists()`) and
does something else when it does not gets no warning for a missing file:
it does not fail, and it names no `rerun-if-changed` path. Read the build
script, and add such files to `extraSources` too.
