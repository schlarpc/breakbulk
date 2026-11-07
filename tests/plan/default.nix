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
    }:
    pkgs.runCommandCC "${fixture}-golden-${kind}"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
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
  walking-skeleton-cargo = cargoBuild {
    fixture = "walking-skeleton";
    ws = walking-skeleton;
    install = "install -D $t/walking-skeleton $out/bin/walking-skeleton";
  };
in
{
  workspaces = {
    inherit walking-skeleton;
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
