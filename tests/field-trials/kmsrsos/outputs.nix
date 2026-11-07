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
  policy-features = pkgs.linkFarm "kmsrsos-policy-features" (
    lib.concatMapAttrs (pkg: rs: lib.mapAttrs' (n: d: lib.nameValuePair "${pkg}-${n}" d) rs.enabled) (
      lib.filterAttrs (p: _: p == "kmsrs-policy" || p == "kmsrs-server") policy.namedTestRuns
    )
  );
}
