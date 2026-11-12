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
#   test-control-stable-dylibs   the env binary's dylib-path test passes
#                           with the stable (content-addressed) copies of
#                           the build scripts' library directories
#   test-control-include-ignored   includeIgnored runs the ignored tests
#   test-control-skip-list  changing one binary's skip list changes that
#                           test run's derivation only (drv paths compared)
#   test-control-bin-exe    CARGO_BIN_EXE_ctl in the integration test's
#                           compile env names the test plan's `ctl` bin unit
#                           (not a test harness), and that unit runs
#   test-control-app        the test apps run outside a test run, as `nix
#                           run` runs a derivation: the network binary with
#                           a filter, and the env binary against a checkout
#                           at /build/checkout
#   test-control-repo-apps  repo.apps: every test app of every build
#                           variant (a disabled run's and a `checks =
#                           false` variant's too), named as its test run's
#                           check, in the flake app shape; two of them run
#   runner                  test runs start the binary through the runner;
#                           doctests pass it as --test-runtool(-arg)
#   nextest                 `test.runner = "nextest"` over the nextest
#                           fixture: retries, a per-test slow-timeout that
#                           terminates a hung attempt, a default filter
#                           naming another package, junit, package env from
#                           the synthesized metadata; no config file; an
#                           override on `package(nx) and binary(flaky)`
#                           applies to that binary only, and one on
#                           `rdeps(other)` to `nx` and not to `solo`
#   nextest-repo            the same through the module options, with the
#                           workspace's .config/nextest.toml found by default
#   dylib-rule              testRuns.dylibJq over hand-written
#                           directives.json files: a test process gets the
#                           paths each run classified as inside its own
#                           `out` or an upstream (`DEP_*`) run's `out`, the
#                           rule compiles, runs and doctests use; files
#                           without `inBuildDir` read as `inOutDir`; a value
#                           kept by one run survives another run's
#                           unclassified copy; sorted by path component and
#                           deduplicated, kind prefix stripped
#   test-threads            over the `test-threads` fixture: the `one`
#                           test, which fails unless RUST_TEST_THREADS is
#                           1, passes with it set through `test.env`,
#                           `test.binaries.<bin>.env` and the project's
#                           `[env]`, with libtest and with nextest;
#                           without a setting, RUST_TEST_THREADS and
#                           nextest's thread count are NIX_BUILD_CORES; a
#                           nextest profile's `test-threads` and
#                           NEXTEST_TEST_THREADS win over that default
#   post-run                a run's `$out` is empty by default; the
#                           package's `test.postRun`, the binary's and
#                           `keepLog`'s copy run in that order after a
#                           passing run and see `$log`; the doctest run
#                           gets the package's snippet and `keepLog`
#   home                    over the `test-home` fixture: a test and a
#                           doctest that write under $HOME and the user
#                           cache directory pass with no setting, in a
#                           fresh, empty home in $TMPDIR with
#                           XDG_CACHE_HOME unset; with `test.env.HOME =
#                           "/homeless-shelter"` both fail
#
# `workspaces` exposes the mkWorkspace results for debugging; `repos` the
# mkRepository results that tests/dynamic builds in both modes.
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
  # Modules added to `repos` (tests/dynamic sets `mode`).
  extraModules ? [ ],
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

  # The checks below read the runs' output, so they keep it
  # (`test.keepLog`); `$out` is otherwise empty.
  keepLog = names: lib.genAttrs names (_: { test.keepLog = true; });

  doctestsWs = mk "doctests" {
    packages = keepLog [
      "dd"
      "e2024"
      "helper"
    ];
  };

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
    keepLog = true;
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
        grep -q 'test bin_exe_at_run_time ... ok' $binExe/log
        grep -q 'running 0 tests' $bin/log
        grep -q '`needs_feat` was skipped: not built by Cargo' $stub
        grep -q 'running 0 tests' $doctest/log
        mkdir -p $out
      '';

  # The env binary's dylib-path test with the stable inputs that
  # content-addressed test runs use (testRuns.stableSpec),
  # built input-addressed as stock Nix cannot build CA: the build script's
  # library directory is on the path as a copy, which the test accepts.
  testControlStableDylibs =
    let
      s = ctl.testRuns.ctl.env.passthru.breakbulkTest;
      stable = breakbulk.testRuns.stableSpec {
        inherit pkgs;
        spec = s;
        caAttrs = { };
        name = "test-control";
      };
    in
    assert lib.assertMsg (stable.dylib.stable != null) "test-control-stable-dylibs: no stable copy";
    pkgs.runCommand "test-runs-test-control-stable-dylibs" { } ''
      ${breakbulk.testRuns.envScript {
        spec = stable;
        jq = "${pkgs.jq}/bin/jq";
      }}
      case :$LD_LIBRARY_PATH: in
        *:${stable.dylib.stable}/dylib/*) ;;
        *) echo "no stable copy on $LD_LIBRARY_PATH" >&2; exit 1 ;;
      esac
      files=(${s.unitOut}/*)
      cd ${lib.escapeShellArg s.sourceDir}
      "''${files[0]}" --exact dylib_path_has_only_out_dir_search_paths | tee $TMPDIR/log
      grep -q 'test dylib_path_has_only_out_dir_search_paths ... ok' $TMPDIR/log
      mkdir -p $out
      cp $TMPDIR/log $out/
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
  # The program `nix run` runs for a derivation (src/nix/app.cc: `outPath`,
  # `/bin/`, `meta.mainProgram`); a check cannot call `nix run` itself.
  nixRunProgram =
    drv:
    assert lib.assertMsg (lib.isDerivation drv) "a test app is not a derivation";
    "${drv.outPath}/bin/${drv.meta.mainProgram}";
  testControlApp =
    pkgs.runCommand "test-runs-test-control-app"
      {
        net = nixRunProgram ctl.testApps.ctl.net;
        envApp = nixRunProgram ctlCheckout.testApps.ctl.env;
      }
      ''
        $net --skip needs_network | tee net.log
        grep -q 'test offline_ok ... ok' net.log
        cp -r --no-preserve=mode ${fixtures + "/test-control"} /build/checkout
        export CTL_EXPECT_NIX=1 NIX_BUILD_CORES=$NIX_BUILD_CORES RUST_TEST_THREADS=$NIX_BUILD_CORES
        $envApp --show-output | tee env.log
        grep -q 'CARGO_MANIFEST_DIR=/build/checkout$' env.log
        grep -q 'cwd=/build/checkout$' env.log
        grep -q 'test result: ok. 4 passed' env.log
        mkdir -p $out
        cp net.log env.log $out/
      '';

  # repo.apps over the same fixture through mkRepository: every test app
  # of every build variant, named as its test run's check, a disabled run's
  # and a `checks = false` variant's included; each in the flake app shape,
  # its program the one `nix run` runs for the variant's test app.
  ctlRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/test-control";
    modules = [
      {
        workspaces.main = {
          path = ".";
          variants.default.profile = "dev";
          variants.unchecked = {
            profile = "dev";
            checks = false;
          };
        };
        packages.ctl.test = ctlTest // {
          binaries = ctlTest.binaries // {
            ignored.enable = false;
          };
        };
      }
    ];
  };
  testControlRepoApps =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      apps = ctlRepo.apps;
      tests = [
        "bin-ctl"
        "bin_exe"
        "env"
        "ignored"
        "lib"
        "net"
      ];
      want = lib.concatMap (p: map (t: "main/${native}/${p}ctl/test-${t}") tests) [
        ""
        "variant-unchecked/"
      ];
      checkNames = lib.filter (n: lib.hasInfix "/test-" n) (lib.attrNames ctlRepo.checks);
      discard = builtins.unsafeDiscardStringContext;
      net = apps."main/${native}/ctl/test-net";
      variantNet = ctlRepo.workspaces.main.target.${native}.variants.default.testApps.ctl.net;
    in
    assert lib.assertMsg (lib.attrNames apps == lib.sort lib.lessThan want)
      "test-control-repo-apps: apps ${toString (lib.attrNames apps)}";
    # IFD mode has no app for a binary Cargo did not build (needs_feat).
    assert lib.assertMsg (
      checkNames == [
        "main/${native}/ctl/test-bin-ctl"
        "main/${native}/ctl/test-bin_exe"
        "main/${native}/ctl/test-env"
        "main/${native}/ctl/test-lib"
        "main/${native}/ctl/test-needs_feat"
        "main/${native}/ctl/test-net"
      ]
    ) "test-control-repo-apps: test-run checks ${toString checkNames}";
    assert lib.assertMsg (lib.all (
      a: a.type == "app" && lib.isString a.program && lib.isString a.meta.description
    ) (lib.attrValues apps)) "test-control-repo-apps: an app is not in the flake app shape";
    assert lib.assertMsg (discard net.program == discard (nixRunProgram variantNet))
      "test-control-repo-apps: ${net.program} is not the variant's test app";
    pkgs.runCommand "test-runs-test-control-repo-apps"
      {
        net = net.program;
        ignored = apps."main/${native}/variant-unchecked/ctl/test-ignored".program;
      }
      ''
        $net --skip needs_network | tee net.log
        grep -q 'test offline_ok ... ok' net.log
        $ignored | tee ignored.log
        grep -q 'test slow ... ignored, slow' ignored.log
        mkdir -p $out
        cp net.log ignored.log $out/
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

  # nextest's store (the `ci` profile's junit) reaches `$out` through
  # `test.postRun`.
  keepJunit = {
    keepLog = true;
    postRun = ''cp -r "$nextestDir" "$out/nextest"'';
  };
  nxWs = mk "nextest" {
    packages.nx.test = keepJunit // {
      runner = "nextest";
      nextest.profile = "ci";
      nextest.configFile = fixtures + "/nextest/.config/nextest.toml";
      env.NX_FROM_TEST_ENV = "yes";
      env.NX_EXPECT_NIX = "1";
    };
    packages.other.test = {
      keepLog = true;
      runner = "nextest";
    };
    packages.solo.test = keepJunit // {
      runner = "nextest";
      nextest.profile = "ci";
      nextest.configFile = fixtures + "/nextest/.config/nextest.toml";
    };
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
        solo = r.solo."lib/solo";
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
        # junit from the profile's config, put in the output by postRun.
        grep -q 'testsuite name="nx::flaky"' $flaky/nextest/ci/junit.xml
        grep -E 'PASS .*nx unit_ok|PASS .*nx tests::unit_ok' $nxLib/log
        # No configuration file: nextest's defaults.
        grep -E 'PASS .*other tests::adds' $other/log
        # `package(nx) and binary(flaky)`: success output shown for the
        # flaky binary's tests, not for the library's.
        grep -q nx-runtime-env-success-output $flaky/log
        ! grep -q nx-unit-success-output $nxLib/log
        # `rdeps(other)`: success output kept in junit for nx, which
        # depends on other, and not for solo.
        grep -q nx-unit-success-output $nxLib/nextest/ci/junit.xml
        grep -E 'PASS .*solo tests::solo_ok' $solo/log
        grep -q 'testsuite name="solo"' $solo/nextest/ci/junit.xml
        ! grep -q solo-success-output $solo/nextest/ci/junit.xml
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
        workspaces.main = {
          variants.default.profile = "dev";
          memberDefaults.test.keepLog = true;
        };
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

  # Two runs' directives.json, as breakbulk-unit writes them.
  dylibRule =
    let
      a = pkgs.writeText "a-directives.json" (
        builtins.toJSON {
          libraryPaths = [
            {
              value = "native=/s/a-out/lib";
              inOutDir = true;
              inBuildDir = true;
            }
            # Inside b's `out`, which a received through `DEP_B_ROOT`.
            {
              value = "/s/b-out/shared";
              inOutDir = false;
              inBuildDir = true;
            }
            # Outside every `out`: inBuildDir is not written when false.
            {
              value = "native=/usr/lib";
              inOutDir = false;
            }
            # Inside b's `out` without a DEP_* route: not kept.
            {
              value = "/s/b-out/other";
              inOutDir = false;
            }
          ];
        }
      );
      # Written before inBuildDir existed.
      b = pkgs.writeText "b-directives.json" (
        builtins.toJSON {
          libraryPaths = [
            {
              value = "/s/b-out/shared";
              inOutDir = true;
            }
            {
              value = "all=/s/b-out/a";
              inOutDir = true;
            }
          ];
        }
      );
    in
    pkgs.runCommand "test-runs-dylib-rule" { nativeBuildInputs = [ pkgs.jq ]; } ''
      got=$(jq -rn ${lib.escapeShellArg breakbulk.testRuns.dylibJq} ${a} ${b})
      # Sorted as PathBuf: the root before `all=`, before `native=`.
      want=/s/b-out/shared:/s/b-out/a:/s/a-out/lib
      if [ "$got" != "$want" ]; then
        echo "dylib-rule: got $got, want $want" >&2
        exit 1
      fi
      mkdir -p $out
    '';

  # The same settings as the workspace's default, with one
  # package overriding it back to libtest.
  nxWsRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/nextest";
    modules = [
      {
        workspaces.main = {
          variants.default.profile = "dev";
          memberDefaults.test = {
            runner = "nextest";
            nextest.profile = "ci";
            keepLog = true;
          };
        };
        packages.other.test.runner = "libtest";
      }
    ];
  };
  nextestWorkspaceDefault =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      r = nxWsRepo.workspaces.main.target.${native}.testRuns;
    in
    pkgs.runCommand "test-runs-nextest-workspace-default"
      {
        flaky = r.nx.flaky;
        other = r.other."lib/other";
      }
      ''
        grep -q 'nextest profile: ci' $flaky/log
        grep -E 'TRY 2 PASS .*nx::flaky flaky_once' $flaky/log
        grep -q 'test result: ok. 1 passed' $other/log
        ! grep -q 'Nextest run ID' $other/log
        mkdir -p $out
      '';

  # --- test threads --------------------------------------------------------

  # One workspace per way of setting the thread count. Every test run of
  # every workspace must pass: `one` asserts 1 everywhere, the others
  # assert only where their marker is set.
  testThreadsRepo =
    let
      ws = path: test: {
        inherit path;
        variants.default.profile = "dev";
        memberDefaults.test = test // {
          keepLog = true;
        };
      };
      nx = test: test // { runner = "nextest"; };
      oneThread.RUST_TEST_THREADS = "1";
      binary = {
        binaries.one.env = oneThread;
        binaries.cores.env.TT_EXPECT_DEFAULT = "1";
      };
    in
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/test-threads";
      modules = [
        {
          workspaces = {
            env = ws "plain" { env = oneThread; };
            binary = ws "plain" binary;
            config = ws "env-config" { };
            nextest-env = ws "plain" (nx { env = oneThread; });
            nextest-binary = ws "plain" (
              nx (
                lib.recursiveUpdate binary {
                  binaries.nextest_one.env = {
                    NEXTEST_TEST_THREADS = "1";
                    TT_EXPECT_NEXTEST_ONE = "1";
                  };
                }
              )
            );
            nextest-config = ws "env-config" (nx { });
            nextest-profile = ws "plain" (nx {
              env = oneThread;
              binaries.nextest_one.env.TT_EXPECT_NEXTEST_ONE = "1";
              nextest.configFile = pkgs.writeText "nextest.toml" ''
                [profile.default]
                test-threads = 1
              '';
            });
          };
        }
      ]
      ++ extraModules;
    };
  testThreads =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      runs = lib.concatMapAttrs (
        w: v:
        lib.mapAttrs' (
          n: d: lib.nameValuePair (lib.replaceStrings [ "-" ] [ "_" ] "${w}_${n}") d
        ) (removeAttrs v.target.${native}.testRuns.tt [ "lib/tt" ])
      ) testThreadsRepo.workspaces;
    in
    assert lib.assertMsg (
      lib.attrNames runs == [
        "binary_cores"
        "binary_nextest_one"
        "binary_one"
        "config_one"
        "env_cores"
        "env_nextest_one"
        "env_one"
        "nextest_binary_cores"
        "nextest_binary_nextest_one"
        "nextest_binary_one"
        "nextest_config_one"
        "nextest_env_cores"
        "nextest_env_nextest_one"
        "nextest_env_one"
        "nextest_profile_cores"
        "nextest_profile_nextest_one"
        "nextest_profile_one"
      ]
    ) "test-threads: unexpected test runs ${toString (lib.attrNames runs)}";
    pkgs.runCommand "test-runs-test-threads" runs ''
      for r in $env_one $binary_one $config_one; do
        grep -q 'test one_thread ... ok' $r/log
      done
      grep -q 'test default_threads ... ok' $binary_cores/log
      for r in $nextest_env_one $nextest_binary_one $nextest_config_one $nextest_profile_one; do
        grep -E 'PASS .*tt::one one_thread' $r/log
      done
      grep -E 'PASS .*tt::cores default_threads' $nextest_binary_cores/log
      grep -E 'PASS .*tt::nextest_one nextest_one_thread' $nextest_binary_nextest_one/log
      grep -E 'PASS .*tt::nextest_one nextest_one_thread' $nextest_profile_nextest_one/log
      mkdir -p $out
    '';

  # --- post-run --------------------------------------------------------------

  postRunRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/test-control";
    modules = [
      {
        workspaces.main.variants.default.profile = "dev";
        packages.ctl.test = lib.recursiveUpdate ctlTest {
          keepLog = false;
          postRun = ''
            grep -q '^test result: ok' "$log"
            echo package >> "$out/order"
          '';
          binaries.env.postRun = ''
            echo binary >> "$out/order"
          '';
        };
      }
      # A second matching key: a later layer.
      { packages."ctl@0.1.0".test.keepLog = true; }
    ];
  };
  postRun =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      t = postRunRepo.workspaces.main.target.${native};
    in
    pkgs.runCommand "test-runs-post-run"
      {
        plain = (mk "test-control" { packages.ctl.test = removeAttrs ctlTest [ "keepLog" ]; }).testRuns.ctl.env;
        envRun = t.testRuns.ctl.env;
        net = t.testRuns.ctl.net;
        doctest = t.doctests.ctl;
      }
      ''
        # Without postRun or keepLog, the output is an empty directory.
        [ -z "$(ls -A $plain)" ]
        # Package, then binary, then keepLog's copy (a later layer's keepLog
        # wins over the earlier false).
        [ "$(cat $envRun/order)" = "$(printf 'package\nbinary')" ]
        grep -q 'test result: ok' $envRun/log
        [ "$(cat $net/order)" = package ]
        [ "$(cat $doctest/order)" = package ]
        grep -q 'test result: ok' $doctest/log
        mkdir -p $out
      '';

  # --- home ------------------------------------------------------------------

  # TH_EXPECT_NIX makes the fixture check that its home is fresh, empty and
  # in $TMPDIR; HOME itself is not set.
  homeRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/test-home";
    modules = [
      {
        workspaces.main.variants.default.profile = "dev";
        packages.th.test = {
          keepLog = true;
          env.TH_EXPECT_NIX = "1";
        };
      }
    ]
    ++ extraModules;
  };
  # The doctest derivation has no `overrideAttrs` for testBuildFailure, so
  # the strict doctest is run by hand, as in `runner`, with the
  # derivation's own test env.
  home =
    let
      native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      t = homeRepo.workspaces.main.target.${native};
      strict = mk "test-home" { packages.th.test.env.HOME = "/homeless-shelter"; };
    in
    pkgs.runCommand "test-runs-home"
      {
        run = t.testRuns.th.home;
        doctest = t.doctests.th;
        strictRun = pkgs.testers.testBuildFailure strict.testRuns.th.home;
        unit = strict.doctests.th.drvAttrs.BREAKBULK_UNIT;
        testEnv = strict.doctests.th.drvAttrs.BREAKBULK_TEST_ENV;
      }
      ''
        grep -q 'test writes_home_and_cache ... ok' $run/log
        grep -Eq 'write_home_and_cache \(line [0-9]+\) \.\.\. ok' $doctest/log
        cat $strictRun/testBuildFailure.log
        grep -q 'cannot create /homeless-shelter/.config/th' $strictRun/testBuildFailure.log
        result=$out
        if BREAKBULK_UNIT="$unit" BREAKBULK_TEST_ENV="$testEnv" out=$TMPDIR/o \
            ${tools.breakbulk-unit}/bin/breakbulk-unit doctest 2> err; then
          cat err
          echo "the doctest succeeded with HOME=/homeless-shelter" >&2
          exit 1
        fi
        cat err
        grep -Eq 'write_home_and_cache \(line [0-9]+\) \.\.\. FAILED' err
        grep -q 'cannot create /homeless-shelter/.config/th' err
        mkdir -p $result
      '';
in
{
  workspaces = {
    inherit doctestsWs ctl nxWs;
  };
  repos = {
    test-threads = testThreadsRepo;
    home = homeRepo;
  };
  post-run = postRun;
  inherit home;
  test-threads = testThreads;
  dylib-rule = dylibRule;
  inherit nextest;
  nextest-repo = nextestRepo;
  nextest-workspace-default = nextestWorkspaceDefault;
  runner = testRunner;
  inherit doctests;
  test-control = testControl;
  test-control-stable-dylibs = testControlStableDylibs;
  test-control-include-ignored = testControlIncludeIgnored;
  test-control-skip-list = testControlSkipList;
  test-control-bin-exe = testControlBinExe;
  test-control-app = testControlApp;
  test-control-repo-apps = testControlRepoApps;
}
