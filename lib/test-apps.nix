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
# Everything it takes from the plan is read at run time from the test
# root's wrapper (`breakbulk-root.json`): the app script depends on the
# wrapper, so in dynamic-derivation mode it is resolved at build time, and
# `nix run` substitutes the script's real path for its placeholder (Nix's
# `resolveString`, src/nix/app.cc). A test binary Cargo did not build gets
# an app that fails with the reason.
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
let
  storeName = s: lib.replaceStrings [ "/" ] [ "-" ] s;
in
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
      jq = "${pkgs.jq}/bin/jq";
      app =
        r:
        let
          b = r.breakbulkRoot;
          p = t.platforms.${b.platform};
          n = storeName "${b.package}-${testRunsLib.binaryKey b}";
          cfg = testRunsLib.runConfig packages b.package "test" (testRunsLib.binaryKey b);
          wrapper = testRunsLib.wrapperOf pkgs cfg;
          checkoutDir = lib.removeSuffix "/" (toString checkout);
          script = pkgs.writeShellScriptBin "${name}-${n}" ''
            set -euo pipefail
            info=${b.wrapper}/breakbulk-root.json
            reason=$(${jq} -r '.reason // ""' "$info")
            if [ -n "$reason" ]; then
              printf 'breakbulk: %s\n' "$reason" >&2
              exit 1
            fi
            ${testRunsLib.envScript {
              inherit jq;
              inherit (p) dylibPath;
              extra = lib.optional (p.libDir != null) p.libDir;
            }}
            ${
              if checkout == null then
                "dir=$CARGO_MANIFEST_DIR"
              else
                ''
                  if [ "$(${jq} -r '.testSpec.packageDir == null' "$info")" = true ]; then
                    echo "breakbulk: cannot place ${b.package} in the checkout: its CARGO_MANIFEST_DIR is not a source view path" >&2
                    exit 1
                  fi
                  dir=${lib.escapeShellArg checkoutDir}
                  __bb_rel=$(${jq} -r '.testSpec.packageDir' "$info")
                  if [ -n "$__bb_rel" ]; then dir=$dir/$__bb_rel; fi
                  export CARGO_MANIFEST_DIR=$dir CARGO_MANIFEST_PATH=$dir/Cargo.toml
                ''
            }
            ${testRunsLib.configScript pkgs cfg}
            ${lib.optionalString (wrapper != null) (testRunsLib.sourceRootExport jq checkout)}
            files=(${b.wrapper}/root/*)
            ${testRunsLib.appRunScript {
              inherit pkgs;
              dir = ''"$dir"'';
              command = ''${pkgs.coreutils}/bin/env "''${__bb_env[@]}" ${
                testRunsLib.launchWords {
                  inherit pkgs wrapper;
                  inherit (p) runner;
                }
              } "''${files[0]}" "$@"'';
            }}
          '';
        in
        script;
    in
    lib.mapAttrs (_: lib.mapAttrs (_: app)) t.roots;
}
