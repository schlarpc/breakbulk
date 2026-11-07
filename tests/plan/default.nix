# End-to-end fixture checks for the traced planner (M1), in IFD mode:
# breakbulk.mkWorkspace plans each fixture with the real cargo, instantiates
# the plan, builds the units, and compares the products' behaviour with a
# plain `cargo build` of the same fixture.
#
#   nix build -f tests/plan walking-skeleton
#
# Attributes are derivations (flake checks). `workspaces.<fixture>` exposes
# each mkWorkspace result for debugging.
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
  target = pkgs.stdenv.hostPlatform.rust.rustcTarget;
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

  # Plain cargo over the same sources, offline against the same vendor
  # directory: the reference products. Run outside $HOME (the sandbox).
  cargoBuild =
    {
      fixture,
      ws,
      command ? "build",
      install,
    }:
    pkgs.runCommandCC "${fixture}-cargo-${command}"
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
        cargo ${command} --offline --frozen --target ${target} \
          --config ${ws.vendor.configFile} 2> build.log || { cat build.log; exit 1; }
        mkdir -p $out
        cp build.log $out/
        t=target/${target}/debug
        ${install}
      '';

  # The trace golden test: real `cargo build -v` (or `cargo test --no-run
  # -v`) over the real sources at the plan's skeleton location, compared
  # unit by unit with the traced plan rendered into the same layout.
  golden =
    {
      fixture,
      ws,
      kind ? "build",
      cargoArgs ? [ "--workspace" ],
      toolchain ? { inherit (pkgs) cargo rustc; },
    }:
    pkgs.runCommandCC "${fixture}-golden-${kind}"
      {
        nativeBuildInputs = [
          toolchain.cargo
          toolchain.rustc
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} "$NIX_BUILD_TOP/skeleton"
        cd "$NIX_BUILD_TOP/skeleton"
        common=(--frozen --offline --config ${ws.vendor.configFile})
        cargo metadata --format-version 1 "''${common[@]}" > $TMPDIR/metadata.json
        cargo ${if kind == "build" then "build" else "test --no-run"} -v \
          ${lib.escapeShellArgs cargoArgs} "''${common[@]}" \
          --target ${target} --profile dev \
          --config "build.target-dir=\"$TMPDIR/target\"" 2> build.log || { cat build.log; exit 1; }
        mkdir -p $out
        cp build.log $out/
        ${tools.breakbulk-plan}/bin/breakbulk-plan-golden \
          --plan ${ws.plans.${kind}}/plan.json --log build.log \
          --target-dir $TMPDIR/target --metadata $TMPDIR/metadata.json | tee $out/report
      '';

  walking-skeleton = mk "walking-skeleton" { };
  build-dep-leak-ws = mk "build-dep-leak" { };

  # Older stable releases for the golden test, from rust-overlay when the
  # package set has it (the flake's does). nixpkgs' own cargo is the third.
  goldenToolchains = lib.optionalAttrs (pkgs ? rust-bin) (
    lib.genAttrs [ "1.95.0" "1.97.0" ] (
      v:
      let
        tc = pkgs.rust-bin.stable.${v}.minimal;
      in
      {
        cargo = tc;
        rustc = tc;
      }
    )
  );
  # The golden test of a fixture's build and test plans on each of them.
  goldenOn =
    fixture: args:
    lib.concatMapAttrs (
      v: toolchain:
      let
        ws = mk fixture (args // { inherit toolchain; });
        n = "${fixture}-golden-${lib.replaceStrings [ "." ] [ "_" ] v}";
      in
      {
        ${n} = golden { inherit fixture ws toolchain; };
        "${n}-test" = golden {
          inherit fixture ws toolchain;
          kind = "test";
        };
      }
    ) goldenToolchains;

  # A plan, read at evaluation time (IFD).
  readPlan =
    ws: kind:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (builtins.readFile "${ws.plans.${kind}}/plan.json")
    );

  directivesPackages = [
    "a-sys"
    "b-sys"
    "c"
    "pm"
    "hostdep"
    "app"
    "oldsyn"
  ];
  directives = mk "directives" {
    # Every build script includes ../common/build_common.rs.
    extraSources = lib.genAttrs directivesPackages (_: [ "common" ]);
  };
  walking-skeleton-cargo = cargoBuild {
    fixture = "walking-skeleton";
    ws = walking-skeleton;
    install = "install -D $t/walking-skeleton $out/bin/walking-skeleton";
  };
in
{
  workspaces = {
    inherit walking-skeleton directives;
  };

  # One bin, one registry dependency (itoa) and one build script (cfg, env,
  # a generated file in OUT_DIR), end to end; the product's output equals
  # plain cargo's.
  walking-skeleton =
    pkgs.runCommand "walking-skeleton-check"
      {
        bb = walking-skeleton.packages.walking-skeleton;
        ref = walking-skeleton-cargo;
      }
      ''
        got=$($bb/bin/walking-skeleton)
        want=$($ref/bin/walking-skeleton)
        echo "breakbulk: $got"
        echo "cargo:     $want"
        [ "$got" = "$want" ]
        [ "$got" = "walking-skeleton 42 cfg-on hello-from-build-script debug" ]
        mkdir -p $out
        echo "$got" > $out/output
      '';

  walking-skeleton-golden = golden {
    fixture = "walking-skeleton";
    ws = walking-skeleton;
  };
  walking-skeleton-golden-test = golden {
    fixture = "walking-skeleton";
    ws = walking-skeleton;
    kind = "test";
  };

  # Placement of every directive kind equals Cargo's, for every unit of the
  # build and test plans (the golden comparison expands each splice with
  # the real build scripts' output).
  directives-golden = golden {
    fixture = "directives";
    ws = directives;
  };
  directives-golden-test = golden {
    fixture = "directives";
    ws = directives;
    kind = "test";
  };

  # The products run as plain cargo's do: links chains, DEP_* metadata, a
  # proc macro and a build-dependency with build scripts, `cargo:` syntax.
  directives =
    let
      testPlan = readPlan directives "test";
      # One traced `rustdoc --test` per library (proc macro included), with
      # the search paths of every run as one searchPathsOf splice.
      doctestsOk =
        lib.attrNames testPlan.doctests == map (p: "d-${p}") (lib.sort lib.lessThan directivesLibs)
        && lib.all (
          d: lib.length (lib.filter (a: builtins.isAttrs a && a ? searchPathsOf) d.args) == 1
        ) (lib.attrValues testPlan.doctests);
      directivesLibs = lib.remove "app" directivesPackages;
      ref = cargoBuild {
        fixture = "directives";
        ws = directives;
        install = ''
          install -D $t/app $out/bin/app
          install -D $t/app-tool $out/bin/app-tool
        '';
      };
    in
    assert lib.assertMsg doctestsOk "directives: the test plan's doctests are not one per library";
    pkgs.runCommand "directives-check"
      {
        app = directives.packages.app;
        tool = directives.packages.app-tool;
        it = directives.testBins."c/test/it";
        ex = directives.testBins."c/example/ex";
        inherit ref;
      }
      ''
        for b in app app-tool; do
          d=$app; [ $b = app ] || d=$tool
          got=$($d/bin/$b); want=$($ref/bin/$b)
          echo "$b: breakbulk '$got', cargo '$want'"
          [ "$got" = "$want" ]
        done
        [ "$($app/bin/app)" = "a_sys 42 2" ]
        $it/bin/it | tee it.log
        grep -q 'test result: ok. 1 passed' it.log
        [ "$($ex/bin/ex)" = "a_sys" ]
        mkdir -p $out
      '';

  # Build-dependency link directives stay on the host: every splice of a
  # target unit names a target run; helper's run is host-only; shared runs
  # once per platform. The product runs as cargo's does; golden passes.
  build-dep-leak =
    let
      plan = readPlan build-dep-leak-ws "build";
      inherit (plan) units;
      pkgOf = id: lib.head (lib.splitString "#" (lib.last (lib.splitString "/" units.${id}.package)));
      runsOf = name: lib.filter (id: units.${id}.kind == "run" && pkgOf id == name) (lib.attrNames units);
      spliceRuns =
        u:
        map (a: a.splice) (lib.filter (a: builtins.isAttrs a && a ? splice) u.args)
        ++ map (s: s.splice) u.envSplices
        ++ (u.dylibPathFrom or [ ]);
      compiles = lib.filterAttrs (_: u: u.kind == "compile") units;
      leaks = lib.filterAttrs (
        _: u: u.platform == "target" && lib.any (r: units.${r}.platform != "target") (spliceRuns u)
      ) compiles;
      platforms = ids: lib.sort lib.lessThan (map (id: units.${id}.platform) ids);
      hostRuns = name: lib.filter (id: units.${id}.platform == "host") (runsOf name);
      appBin = units.${(lib.findFirst (r: r.target == "app") null plan.roots).unit};
      checks = {
        "no target unit splices a host run" = leaks == { };
        # Both run once per platform: helper is a workspace member too, so
        # `--workspace` also builds it for the target.
        "helper and shared run once per platform" = lib.all (
          n:
          platforms (runsOf n) == [
            "host"
            "target"
          ]
        ) [ "helper" "shared" ];
        "the host runs reach host units only" = lib.all (u: u.platform == "host") (
          lib.attrValues (
            lib.filterAttrs (
              _: u: lib.any (r: lib.elem r (hostRuns "helper" ++ hostRuns "shared")) (spliceRuns u)
            ) compiles
          )
        );
        "the app links nothing of helper" = !lib.any (r: lib.elem r (runsOf "helper")) (spliceRuns appBin);
        "app's build script finds the host runs' libraries" =
          lib.sort lib.lessThan (units.${lib.head (runsOf "app")}.dylibPathFrom or [ ])
          == lib.sort lib.lessThan (hostRuns "helper" ++ hostRuns "shared");
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
      ref = cargoBuild {
        fixture = "build-dep-leak";
        ws = build-dep-leak-ws;
        install = "install -D $t/app $out/bin/app";
      };
    in
    pkgs.runCommand "build-dep-leak-check"
      {
        app = build-dep-leak-ws.packages.app;
        inherit ref;
        golden = golden {
          fixture = "build-dep-leak";
          ws = build-dep-leak-ws;
        };
        failed = lib.concatStringsSep "\n" failed;
      }
      ''
        if [ -n "$failed" ]; then echo "failed: $failed"; exit 1; fi
        got=$($app/bin/app); want=$($ref/bin/app)
        echo "breakbulk '$got', cargo '$want'"
        [ "$got" = "$want" ] && [ "$got" = "app 42 35" ]
        mkdir -p $out
        cp $golden/report $out/
      '';

  # Every crate type's outputs are present and usable: the cdylib and the
  # staticlib from C, the rlib and the proc macro from the bin.
  crate-types =
    let
      ws = mk "crate-types" { };
      ref = cargoBuild {
        fixture = "crate-types";
        inherit ws;
        install = "install -D $t/app $out/bin/app";
      };
    in
    pkgs.runCommandCC "crate-types-check"
      {
        app = ws.packages.app;
        cdylib = ws.roots."both/cdylib/both";
        staticlib = ws.roots."stat/staticlib/stat";
        golden = golden {
          fixture = "crate-types";
          inherit ws;
        };
        inherit ref;
      }
      ''
        got=$($app/bin/app); want=$($ref/bin/app)
        echo "breakbulk '$got', cargo '$want'"
        [ "$got" = "$want" ] && [ "$got" = "app 42 from-proc-macro" ]
        ls -l $cdylib $staticlib
        cc ${fixtures + "/crate-types/cuser/main.c"} $cdylib/libboth.so $staticlib/libstat*.a \
          -lpthread -ldl -lm -o cuser
        [ "$(LD_LIBRARY_PATH=$cdylib ./cuser)" = "c 42 7" ]
        mkdir -p $out
        cp $golden/report $out/
      '';

  # The build plan's product lacks the dev-dependency's feature; the test
  # plan's binaries (bin harness, integration test, and the bin built for
  # CARGO_BIN_EXE_app) have it.
  dev-dep-features =
    let
      ws = mk "dev-dep-features" { };
      featFlags =
        kind:
        lib.any (
          u:
          u.kind == "compile"
          && u.crate.name == "feat"
          && lib.elem "feature=\"extra\"" (lib.filter builtins.isString u.args)
        ) (lib.attrValues (readPlan ws kind).units);
    in
    assert lib.assertMsg (!featFlags "build") "dev-dep-features: the build plan enables `extra`";
    assert lib.assertMsg (featFlags "test") "dev-dep-features: the test plan lacks `extra`";
    pkgs.runCommand "dev-dep-features-check"
      {
        app = ws.packages.app;
        harness = ws.testBins."app/bin-test/app";
        it = ws.testBins."app/test/it";
        featTest = ws.testBins."feat/lib-test/feat";
        golden = golden {
          fixture = "dev-dep-features";
          inherit ws;
        };
        goldenTest = golden {
          fixture = "dev-dep-features";
          inherit ws;
          kind = "test";
        };
      }
      ''
        [ "$($app/bin/app)" = "extra=false" ]
        $harness/bin/app | tee log
        grep -q 'dev_dependency_feature_is_on_in_tests ... ok' log
        $it/bin/it | tee log
        grep -q 'test result: ok. 2 passed' log
        $featTest/bin/feat
        mkdir -p $out
        cat $golden/report $goldenTest/report > $out/report
      '';

  # A build script killed by a signal fails its run unit, naming the
  # signal. The run unit's BREAKBULK_UNIT is executed by hand, so the check
  # can expect the failure.
  build-script-signal =
    let
      ws = mk "build-script-signal" { };
      runs = lib.filter (u: lib.hasSuffix "-build-run" u.name) (lib.attrValues ws.units.build);
      run = assert lib.length runs == 1; lib.head runs;
    in
    pkgs.runCommand "build-script-signal-check" { unit = run.drvAttrs.BREAKBULK_UNIT; } ''
      result=$out
      if BREAKBULK_UNIT="$unit" out=$TMPDIR/o flags=$TMPDIR/f \
          ${tools.breakbulk-unit}/bin/breakbulk-unit unit 2> err; then
        echo "the run unit succeeded; it must fail" >&2
        exit 1
      fi
      cat err
      grep -q 'failed to run custom build command for `build-script-signal v0.1.0`' err
      grep -q 'signal: 6, SIGABRT' err
      mkdir -p $result
      cp err $result/
    '';

  # Decision 50: breakbulk's binaries are built from narrow sources, so an
  # edit to the planner leaves breakbulk-unit (an input of every unit) and
  # breakbulk-shim alone. Computes the tools' derivations from a copy of
  # the repository with a line added to breakbulk-plan's main.rs and to
  # breakbulk-format's lib.rs (IFD: the copy is a derivation), and compares
  # .drv paths with the real ones.
  tools-narrow =
    let
      repo = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ../../Cargo.toml
          ../../Cargo.lock
          ../../crates
        ];
      };
      edited = pkgs.runCommand "breakbulk-edited-repo" { } ''
        cp -r --no-preserve=mode ${repo} $out
        echo '// edited' >> $out/crates/breakbulk-plan/src/main.rs
        echo '// edited' >> $out/crates/breakbulk-format/src/lib.rs
      '';
      # Realise the copy (IFD), then use it as a path value.
      editedRoot = builtins.seq (builtins.readDir edited) (
        /. + builtins.unsafeDiscardStringContext edited.outPath
      );
      real = import ../../lib/tools.nix { inherit lib; } pkgs;
      other = import ../../lib/tools.nix {
        inherit lib;
        root = editedRoot;
      } pkgs;
      same = n: real.${n}.drvPath == other.${n}.drvPath;
      checks = {
        "breakbulk-unit unchanged" = same "breakbulk-unit";
        "breakbulk-shim unchanged" = same "breakbulk-shim";
        "breakbulk-plan changed" = !same "breakbulk-plan";
        "breakbulk-instantiate changed" = !same "breakbulk-instantiate";
        "breakbulk-unit's source has only itself" = real.breakbulk-unit.crates == [ "breakbulk-unit" ];
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    assert lib.assertMsg (failed == [ ]) "tools-narrow: ${lib.concatStringsSep ", " failed}";
    pkgs.runCommand "tools-narrow-check" { } ''
      echo ${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.attrNames checks))} > $out
    '';

  # The test plan: the bin's test harness, built from `cargo test --no-run`.
  walking-skeleton-test =
    pkgs.runCommand "walking-skeleton-test-check"
      { t = walking-skeleton.testBins."walking-skeleton/bin-test/walking-skeleton"; }
      ''
        $t/bin/walking-skeleton | tee log
        grep -q 'test tests::build_script_reached_the_test_harness ... ok' log
        grep -q 'test result: ok. 1 passed' log
        mkdir -p $out
        cp log $out/
      '';
}
// goldenOn "directives" { extraSources = lib.genAttrs directivesPackages (_: [ "common" ]); }
// goldenOn "dev-dep-features" { }
