# The plan derivation: skeleton + vendor directory + toolchain -> plan.json
# (docs/src/explanation/internals/planner.md).
#
#   plan = breakbulk.mkPlan pkgs {
#     skeleton;              # breakbulk.mkSkeleton output (repository-root shaped)
#     wsDir = "";            # the workspace, relative to the repository root
#     vendor;                # breakbulk.mkVendor output
#     cargo; rustc;          # the toolchain (rustc provides bin/rustc and bin/rustdoc)
#     tools;                 # breakbulk.mkTools pkgs
#     kind = "build";        # or "test", "bench" (`cargo bench --no-run`), "doc"
#     noDeps = false;        # kind = "doc": `cargo doc --no-deps`
#     mode = "build";        # or "check", "clippy", "coverage" (the variant's)
#     clippyDriver = null;   # clippy-driver (a path) for mode = "clippy"
#     clippyOption = null;   # the option that set it, named when it does not match rustc
#     clippyArgs = [ ];      # clippy's arguments (`cargo clippy -- ARGS`)
#     target = "x86_64-unknown-linux-gnu";
#     profile = "dev";
#     features = [ ]; allFeatures = false; noDefaultFeatures = false;
#     packages = [ ];        # -p selection; [ ] means --workspace
#     configs = [ ];         # extra --config files or values (toolchain spec)
#     cargoConfig = null;    # the variant's Cargo config file (TOML), or null
#     capabilities = null;   # the toolchain's capabilities (null: toolchainFacts')
#     trimPaths = "auto";    # Cargo's trim-paths: "auto", "on" or "off"
#   };
#   "${plan}/plan.json"
#
# The derivation runs sandboxed like any other. The skeleton is copied to
# $NIX_BUILD_TOP/skeleton, which is /build/skeleton with the default
# sandbox-build-dir: the canonical location ("Fixed skeleton location").
# breakbulk-plan fails when the skeleton is elsewhere and a path crate lies
# outside the workspace root, because Cargo would then hash its absolute
# path into `-C metadata`.
{
  lib,
  toolchainFacts,
}:
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
      noDeps ? false,
      target,
      profile ? "dev",
      features ? [ ],
      allFeatures ? false,
      noDefaultFeatures ? false,
      packages ? [ ],
      configs ? [ ],
      # The variant's own Cargo configuration (`cargoConfig`), a TOML file:
      # Cargo gets it with `--config`, and the planner's reader of the
      # project's config takes it as the highest layer.
      cargoConfig ? null,
      # The toolchain spec for the planner (crates/breakbulk-plan/src/spec.rs):
      # { rustflags; linker; hostLinker; }, or null. Passed without string
      # context: planning never runs the tools it names.
      spec ? null,
      name ? "breakbulk-plan",
      mode ? "build",
      clippyDriver ? null,
      clippyOption ? null,
      clippyArgs ? [ ],
      # The toolchain's capabilities (lib/toolchain-facts.nix), or null for
      # toolchainFacts' own for this rustc and cargo.
      capabilities ? null,
      # Cargo's trim-paths: "auto" (on when the toolchain
      # has it, unless the project declares it), "on" or "off".
      trimPaths ? "auto",
    }:
    let
      caps =
        if capabilities != null then
          capabilities
        else
          (toolchainFacts.of { inherit pkgs rustc cargo; }).capabilities;
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
        "--capabilities"
        (toolchainFacts.capabilitiesFile caps)
      ]
      ++ lib.optional (kind == "doc" && noDeps) "--no-deps"
      ++ lib.optionals (mode != "build") [
        "--mode"
        mode
      ]
      ++ lib.optionals (trimPaths != "auto") [
        "--trim-paths"
        trimPaths
      ]
      ++ lib.optionals (clippyDriver != null) [
        "--clippy-driver"
        "${clippyDriver}"
      ]
      ++ lib.optionals (clippyDriver != null && clippyOption != null) [
        "--clippy-option"
        clippyOption
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
      ++ lib.optionals (cargoConfig != null) [
        "--cargo-config"
        "${cargoConfig}"
      ]
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

  # The dev shell's `cargo-env.json`: the native toolchain spec as Cargo
  # environment configuration, as the planner passes it with `--config`
  # (crates/breakbulk-plan/src/spec.rs `CargoEnv`), and
  # CARGO_PROFILE_<P>_TRIM_PATHS=all for each of `profiles` (the build and
  # the test plan's) when the planner would turn Cargo's
  # trim-paths on (the same rule, from the workspace root's
  # Cargo.toml and the config files, read as TOML; a file that does not
  # parse is a warning; the toolchain's `trimPaths` capability). Computed
  # apart from the plan, from those files and `rustc --print cfg` only, so
  # the dev shell still opens while a manifest is broken and planning fails.
  #
  #   breakbulk.mkCargoEnv pkgs { configSkeleton; wsDir; rustc; tools; target; spec; capabilities; profiles; trimPaths; }
  #   "''${drv}/cargo-env.json"
  mkCargoEnv =
    pkgs:
    {
      # lib/skeleton.nix mkConfigSkeleton: the config files only.
      configSkeleton,
      wsDir ? "",
      rustc,
      tools,
      target,
      spec ? null,
      name ? "breakbulk-cargo-env",
      # With the toolchain's capabilities (lib/toolchain-facts.nix): the
      # trim-paths variable for each of `profiles` (mkPlan's `trimPaths`).
      # Without: none.
      capabilities ? null,
      profiles ? [ "dev" ],
      trimPaths ? "auto",
    }:
    let
      args = [
        "--cargo-env-only"
        "--rustc"
        "${rustc}/bin/rustc"
        "--workspace"
        wsDir
        "--target"
        target
      ]
      ++ lib.optionals (capabilities != null) [
        "--capabilities"
        (toolchainFacts.capabilitiesFile capabilities)
        "--trim-paths"
        trimPaths
      ]
      ++ lib.optionals (capabilities != null) (
        lib.concatMap (p: [
          "--profile"
          p
        ]) profiles
      )
      ++ lib.optionals (spec != null) [
        "--spec"
        (builtins.toFile "breakbulk-spec.json" (builtins.unsafeDiscardStringContext (builtins.toJSON spec)))
      ];
    in
    pkgs.runCommand name { } ''
      cp -r --no-preserve=mode ${configSkeleton} "$NIX_BUILD_TOP/skeleton"
      mkdir -p $out
      ${tools.breakbulk-plan}/bin/breakbulk-plan ${lib.escapeShellArgs args} \
        --skeleton "$NIX_BUILD_TOP/skeleton" \
        --scratch "$NIX_BUILD_TOP/scratch" \
        --cargo-env $out/cargo-env.json
    '';

  # The project's `build.target` (breakbulk-plan --build-target-only), from
  # the same config files as mkCargoEnv; read by import-from-derivation to
  # choose a workspace's default target (`workspaces.<ws>.defaultTarget`).
  #   breakbulk.mkBuildTarget pkgs { configSkeleton; wsDir; tools; }
  #   "''${drv}/build-target.json"   { "buildTarget": [ … ] | null }
  mkBuildTarget =
    pkgs:
    {
      configSkeleton,
      wsDir ? "",
      tools,
      name ? "breakbulk-build-target",
    }:
    pkgs.runCommand name { } ''
      cp -r --no-preserve=mode ${configSkeleton} "$NIX_BUILD_TOP/skeleton"
      mkdir -p $out
      ${tools.breakbulk-plan}/bin/breakbulk-plan --build-target-only \
        --skeleton "$NIX_BUILD_TOP/skeleton" --workspace ${lib.escapeShellArg wsDir} \
        --out $out/build-target.json
    '';
}
