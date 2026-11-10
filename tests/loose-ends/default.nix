# Loose ends, one check each. Wired into the flake's checks as
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
#   devshell     the walking skeleton with the linux preset and extra
#                rustflags: the dev shell exports CARGO_BUILD_TARGET and the
#                spec as CARGO_TARGET_<TRIPLE>_{LINKER,RUSTFLAGS}; a local
#                `cargo build -v --release` in that environment, outside any
#                home directory, gives exactly the plan's `-C metadata`
#                values, and every target unit gets the spec's linker and
#                rustflags.
#   devshell-trim-paths   the same with Cargo 1.101 (nightly): the planner
#                turns trim-paths on itself, the shell exports
#                CARGO_PROFILE_RELEASE_TRIM_PATHS=all, and local `-C
#                metadata` values again equal the plan's; the Cargo 1.99
#                shell does not export it.
#   devshell-env `devShell.env` over two packages' env: null removes a
#                variable and the shell's dependency on its derivation
#                (inputs and .drv closure), a value replaces one and is
#                not a conflict, and an unsettled conflict warns with each
#                package's value, the winner and the fix.
#   wasm-embed   the flagship pattern: a native host bin embeds (with
#                include_bytes!) the wasm component that another
#                workspace builds for wasm32 with the wasmComponent preset
#                (wasmOpt, componentize, install), through
#                `packages.host.env`. Only the host's bin and its test
#                harness name the product; the host workspace's
#                instantiation and `util`'s units do not depend on it; the
#                embedded bytes are a valid component.
#   sys-defaults-no-package-set   `sysDefaults.packages` settings do not
#                reach target units of a target without a package set
#                (wasm32-unknown-unknown); `packages` settings do.
#   cfg-rustflags  spec rustflags that turn on a `target.'cfg(…)'` key: the
#                planner asks rustc for the cfg with Cargo's rustflags and
#                puts the spec's flags under the target key; the product
#                matches local `cargo run` with the same `--config`.
#   names        two members with a bin of the same name: each package's
#                test gets its own as CARGO_BIN_EXE_tool; a bench with
#                `test = true` is `bench-<name>` in tests, testRuns and
#                checks alike.
#   runner-list  `targets.<triple>.runner` as a list (program and arguments):
#                the test run runs `env BB_RUNNER=1 <binary>`.
#   test-libs    a test run depends on the sysroot's target shared
#                libraries (a small copy), not the whole toolchain.
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
    # The tests compare a source path the library embedded at compile time
    # with the one the test run gets, which needs one view for both.
    packages.config-env.test.scopeTestsDir = false;
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

  # The walking skeleton with the linux preset (a mold linker wrapper)
  # and extra spec rustflags; the default variant (release).
  shellRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = ../fixtures/walking-skeleton;
    modules = [
      {
        workspaces.main = { };
        targets.${native} = {
          preset = breakbulk.presets.linux;
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

  # `defaultTarget` and `devShell.target` (#32): the native triple when the
  # workspace targets it, else its only target, else the project's
  # `build.target` (one triple among the targets, read from its
  # `.cargo/config.toml` files), else none: empty shortcuts, and no
  # CARGO_BUILD_TARGET, so the project's `build.target` applies locally. A
  # triple that is not one of the targets, and the removed `setTarget`,
  # fail.
  devshell-target =
    let
      # The walking skeleton with a `.cargo/config.toml` holding `config`.
      withConfig =
        config:
        let
          drv = pkgs.runCommand "walking-skeleton-config" { inherit config; } ''
            cp -r --no-preserve=mode ${../fixtures/walking-skeleton} $out
            mkdir $out/.cargo
            printf '%b\n' "$config" > $out/.cargo/config.toml
          '';
        in
        builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);
      repoOf =
        root: ws:
        (breakbulk.mkRepository {
          inherit pkgs tools root;
          modules = [ { workspaces.main = ws; } ];
        }).workspaces.main;
      plain = repoOf ../fixtures/walking-skeleton;
      uefi = {
        x86_64-unknown-uefi = { };
        aarch64-unknown-uefi = { };
      };
      targetOf = ws: (plain ws).devShell.drvAttrs.CARGO_BUILD_TARGET or null;
      fails = ws: !(builtins.tryEval (plain ws).devShell.drvPath).success;
      buildTargetOf =
        config: (repoOf (withConfig config) { targets = uefi; }).devShell.drvAttrs.CARGO_BUILD_TARGET or null;
      got = {
        native = targetOf { };
        withNative = targetOf { targets = uefi // { ${native} = { }; }; };
        only = targetOf { targets.x86_64-unknown-uefi = { }; };
        several = targetOf { targets = uefi; };
        severalPackages = (plain { targets = uefi; }).packages;
        chosen = targetOf {
          targets = uefi;
          devShell.target = "aarch64-unknown-uefi";
        };
        viaDefault = targetOf {
          targets = uefi;
          defaultTarget = "aarch64-unknown-uefi";
        };
        buildTarget = buildTargetOf ''[build]\ntarget = "aarch64-unknown-uefi"'';
        buildTargetList = buildTargetOf ''[build]\ntarget = ["aarch64-unknown-uefi"]'';
        buildTargetTwo = buildTargetOf ''[build]\ntarget = ["aarch64-unknown-uefi", "x86_64-unknown-uefi"]'';
        buildTargetOther = buildTargetOf ''[build]\ntarget = "wasm32-unknown-unknown"'';
        noBuildTarget = buildTargetOf "[build]\njobs = 2";
        notATarget = fails {
          targets = uefi;
          devShell.target = native;
        };
        defaultNotATarget = fails {
          targets = uefi;
          defaultTarget = native;
        };
        removed = fails { devShell.setTarget = false; };
      };
    in
    assert lib.assertMsg (
      got == {
        inherit native;
        withNative = native;
        only = "x86_64-unknown-uefi";
        several = null;
        severalPackages = { };
        chosen = "aarch64-unknown-uefi";
        viaDefault = "aarch64-unknown-uefi";
        buildTarget = "aarch64-unknown-uefi";
        buildTargetList = "aarch64-unknown-uefi";
        buildTargetTwo = null;
        buildTargetOther = null;
        noBuildTarget = null;
        notATarget = true;
        defaultNotATarget = true;
        removed = true;
      }
    ) "devshell-target: ${builtins.toJSON got}";
    pkgs.runCommand "devshell-target" { } "touch $out";

  # `devShell.env` over package env, in the walking skeleton (Cargo.lock
  # order: itoa, then walking-skeleton). `marker` fails to build, so a
  # shell that still needed it could not build either.
  devshellEnv =
    let
      marker = pkgs.runCommand "devshell-env-marker" { } "exit 1";
      shellOf =
        env:
        (breakbulk.mkRepository {
          inherit pkgs tools;
          root = ../fixtures/walking-skeleton;
          modules = [
            {
              workspaces.main.devShell.env = env;
              packages.itoa.env = {
                BB_X = "${marker}";
                BB_C = "from-itoa";
                BB_Y = "from-itoa";
              };
              packages.walking-skeleton.env = {
                BB_C = "from-ws";
                BB_Y = "from-ws";
              };
            }
          ];
        }).workspaces.main.devShell;
      plain = shellOf { };
      over = shellOf {
        BB_X = null;
        BB_Y = "y";
        CARGO_BUILD_TARGET = null;
      };
      inputsOf = s: lib.attrNames (builtins.getContext (builtins.toJSON s.drvAttrs));
      conflict =
        var:
        "breakbulk: the dev shell of workspace `main`: ${var} is set to different values: itoa@1.0.11 = \"from-itoa\", walking-skeleton@0.1.0 = \"from-ws\". The shell uses \"from-ws\" from walking-skeleton@0.1.0: the last value, with packages in Cargo.lock order and the target's env after them. To choose a value, set `workspaces.main.devShell.env.${var}`.";
      # The closure of the shell's .drv file: every derivation it needs.
      drvClosure = s: pkgs.closureInfo { rootPaths = [ (builtins.unsafeDiscardOutputDependency s.drvPath) ]; };
    in
    assert lib.assertMsg (
      plain.warnings == map conflict [
        "BB_C"
        "BB_Y"
      ]
    ) "devshell-env: the shell without devShell.env warns ${builtins.toJSON plain.warnings}";
    assert lib.assertMsg (over.warnings == [ (conflict "BB_C") ])
      "devshell-env: the shell with devShell.env warns ${builtins.toJSON over.warnings}";
    assert lib.assertMsg (lib.elem marker.drvPath (inputsOf plain))
      "devshell-env: the shell without devShell.env does not depend on the marker";
    assert lib.assertMsg (!(lib.elem marker.drvPath (inputsOf over)))
      "devshell-env: BB_X = null leaves the shell depending on the marker";
    over.overrideAttrs (_: {
      name = "loose-ends-devshell-env";
      phases = [ "buildPhase" ];
      markerDrv = builtins.unsafeDiscardStringContext marker.drvPath;
      plainClosure = drvClosure plain;
      overClosure = drvClosure over;
      buildPhase = ''
        grep -qxF "$markerDrv" $plainClosure/store-paths
        if grep -qxF "$markerDrv" $overClosure/store-paths; then
          echo "the shell's closure has $markerDrv" >&2; exit 1
        fi
        [ -z "''${BB_X+set}" ]
        [ -z "''${CARGO_BUILD_TARGET+set}" ]
        [ "$BB_Y" = y ]
        [ "$BB_C" = from-ws ]
        touch $out
      '';
    });

  # With Cargo 1.101 (rust-overlay's nightly) the planner
  # turns trim-paths on for the release profile itself (`trimPathsDefault`),
  # and the dev shell sets CARGO_PROFILE_RELEASE_TRIM_PATHS=all, so a local
  # `cargo build -v --release` again gives exactly the plan's `-C metadata`
  # values (trim-paths is part of the profile Cargo hashes into them). The
  # stable shell above (Cargo 1.99) does not set it.
  trimShellRust = pkgs.rust-bin.nightly.latest.minimal;
  trimShellRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = ../fixtures/walking-skeleton;
    modules = [
      {
        workspaces.main.toolchain = {
          rustc = trimShellRust;
          cargo = trimShellRust;
        };
      }
    ];
  };
  trimShellInst = trimShellRepo.workspaces.main.instances.${native}.default;
  devshellTrimPaths =
    let
      shell = trimShellRepo.workspaces.main.devShell;
      plan = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (builtins.readFile "${trimShellInst.plans.build}/plan.json")
      );
    in
    assert lib.assertMsg (plan.trimPathsDefault or false) "devshell-trim-paths: the plan has no trimPathsDefault";
    assert lib.assertMsg (
      shell.drvAttrs.CARGO_PROFILE_RELEASE_TRIM_PATHS or null == "all"
    ) "devshell-trim-paths: CARGO_PROFILE_RELEASE_TRIM_PATHS is not set";
    assert lib.assertMsg (
      !(devShell.drvAttrs ? CARGO_PROFILE_RELEASE_TRIM_PATHS)
    ) "devshell-trim-paths: the Cargo 1.99 shell sets CARGO_PROFILE_RELEASE_TRIM_PATHS";
    shell.overrideAttrs (_: {
      name = "loose-ends-devshell-trim-paths";
      phases = [ "buildPhase" ];
      plan = "${trimShellInst.plans.build}/plan.json";
      vendorConfig = trimShellInst.vendor.configFile;
      fixture = ../fixtures/walking-skeleton;
      jq = "${pkgs.jq}/bin/jq";
      buildPhase = ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode $fixture $TMPDIR/ws
        cd $TMPDIR/ws
        cargo -V
        echo "CARGO_PROFILE_RELEASE_TRIM_PATHS=$CARGO_PROFILE_RELEASE_TRIM_PATHS"
        cargo build -v --release --offline --frozen --config "$vendorConfig" 2>&1 | tee $TMPDIR/log
        grep -q -- '--remap-path-scope=all' $TMPDIR/log
        grep -o -- '-C metadata=[0-9a-f]*' $TMPDIR/log | sed 's/.*=/c-/' | sort -u > local
        $jq -r '.units | keys[] | select(startswith("c-"))' $plan | sort -u > planned
        echo "planned:"; cat planned
        diff -u planned local
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

  # --- sys-defaults-no-package-set --------------------------------------------

  # `sysDefaults.packages` on a target without a nixpkgs package set
  # (wasm32-unknown-unknown): its target units get neither the env nor a
  # capture of the inputs (which would fail for want of a package set);
  # `packages` settings still apply there.
  sysDefaultsNoSet =
    let
      repo = breakbulk.mkRepository {
        inherit pkgs tools;
        root = fixtures + "/wasm-embed";
        modules = [
          {
            workspaces.ui = {
              path = "ui";
              toolchain = {
                rustc = wasmRust;
                cargo = wasmRust;
              };
              targets = lib.mkForce { ${wasm} = { }; };
              variants.default.profile = "release";
            };
            targets.${wasm}.preset = breakbulk.presets.wasmComponent { rustc = wasmRust; };
            sysDefaults.packages.ui = _: {
              env.SYS_UI = "curated";
              inputs = p: [ p.zlib ];
            };
            packages.ui.env.USER_UI = "user";
          }
        ];
      };
      i = repo.workspaces.ui.instances.${wasm}.default;
      unit = lib.findFirst (u: u.name == "ui-0.1.0-lib") (throw "no ui lib unit") (lib.attrValues i.units.build);
      data = builtins.fromJSON (builtins.unsafeDiscardStringContext unit.drvAttrs.BREAKBULK_UNIT);
    in
    assert lib.assertMsg (
      !(data.env ? SYS_UI) && data.env.USER_UI or null == "user" && !(lib.hasInfix "no-package-set" (data.envCapture or ""))
    ) "sys-defaults-no-package-set: ui lib ${builtins.toJSON data.env} ${data.envCapture or ""}";
    pkgs.runCommand "loose-ends-sys-defaults-no-package-set" { } "touch $out";

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

  # --- names ------------------------------------------------------------------

  # Two members with a bin `tool` each: each package's integration test
  # gets its own bin as CARGO_BIN_EXE_tool (Cargo sets it for the test's
  # own package's bins). A bench with `test = true` is `bench-speed` in
  # `tests`, in `testRuns` and in `repo.checks` (`test-bench-speed`).
  namesRepo = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixtures + "/names";
    modules = [ { workspaces.main.variants.default.profile = "dev"; } ];
  };
  names =
    let
      t = namesRepo.workspaces.main.target.${native};
      runs = t.namedTestRuns.a;
      check = "main/${native}/a/test-bench-speed";
    in
    assert lib.assertMsg (t.tests.a ? bench-speed)
      "names: tests.a has ${toString (lib.attrNames t.tests.a)}";
    assert lib.assertMsg (runs ? bench-speed)
      "names: the named test runs of a are ${toString (lib.attrNames runs)}";
    assert lib.assertMsg (namesRepo.checks ? ${check})
      "names: no check ${check} among ${toString (lib.attrNames namesRepo.checks)}";
    pkgs.runCommand "loose-ends-names"
      {
        a = runs.runs_tool;
        b = t.namedTestRuns.b.runs_tool;
        bench = runs.bench-speed;
      }
      ''
        grep -q 'test own_tool ... ok' $a/log
        grep -q 'test own_tool ... ok' $b/log
        grep -q 'test bench_as_test ... ok' $bench/log
        touch $out
      '';

  # --- runner-list ------------------------------------------------------------

  # `targets.<triple>.runner` as a list (program and arguments, as Cargo's
  # runner array): `env BB_RUNNER=1 <binary> <args…>`.
  runnerList =
    let
      repo = breakbulk.mkRepository {
        inherit pkgs tools;
        root = fixtures + "/names";
        modules = [
          {
            workspaces.main.variants.default.profile = "dev";
            targets.${native}.runner = [
              "${pkgs.coreutils}/bin/env"
              "BB_RUNNER=1"
            ];
          }
        ];
      };
      t = repo.workspaces.main.target.${native};
    in
    assert lib.assertMsg (t.runner == [
      "${pkgs.coreutils}/bin/env"
      "BB_RUNNER=1"
    ]) "runner-list: the runner is ${builtins.toJSON t.runner}";
    t.namedTestRuns.a.runs_tool;

  # --- test-libs --------------------------------------------------------------

  # A test run depends on the sysroot's target libraries only
  # (a small copy), not on the whole Rust toolchain.
  testLibs =
    let
      t = namesRepo.workspaces.main.target.${native};
      run = t.namedTestRuns.a.runs_tool;
      sysroot = pkgs.rustc.unwrapped or pkgs.rustc;
      libs = breakbulk.testRuns.testLibs pkgs sysroot native;
      inputs = lib.attrNames (builtins.getContext (builtins.toJSON run.drvAttrs));
    in
    assert lib.assertMsg (!(lib.elem sysroot.drvPath inputs))
      "test-libs: the test run depends on the whole sysroot ${sysroot.drvPath}";
    assert lib.assertMsg (lib.elem libs.drvPath inputs)
      "test-libs: the test run does not depend on ${libs.drvPath}: ${toString inputs}";
    pkgs.runCommand "loose-ends-test-libs"
      {
        inherit run libs;
        closure = pkgs.closureInfo { rootPaths = [ libs ]; };
        sysroot = builtins.unsafeDiscardStringContext sysroot.outPath;
      }
      ''
        ls $libs/lib/rustlib/${native}/lib/libstd-*.so
        if grep -qxF "$sysroot" $closure/store-paths; then
          echo "the test libraries reference the sysroot" >&2; exit 1
        fi
        du -sh $libs
        touch $out
      '';
in
{
  config-env = configEnv;
  test-scope = testScope;
  inherit devshell;
  devshell-trim-paths = devshellTrimPaths;
  inherit devshell-target;
  devshell-env = devshellEnv;
  wasm-embed = wasmEmbedCheck;
  sys-defaults-no-package-set = sysDefaultsNoSet;
  cfg-rustflags = cfgRustflags;
  inherit names;
  runner-list = runnerList;
  test-libs = testLibs;
  workspaces = {
    config-env = configEnvWs;
    test-scope = withScope;
    devshell = shellRepo;
    wasm-embed = wasmEmbed;
    cfg-rustflags = cfgRepo;
    names = namesRepo;
  };
}
