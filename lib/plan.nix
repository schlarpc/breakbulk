# The plan derivation: skeleton + vendor directory + toolchain -> plan.json
# ("Trace planner" in docs/implementation.md).
#
#   plan = breakbulk.mkPlan pkgs {
#     skeleton;              # breakbulk.mkSkeleton output (repository-root shaped)
#     wsDir = "";            # the workspace, relative to the repository root
#     vendor;                # breakbulk.mkVendor output
#     cargo; rustc;          # the toolchain (rustc provides bin/rustc and bin/rustdoc)
#     tools;                 # breakbulk.mkTools pkgs
#     kind = "build";        # or "test", or "bench" (`cargo bench --no-run`)
#     mode = "build";        # or "check", "clippy", "coverage" (the variant's)
#     clippyDriver = null;   # clippy-driver (a path) for mode = "clippy"
#     clippyArgs = [ ];      # clippy's arguments (`cargo clippy -- ARGS`)
#     target = "x86_64-unknown-linux-gnu";
#     profile = "dev";
#     features = [ ]; allFeatures = false; noDefaultFeatures = false;
#     packages = [ ];        # -p selection; [ ] means --workspace
#     configs = [ ];         # extra --config files or values (toolchain spec)
#   };
#   "${plan}/plan.json"
#
# The derivation runs sandboxed like any other. The skeleton is copied to
# $NIX_BUILD_TOP/skeleton, which is /build/skeleton with the default
# sandbox-build-dir: the canonical location ("Fixed skeleton location").
# breakbulk-plan fails when the skeleton is elsewhere and a path crate lies
# outside the workspace root, because Cargo would then hash its absolute
# path into `-C metadata`.
{ lib }:
{
  mkPlan =
    pkgs:
    {
      skeleton,
      wsDir ? "",
      vendor,
      cargo,
      rustc,
      tools,
      kind ? "build",
      target,
      profile ? "dev",
      features ? [ ],
      allFeatures ? false,
      noDefaultFeatures ? false,
      packages ? [ ],
      configs ? [ ],
      # The toolchain spec for the planner (crates/breakbulk-plan/src/spec.rs):
      # { rustflags; linker; hostLinker; }, or null. Passed without string
      # context: planning never runs the tools it names.
      spec ? null,
      name ? "breakbulk-plan",
      mode ? "build",
      clippyDriver ? null,
      clippyArgs ? [ ],
    }:
    let
      args = [
        "--cargo"
        "${cargo}/bin/cargo"
        "--rustc"
        "${rustc}/bin/rustc"
        "--rustdoc"
        "${rustc}/bin/rustdoc"
        "--shim"
        "${tools.breakbulk-shim}/bin/breakbulk-shim"
        "--workspace"
        wsDir
        "--canonical-root"
        "/build/skeleton"
        "--kind"
        kind
        "--target"
        target
        "--profile"
        profile
        "--config"
        "${vendor.configFile}"
        "--forbid"
        "${vendor.dir}"
      ]
      ++ lib.optionals (mode != "build") [
        "--mode"
        mode
      ]
      ++ lib.optionals (clippyDriver != null) [
        "--clippy-driver"
        "${clippyDriver}"
      ]
      ++ lib.concatMap (a: [
        "--clippy-arg"
        a
      ]) clippyArgs
      ++ lib.concatMap (f: [
        "--features"
        f
      ]) features
      ++ lib.optional allFeatures "--all-features"
      ++ lib.optional noDefaultFeatures "--no-default-features"
      ++ lib.concatMap (p: [
        "-p"
        p
      ]) packages
      ++ lib.concatMap (c: [
        "--config"
        "${c}"
      ]) configs
      ++ lib.optionals (spec != null) [
        "--spec"
        (builtins.toFile "breakbulk-spec.json" (builtins.unsafeDiscardStringContext (builtins.toJSON spec)))
      ];
    in
    pkgs.runCommand "${name}-${kind}"
      {
        passthru = {
          inherit
            kind
            target
            profile
            mode
            ;
        };
      }
      ''
        cp -r --no-preserve=mode ${skeleton} "$NIX_BUILD_TOP/skeleton"
        mkdir -p $out
        ${tools.breakbulk-plan}/bin/breakbulk-plan ${lib.escapeShellArgs args} \
          --skeleton "$NIX_BUILD_TOP/skeleton" \
          --scratch "$NIX_BUILD_TOP/scratch" \
          --forbid "$NIX_BUILD_TOP" \
          --forbid "$HOME" \
          --out $out/plan.json
      '';
}
