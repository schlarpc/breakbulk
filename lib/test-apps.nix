# Test apps: every test binary as a runnable flake app, with its test run's
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
#     packages = { };    # packages.<name>.test (only `env` and `path` apply)
#     name = "breakbulk";
#   };
#   apps.<pkg>.<binary> = { type = "app"; program = "…/bin/<name>"; }
#
#   nix run .#<app> -- --exact net::fetches --nocapture
#
# The app runs the test binary (not a content-addressed copy) in the
# package's directory with the same dynamic-library path, `rustc-env`
# values, `CARGO_*` runtime variables, `test.env`,
# `test.binaries.<binary>.env` and `test.path` as its test run, under the
# target's runner, and creates
# `/tmp/breakbulk-target-tmp`. With `checkout`, `CARGO_MANIFEST_DIR` and
# `CARGO_MANIFEST_PATH` name the checkout, so tests that read files through
# them see the working tree; values compiled in with `env!` still name the
# store.
#
# Unlike the test run, it passes only its own command-line arguments: no
# `test.args` skip list (the point is to run what the sandbox skips), no
# `--include-ignored`, and no `RUST_TEST_THREADS`; and it keeps the user's
# `HOME`, as `cargo test` does.
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
          cfg = testRunsLib.testConfig packages spec.package;
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
            ${testRunsLib.configScript cfg spec.binary}
            mkdir -p /tmp/breakbulk-target-tmp
            files=(${spec.unitOut}/*)
            cd ${lib.escapeShellArg dir}
            exec ${pkgs.coreutils}/bin/env "''${__bb_env[@]}" ${lib.escapeShellArgs t.runner} "''${files[0]}" "$@"
          '';
        in
        {
          type = "app";
          program = "${script}/bin/${name}-${spec.name}";
        };
    in
    lib.mapAttrs (_: lib.mapAttrs (_: app)) t.specs;
}
