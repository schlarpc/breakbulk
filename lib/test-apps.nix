# Test apps: every test binary as a runnable program, with its test run's
# working directory, environment and runner, run on the user's machine ("Tests"
# in docs/src/explanation/internals/products.md). The escape hatch for tests
# that cannot run in the sandbox (network, devices), and the way to rerun one
# binary under a debugger or with a filter.
#
#   apps = breakbulk.testApps.mkTestApps {
#     pkgs;              # the user's machine's package set
#     testRuns;          # breakbulk.testRuns.mkTestRuns's result
#     checkout = null;   # the user's checkout of the repository root, as a
#                        # string (e.g. "/home/me/src/project"); null: the
#                        # store's source view
#     packages = { };    # packages.<name>, with `runs` (only each run's `env`,
#                        # `path` and `wrapper` apply)
#     name = "breakbulk";
#   };
#   apps.<pkg>.<binary>   a derivation: the script, bin/<name>, as
#                         meta.mainProgram
#
#   nix run .#<attribute path to the app> -- --exact net::fetches --nocapture
#
# A derivation, not the flake app shape (`{ type = "app"; program; }`):
# `nix run` takes that shape only under a flake's `apps` output, and a
# derivation with `meta.mainProgram` anywhere (Nix's src/nix/app.cc).
# repo.apps gives them in the app shape for `apps`.
#
# The app runs the test binary (not the output of its run's stages) in
# the package's directory with the same dynamic-library path, `rustc-env`
# values, `CARGO_*` runtime variables, `env`, `path` and `wrapper` (of
# its run settings, testRuns.runConfig) as its test run, under the
# runner of its platform (the build machine's for a proc macro's unit
# tests), in a private working directory when the binary uses
# `CARGO_TARGET_TMPDIR`, as its test run (testRuns.workdirScript; removed
# when the app exits). With `checkout`, `CARGO_MANIFEST_DIR` and
# `CARGO_MANIFEST_PATH` name the checkout, so tests that read files through
# them see the working tree; values compiled in with `env!` still name the
# store.
#
# Unlike the test run, it passes only its own command-line arguments: no
# `args` skip list (the point is to run what the sandbox skips); and it
# runs no `preRun` entries, so it keeps the user's `HOME` and has no
# `RUST_TEST_THREADS`, as `cargo test`.
{ lib, testRunsLib }:
{
  mkTestApps =
    {
      pkgs,
      testRuns,
      checkout ? null,
      packages ? { },
      name ? "breakbulk",
    }:
    let
      t = testRuns;
      app =
        spec:
        let
          cfg = testRunsLib.runConfig packages spec.package "test" spec.binary;
          dir =
            if checkout == null then
              spec.sourceDir
            else if spec.packageDir == null then
              throw "breakbulk: cannot place ${spec.package} in the checkout: its CARGO_MANIFEST_DIR is not a source view path"
            else
              "${lib.removeSuffix "/" (toString checkout)}${
                lib.optionalString (spec.packageDir != "") "/${spec.packageDir}"
              }";
          vars = lib.optionalAttrs (checkout != null) {
            CARGO_MANIFEST_DIR = dir;
            CARGO_MANIFEST_PATH = "${dir}/Cargo.toml";
          };
          script = pkgs.writeShellScriptBin "${name}-${spec.name}" ''
            set -euo pipefail
            ${testRunsLib.envScript {
              inherit spec vars;
              jq = "${pkgs.jq}/bin/jq";
            }}
            ${testRunsLib.configScript pkgs cfg}
            files=(${spec.unitOut}/*)
            ${testRunsLib.appRunScript {
              inherit pkgs;
              dir = lib.escapeShellArg dir;
              command = ''${pkgs.coreutils}/bin/env "''${__bb_env[@]}" ${
                testRunsLib.launchWords {
                  inherit pkgs;
                  inherit (spec) runner;
                  wrapper = testRunsLib.wrapperOf pkgs cfg;
                  sourceRoot = testRunsLib.sourceRootOf spec checkout;
                }
              } "''${files[0]}" "$@"'';
            }}
          '';
        in
        script;
    in
    lib.mapAttrs (_: lib.mapAttrs (_: app)) t.specs;
}
