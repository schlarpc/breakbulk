# Instantiation in IFD mode, driven by the hand-written plan of
# tests/unit-smoke: plan.json -> breakbulk-instantiate -> units.json ->
# derivations, built and run.
#
#   nix-build tests/instantiate -A check
#
# Attributes:
#   check        builds the plan's root through instantiation and runs it;
#                builds the skipped-test stub
#   eval-checks  evaluation-time assertions (needs IFD):
#                - BREAKBULK_UNIT of every unit equals what
#                  tests/unit-smoke/default.nix renders directly (with unit
#                  output paths mapped between the two);
#                - re-instantiating from a reformatted plan (a different
#                  instantiate derivation) gives the same unit .drv paths;
#                - a new source view for smokeapp, or a new env value,
#                  leaves the instantiate derivation unchanged, and changes
#                  only the units that use it;
#                - tools, sources and env captures that cannot be built do
#                  not stop instantiation: nothing but the plan and the
#                  instantiate binary is realised before units.json is read;
#                - stubs for predicted roots the plan lacks, and
#                  predictedRoots over the fixture's manifests.
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
  root = ../..;
  smoke = import ../unit-smoke { inherit pkgs; };
  system = pkgs.stdenv.buildPlatform.system;

  breakbulk-instantiate = pkgs.rustPlatform.buildRustPackage {
    pname = "breakbulk-instantiate";
    version = "0.1.0";
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/Cargo.toml")
        (root + "/Cargo.lock")
        (lib.fileset.difference (root + "/crates") (root + "/crates/breakbulk-drv"))
        # The crate's tests read the smoke plan.
        (root + "/tests/unit-smoke/plan.json")
      ];
    };
    cargoLock.lockFile = root + "/Cargo.lock";
    cargoBuildFlags = [
      "-p"
      "breakbulk-instantiate"
    ];
    doCheck = false;
  };

  # The smoke plan names rustc by a token; a real plan has its store path.
  # Context is dropped, as a plan derivation's output would carry none here.
  planText =
    rustc:
    builtins.unsafeDiscardStringContext (
      builtins.replaceStrings [ "@bb:rustc@" ] [ "${rustc}/bin/rustc" ] (
        builtins.readFile ../unit-smoke/plan.json
      )
    );
  plan = builtins.toFile "plan.json" (planText pkgs.rustc);

  predicted = {
    variant = "dev";
    roots = [
      {
        package = "smokeapp";
        target = "smokeapp";
        kind = "bin";
        test = false;
        requiredFeatures = null;
      }
      {
        package = "smokeapp";
        target = "admin-cli";
        kind = "bin";
        test = false;
        requiredFeatures = [ "cli" ];
      }
      {
        package = "smokeapp";
        target = "it";
        kind = "test";
        test = true;
        requiredFeatures = null;
      }
    ];
  };

  args = {
    breakbulkInstantiate = breakbulk-instantiate;
    inherit system plan;
    sources.workspace = {
      smokelib = smoke.src;
      smokeapp = smoke.src;
    };
    tools = {
      rustc = pkgs.rustc;
      breakbulk-unit = "${smoke.breakbulk-unit}/bin/breakbulk-unit";
      shell = "${pkgs.bash}/bin/bash";
    };
    host.envCapture = smoke.capture;
    target.envCapture = smoke.capture;
    roots = predicted;
    targetTraits = breakbulk.targetTraits.forRust (
      breakbulk.targetTraits.resolve { triple = "x86_64-unknown-linux-gnu"; }
    );
    # No `--remap-path-scope`, as in unit-smoke's direct rendering, which
    # gives no unit a scope (host units would otherwise get one).
    capabilities =
      (breakbulk.toolchainFacts.of {
        inherit pkgs;
        inherit (pkgs) rustc cargo;
      }).capabilities
      // {
        remapPathScope = false;
      };
  };

  inst = breakbulk.instantiate args;
  app = inst.roots."smokeapp/bin/smokeapp";
  run = inst.units.r-smokelib-63aa584f9c6a6c6c;

  ids = lib.attrNames smoke.units;
  drvPaths = i: lib.genAttrs ids (id: i.units.${id}.drvPath);
  outPathsOf = i: lib.concatMap (id: map (o: i.units.${id}.${o}.outPath) i.units.${id}.outputs) ids;

  # --- re-instantiation ------------------------------------------------------

  # The same plan, reformatted: a different file, so a different
  # instantiate derivation that really runs again.
  reformatted = breakbulk.instantiate (
    args
    // {
      plan = builtins.toFile "plan-compact.json" (builtins.toJSON (builtins.fromJSON (planText pkgs.rustc)));
    }
  );

  # smokeapp gets its own source view; a target env value is added in both.
  withEnv = v: {
    target = {
      envCapture = smoke.capture;
      env.SMOKE_MARKER = v;
    };
  };
  # List-like variables: the package override (layer 5) appends to the
  # toolchain spec (layer 4); empty layers leave no separator.
  listEnv = breakbulk.instantiate (
    args
    // {
      target = {
        envCapture = smoke.capture;
        env = {
          PATH = "${pkgs.hello}/bin";
          NIX_CFLAGS_COMPILE = "";
          PKG_CONFIG_PATH = "/spec";
          SMOKE_MARKER = "spec";
        };
      };
      overrides.smokelib.target.env = {
        PATH = "${pkgs.cowsay}/bin";
        NIX_CFLAGS_COMPILE = "-DFROM_OVERRIDE";
        PKG_CONFIG_PATH = "";
        SMOKE_MARKER = "override";
      };
    }
  );
  listEnvLib = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (unitText listEnv "c-a0e9aa7440d71279")
  );
  envA = breakbulk.instantiate (args // withEnv "a");
  envB = breakbulk.instantiate (args // withEnv "b \"quoted\"\n");
  appView = breakbulk.instantiate (
    args
    // {
      sources.workspace = args.sources.workspace // {
        smokeapp = builtins.path {
          path = ../unit-smoke/fixture;
          name = "unit-smoke-app-source";
        };
      };
    }
  );

  # Tools, sources and captures that fail to build. Instantiation and the
  # unit .drv paths must not need any of them built.
  broken = name: pkgs.runCommand "broken-${name}" { } "echo ${name} must not be built; exit 1";
  brokenRustc = broken "rustc";
  unbuildable = breakbulk.instantiate (
    args
    // {
      plan = builtins.toFile "plan-broken.json" (planText brokenRustc);
      tools = args.tools // {
        rustc = brokenRustc;
        breakbulk-unit = "${broken "breakbulk-unit"}/bin/breakbulk-unit";
        shell = "${broken "shell"}/bin/bash";
      };
      sources.workspace = {
        smokelib = broken "smokelib-source";
        smokeapp = broken "smokeapp-source";
      };
      host.envCapture = broken "host-capture";
      target.envCapture = broken "target-capture";
    }
  );

  unitText = i: id: i.units.${id}.drvAttrs.BREAKBULK_UNIT;
  changed = a: b: lib.filter (id: a.units.${id}.drvPath != b.units.${id}.drvPath) ids;

  assertions = {
    # The same unit text as direct rendering: map this instantiation's unit
    # output paths to unit-smoke's (its derivations have other names). The
    # remap list is sorted by path, so its order follows the store hashes.
    same-as-direct-rendering = lib.all (
      id:
      let
        parse =
          s:
          let
            j = builtins.fromJSON (builtins.unsafeDiscardStringContext s);
          in
          j // { remap = lib.sort lib.lessThan (j.remap or [ ]); };
      in
      parse (builtins.replaceStrings (outPathsOf inst) (outPathsOf smoke) (unitText inst id))
      == parse (unitText smoke id)
    ) ids;
    names =
      map (id: inst.units.${id}.name) ids == [
        "smokelib-0.1.0-build-script"
        "smokelib-0.1.0-lib"
        "smokeapp-0.1.0-bin"
        "smokelib-0.1.0-build-run"
      ];
    stable-across-reinstantiation =
      reformatted.unitsJson.drvPath != inst.unitsJson.drvPath && drvPaths reformatted == drvPaths inst;
    env-values-do-not-rerun-instantiate =
      envA.unitsJson.drvPath == envB.unitsJson.drvPath
      # The build script compiles for the host: unchanged.
      && changed envA envB == [
        "c-a0e9aa7440d71279"
        "c-a6654c0a89d81026"
        "r-smokelib-63aa584f9c6a6c6c"
      ]
      && lib.hasInfix ''"SMOKE_MARKER":"b \"quoted\"\n"'' (unitText envB "c-a6654c0a89d81026");
    list-like-env-appends =
      listEnvLib.env.PATH == "${pkgs.hello}/bin:${pkgs.cowsay}/bin"
      && listEnvLib.env.NIX_CFLAGS_COMPILE == "-DFROM_OVERRIDE"
      && listEnvLib.env.PKG_CONFIG_PATH == "/spec"
      && listEnvLib.env.SMOKE_MARKER == "override"
      # The joined values keep their context: both PATH entries are inputs.
      && lib.all (p: builtins.getContext (unitText listEnv "c-a0e9aa7440d71279") ? ${builtins.unsafeDiscardStringContext p.drvPath}) [
        pkgs.hello
        pkgs.cowsay
      ];
    source-views-do-not-rerun-instantiate =
      appView.unitsJson.drvPath == inst.unitsJson.drvPath && changed inst appView == [ "c-a6654c0a89d81026" ];
    nothing-else-realised = builtins.deepSeq (drvPaths unbuildable) true;
    builder = inst.units.c-a6654c0a89d81026.builder == "${smoke.breakbulk-unit}/bin/breakbulk-unit";
    # A short unit text stays in the environment; the attribute is there
    # all the same.
    no-pass-as-file = inst.units.c-a6654c0a89d81026.drvAttrs.passAsFile == [ ];
    # The fixture's own prediction for the build plan is the one root above.
    predicted-from-manifests =
      (breakbulk.predictedRoots {
        workspaceRoots = breakbulk.roots.workspaceRoots { root = ../unit-smoke/fixture; };
        planKind = "build";
        variant = "dev";
      }) == {
        variant = "dev";
        roots = [ (builtins.head predicted.roots) ];
      };
    stubs =
      inst.roots."smokeapp/bin/admin-cli".breakbulkRoot.reason
      == "`admin-cli` was not built by Cargo in variant `dev`: required features `[cli]` not enabled"
      && inst.roots."smokeapp/test/it".breakbulkRoot.reason
        == "`it` was skipped: not built by Cargo in variant `dev`: Cargo did not select it"
      && app.breakbulkRoot.unit == "c-a6654c0a89d81026"
      && app.outPath == inst.units.c-a6654c0a89d81026.out.outPath;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) assertions);
in
{
  inherit
    breakbulk-instantiate
    inst
    unbuildable
    assertions
    ;

  eval-checks =
    if failed == [ ] then
      pkgs.runCommand "instantiate-eval-checks" { } "touch $out"
    else
      throw "tests/instantiate: failed: ${lib.concatStringsSep ", " failed}";

  # The root built through instantiation runs, and keeps no source or
  # OUT_DIR path; the skipped-test stub builds and logs its reason.
  check =
    pkgs.runCommand "instantiate-check"
      {
        disallowedReferences = [
          smoke.src
          run.out
        ];
      }
      ''
        mkdir -p $out/bin
        cp ${app}/smokeapp $out/bin/smokeapp
        $out/bin/smokeapp | tee $out/log
        grep -qx 'smoke ok: hello-from-build 42 c=6' $out/log
        grep -q 'smoke_cfg' ${run.flags}/directives.json
        grep -qx '`it` was skipped: .*' ${inst.roots."smokeapp/test/it"}
      '';
}
