Three workspaces (`a`, `b`, `c`) with their own lockfiles.

- `shared/` lies outside every workspace root: all three use it, so its
  units (lib, build-script compile and run) are shared.
- `a/inner` is a member of `a` and a path dependency of `b` and `c`: shared
  between `b` and `c` (outside both roots), not with `a` (relative path,
  working directory, `CARGO_PRIMARY_PACKAGE`).
- `itoa` and `libc` (with a build script) come from crates.io in all three.
