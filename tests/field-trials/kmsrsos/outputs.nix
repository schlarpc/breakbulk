# What kmsrsos's flake builds: the workspace, the static server and client,
# the Windows binaries; plus the policy-features test runs (a non-default
# variant, so not in repo.checks).
{
  pkgs,
  lib,
  repo,
}:
let
  ws = repo.workspaces.main;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  musl = ws.target.x86_64-unknown-linux-musl.packages;
  win = t: ws.target.${t}.packages;
  policy = ws.target.${native}.variants.policy;
in
{
  build = pkgs.linkFarm "kmsrsos-build" (
    lib.mapAttrs' (n: v: lib.nameValuePair "native-${n}" v) ws.packages
    // {
      static-server = musl.kmsrs-server;
      static-client = musl.kmsrs-client;
      windows-x86_64-server = (win "x86_64-pc-windows-msvc").kmsrs-server;
      windows-x86_64-client = (win "x86_64-pc-windows-msvc").kmsrs-client;
      windows-aarch64-server = (win "aarch64-pc-windows-msvc").kmsrs-server;
      windows-aarch64-client = (win "aarch64-pc-windows-msvc").kmsrs-client;
    }
  );
  # The flake's checks: build, clippy and the tests natively (nextest, so no
  # doctests), and the policy features.
  ci = pkgs.linkFarm "kmsrsos-ci" (
    lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) (
      lib.filterAttrs (
        n: _:
        lib.hasPrefix "main/${native}/" n
        && !(lib.hasSuffix "/doctest" n)
        && !(lib.hasInfix "variant-policy" n)
      ) repo.checks
    )
  );
  # Beyond the flake: the same tests on the static and Windows targets
  # (x86_64 under wine; aarch64 has no runner here).
  cross-tests = pkgs.linkFarm "kmsrsos-cross-tests" (
    lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) (
      lib.filterAttrs (
        n: _:
        (
          lib.hasPrefix "main/x86_64-unknown-linux-musl/" n || lib.hasPrefix "main/x86_64-pc-windows-msvc/" n
        )
        && lib.hasInfix "/test-" n
      ) repo.checks
    )
  );
  policy-features = pkgs.linkFarm "kmsrsos-policy-features" (
    lib.concatMapAttrs (pkg: rs: lib.mapAttrs' (n: d: lib.nameValuePair "${pkg}-${n}" d) rs.enabled) (
      lib.filterAttrs (p: _: p == "kmsrs-policy" || p == "kmsrs-server") policy.namedTestRuns
    )
  );
}
