# Products, stages, source paths, products as inputs and variants (M4),
# through mkRepository (IFD mode, native target). Wired into the flake's
# checks as `products-*`.
#
#   nix build -f tests/products post-link
#
#   post-link        stage order from target and package stages; a stage
#                    removed with mkForce null; a check on `linked` sees
#                    unstripped bytes; checks in repo.checks
#   source-paths     no source reference in the product's main output
#                    (noSourceReferences passes); panics and file!() in a
#                    dependency print remapped paths; the debug output
#                    references the dependency's source view and the
#                    registry crate's source; gdb lists source lines from
#                    it; non-test units remap macro,diagnostics, test
#                    harnesses every scope; dep's tests pass
#   source-paths-readme   editing dep's README changes its test binary's
#                    derivation but not its bytes
#   variants         build, check, clippy (with and without clippy
#                    arguments), a custom profile inheriting release and a
#                    feature powerset: host units shared between build and
#                    clippy at the same profile; every dependency unit
#                    shared between check and clippy, members not; every
#                    unit shared between release and the custom profile;
#                    the powerset's products have their features; the check
#                    and clippy variants' unit checks build
#   variants-clippy-strict   `clippyArgs = [ "-D" "clippy::len_zero" ]`
#                    fails the member's clippy unit naming the lint
#   benches          a libtest-harness bench and a Criterion bench come
#                    from the bench variant only (`cargo bench --no-run`,
#                    bench profile, opt-level 3); the test plan has none;
#                    benchSmoke runs each once with `--test` as a check
#
# `repos` exposes each repository for debugging.
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
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  helpers = breakbulk.stageHelpers;

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      inherit modules;
    };

  oneWs = path: profile: {
    workspaces.main = {
      inherit path;
      variants.default = { inherit profile; };
    };
  };

  evalCheck =
    name: report:
    pkgs.runCommand name { inherit report; } ''
      mkdir -p $out
      printf '%s\n' "$report" > $out/report
    '';

  # A copy of a fixture with an edit applied, usable as a repository root.
  edited =
    fixture: script:
    let
      drv = pkgs.runCommand "${fixture}-edited" { } ''
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} $out
        cd $out
        ${script}
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  inst = repo: repo.workspaces.main.instances.${native}.default;

  # Rendered BREAKBULK_UNIT of each unit of a plan kind, by derivation name.
  renderedUnits =
    repo: kind:
    lib.listToAttrs (
      map (
        u:
        lib.nameValuePair u.name (builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT))
      ) (lib.attrValues (inst repo).units.${kind})
    );

  expectFailure =
    name: unit: patterns:
    let
      a = unit.drvAttrs;
    in
    derivation (
      a
      // {
        name = "${name}-expect-failure";
        builder = "${pkgs.bash}/bin/bash";
        args = [
          "-c"
          ''
            set -u
            result=$out
            for o in $unitOutputs; do
              d=$NIX_BUILD_TOP/unit-out-$o
              export "$o=$d"
            done
            unitArgs=()
            for ((i = 0; i < unitArgc; i++)); do
              v=unitArg$i
              unitArgs+=("''${!v}")
            done
            rc=0
            "$unitBuilder" "''${unitArgs[@]}" > $NIX_BUILD_TOP/log 2>&1 || rc=$?
            ${pkgs.coreutils}/bin/cat $NIX_BUILD_TOP/log
            if [ $rc -eq 0 ]; then
              echo "expected the unit to fail, but it succeeded" >&2
              exit 1
            fi
            ${lib.concatMapStrings (p: ''
              ${pkgs.gnugrep}/bin/grep -qF -- ${lib.escapeShellArg p} $NIX_BUILD_TOP/log || {
                echo "the failure does not mention: "${lib.escapeShellArg p} >&2
                exit 1
              }
            '') patterns}
            ${pkgs.coreutils}/bin/mkdir -p $result
            ${pkgs.coreutils}/bin/cp $NIX_BUILD_TOP/log $result/log
          ''
        ];
        outputs = [ "out" ];
        unitOutputs = a.outputs or [ "out" ];
        unitBuilder = a.builder;
        unitArgc = toString (lib.length (a.args or [ ]));
      }
      // lib.listToAttrs (lib.imap0 (i: v: lib.nameValuePair "unitArg${toString i}" v) (a.args or [ ]))
    );

  # Unit derivations of one plan kind of a variant, by derivation name.
  unitsOf =
    repo: vName: kind:
    lib.listToAttrs (
      map (u: lib.nameValuePair u.name u) (
        lib.attrValues repo.workspaces.main.instances.${native}.${vName}.units.${kind}
      )
    );
  drvsOf = repo: vName: kind: lib.mapAttrs (_: u: u.drvPath) (unitsOf repo vName kind);

  # --- post-link ---------------------------------------------------------------

  # A custom stage: copies its input and writes a marker file listing the
  # stages seen so far (each stage appends its name).
  marker =
    stage:
    { input, product, pkgs, ... }:
    pkgs.runCommand "${product.name}-${stage}" { } ''
      cp -RL --no-preserve=mode,ownership ${input} $out
      chmod -R u+w $out
      find $out -type f ! -name '*.txt' -exec chmod +x {} +
      echo ${stage} >> $out/stages.txt
    '';

  # A check that fails unless every ELF file in its input still has debug
  # info: on `linked` it sees the bytes before splitDebug and strip.
  hasDebugInfo =
    { input, product, pkgs, ... }:
    pkgs.runCommand "${product.name}-has-debug-info" { nativeBuildInputs = [ pkgs.binutils-unwrapped ]; } ''
      for f in ${input}/*; do
        readelf -S -W "$f" > sections
        grep -q ' \.debug_info ' sections || { echo "$f: no debug info" >&2; exit 1; }
      done
      touch $out
    '';

  postLink = mkRepo (fixtures + "/post-link") [
    (oneWs "." "dev")
    {
      # Target level: strip after splitDebug (removes the debuglink's
      # remaining symbol tables too) for every product.
      targets.${native} = {
        stages.strip = {
          after = "splitDebug";
          run = helpers.strip { all = true; };
        };
        checks.unstripped = {
          on = "linked";
          run = hasDebugInfo;
        };
      };
      packages.server = {
        stages = {
          # Signing breaks if stripped: remove the target's strip stage.
          strip = lib.mkForce null;
          stamp = {
            after = "splitDebug";
            run = marker "stamp";
          };
          sign = {
            after = "stamp";
            run = marker "sign";
          };
        };
      };
    }
    # A second module sets strip again at normal priority; mkForce wins.
    {
      packages.server.stages.strip = {
        after = "sign";
        run = helpers.strip;
      };
    }
  ];
  plServer = postLink.workspaces.main.packages.server;
  plTool = postLink.workspaces.main.packages.tool;

  # --- source-paths ------------------------------------------------------------

  spModules = [ (oneWs "." "dev") ];
  sourcePaths = mkRepo (fixtures + "/source-paths") spModules;
  sourcePathsReadme = mkRepo (edited "source-paths" "echo 'More words.' >> dep/README.md") spModules;
  spApp = sourcePaths.workspaces.main.packages.app;

  # --- variants ------------------------------------------------------------------

  variantsRepo = mkRepo (fixtures + "/variants") [
    {
      workspaces.main = {
        path = "ws";
        variants = {
          default.profile = "release";
          custom.profile = "release-custom";
          check = {
            mode = "check";
            profile = "release";
          };
          clippy = {
            mode = "clippy";
            profile = "release";
          };
          strict = {
            mode = "clippy";
            profile = "release";
            clippyArgs = [
              "-D"
              "clippy::len_zero"
            ];
          };
        }
        // breakbulk.variants.featurePowerset {
          features = [
            "lib-a/x"
            "lib-a/y"
          ];
          profile = "release";
          prefix = "fp";
        };
      };
    }
  ];
  vt = variantsRepo.workspaces.main.target.${native};

  # --- benches -------------------------------------------------------------------

  benchesRepo = mkRepo (fixtures + "/benches") [
    {
      workspaces.main = {
        path = ".";
        benchSmoke = true;
        variants = {
          default.profile = "dev";
          bench = {
            profile = "bench";
            benches = true;
          };
        };
      };
    }
  ];
in
{
  repos = {
    inherit
      postLink
      sourcePaths
      sourcePathsReadme
      variantsRepo
      benchesRepo
      ;
  };

  benches =
    let
      w = benchesRepo.workspaces.main;
      t = w.target.${native};
      readPlan = drv: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${drv}/plan.json"));
      benchPlan = readPlan w.plans.${native}.bench.bench;
      testPlans = map (v: readPlan w.plans.${native}.${v}.test) [
        "default"
        "bench"
      ];
      kinds = plan: map (r: r.kind) plan.roots;
      critUnit = (unitsOf benchesRepo "bench" "bench")."bencher-0.1.0-bin-crit" or null;
      critArgs = lib.filter builtins.isString (
        (builtins.fromJSON (builtins.unsafeDiscardStringContext critUnit.drvAttrs.BREAKBULK_UNIT)).args
      );
      smoke = lib.filterAttrs (n: _: lib.hasInfix "/bench-" n) benchesRepo.checks;
    in
    assert lib.assertMsg (lib.attrNames t.benches.bencher == [
      "crit"
      "lib"
      "libtest"
    ]) "benches: ${builtins.toJSON (lib.attrNames t.benches.bencher)}";
    assert lib.assertMsg (lib.all (p: !(lib.elem "bench" (kinds p))) testPlans) "benches: a test plan has bench roots";
    assert lib.assertMsg (benchPlan.kind == "bench" && benchPlan.variant.profile == "bench") "benches: bench plan header ${builtins.toJSON benchPlan.variant}";
    assert lib.assertMsg (lib.sort lib.lessThan (kinds benchPlan) == [
      "bench"
      "bench"
      "lib"
    ]) "benches: bench plan roots ${builtins.toJSON benchPlan.roots}";
    assert lib.assertMsg (critUnit != null && lib.elem "opt-level=3" critArgs) "benches: crit unit args ${builtins.toJSON critArgs}";
    assert lib.assertMsg (lib.length (lib.attrNames smoke) == 3) "benches: smoke checks ${builtins.toJSON (lib.attrNames smoke)}";
    pkgs.runCommand "benches"
      (
        {
          crit = t.benches.bencher.crit;
          libtest = t.benches.bencher.libtest;
        }
        // lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) smoke
      )
      ''
        set -euo pipefail
        [ -x $crit/bin/crit ]
        [ -x $libtest/bin/libtest ]
        cat ${lib.concatMapStringsSep " " (d: "${d}/log") (lib.attrValues smoke)}
        grep -q Success ${smoke."main/${native}/bencher/bench-crit"}/log
        touch $out
      '';

  variants =
    let
      d = drvsOf variantsRepo;
      same = a: b: names: lib.filter (n: (a.${n} or "missing-a") != (b.${n} or "missing-b")) names;
      hostUnits = [
        "pm-0.1.0-lib"
        "hostdep-0.1.0-build-script"
        "hostdep-0.1.0-build-run"
      ];
      depNames = plan: lib.filter (n: lib.hasPrefix "pm-" n || lib.hasPrefix "hostdep-" n) (lib.attrNames plan);
      memberNames = plan: lib.filter (n: lib.hasPrefix "app-" n || lib.hasPrefix "lib-a-" n) (lib.attrNames plan);
      buildVsClippy = same (d "default" "build") (d "clippy" "build") hostUnits;
      checkVsClippy = lib.concatMap (
        k: same (d "check" k) (d "clippy" k) (depNames (d "check" k))
      ) [ "build" "test" ];
      membersDiffer = lib.filter (n: (d "check" "build").${n} == (d "clippy" "build").${n}) (
        memberNames (d "check" "build")
      );
      customVsRelease = lib.concatMap (
        k:
        let
          a = d "default" k;
          b = d "custom" k;
        in
        lib.optional (lib.sort lib.lessThan (lib.attrValues a) != lib.sort lib.lessThan (lib.attrValues b)) k
      ) [ "build" "test" ];
      # The lib target unit of the check variant is metadata only, so it
      # differs from the build variant's (sanity check for the comparison).
      libDiffers = (d "default" "build")."hostdep-0.1.0-lib" != (d "check" "build")."hostdep-0.1.0-lib";
      fpNames = lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "fp-" n) vt.variants);
    in
    assert lib.assertMsg (buildVsClippy == [ ]) "variants: host units differ between build and clippy: ${builtins.toJSON buildVsClippy}";
    assert lib.assertMsg (checkVsClippy == [ ]) "variants: dependency units differ between check and clippy: ${builtins.toJSON checkVsClippy}";
    assert lib.assertMsg (membersDiffer == [ ]) "variants: member units shared between check and clippy: ${builtins.toJSON membersDiffer}";
    assert lib.assertMsg (customVsRelease == [ ]) "variants: release and release-custom differ in plans ${builtins.toJSON customVsRelease}";
    assert lib.assertMsg libDiffers "variants: hostdep's lib is shared between build and check";
    assert lib.assertMsg (fpNames == [
      "fp-lib-a_x"
      "fp-lib-a_x+lib-a_y"
      "fp-lib-a_y"
      "fp-none"
    ]) "variants: powerset ${builtins.toJSON fpNames}";
    assert lib.assertMsg (variantsRepo.checks ? "main/${native}/variant-clippy/check") "variants: no clippy check in repo.checks";
    pkgs.runCommand "variants"
      {
        app = vt.packages.app;
        custom = vt.variants.custom.packages.app;
        none = vt.variants.fp-none.packages.app;
        both = vt.variants."fp-lib-a_x+lib-a_y".packages.app;
        check = vt.variants.check.check;
        clippy = vt.variants.clippy.check;
      }
      ''
        set -euo pipefail
        [ "$($app/bin/app)" = "app 42 x=true y=false host=7" ]
        [ "$($custom/bin/app)" = "app 42 x=true y=false host=7" ]
        [ "$($none/bin/app)" = "app 42 x=false y=false host=7" ]
        [ "$($both/bin/app)" = "app 42 x=true y=true host=7" ]
        cat $check/units $clippy/units > $out
      '';

  variants-clippy-strict =
    let
      unit = (unitsOf variantsRepo "strict" "build")."lib-a-0.1.0-lib";
    in
    pkgs.runCommand "variants-clippy-strict"
      {
        failure = expectFailure "lib-a-clippy" unit [ "#len_zero" "-D clippy::len-zero" ];
        # The default clippy variant lints the same code and succeeds.
        lenient = (unitsOf variantsRepo "clippy" "build")."lib-a-0.1.0-lib";
      }
      ''
        cat $failure/log
        touch $out
      '';

  source-paths =
    let
      i = inst sourcePaths;
      depView = i.sources.workspace.dep;
      itoaSrc = lib.head (lib.attrValues (lib.filterAttrs (id: _: lib.hasSuffix "#itoa@1.0.11" id) i.sources.crates));
      build = renderedUnits sourcePaths "build";
      test = renderedUnits sourcePaths "test";
      scopes = lib.mapAttrs (_: u: u.remapScope or null) (lib.filterAttrs (_: u: u.kind == "compile") (build // test));
      want = {
        "app-0.1.0-bin" = "macro,diagnostics";
        "dep-0.1.0-lib" = "macro,diagnostics";
        "itoa-1.0.11-lib" = "macro,diagnostics";
        "app-0.1.0-test" = null;
        "dep-0.1.0-test" = null;
      };
      bad = lib.filterAttrs (n: s: (scopes.${n} or "missing") != s) want;
    in
    assert lib.assertMsg (bad == { }) "source-paths: remap scopes ${builtins.toJSON scopes}";
    assert lib.assertMsg (spApp.stageOrder == [
      "splitDebug"
      "install"
    ]) "source-paths: stages ${builtins.toJSON spApp.stageOrder}";
    pkgs.runCommand "source-paths"
      {
        nativeBuildInputs = [ pkgs.gdb ];
        app = spApp;
        debug = spApp.debug;
        debugClosure = pkgs.closureInfo { rootPaths = [ spApp.debug ]; };
        # Negative control: before splitDebug, the binary does reference
        # the sources (debug info keeps real paths), so noSourceReferences
        # is not passing vacuously.
        linkedClosure = pkgs.closureInfo { rootPaths = [ spApp.stages.linked ]; };
        noSrc = spApp.checks.noSourceReferences;
        depView = builtins.unsafeDiscardStringContext "${depView}";
        itoaSrc = builtins.unsafeDiscardStringContext "${itoaSrc}";
        depTests = sourcePaths.workspaces.main.testRuns.dep.lib;
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        cat run.txt
        grep -qxF 'dep is dep/src/lib.rs' run.txt
        grep -qxF 'formatted 42' run.txt
        grep -qxF 'panicked at dep/src/lib.rs:16' run.txt
        # The debug output references exactly the sources a debugger needs.
        grep -qxF "$depView" $debugClosure/store-paths
        grep -qxF "$itoaSrc" $debugClosure/store-paths
        grep -qxF "$depView" $linkedClosure/store-paths
        # gdb finds the split debug info by build ID and lists the source.
        gdb -batch -nx -iex "set debug-file-directory $debug/lib/debug" \
          -ex 'list dep::boom' $app/bin/app > gdb.txt 2>&1 || true
        cat gdb.txt
        grep -qF 'panic!("boom {n}");' gdb.txt
        cat $depTests/log
        touch $out
      '';

  source-paths-readme =
    let
      before = sourcePaths.workspaces.main.tests.dep.lib;
      after = sourcePathsReadme.workspaces.main.tests.dep.lib;
    in
    assert lib.assertMsg (before.drvPath != after.drvPath) "source-paths-readme: the README edit changed no derivation";
    pkgs.runCommand "source-paths-readme" { inherit before after; } ''
      cmp $before/bin/dep $after/bin/dep
      touch $out
    '';

  post-link =
    let
      checkNames = lib.attrNames postLink.checks;
      want = map (n: "main/${native}/${n}") [
        "server/build"
        "server/noSourceReferences"
        "server/unstripped"
        "tool/build"
        "tool/noSourceReferences"
        "tool/unstripped"
      ];
    in
    assert lib.assertMsg (plServer.stageOrder == [
      "splitDebug"
      "stamp"
      "sign"
      "install"
    ]) "post-link: server stages ${builtins.toJSON plServer.stageOrder}";
    assert lib.assertMsg (plTool.stageOrder == [
      "splitDebug"
      "strip"
      "install"
    ]) "post-link: tool stages ${builtins.toJSON plTool.stageOrder}";
    assert lib.assertMsg (lib.all (n: lib.elem n checkNames) want) "post-link: checks ${builtins.toJSON checkNames}";
    pkgs.runCommand "post-link"
      {
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
        server = plServer;
        serverLinked = plServer.stages.linked;
        serverDebug = plServer.debug;
        tool = plTool;
        unstripped = plServer.checks.unstripped;
        toolUnstripped = plTool.checks.unstripped;
        noSrc = plServer.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        # has FILE SECTION: whether FILE has SECTION (no pipe into grep -q,
        # which can fail with SIGPIPE under pipefail).
        has() { readelf -S -W "$1" > sections; grep -qF " $2 " sections; }
        [ "$($server/bin/server)" = "server 1" ]
        [ "$($tool/bin/tool)" = tool ]
        # Stage order as the marker stages saw it.
        [ "$(cat $server/stages.txt)" = "$(printf 'stamp\nsign')" ]
        # linked holds the unstripped binary under its target name.
        has $serverLinked/server .debug_info
        # splitDebug moved it to the debug output; no strip ran on server
        # (its symbol table is still there), but tool was stripped.
        ! has $server/bin/server .debug_info
        has $server/bin/server .symtab
        ! has $tool/bin/tool .symtab
        has $server/bin/server .gnu_debuglink
        ls $serverDebug/lib/debug/.build-id/*/*.debug
        touch $out
      '';
}
