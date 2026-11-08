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
      # Native inputs the fixture's build scripts need.
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
    }:
    pkgs.runCommandCC "${fixture}-cargo-${command}"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
        ]
        ++ nativeBuildInputs;
        inherit buildInputs;
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
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
    }:
    pkgs.runCommandCC "${fixture}-golden-${kind}"
      {
        nativeBuildInputs = [
          toolchain.cargo
          toolchain.rustc
        ]
        ++ nativeBuildInputs;
        inherit buildInputs;
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} "$NIX_BUILD_TOP/skeleton"
        cd "$NIX_BUILD_TOP/skeleton"
        common=(--frozen --offline --config ${ws.vendor.configFile})
        # When the planner turned Cargo's trim-paths on (Cargo >= 1.101 and
        # the project did not), the reference build does the same.
        if grep -q '"trimPathsDefault":true' ${ws.plans.${kind}}/plan.json; then
          common+=(--config 'profile.dev.trim-paths="all"')
        fi
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

  # What sys-native's build scripts need, for breakbulk (per package) and
  # for the plain cargo references (all at once).
  sysNativeInputs = {
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.cmake
      pkgs.rustPlatform.bindgenHook
    ];
    buildInputs = [ pkgs.openssl ];
  };
  sysNativeArgs = {
    packages = {
      openssl-sys = {
        nativeInputs = p: [ p.pkg-config ];
        inputs = p: [ p.openssl ];
        env.BB_MARKER = "ssl";
      };
      cm-sys.nativeInputs = p: [ p.cmake ];
      bg-sys.nativeInputs = p: [ p.rustPlatform.bindgenHook ];
    };
  };
  sysNative = mk "sys-native" sysNativeArgs;

  # The other releases of the supported window for the golden test, from
  # rust-overlay when the package set has it (the flake's does): the oldest
  # stable (1.95), one between, and the latest nightly (new build-directory
  # layout, -Zembed-metadata=no). nixpkgs' own cargo (1.99) is the latest
  # stable, tested by the checks above.
  goldenToolchains = lib.optionalAttrs (pkgs ? rust-bin) (
    lib.mapAttrs
      (_: tc: {
        cargo = tc;
        rustc = tc;
      })
      {
        "1_95" = pkgs.rust-bin.stable."1.95.0".minimal;
        "1_97" = pkgs.rust-bin.stable."1.97.0".minimal;
        nightly = pkgs.rust-bin.nightly.latest.minimal;
      }
  );
  # The golden test of a fixture's build and test plans on each of them:
  # `<fixture>-golden-<label>` and `<fixture>-golden-<label>-test`.
  # `args` go to mkWorkspace; `goldenArgs` to `golden` (native inputs).
  goldenOn =
    fixture: args: goldenArgs:
    lib.concatMapAttrs (
      v: toolchain:
      let
        ws = mk fixture (args // { inherit toolchain; });
        n = "${fixture}-golden-${v}";
      in
      {
        ${n} = golden ({ inherit fixture ws toolchain; } // goldenArgs);
        "${n}-test" = golden (
          {
            inherit fixture ws toolchain;
            kind = "test";
          }
          // goldenArgs
        );
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

  # #34: breakbulk-unit turns rustc's JSON diagnostics into its rendered
  # text. With a real rustc, a warning and an error in two compile units
  # (run by hand, as above) appear as rustc renders them, and no raw JSON
  # line (`{"$message_type"`) reaches the log.
  diagnostics =
    let
      ws = mk "diagnostics" { };
      unitOf =
        n:
        (lib.findFirst (u: u.name == "${n}-0.1.0-lib") (throw "diagnostics: no ${n} unit") (
          lib.attrValues ws.units.build
        )).drvAttrs.BREAKBULK_UNIT;
    in
    pkgs.runCommand "diagnostics-check"
      {
        warns = unitOf "warns";
        broken = unitOf "broken";
      }
      ''
        result=$out
        run() { BREAKBULK_UNIT="$1" out=$TMPDIR/$2-o rlib=$TMPDIR/$2-rlib rmeta=$TMPDIR/$2-rmeta flags=$TMPDIR/$2-f \
          ${tools.breakbulk-unit}/bin/breakbulk-unit unit; }
        run "$warns" warns 2> warns.log || { cat warns.log; echo "warns failed" >&2; exit 1; }
        if run "$broken" broken 2> broken.log; then
          echo "the broken unit succeeded; it must fail" >&2
          exit 1
        fi
        cat warns.log broken.log
        # Cargo asks for `diagnostic-rendered-ansi`: the text is colored.
        for f in warns broken; do sed 's/\x1b\[[0-9;]*m//g' $f.log > $f.txt; done
        grep -q 'warning: unused variable: `unused`' warns.txt
        grep -q 'error\[E0308\]: mismatched types' broken.txt
        if grep -q '{"\$message_type"' warns.log broken.log; then
          echo "raw rustc JSON in a unit log" >&2
          exit 1
        fi
        mkdir -p $result
        cp warns.log broken.log $result/
      '';

  # Decision 50: breakbulk's binaries are built from narrow sources, so an
  # edit to the planner leaves breakbulk-unit (an input of every unit) and
  # breakbulk-shim alone, and so does an edit to breakbulk-unit's
  # integration tests. Computes the tools' derivations from a copy of the
  # repository with a line added to breakbulk-plan's main.rs, to
  # breakbulk-format's lib.rs and to breakbulk-unit's tests/smoke.rs
  # (IFD: the copy is a derivation), and compares
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
        echo '// edited' >> $out/crates/breakbulk-unit/tests/smoke.rs
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

  # `-sys` crates with native inputs declared per package: pkg-config
  # (openssl-sys), cmake (cm-sys), bindgen and cc (bg-sys). Each package's
  # env capture and env reach only that package's units (read from every
  # unit derivation of both plans); `plain`'s build script sees none of
  # their variables; the product runs as plain cargo's does.
  sys-native =
    let
      ws = sysNative;
      captureOf = n: ws.overrides.${n}.target.envCapture;
      expect = {
        openssl-sys = {
          capture = captureOf "openssl-sys";
          marker = "ssl";
        };
        cm-sys = {
          capture = captureOf "cm-sys";
          marker = null;
        };
        bg-sys = {
          capture = captureOf "bg-sys";
          marker = null;
        };
      };
      base = {
        capture = ws.captures.target;
        marker = null;
      };
      # The package a unit derivation belongs to, from its name
      # (`<package>-<version>-<kind>`).
      pkgOf =
        d:
        lib.findFirst (n: builtins.match "${n}-[0-9].*" d.name != null) null (lib.attrNames expect);
      unitOf = d: builtins.fromJSON (builtins.unsafeDiscardStringContext d.drvAttrs.BREAKBULK_UNIT);
      wrong = lib.concatLists (
        lib.mapAttrsToList (
          kind: units:
          lib.concatMap (
            d:
            let
              u = unitOf d;
              p = pkgOf d;
              want = if p == null then base else expect.${p};
              capture = builtins.unsafeDiscardStringContext "${want.capture}";
            in
            lib.optional (u.envCapture or null != capture || u.env.BB_MARKER or null != want.marker) "${kind}: ${d.name} (capture ${u.envCapture or "none"}, BB_MARKER ${toString (u.env.BB_MARKER or null)})"
          ) (lib.attrValues units)
        ) ws.units
      );
      captures = lib.mapAttrs (_: e: e.capture) expect;
      ref = cargoBuild (
        {
          fixture = "sys-native";
          inherit ws;
          install = "install -D $t/app $out/bin/app";
        }
        // sysNativeInputs
      );
    in
    assert lib.assertMsg (wrong == [ ]) "sys-native: units with the wrong capture or env:\n${lib.concatStringsSep "\n" wrong}";
    assert lib.assertMsg (
      lib.length (lib.unique (lib.attrValues captures ++ [ base.capture ])) == 4
    ) "sys-native: the captures are not distinct";
    pkgs.runCommand "sys-native-check"
      {
        app = ws.packages.app;
        inherit ref;
        golden = golden (
          {
            fixture = "sys-native";
            inherit ws;
          }
          // sysNativeInputs
        );
      }
      ''
        got=$($app/bin/app); want=$($ref/bin/app)
        echo "breakbulk '$got', cargo '$want'"
        [ "$got" = "openssl=3+ cm=42 bg=7 plain-saw=none" ]
        [ "''${want% plain-saw=*}" = "''${got% plain-saw=*}" ]
        mkdir -p $out
        cp $golden/report $out/
      '';

  # C objects with debug info record the compiler's switches, including
  # `-frandom-seed`. The seed is the unit's plan key, so a unit whose
  # derivation changes without its content changing (here: one extra
  # attribute, standing in for a new breakbulk-unit or env capture) builds
  # byte-identical C archives. cm-sys builds with cmake, bg-sys with cc.
  c-seed =
    let
      runOf =
        p:
        lib.findFirst (d: d.name == "${p}-0.1.0-build-run") (throw "no run unit for ${p}") (
          lib.attrValues sysNative.units.build
        );
      salted = d: derivation (d.drvAttrs // { breakbulkSalt = "c-seed"; });
      pair = p: {
        a = runOf p;
        b = salted (runOf p);
      };
      cm = pair "cm-sys";
      bg = pair "bg-sys";
    in
    pkgs.runCommand "c-seed-check"
      {
        nativeBuildInputs = [ pkgs.binutils ];
        cmA = cm.a.out;
        cmB = cm.b.out;
        bgA = bg.a.out;
        bgB = bg.b.out;
      }
      ''
        [ "$cmA" != "$cmB" ] && [ "$bgA" != "$bgB" ]
        check() {
          a=$1; b=$2
          echo "comparing $a with $b"
          cmp "$a" "$b"
          # Not vacuous: the objects record a seed (in DW_AT_producer, in
          # compressed debug sections), and it is the plan key.
          rm -rf x && mkdir x && (cd x && ar x "$a")
          readelf --debug-dump=info x/*.o | grep -o -- '-frandom-seed=[^ ]*' | sort -u | tee seeds
          grep -q -- '-frandom-seed=r-' seeds
        }
        check $cmA/lib/libcm.a $cmB/lib/libcm.a
        check $bgA/libbg.a $bgB/libbg.a
        mkdir -p $out
      '';

  # Decision 65: cm-sys leaves the cmake crate's build tree in OUT_DIR;
  # breakbulk-unit removes its `CMakeFiles` (the configure log names
  # randomly named try-compile directories), so two builds of the run give
  # the same tree, except for the output's own path (a salted copy of the
  # derivation stands in for `nix build --rebuild`, which a check cannot
  # run). The rest of the tree stays.
  cmake-reproducible =
    let
      run = lib.findFirst (d: d.name == "cm-sys-0.1.0-build-run") (throw "no cm-sys run") (
        lib.attrValues sysNative.units.build
      );
      salted = derivation (run.drvAttrs // { breakbulkSalt = "cmake-reproducible"; });
    in
    pkgs.runCommand "cmake-reproducible"
      {
        a = run.out;
        b = salted.out;
      }
      ''
        [ -f $a/build/CMakeCache.txt ] && [ -f $a/build/libcm.a ] && [ -f $a/lib/libcm.a ]
        [ ! -e $a/build/CMakeFiles ]
        norm() {
          cp -r --no-preserve=mode "$1" "$2"
          grep -rlF "$1" "$2" | while read -r f; do
            sed -i "s|$1|@out@|g" "$f"
          done
        }
        norm $a ta
        norm $b tb
        diff -r ta tb
        mkdir -p $out
        (cd $a && find . | sort) > $out/files
      '';

  # Cargo gives an integration test CARGO_BIN_EXE_<bin> for every bin of
  # its package, also one it does not build because a required feature is
  # off. The plan points it at a path that does not exist (as Cargo's does
  # not), and the test, which runs the built bin and checks the other is
  # absent, passes.
  bin-exe-not-built =
    let
      ws = mk "bin-exe-not-built" { };
      plan = readPlan ws "test";
      envs = lib.concatMap (u: lib.optional (u ? env.CARGO_BIN_EXE_extra) u.env.CARGO_BIN_EXE_extra) (
        lib.attrValues plan.units
      );
    in
    assert lib.assertMsg (envs == [ "/breakbulk/not-built/extra" ])
      "bin-exe-not-built: CARGO_BIN_EXE_extra is ${builtins.toJSON envs}";
    pkgs.runCommand "bin-exe-not-built-check" { t = ws.testBins."tool/test/run"; } ''
      $t/bin/run | tee log
      grep -q 'test result: ok. 2 passed' log
      mkdir -p $out
      cp log $out/
    '';

  # A cargo wrapped like rust-overlay's (which exports LD_LIBRARY_PATH for
  # libsecret): Cargo appends its own process's value to every dynamic
  # library path it sets, and that value is the planner's, so it must not
  # reach the plan (field trials: it failed planning with "not a declared
  # toolchain input"). The marker is a store path no unit may name.
  inherited-dylib-path =
    let
      marker = pkgs.writeTextDir "lib/marker" "";
      cargo =
        (pkgs.symlinkJoin {
          name = "cargo-wrapped";
          paths = [ pkgs.cargo ];
          postBuild = ''
            rm $out/bin/cargo
            cat > $out/bin/cargo <<EOF
            #!${pkgs.runtimeShell}
            export LD_LIBRARY_PATH=${marker}/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
            exec ${pkgs.cargo}/bin/cargo "\$@"
            EOF
            chmod +x $out/bin/cargo
          '';
        })
        // {
          paths = [ pkgs.cargo ];
        };
      toolchain = {
        inherit cargo;
        inherit (pkgs) rustc;
      };
      ws = mk "walking-skeleton" { inherit toolchain; };
      # Compiles with host plugin dependencies (proc macros, build
      # dependencies with build scripts) get those runs' paths after the
      # inherited value.
      dir = mk "directives" {
        inherit toolchain;
        extraSources = lib.genAttrs directivesPackages (_: [ "common" ]);
      };
      units = lib.concatMap (p: lib.attrValues p.units) [
        (readPlan ws "build")
        (readPlan dir "build")
        (readPlan dir "test")
      ];
      dylibs = lib.concatMap (u: lib.optional (u ? env.LD_LIBRARY_PATH) u.env.LD_LIBRARY_PATH) units;
      leaked = lib.filter (
        v: lib.hasInfix (builtins.unsafeDiscardStringContext "${marker}") (builtins.toJSON v)
      ) dylibs;
    in
    assert lib.assertMsg (dylibs != [ ]) "inherited-dylib-path: no unit has LD_LIBRARY_PATH";
    assert lib.assertMsg (leaked == [ ]) "inherited-dylib-path: ${builtins.toJSON leaked}";
    pkgs.runCommand "inherited-dylib-path-check"
      {
        bb = ws.packages.walking-skeleton;
        app = dir.packages.app;
      }
      ''
        $bb/bin/walking-skeleton | grep -q '^walking-skeleton 42 '
        [ "$($app/bin/app)" = "a_sys 42 2" ]
        mkdir -p $out
        echo ${lib.escapeShellArg (builtins.toJSON dylibs)} > $out/report
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
// goldenOn "walking-skeleton" { } { }
// goldenOn "directives" { extraSources = lib.genAttrs directivesPackages (_: [ "common" ]); } { }
// goldenOn "build-dep-leak" { } { }
// goldenOn "crate-types" { } { }
// goldenOn "dev-dep-features" { } { }
// goldenOn "sys-native" sysNativeArgs sysNativeInputs
# Nightly Cargo and rustc (rust-overlay's latest): the new build-directory
# layout and `-Zembed-metadata=no`. The golden tests of the walking skeleton
# and the directives fixture, and their products, which link against rlibs
# that carry no metadata.
// lib.optionalAttrs (pkgs ? rust-bin) (
  let
    tc = pkgs.rust-bin.nightly.latest.minimal;
    toolchain = {
      cargo = tc;
      rustc = tc;
    };
    ws = mk "walking-skeleton" { inherit toolchain; };
    dir = mk "directives" {
      inherit toolchain;
      extraSources = lib.genAttrs directivesPackages (_: [ "common" ]);
    };
    goldens =
      fixture: w:
      lib.genAttrs [ "build" "test" ] (
        kind:
        golden {
          inherit fixture toolchain kind;
          ws = w;
        }
      );
    wsG = goldens "walking-skeleton" ws;
    dirG = goldens "directives" dir;
  in
  {
    # #39: a package with nightly `package.forced-target` would build for
    # another target inside this target's plan; planning fails naming it.
    forced-target =
      let
        failure = pkgs.testers.testBuildFailure (mk "forced-target" { inherit toolchain; }).plans.build;
      in
      pkgs.runCommand "forced-target-check" { inherit failure; } ''
        cat $failure/testBuildFailure.log
        grep -qF 'package `forced` builds for `wasm32-unknown-unknown`' $failure/testBuildFailure.log
        grep -qF 'package.forced-target' $failure/testBuildFailure.log
        touch $out
      '';
    walking-skeleton-nightly =
      pkgs.runCommand "walking-skeleton-nightly-check"
        {
          bb = ws.packages.walking-skeleton;
          t = ws.testBins."walking-skeleton/bin-test/walking-skeleton";
          g = wsG.build;
          gt = wsG.test;
        }
        ''
          [ "$($bb/bin/walking-skeleton)" = "walking-skeleton 42 cfg-on hello-from-build-script debug" ]
          $t/bin/walking-skeleton | grep -q 'test result: ok. 1 passed'
          mkdir -p $out
          cat $g/report $gt/report > $out/report
        '';
    directives-nightly =
      pkgs.runCommand "directives-nightly-check"
        {
          app = dir.packages.app;
          it = dir.testBins."c/test/it";
          g = dirG.build;
          gt = dirG.test;
        }
        ''
          [ "$($app/bin/app)" = "a_sys 42 2" ]
          $it/bin/it | grep -q 'test result: ok. 1 passed'
          mkdir -p $out
          cat $g/report $gt/report > $out/report
        '';
  }
)
