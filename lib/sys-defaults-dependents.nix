# Curated settings for the workspace members that depend on a crate, by
# the crate's name: what a library needs from its dependents' test runs
# rather than from its own units (lib/sys-defaults.nix). Each value is the
# `sysDefaults.dependents.<name>` settings, or a function of the crate's
# lockfile entry (`{ version, ... }`) that returns them. lib/modules/top.nix
# defines them at `mkDefault` priority when `sysDefaults.enable`.
{ lib }:
{
  # insta finds snapshots under `INSTA_WORKSPACE_ROOT`, else through
  # `cargo metadata`, which fails in a source view (it wants every
  # member). `INSTA_UPDATE = "no"`: a mismatch prints its diff and fails,
  # where insta would otherwise try to write `.snap.new` into the store.
  # insta reads `.snap` files when the test runs, never when it compiles,
  # so the test compiles' view leaves them out and a snapshot edit only
  # re-runs the tests.
  insta = {
    test.env = {
      INSTA_WORKSPACE_ROOT = run: run.workspaceRoot;
      INSTA_UPDATE = "no";
    };
    sources = [
      (
        {
          default,
          kind,
          root,
          packageDir,
          ...
        }:
        if kind == "test" then
          lib.fileset.difference default (
            lib.fileset.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}")
          )
        else
          default
      )
    ];
  };
}
