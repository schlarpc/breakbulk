# Test runs, doctests and test apps (lib/test-runs.nix, lib/test-apps.nix)
# over the `doctests` and `test-control` fixtures, through mkWorkspace (IFD
# mode, native target). Wired into the flake's checks as `test-runs-*`.
#
#   nix build -f tests/test-runs doctests
#
#   doctests                every doctest derivation passes, and the set of
#                           `test … ok|ignored` lines equals plain
#                           `cargo test --doc`'s (dev-dependency,
#                           should_panic, compile_fail, no_run, ignore,
#                           rustc-env and rustc-cfg from a build script, an
#                           edition-2024 crate with merged doctests)
#   test-control            every enabled test run passes; the skip list
#                           kept the network test out; #[ignore] tests are
#                           reported ignored; the required-features test is
#                           a skipped stub; runtime env, cwd, rustc-env,
#                           dynamic-library path, CARGO_TARGET_TMPDIR,
#                           test.env, test.path, RUST_TEST_THREADS
#   test-control-include-ignored   includeIgnored runs the ignored tests
#   test-control-skip-list  changing one binary's skip list changes that
#                           test run's derivation only (drv paths compared)
#   test-control-bin-exe    CARGO_BIN_EXE_ctl in the integration test's
#                           compile env names the test plan's `ctl` bin unit
#                           (not a test harness), and that unit runs
#   test-control-app        the test apps run outside a test run: the
#                           network binary with a filter, and the env
#                           binary against a checkout at /build/checkout
#   runner                  test runs start the binary through the runner;
#                           doctests pass it as --test-runtool(-arg)
#   nextest                 `test.runner = "nextest"` over the nextest
#                           fixture: retries, a per-test slow-timeout that
#                           terminates a hung attempt, a default filter
#                           naming another package, junit, package env from
#                           the synthesized metadata; no config file
#   nextest-repo            the same through the module options, with the
#                           workspace's .config/nextest.toml found by default
#
# `workspaces` exposes the mkWorkspace results for debugging.
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
  fixtures = ../fixtures;
  tools = breakbulk.mkTools pkgs;

  mk =
    fixture: args:
    breakbulk.mkWorkspace pkgs (
      {
        root = fixtures + "/${fixture}";
        inherit tools;
        name = fixture;
      }
      // args
    );

  readPlan =
    ws: kind:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (builtins.readFile "${ws.plans.${kind}}/plan.json")
    );

  # --- doctests -------------------------------------------------------------

  doctestsWs = mk "doctests" { };

  # Plain `cargo test --doc` over the same sources.
  cargoDoctests =
    pkgs.runCommandCC "doctests-cargo-test-doc"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${fixtures + "/doctests"} ws
        cd ws
        cargo test --doc --offline --frozen --workspace 2>&1 | tee $TMPDIR/log
        mkdir -p $out
        cp $TMPDIR/log $out/log
      '';

  doctests =
    let
      d = doctestsWs.doctests;
    in
    assert lib.assertMsg (
      lib.attrNames d == [
        "dd"
        "e2024"
        "helper"
      ]
    ) "doctests: expected one doctest derivation per library, got ${toString (lib.attrNames d)}";
    pkgs.runCommand "test-runs-doctests"
      {
        logs = map (p: "${d.${p}}/log") (lib.attrNames d);
        ref = cargoDoctests;
      }
      ''
        lines() { grep -hE '^test .* \.\.\. ' "$@" | sort; }
        lines $logs > got
        lines $ref/log > want
        echo "breakbulk:"; cat got
        diff -u want got
        grep -q 'dd/src/lib.rs - (line 3) ... ok' got            # dev-dependency
        grep -q 'checked_half (line 36) ... ok' got               # should_panic
        grep -q 'double (line 19) - compile fail ... ok' got
        grep -q 'double (line 14) ... ok' got                     # rustc-env
        grep -q 'cfg_on (line 46) ... ok' got                     # rustc-cfg
        grep -q 'e2024/src/lib.rs - inc (line 18) - should panic ... ok' got
        [ "$(grep -c '^test e2024' got)" = 4 ]
        mkdir -p $out
        cp got $out/
      '';

  # --- test-control -----------------------------------------------------------

  ctlTest = {
    env.CTL_EXPECT_NIX = "1";
    path = [ pkgs.hello ];
    binaries.net.args = [
      "--skip"
      "needs_network"
    ];
  };
  ctl = mk "test-control" { packages.ctl.test = ctlTest; };

  testControl =
    let
      r = ctl.testRuns.ctl;
      stub = r.needs_feat;
    in
    assert lib.assertMsg (
      lib.attrNames r == [
        "bin/ctl"
        "bin_exe"
        "env"
        "ignored"
        "lib/ctl"
        "needs_feat"
        "net"
      ]
    ) "test-control: unexpected test binaries ${toString (lib.attrNames r)}";
    assert lib.assertMsg (
      stub.breakbulkRoot.unit == null
    ) "test-control: needs_feat should be a skipped stub";
    assert lib.assertMsg (
      lib.attrNames ctl.checks == [
        "doctest/ctl"
        "test/ctl/bin/ctl"
        "test/ctl/bin_exe"
        "test/ctl/env"
        "test/ctl/ignored"
        "test/ctl/lib/ctl"
        "test/ctl/needs_feat"
        "test/ctl/net"
      ]
    ) "test-control: unexpected checks ${toString (lib.attrNames ctl.checks)}";
    pkgs.runCommand "test-runs-test-control"
      {
        lib_ = r."lib/ctl";
        net = r.net;
        envRun = r.env;
        ignored = r.ignored;
        binExe = r.bin_exe;
        bin = r."bin/ctl";
        inherit stub;
        doctest = ctl.doctests.ctl;
      }
      ''
        grep -q 'test tests::answer_is_42 ... ok' $lib_/log
        grep -q 'test tests::ignored_unit ... ignored' $lib_/log
        grep -q 'test offline_ok ... ok' $net/log
        ! grep -q needs_network $net/log
        grep -q 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out' $net/log
        grep -q 'test slow ... ignored, slow' $ignored/log
        for t in runtime_env dylib_path_has_only_out_dir_search_paths target_tmpdir_is_writable test_config; do
          grep -q "test $t ... ok" $envRun/log
        done
        grep -q 'test runs_the_bin ... ok' $binExe/log
        grep -q 'running 0 tests' $bin/log
        grep -q '`needs_feat` was skipped: not built by Cargo' $stub
        grep -q 'running 0 tests' $doctest/log
        mkdir -p $out
      '';

  # includeIgnored adds --include-ignored to every binary of the package.
  ctlIgnored = mk "test-control" {
    packages.ctl.test = ctlTest // {
      includeIgnored = true;
    };
  };
  testControlIncludeIgnored =
    pkgs.runCommand "test-runs-test-control-include-ignored"
      {
        ignored = ctlIgnored.testRuns.ctl.ignored;
        lib_ = ctlIgnored.testRuns.ctl."lib/ctl";
      }
      ''
        grep -q 'test slow ... ok' $ignored/log
        grep -q 'test tests::ignored_unit ... ok' $lib_/log
        mkdir -p $out
      '';

  # A changed skip list for `net` changes that run's derivation only.
  ctlSkip = mk "test-control" {
    packages.ctl.test = ctlTest // {
      binaries.net.args = [
        "--skip"
        "needs_network"
        "--skip"
        "nothing_else"
      ];
    };
  };
  testControlSkipList =
    let
      drvs = ws: lib.mapAttrs (_: d: d.drvPath) ws.checks;
      a = drvs ctl;
      b = drvs ctlSkip;
      changed = lib.attrNames (lib.filterAttrs (n: p: b.${n} != p) a);
      unitsSame =
        lib.mapAttrs (_: d: d.drvPath) ctl.units.test == lib.mapAttrs (_: d: d.drvPath) ctlSkip.units.test;
    in
    assert lib.assertMsg (lib.attrNames a == lib.attrNames b) "skip list: check sets differ";
    assert lib.assertMsg (
      changed == [
        "test/ctl/net"
      ]
    ) "skip list: expected only test/ctl/net to change, changed: ${toString changed}";
    assert lib.assertMsg unitsSame "skip list: unit derivations changed";
    pkgs.runCommand "test-runs-test-control-skip-list" { } ''
      echo "changed: ${toString changed}" > $out
    '';

  # CARGO_BIN_EXE_ctl names the bin unit of the test plan, which is the
  # plain `ctl` bin (no --test), and that unit's file runs.
  testControlBinExe =
    let
      plan = readPlan ctl "test";
      itRoot = lib.findFirst (r: r.kind == "test" && r.target == "bin_exe") null plan.roots;
      it = plan.units.${itRoot.unit};
      ref = it.env.CARGO_BIN_EXE_ctl;
      piece = lib.head ref;
      binUnit = plan.units.${piece.out};
      isPlainBin =
        binUnit.kind == "compile"
        && binUnit.crate.name == "ctl"
        && binUnit.crate.types == [ "bin" ]
        && !(lib.elem "--test" binUnit.args)
        && piece.output == "bin"
        && lib.length ref == 1;
      binDrv = ctl.units.test.${piece.out};
      buildBin = ctl.roots."ctl/bin/ctl";
    in
    assert lib.assertMsg isPlainBin
      "CARGO_BIN_EXE_ctl does not name the plain ctl bin unit: ${builtins.toJSON ref}";
    pkgs.runCommand "test-runs-test-control-bin-exe"
      {
        bin = "${binDrv.out}/${piece.file}";
        sameAsBuildPlan = lib.boolToString (binDrv.drvPath == buildBin.drvPath);
      }
      ''
        [ "$($bin)" = "ctl says hi 42" ]
        echo "the test plan's ctl bin unit is the build plan's: $sameAsBuildPlan" | tee $out
      '';

  # Test apps run outside the sandbox; here they run inside a check to
  # test their setup: the network binary with the skipped test filtered
  # out, and the env binary against a checkout of the fixture.
  ctlCheckout = mk "test-control" {
    packages.ctl.test = ctlTest;
    checkout = "/build/checkout";
  };
  testControlApp =
    pkgs.runCommand "test-runs-test-control-app"
      {
        net = ctl.testApps.ctl.net.program;
        envApp = ctlCheckout.testApps.ctl.env.program;
        type = ctl.testApps.ctl.net.type;
      }
      ''
        [ "$type" = app ]
        $net --skip needs_network | tee net.log
        grep -q 'test offline_ok ... ok' net.log
        cp -r --no-preserve=mode ${fixtures + "/test-control"} /build/checkout
        export CTL_EXPECT_NIX=1 NIX_BUILD_CORES=$NIX_BUILD_CORES RUST_TEST_THREADS=$NIX_BUILD_CORES
        $envApp --nocapture | tee env.log
        grep -q 'CARGO_MANIFEST_DIR=/build/checkout$' env.log
        grep -q 'cwd=/build/checkout$' env.log
        grep -q 'test result: ok. 4 passed' env.log
        mkdir -p $out
        cp net.log env.log $out/
      '';

  # A runner that announces itself, then runs the program. Test runs start
  # the binary through it. rustdoc gets it as --test-runtool and shows a
  # doctest's output only when it fails, so the doctest is run by hand
  # (as build-script-signal in tests/plan does) with a runner that
  # announces itself and fails.
  runner = pkgs.writeShellScript "announcing-runner" ''
    echo "runner: $(basename "$1")" >&2
    exec "$@"
  '';
  failingRunner = pkgs.writeShellScript "failing-runner" ''
    echo "failing runner: $*" >&2
    exit 3
  '';
  ctlRunner = mk "test-control" {
    packages.ctl.test = ctlTest;
    runner = [ runner ];
  };
  testRunner =
    pkgs.runCommand "test-runs-runner"
      {
        quick = ctlRunner.testRuns.ctl.ignored;
        unit = doctestsWs.doctests.helper.drvAttrs.BREAKBULK_UNIT;
        testRunner = builtins.toJSON [
          "${failingRunner}"
          "--flag"
        ];
      }
      ''
        grep -q '^runner: ignored-' $quick/log
        grep -q 'test quick ... ok' $quick/log
        result=$out
        if BREAKBULK_UNIT="$unit" BREAKBULK_TEST_RUNNER="$testRunner" out=$TMPDIR/o \
            ${tools.breakbulk-unit}/bin/breakbulk-unit doctest 2> err; then
          cat err
          echo "the doctest succeeded under a failing runner" >&2
          exit 1
        fi
        cat err
        grep -q -- '--test-runtool ${failingRunner} --test-runtool-arg --flag' err
        grep -q 'failing runner: --flag /' err
        grep -q 'triple (line 3) ... FAILED' err
        grep -q 'error: doctests of `helper` failed' err
        mkdir -p $result
        cp err $result/
      '';
  # --- nextest -------------------------------------------------------------

  nxWs = mk "nextest" {
    packages.nx.test = {
      runner = "nextest";
      nextest.profile = "ci";
      nextest.configFile = fixtures + "/nextest/.config/nextest.toml";
      env.NX_FROM_TEST_ENV = "yes";
      env.NX_EXPECT_NIX = "1";
    };
    packages.other.test.runner = "nextest";
  };

  nextest =
    let
      r = nxWs.testRuns;
    in
    assert lib.assertMsg (
      lib.attrNames r.nx == [
        "flaky"
        "lib/nx"
      ]
    ) "nextest: unexpected test binaries ${toString (lib.attrNames r.nx)}";
    pkgs.runCommand "test-runs-nextest"
      {
        flaky = r.nx.flaky;
        nxLib = r.nx."lib/nx";
        other = r.other."lib/other";
      }
      ''
        cat $flaky/log
        # Retries: the flaky test failed once and passed on the second try.
        grep -E 'TRY 2 PASS .*nx::flaky flaky_once' $flaky/log
        # slow-timeout terminate-after (a per-test override) killed the hung
        # first attempt; the retry passed.
        grep -E 'TRY 1 TMT .*nx::flaky hangs_once' $flaky/log
        grep -E 'TRY 2 PASS .*nx::flaky hangs_once' $flaky/log
        # The profile's default filter (naming the other package) left a
        # test out.
        grep -q '1 test skipped via profile.ci.default-filter' $flaky/log
        ! grep -q 'excluded_always_fails' $flaky/log
        # Package env from the synthesized metadata, test.env, the profile.
        grep -E 'PASS .*nx::flaky runtime_env' $flaky/log
        # junit from the profile's config lands in the output.
        grep -q 'testsuite name="nx::flaky"' $flaky/nextest/ci/junit.xml
        grep -E 'PASS .*nx unit_ok|PASS .*nx tests::unit_ok' $nxLib/log
        # No configuration file: nextest's defaults.
        grep -E 'PASS .*other tests::adds' $other/log
        mkdir -p $out
        cp $flaky/log $out/
      '';

  # The same through the module options: `test.runner` and
  # `test.nextest.profile`, with the configuration file found at the
  # workspace's `.config/nextest.toml`.
  nxRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/nextest";
    modules = [
      {
        workspaces.main.variants.default.profile = "dev";
        packages.nx.test = {
          runner = "nextest";
          nextest.profile = "ci";
        };
      }
    ];
  };
  nextestRepo =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      r = nxRepo.workspaces.main.target.${native}.testRuns;
    in
    pkgs.runCommand "test-runs-nextest-repo"
      {
        flaky = r.nx.flaky;
        other = r.other."lib/other";
      }
      ''
        grep -q 'nextest profile: ci' $flaky/log
        grep -q '1 test skipped via profile.ci.default-filter' $flaky/log
        grep -E 'TRY 2 PASS .*nx::flaky flaky_once' $flaky/log
        # `other` keeps libtest.
        grep -q 'test result: ok. 1 passed' $other/log
        ! grep -q 'Nextest run ID' $other/log
        mkdir -p $out
      '';
in
{
  workspaces = {
    inherit doctestsWs ctl nxWs;
  };
  inherit nextest;
  nextest-repo = nextestRepo;
  runner = testRunner;
  inherit doctests;
  test-control = testControl;
  test-control-include-ignored = testControlIncludeIgnored;
  test-control-skip-list = testControlSkipList;
  test-control-bin-exe = testControlBinExe;
  test-control-app = testControlApp;
}
