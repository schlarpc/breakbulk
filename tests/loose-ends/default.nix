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
#   devshell     the walking skeleton with the linuxGnu preset and extra
#                rustflags: the dev shell exports CARGO_BUILD_TARGET and the
#                spec as CARGO_TARGET_<TRIPLE>_{LINKER,RUSTFLAGS}; a local
#                `cargo build -v --release` in that environment, outside any
#                home directory, gives exactly the plan's `-C metadata`
#                values, and every target unit gets the spec's linker and
#                rustflags.
#   wasm-embed   the flagship pattern: a native host bin embeds (with
#                include_bytes!) the wasm component that another
#                workspace builds for wasm32 with the wasmComponent preset
#                (wasmOpt, componentize, install), through
#                `packages.host.env`. Only the host's bin and its test
#                harness name the product; the host workspace's
#                instantiation and `util`'s units do not depend on it; the
#                embedded bytes are a valid component.
#   cfg-rustflags  spec rustflags that turn on a `target.'cfg(…)'` key: the
#                planner asks rustc for the cfg with Cargo's rustflags and
#                puts the spec's flags under the target key; the product
#                matches local `cargo run` with the same `--config`.
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

  # --- devshell ---------------------------------------------------------------

  # The walking skeleton with the linuxGnu preset (a mold linker wrapper)
  # and extra spec rustflags; the default variant (release).
  shellRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = ../fixtures/walking-skeleton;
    modules = [
      {
        workspaces.main = { };
        targets.${native} = {
          preset = breakbulk.presets.linuxGnu;
          rustflags = [
            "--cfg"
            "bb_devshell"
          ];
        };
      }
    ];
  };
  shellInst = shellRepo.workspaces.main.instances.${native}.default;
  devShell = shellRepo.workspaces.main.devShell;

  # Local `cargo build -v --release` in the dev shell's environment (the
  # shell derivation, made buildable), staged outside any home directory,
  # with the planner's source replacement so it builds offline. The set of
  # `-C metadata` values equals the plan's compile unit keys, and every
  # target unit gets the spec's linker and rustflags.
  devshell =
    let
      envVar = "CARGO_TARGET_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] native)}";
      shellEnv = devShell.drvAttrs;
    in
    assert lib.assertMsg (
      shellEnv.CARGO_BUILD_TARGET or null == native
    ) "devshell: CARGO_BUILD_TARGET is not set";
    assert lib.assertMsg (
      (shellEnv."${envVar}_RUSTFLAGS" or null) == "--cfg bb_devshell"
    ) "devshell: ${envVar}_RUSTFLAGS is ${builtins.toJSON (shellEnv."${envVar}_RUSTFLAGS" or null)}";
    assert lib.assertMsg (shellEnv ? "${envVar}_LINKER") "devshell: ${envVar}_LINKER is not set";
    devShell.overrideAttrs (_: {
      name = "loose-ends-devshell";
      phases = [ "buildPhase" ];
      plan = "${shellInst.plans.build}/plan.json";
      vendorConfig = shellInst.vendor.configFile;
      fixture = ../fixtures/walking-skeleton;
      jq = "${pkgs.jq}/bin/jq";
      buildPhase = ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode $fixture $TMPDIR/ws
        cd $TMPDIR/ws
        echo "$CARGO_BUILD_TARGET ''$${envVar}_LINKER ''$${envVar}_RUSTFLAGS"
        cargo build -v --release --offline --frozen --config "$vendorConfig" 2>&1 | tee $TMPDIR/log
        grep -o -- '-C metadata=[0-9a-f]*' $TMPDIR/log | sed 's/.*=/c-/' | sort -u > local
        $jq -r '.units | keys[] | select(startswith("c-"))' $plan | sort -u > planned
        echo "planned:"; cat planned
        diff -u planned local
        # Target units (those built with --target) carry the spec.
        grep -- '--target ${native}' $TMPDIR/log | grep -v 'build_script_build' > target-lines
        [ -s target-lines ]
        while read -r l; do
          case "$l" in *"-C linker=''$${envVar}_LINKER"*) ;; *) echo "no spec linker: $l" >&2; exit 1 ;; esac
          case "$l" in *"--cfg bb_devshell"*) ;; *) echo "no spec rustflags: $l" >&2; exit 1 ;; esac
        done < target-lines
        mkdir -p $out
        cp local $out/
      '';
    });

  # --- wasm-embed -------------------------------------------------------------

  wasm = "wasm32-unknown-unknown";
  wasmRust = pkgs.rust-bin.stable."1.99.0".minimal.override { targets = [ wasm ]; };
  # The `ui` workspace builds only for wasm32 with the wasmComponent preset;
  # the `host` workspace (native) embeds its product through
  # `packages.host.env`, a reference to another workspace's product.
  wasmEmbed =
    let
      repo = breakbulk.mkRepository {
        inherit pkgs tools;
        root = fixtures + "/wasm-embed";
        modules = [
          {
            workspaces = {
              ui = {
                path = "ui";
                toolchain = {
                  rustc = wasmRust;
                  cargo = wasmRust;
                };
                targets = lib.mkForce { ${wasm} = { }; };
                variants.default.profile = "release";
              };
              host = {
                path = "host";
                variants.default.profile = "dev";
              };
            };
            targets.${wasm}.preset = breakbulk.presets.wasmComponent { rustc = wasmRust; };
            packages.host.env.UI_WASM = "${repo.workspaces.ui.target.${wasm}.packages.ui}/pkg/ui.wasm";
          }
        ];
      };
    in
    repo;

  wasmEmbedCheck =
    let
      i = wasmEmbed.workspaces.host.instances.${native}.default;
      ui = wasmEmbed.workspaces.ui.target.${wasm}.packages.ui;
      uiOut = builtins.unsafeDiscardStringContext ui.outPath;
      units = lib.attrValues i.units.build ++ lib.attrValues i.units.test;
      naming = lib.sort lib.lessThan (
        lib.unique (map (u: u.name) (lib.filter (u: lib.hasInfix uiOut (u.drvAttrs.BREAKBULK_UNIT or "")) units))
      );
      drvOnly = d: builtins.unsafeDiscardOutputDependency d.drvPath;
      util = lib.filter (u: lib.hasPrefix "util-" u.name) units;
    in
    assert lib.assertMsg (
      naming == [
        "host-0.1.0-bin"
        "host-0.1.0-test"
      ]
    ) "wasm-embed: units naming the product: ${builtins.toJSON naming}";
    pkgs.runCommand "loose-ends-wasm-embed"
      {
        nativeBuildInputs = [ pkgs.wasm-tools ];
        host = wasmEmbed.workspaces.host.packages.host;
        uiDrv = builtins.unsafeDiscardStringContext ui.drvPath;
        # Neither the host workspace's instantiation nor `util`'s units may
        # depend on the wasm product; the host bin must.
        exportReferencesGraph = [
          "instBuild"
          (drvOnly i.unitsJson.build)
          "instTest"
          (drvOnly i.unitsJson.test)
          "chainHost"
          (drvOnly (lib.findFirst (u: u.name == "host-0.1.0-bin") null units))
        ]
        ++ lib.concatLists (
          lib.imap0 (n: u: [
            "util${toString n}"
            (drvOnly u)
          ]) util
        );
      }
      ''
        set -euo pipefail
        for g in instBuild instTest util*; do
          if grep -qxF "$uiDrv" "$g"; then
            echo "$g depends on the wasm product $uiDrv" >&2
            exit 1
          fi
        done
        grep -qxF "$uiDrv" chainHost
        $host/bin/host $TMPDIR/ui.wasm | tee run.txt
        grep -q '^host embeds a component of [0-9]* bytes$' run.txt
        wasm-tools validate --features component-model $TMPDIR/ui.wasm
        wasm-tools component wit $TMPDIR/ui.wasm
        mkdir -p $out
        cp run.txt $out/
      '';

  # --- cfg-rustflags ----------------------------------------------------------

  # The spec's `--cfg bb_spec` turns on the project's `target.'cfg(bb_spec)'`
  # key, which replaces `build.rustflags`. The planner asks rustc for the
  # cfg with the rustflags Cargo would use, so it puts the spec's flags
  # under the target key; with them under `build`, Cargo drops them and
  # planning fails. The product prints what local Cargo's does with the
  # same `--config`.
  cfgRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/cfg-rustflags";
    modules = [
      {
        workspaces.main = { };
        targets.${native}.rustflags = [
          "--cfg"
          "bb_spec"
        ];
      }
    ];
  };
  cfgRustflags =
    pkgs.runCommandCC "loose-ends-cfg-rustflags"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
        ];
        product = cfgRepo.workspaces.main.packages.cfg-rustflags;
        fixture = fixtures + "/cfg-rustflags";
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode $fixture ws
        cd ws
        cargo run -q --offline --frozen --target ${native} \
          --config 'target.${native}.rustflags=["--cfg","bb_spec"]' > want
        $product/bin/cfg-rustflags > got
        cat got
        diff -u want got
        [ "$(cat got)" = "spec=true key=true build=false" ]
        mkdir -p $out
        cp got $out/
      '';

  # --- docs/options.md --------------------------------------------------------

  # The module options as Markdown (mkRepository's optionsDoc).
  optionsMd = pkgs.runCommand "breakbulk-options.md" { } ''
    {
      echo '# breakbulk: options'
      echo
      echo 'Generated from the module options (`repo.optionsDoc`). Do not edit.'
      echo 'Regenerate with `tests/loose-ends/update-options-doc.sh`.'
      echo
      cat ${shellRepo.optionsDoc.optionsCommonMark}
    } > $out
  '';
in
{
  # Builds the generated Markdown; `options-doc-in-sync` compares it.
  options-md = optionsMd;
  options-doc-in-sync =
    pkgs.runCommand "options-doc-in-sync"
      {
        committed = ../../docs/options.md;
      }
      ''
        if ! diff -u $committed ${optionsMd}; then
          echo "docs/options.md is out of date; run tests/loose-ends/update-options-doc.sh" >&2
          exit 1
        fi
        touch $out
      '';
  config-env = configEnv;
  test-scope = testScope;
  inherit devshell;
  wasm-embed = wasmEmbedCheck;
  cfg-rustflags = cfgRustflags;
  workspaces = {
    config-env = configEnvWs;
    test-scope = withScope;
    devshell = shellRepo;
    wasm-embed = wasmEmbed;
    cfg-rustflags = cfgRepo;
  };
}
