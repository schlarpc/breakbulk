# Checks for mkRepository (M2): overrides, multi-workspace sharing,
# invalidation, required features, failure hints, the dev shell and the
# option docs. IFD throughout (plans are read at evaluation time).
#
#   nix build -f tests/repository multi-ws-sharing
#
# Attributes are derivations (flake checks); `repos.<name>` exposes each
# repository for debugging.
#
# Invalidation tests compare the sets of unit .drv paths of the build and
# test plans before and after a scripted edit. Edits to files are made by a
# derivation that copies the fixture and edits it; its output is then used
# as the repository root (a path into the store, read after IFD realises
# it), so the "after" repository is evaluated exactly like the "before".
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

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      inherit modules;
    };

  # One workspace at `path`, dev profile (faster; every check uses it).
  oneWs = path: {
    workspaces.main = {
      inherit path;
      variants.default.profile = "dev";
    };
  };

  # A check that asserts at evaluation time and records a report.
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
      # Reading the directory realises it (IFD), which also makes the store
      # path readable in pure evaluation.
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  inst = repo: repo.workspaces.main.instances.${native}.default;

  # Unit .drv path -> "<derivation name>" for both plan kinds.
  unitDrvs =
    repo:
    let
      i = inst repo;
    in
    lib.listToAttrs (
      map (u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (lib.attrValues i.units.build ++ lib.attrValues i.units.test)
    );

  # The unit derivations that exist after the edit but not before, by
  # name, sorted and deduplicated.
  changedUnits =
    before: after:
    let
      b = unitDrvs before;
      a = unitDrvs after;
    in
    lib.sort lib.lessThan (lib.unique (lib.attrValues (lib.filterAttrs (d: _: !(b ? ${d})) a)));

  invalidation =
    name: before: after: expected:
    let
      got = changedUnits before after;
    in
    assert lib.assertMsg (got == expected)
      "${name}: changed units ${builtins.toJSON got}, expected ${builtins.toJSON expected}";
    evalCheck name "changed units: ${builtins.toJSON got}";

  # Run a unit derivation's builder in a derivation that succeeds only when
  # the unit fails, and its output contains each of `patterns`.
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

  # Units of a plan, by derivation name.
  unitsNamed = i: kind: lib.listToAttrs (map (u: lib.nameValuePair u.name u) (lib.attrValues i.units.${kind}));

  # --- multi-ws --------------------------------------------------------------

  multiWs = mkRepo (fixtures + "/multi-ws") [
    {
      workspaces = lib.genAttrs [ "a" "b" "c" ] (ws: {
        path = ws;
        variants.default.profile = "dev";
      });
    }
  ];
  mwInst = ws: multiWs.workspaces.${ws}.instances.${native}.default;
  mwDrvs = ws: lib.mapAttrs' (_: u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (mwInst ws).units.build;
  sharedNames =
    wss:
    let
      sets = map mwDrvs wss;
      common = lib.foldl' (acc: s: lib.filterAttrs (d: _: s ? ${d}) acc) (lib.head sets) (lib.tail sets);
    in
    lib.sort lib.lessThan (lib.attrValues common);
  sharedEverywhere = [
    "itoa-1.0.11-lib"
    "libc-0.2.191-build-run"
    "libc-0.2.191-build-script"
    "libc-0.2.191-lib"
    "shared-0.1.0-build-run"
    "shared-0.1.0-build-script"
    "shared-0.1.0-lib"
  ];

  # --- outside-reads -----------------------------------------------------------

  outsideModules = [
    (oneWs "ws")
    {
      packages.reader.extraSources = [ "schema" ];
      packages.app.extraSources = [ "assets" ];
    }
  ];
  outside = mkRepo (fixtures + "/outside-reads") outsideModules;
  outsideUnrelated = mkRepo (edited "outside-reads" "echo changed >> unrelated/notes.txt") outsideModules;
  outsideAsset = mkRepo (edited "outside-reads" "echo 'asset v2' > assets/data.txt") outsideModules;
  outsideSchema = mkRepo (edited "outside-reads" "echo 'hello v2' > schema/greeting.txt") outsideModules;

  # --- stamps --------------------------------------------------------------------

  stampsWith =
    rev:
    mkRepo (fixtures + "/stamps") [
      (oneWs ".")
      {
        packages.app.env = {
          GIT_REV = rev;
          SOURCE_DATE_EPOCH = 1700000000;
        };
      }
    ];
  stampsA = stampsWith "aaaaaaa";
  stampsB = stampsWith "bbbbbbb";

  # --- required-features -------------------------------------------------------

  rf = mkRepo (fixtures + "/required-features") [
    (oneWs ".")
    {
      workspaces.main.variants.full.features = [
        "rf/cli"
        "rft/extra"
      ];
    }
    { workspaces.main.variants.full.profile = "dev"; }
  ];
  rfDefault = rf.workspaces.main.packages.rf;
  rfFull = rf.workspaces.main.target.${native}.variants.full;

  # --- missing-input ---------------------------------------------------------

  mylib = pkgs.runCommand "mylib" { } ''
    mkdir -p $out/include
    echo 3.1 > $out/include/mylib.h
  '';
  missing = mkRepo (fixtures + "/missing-input") [ (oneWs ".") ];
  provided = mkRepo (fixtures + "/missing-input") [
    (oneWs ".")
    {
      packages.mylib-sys = {
        env.MYLIB_DIR = mylib;
        extraSources = [ "vendor" ];
      };
    }
  ];

  # --- overrides and options ---------------------------------------------------

  # Evaluation only: the repository is never built.
  overrideRepo = mkRepo (fixtures + "/multi-ws") [
    {
      workspaces.b = {
        path = "b";
        variants.default.profile = "dev";
      };
      packages = {
        "itoa@^1".env.ITOA_CARET = "1";
        itoa = {
          version = ">=2";
          env.ITOA_TWO = "1";
        };
        libc.env.LIBC = "plain";
        "libc@=0.2.191".env.LIBC = "exact";
        not-in-any-lockfile.env.X = "1";
        app-b.test.args = [ "--skip" "slow" ];
      };
      targets.${native}.rustflags = [ "-Cfoo" ];
    }
  ];
  inst' = repo: ws: repo.workspaces.${ws}.instances.${native}.default;
in
{
  repos = {
    inherit
      multiWs
      outside
      stampsA
      rf
      missing
      provided
      overrideRepo
      ;
  };

  # Exactly the registry crates and the path crate outside every root are
  # shared by all three workspaces; `inner` (inside a's root) is shared
  # only by b and c, which both see it from outside.
  multi-ws-sharing =
    let
      all3 = sharedNames [ "a" "b" "c" ];
      bc = sharedNames [ "b" "c" ];
      ab = sharedNames [ "a" "b" ];
      inner = multiWs.explainSharing {
        a = multiWs.workspaces.a.plans.${native}.default.build;
        b = "b";
        package = "inner";
      };
      innerUnit = lib.head inner.units;
    in
    assert lib.assertMsg (all3 == sharedEverywhere) "multi-ws: shared by a, b, c: ${builtins.toJSON all3}";
    assert lib.assertMsg (bc == lib.sort lib.lessThan (sharedEverywhere ++ [ "inner-0.1.0-lib" ]))
      "multi-ws: shared by b, c: ${builtins.toJSON bc}";
    assert lib.assertMsg (ab == sharedEverywhere) "multi-ws: shared by a, b: ${builtins.toJSON ab}";
    # explainSharing names why `inner` differs: Cargo passes a member's
    # source path relative to the workspace root and runs rustc there, and
    # marks it as a primary package.
    assert lib.assertMsg (
      !inner.shared
      && innerUnit.fields.env ? CARGO_PRIMARY_PACKAGE
      && innerUnit.fields ? cwd
      && lib.elem "inner/src/lib.rs" innerUnit.fields.args.onlyA
    ) "multi-ws: explainSharing inner: ${inner.text}";
    assert lib.assertMsg (
      (multiWs.explainSharing {
        a = "a";
        b = "c";
        package = "shared";
      }).shared
    ) "multi-ws: explainSharing shared reports a difference";
    pkgs.runCommand "multi-ws-sharing"
      {
        a = multiWs.workspaces.a.packages.app-a;
        b = multiWs.workspaces.b.packages.app-b;
        c = multiWs.workspaces.c.packages.app-c;
        text = inner.text;
      }
      ''
        for x in a b c; do
          got=$(''${!x}/bin/app-$x)
          echo "$got"
          [ "$got" = "app-$x shared:7+cfg inner 1" ]
        done
        mkdir -p $out
        printf '%s\n' "$text" > $out/explain-inner
      '';

  # Builds, with files read from outside the crate directories made
  # visible by extraSources; editing an unrelated sibling changes no unit;
  # editing a file read by the proc macro's caller changes only that
  # caller's units; editing the include_str! file changes its reader and
  # the reader's dependents.
  outside-reads = pkgs.runCommand "outside-reads" { app = outside.workspaces.main.packages.app; } ''
    got=$($app/bin/app)
    echo "$got"
    [ "$got" = "hello from schema | asset v1" ]
    touch $out
  '';
  outside-reads-unrelated = invalidation "outside-reads-unrelated" outside outsideUnrelated [ ];
  outside-reads-asset = invalidation "outside-reads-asset" outside outsideAsset [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];
  outside-reads-schema = invalidation "outside-reads-schema" outside outsideSchema [
    "app-0.1.0-bin"
    "app-0.1.0-test"
    "reader-0.1.0-lib"
    "reader-0.1.0-test"
  ];

  # A per-package stamp reaches only that package's units.
  stamps = pkgs.runCommand "stamps" { app = stampsA.workspaces.main.packages.app; tool = stampsA.workspaces.main.packages.tool; } ''
    got=$($app/bin/app); echo "$got"
    [ "$got" = "app rev=aaaaaaa epoch=1700000000 util:42:yes" ]
    got=$($tool/bin/tool); echo "$got"
    [ "$got" = "tool rev=unset util:1:yes" ]
    touch $out
  '';
  stamps-invalidation = invalidation "stamps-invalidation" stampsA stampsB [
    "app-0.1.0-bin"
    "app-0.1.0-test"
  ];

  # Targets skipped for missing features have attributes: the product
  # root is a stub that fails with the reason, the test a stub that
  # succeeds and says it was skipped. The variant with the features builds
  # and runs them.
  required-features =
    let
      admin = rfDefault.roots."bin/admin";
      reason = admin.breakbulkRoot.reason;
    in
    assert lib.assertMsg (admin.breakbulkRoot.unit == null) "required-features: admin was built without `cli`";
    assert lib.assertMsg (lib.hasInfix "cli" reason) "required-features: the stub's reason does not name the feature: ${reason}";
    assert lib.assertMsg (map (u: u.root) rfDefault.unbuilt == [ "bin/admin" ]) "required-features: unbuilt ${builtins.toJSON rfDefault.unbuilt}";
    pkgs.runCommand "required-features"
      {
        rf = rfDefault;
        skipped = rf.workspaces.main.tests.rft.needs-extra;
        plain = rf.workspaces.main.tests.rft.plain;
        adminFull = rfFull.packages.rf;
        testFull = rfFull.tests.rft.needs-extra;
        adminStub = expectFailure "rf-admin" admin [ "cli" ];
      }
      ''
        [ "$($rf/bin/rf)" = rf ]
        [ ! -e $rf/bin/admin ]
        ls -R $skipped
        $plain/bin/plain
        [ "$($adminFull/bin/admin)" = "admin cli=true" ]
        $testFull/bin/needs-extra
        touch $out
      '';

  # An undeclared input fails the build-script run with a message naming
  # the options to set; declaring them builds.
  missing-input =
    let
      run = (unitsNamed (inst missing) "build")."mylib-sys-0.1.0-build-run";
    in
    pkgs.runCommand "missing-input"
      {
        failure = expectFailure "mylib-sys-run" run [
          "packages.mylib-sys.env.MYLIB_DIR"
          "packages.mylib-sys.extraSources"
        ];
        app = provided.workspaces.main.packages.app;
      }
      ''
        cat $failure/log
        got=$($app/bin/app); echo "$got"
        [ "$got" = "app 3.1 vendored 7" ]
        touch $out
      '';

  # Override keys: name, name@requirement, the version option; merging
  # order (versioned last); warnings for unmatched and unimplemented
  # options.
  overrides =
    let
      units = unitsNamed (inst' overrideRepo "b") "build";
      envOf =
        n:
        (builtins.fromJSON (builtins.unsafeDiscardStringContext units.${n}.drvAttrs.BREAKBULK_UNIT)).env;
      itoa = envOf "itoa-1.0.11-lib";
      libc = envOf "libc-0.2.191-lib";
      libcRun = envOf "libc-0.2.191-build-run";
      ws = overrideRepo.warnings;
      has = s: lib.any (lib.hasInfix s) ws;
    in
    assert lib.assertMsg (itoa.ITOA_CARET or null == "1" && !(itoa ? ITOA_TWO)) "overrides: itoa env ${builtins.toJSON itoa}";
    assert lib.assertMsg (libc.LIBC or null == "exact" && libcRun.LIBC or null == "exact") "overrides: libc env ${builtins.toJSON libc}";
    assert lib.assertMsg (!((envOf "shared-0.1.0-lib") ? LIBC)) "overrides: libc's env reached shared";
    assert lib.assertMsg (has "`packages.not-in-any-lockfile` matches no package") "overrides: no unmatched warning: ${builtins.toJSON ws}";
    assert lib.assertMsg (has "`packages.itoa` matches no package") "overrides: itoa >=2 should match nothing";
    assert lib.assertMsg (has "packages.app-b.test.args") "overrides: no warning for test.args";
    assert lib.assertMsg (has "targets.${native}.rustflags") "overrides: no warning for rustflags";
    assert lib.assertMsg (!(has "openssl-sys")) "overrides: a curated default warned";
    evalCheck "overrides" (builtins.toJSON ws);

  # Version requirements, against the semver crate's rules.
  version-req =
    let
      m = breakbulk.versionReq.matches;
      cases = [
        [ "1.2.3" "1.2.3" true ]
        [ "1.2.3" "1.3.0" true ]
        [ "1.2.3" "2.0.0" false ]
        [ "^0.2.3" "0.2.9" true ]
        [ "^0.2.3" "0.3.0" false ]
        [ "^0.0.3" "0.0.4" false ]
        [ "~1.2" "1.2.9" true ]
        [ "~1.2" "1.3.0" false ]
        [ "~1.2.3" "1.2.2" false ]
        [ "=1.2" "1.2.7" true ]
        [ ">=0.42.0" "0.42.0" true ]
        [ "<0.42.0" "0.41.9" true ]
        [ "<0.42.0" "0.42.0" false ]
        [ ">=1, <2" "1.9.9" true ]
        [ ">=1, <2" "2.0.0" false ]
        [ "1.*" "1.7.0" true ]
        [ "1.2.*" "1.3.0" false ]
        [ "*" "9.9.9" true ]
        [ "1.2.3" "1.2.4-alpha" false ]
        [ ">=1.2.4-alpha" "1.2.4-beta" true ]
        [ ">1.2" "1.2.9" false ]
        [ ">1.2" "1.3.0" true ]
        [ "<=1.2" "1.2.9" true ]
      ];
      bad = lib.filter (c: m (lib.elemAt c 0) (lib.elemAt c 1) != lib.elemAt c 2) cases;
    in
    assert lib.assertMsg (bad == [ ]) "version-req: wrong results for ${builtins.toJSON bad}";
    evalCheck "version-req" "ok";

  # The dev shell: CARGO_BUILD_TARGET, inputs of the packages present, and
  # the warning for CARGO_* variables.
  devshell =
    let
      shell = provided.workspaces.main.devShell;
    in
    pkgs.runCommand "devshell" { inherit (shell) shellHook; target = shell.CARGO_BUILD_TARGET or shell.env.CARGO_BUILD_TARGET or ""; } ''
      [ "$target" = ${native} ]
      export HOME=$TMPDIR CARGO_INCREMENTAL=1 CARGO_TARGET_DIR=x RUSTFLAGS=-g breakbulkOwnEnv=CARGO_BUILD_TARGET
      out_=$out
      eval "$shellHook" 2> warnings
      cat warnings
      grep -q 'CARGO_INCREMENTAL is set' warnings
      grep -q 'RUSTFLAGS is set' warnings
      ! grep -q CARGO_TARGET_DIR warnings
      touch $out_
    '';

  # Every option has a description, so the docs generate.
  options-doc = (mkRepo (fixtures + "/multi-ws") [ ]).optionsDoc.optionsCommonMark;
}
