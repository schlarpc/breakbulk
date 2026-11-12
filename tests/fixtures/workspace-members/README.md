Members found three ways, for `workspaces.<ws>.members` and the exclude
form of package selections.

- `crates/*` is a glob in `members`; `crates/util` is the package
  `ws-util`, so names and directories differ.
- `crates/scratch` matches the glob but is in `[workspace] exclude`: not a
  member.
- `libs/helper` is in no `members` entry: it is a member as a path
  dependency of the root package `app`.

Every member has a test, so its test binaries show which packages a test
plan selected.
