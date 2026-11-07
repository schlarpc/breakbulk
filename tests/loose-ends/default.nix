# Loose ends from M1-M4, one check each. Wired into the flake's checks as
# `loose-ends-*`.
#
#   nix build -f tests/loose-ends config-env
#
#   config-env   the project's `[env]` table (.cargo/config.toml) reaches
#                compiles, test runs and doctests as under `cargo test`:
#                a plain value, a `relative` path, a `force`d HOME, and a
#                PATH that Cargo leaves alone without `force`. The fixture's
#                tests assert the values; the same tests pass under plain
#                `cargo test` (the set of `test … ok` lines is compared).
#   test-scope   `packages.a.test.sourceScope = [ "testdata" ]`: a's
#                integration test reads ../testdata from its working
#                directory and passes; widening the scope changes exactly
#                a's test harnesses and doctest (no build-plan unit, no unit
#                or test run of b); the option gives no warning.
{
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
}:
let
  inherit (pkgs) lib;
  fixtures = ./fixtures;
  tools = breakbulk.mkTools pkgs;

  readPlan =
    ws: kind:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (builtins.readFile "${ws.plans.${kind}}/plan.json")
    );

  # `cargo test` over a fixture, outside any home directory (the sandbox).
  cargoTest =
    fixture:
    pkgs.runCommandCC "loose-ends-${fixture}-cargo-test"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} ws
        cd ws
        cargo test --offline --frozen 2>&1 | tee $TMPDIR/log
        mkdir -p $out
        cp $TMPDIR/log $out/log
      '';

  # --- config-env ---------------------------------------------------------

  configEnvWs = breakbulk.mkWorkspace pkgs {
    root = fixtures + "/config-env";
    inherit tools;
    name = "config-env";
  };

  configEnv =
    let
      plan = readPlan configEnvWs "test";
      checks = configEnvWs.checks;
    in
    assert lib.assertMsg (
      plan.configEnv == [
        "BB_PLAIN"
        "BB_REL"
        "HOME"
      ]
    ) "config-env: the plan's configEnv is ${builtins.toJSON (plan.configEnv or null)}";
    assert lib.assertMsg (
      (readPlan configEnvWs "build").configEnv == plan.configEnv
    ) "config-env: the build plan records other [env] variables";
    assert lib.assertMsg (
      lib.attrNames checks == [
        "doctest/config-env"
        "test/config-env/env"
        "test/config-env/lib/config_env"
      ]
    ) "config-env: unexpected checks ${toString (lib.attrNames checks)}";
    pkgs.runCommand "loose-ends-config-env"
      {
        logs = map (c: "${checks.${c}}/log") (lib.attrNames checks);
        ref = cargoTest "config-env";
      }
      ''
        lines() { grep -hE '^test .* \.\.\. ' "$@" | sort; }
        lines $logs > got
        lines $ref/log > want
        echo "breakbulk:"; cat got
        diff -u want got
        [ "$(grep -c ' ok$' got)" = 6 ]
        mkdir -p $out
        cp got $out/
      '';

  # --- test-scope -----------------------------------------------------------

  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  mkRepo =
    modules:
    breakbulk.mkRepository {
      inherit pkgs tools modules;
      root = fixtures + "/test-scope";
    };
  scopeBase = {
    workspaces.main.variants.default.profile = "dev";
  };
  noScope = mkRepo [ scopeBase ];
  withScope = mkRepo [
    scopeBase
    { packages.a.test.sourceScope = [ "testdata" ]; }
  ];
  instOf = repo: repo.workspaces.main.instances.${native}.default;

  # Unit .drv path -> derivation name, for both plan kinds, plus doctests.
  drvNames =
    repo:
    let
      i = instOf repo;
    in
    lib.listToAttrs (
      map (u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (
        lib.attrValues i.units.build ++ lib.attrValues i.units.test ++ lib.attrValues i.doctests
      )
    );
  changed =
    before: after:
    let
      b = drvNames before;
    in
    lib.sort lib.lessThan (
      lib.unique (lib.attrValues (lib.filterAttrs (d: _: !(b ? ${d})) (drvNames after)))
    );

  testScope =
    let
      got = changed noScope withScope;
      want = [
        "a-0.1.0-doctest"
        "a-0.1.0-test"
        "a-0.1.0-test-data"
      ];
      runs = (instOf withScope).testRuns;
      warnings = lib.filter (w: lib.hasInfix "sourceScope" w) withScope.warnings;
    in
    assert lib.assertMsg (got == want)
      "test-scope: widening a's test scope changed ${builtins.toJSON got}, expected ${builtins.toJSON want}";
    assert lib.assertMsg (warnings == [ ]) "test-scope: ${toString warnings}";
    # b's test run is the same derivation with or without a's scope.
    assert lib.assertMsg (
      runs.b."lib/b".drvPath == (instOf noScope).testRuns.b."lib/b".drvPath
    ) "test-scope: b's test run changed";
    pkgs.runCommand "loose-ends-test-scope"
      {
        data = runs.a.data;
        doctest = (instOf withScope).doctests.a;
      }
      ''
        grep -q 'test reads_testdata ... ok' $data/log
        grep -q 'shout (line 3) ... ok' $doctest/log
        mkdir -p $out
        echo ${lib.escapeShellArg (builtins.toJSON got)} > $out/changed
      '';
in
{
  config-env = configEnv;
  test-scope = testScope;
  workspaces = {
    config-env = configEnvWs;
    test-scope = withScope;
  };
}
