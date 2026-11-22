# Curated settings for the workspace members that depend on a crate, by
# the crate's name: what a library needs from its dependents' test runs
# rather than from its own units (lib/sys-defaults.nix). Each value is the
# `sysDefaults.dependents.<name>` settings, or a function of the crate's
# lockfile entry and `buildDependency` (`{ version, buildDependency, ... }`)
# that returns them. lib/modules/top.nix defines them at `mkDefault`
# priority.
{ lib }:
let
  # Build-dependencies whose library code prints `rerun-if-changed`
  # directives for the build script, each checked in the crate's source
  # (latest release, 2026-11): source prediction reads only the script's
  # own literal directives, so a package that build-depends on one keeps
  # its build-script runs' whole view. Only a direct build-dependency: a
  # crate reached through others prints for their scripts, not the
  # package's. Not prost-build (it prints none), nor cc, pkg-config or
  # napi-build (only `rerun-if-env-changed`).
  directivePrinter =
    { buildDependency, ... }:
    lib.optionalAttrs buildDependency { predictSources.buildScriptRuns = false; };
in
{
  # insta finds snapshots under `INSTA_WORKSPACE_ROOT`, else through
  # `cargo metadata`, which fails in a source view (it wants every
  # member). `INSTA_UPDATE = "no"`: a mismatch prints its diff and fails,
  # where insta would otherwise try to write `.snap.new` into the store.
  # insta reads `.snap` files when the test runs, never when it compiles,
  # so every view but the test runs' leaves them out and a snapshot edit
  # only re-runs the tests.
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
        if kind != "run" then
          lib.fileset.difference default (
            lib.fileset.fileFilter (f: f.hasExt "snap") (root + "/${packageDir}")
          )
        else
          default
      )
    ];
  };

  # They read the dependent's `Cargo.toml` from `CARGO_MANIFEST_DIR`
  # (proc-macro-crate also its workspace's, found with `cargo
  # locate-project --workspace` when `CARGO` is set); checked in each
  # crate's source. bevy_macro_utils panics without it; the others return
  # an error that their callers may pass over.
  proc-macro-crate = {
    predictSources.keep = [
      "Cargo.toml"
      (
        { root, workspaceDir, ... }:
        lib.fileset.maybeMissing (
          root + "/${if workspaceDir == "" then "" else workspaceDir + "/"}Cargo.toml"
        )
      )
    ];
  };
  find-crate = {
    predictSources.keep = [ "Cargo.toml" ];
  };
  bevy_macro_utils = {
    predictSources.keep = [ "Cargo.toml" ];
  };

  autocfg = directivePrinter;
  bindgen = directivePrinter;
  cxx-build = directivePrinter;
  glib-build-tools = directivePrinter;
  lalrpop = directivePrinter;
  slint-build = directivePrinter;
  tauri-build = directivePrinter;
  vergen = directivePrinter;
  vergen-lib = directivePrinter;
}
