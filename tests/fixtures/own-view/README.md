Repository paths in a unit resolve in that unit's own view.

- The repository root is a workspace whose root is also a package (`app`),
  with the member `crates/lib1`. Cargo compiles lib1 in the workspace
  root, as `crates/lib1/src/lib.rs`.
- `.cargo/config.toml` sets three `relative` paths: the repository root
  (with a trailing `/`), the root-level `assets`, and `crates/lib1/data`.
  Each crate reads, with `include_str!`, only paths in its own directory
  or in its `extraSources`.
- `virtual/` is a virtual workspace that the same config applies to.
- Both workspaces depend on the registry crate `itoa`, whose units get
  the three paths too, in an empty directory.
