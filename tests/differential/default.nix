# The directive differential test ("Testing and conformance", item 3, in
# docs/implementation.md), property-test style.
#
# For each seed, gen.py writes a random workspace: path crates only (no
# network), with normal, build and dev dependencies, proc macros, `links`
# chains, cdylibs, and build scripts printing randomized directives
# (several values per kind, duplicates, link-search paths inside and
# outside OUT_DIR and inside a links dependency's OUT_DIR, both syntaxes,
# mixed order), sometimes with a `links` override in .cargo/config.toml.
# Then, in one sandbox:
#
#   1. breakbulk-plan traces the build plan and the test plan, its stubs
#      printing sentinels where the real scripts print values;
#   2. real `cargo build -vv`, `cargo test --no-run -vv` and
#      `cargo test --doc -vv` build the same sources at the same location
#      (/build/skeleton), running the real build scripts;
#   3. breakbulk-plan-golden --env renders each plan into the real build's
#      layout, expands every splice with breakbulk-unit's own code (argv,
#      rustc-env, DEP_* metadata, dynamic-library paths, the doctests' -L
#      list) from the real scripts' output, and compares argv and env unit
#      by unit, doctests included.
#
# The negative control expands with search paths not ordered by class; the
# aggregate check requires it to find differences in at least half of the
# seeds, so the comparison is not vacuous.
#
# Units are matched by `-C metadata` (compiles) and by OUT_DIR hash (runs),
# so equal unit sets also show that sentinels change no unit's identity.
#
#   nix build -f tests/differential                 # the default seeds
#   nix build -f tests/differential seeds.s17       # one seed
#   python3 tests/differential/gen.py --seed 17 --out /tmp/ws   # look at one
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
  tools ? breakbulk.mkTools pkgs,
  toolchain ? { inherit (pkgs) cargo rustc; },
  # How many seeds the aggregate check runs: 1 .. count.
  count ? 32,
}:
let
  inherit (pkgs) lib;
  target = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  inherit (toolchain) cargo rustc;

  one =
    seed:
    pkgs.runCommandCC "differential-${toString seed}"
      {
        nativeBuildInputs = [
          cargo
          rustc
          pkgs.python3
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        # The planner's canonical skeleton location, also for the real build.
        sk=$NIX_BUILD_TOP/skeleton
        mkdir -p $out
        python3 ${./gen.py} --seed ${toString seed} --out $sk --triple ${target} | tee $out/summary
        cd $sk
        cargo generate-lockfile --offline 2> /dev/null
        cargo metadata --format-version 1 --offline > $TMPDIR/metadata.json

        for kind in build test; do
          ${tools.breakbulk-plan}/bin/breakbulk-plan \
            --cargo ${cargo}/bin/cargo --rustc ${rustc}/bin/rustc --rustdoc ${rustc}/bin/rustdoc \
            --shim ${tools.breakbulk-shim}/bin/breakbulk-shim \
            --skeleton $sk --canonical-root /build/skeleton \
            --kind $kind --target ${target} --profile dev \
            --scratch $NIX_BUILD_TOP/scratch-$kind \
            --forbid $NIX_BUILD_TOP --forbid $HOME \
            --out $out/plan-$kind.json
        done

        # As the plan records them: build scripts get RUSTC and RUSTDOC
        # as Cargo was configured.
        export RUSTC=${rustc}/bin/rustc RUSTDOC=${rustc}/bin/rustdoc
        common=(--workspace --offline --frozen --target ${target} --profile dev -vv)
        cargo build "''${common[@]}" --config "build.target-dir=\"$TMPDIR/t-build\"" \
          > $out/build.stdout 2> $out/build.log || { cat $out/build.log; exit 1; }
        cargo test --no-run "''${common[@]}" --config "build.target-dir=\"$TMPDIR/t-test\"" \
          > $out/test.stdout 2> $out/test.log || { cat $out/test.log; exit 1; }
        # Doctests, over the test build: compiles and runs every
        # `rustdoc --test` (the test plan traced them without running).
        cargo test --doc "''${common[@]}" --config "build.target-dir=\"$TMPDIR/t-test\"" \
          > $out/doc.stdout 2> $out/doc.log || { cat $out/doc.stdout $out/doc.log; exit 1; }
        docs_build=()
        docs_test=(--doc-log $out/doc.log)

        ok=1
        for kind in build test; do
          docs=docs_$kind[@]
          ${tools.breakbulk-plan}/bin/breakbulk-plan-golden --env "''${!docs}" \
            --plan $out/plan-$kind.json --log $out/$kind.log \
            --target-dir $TMPDIR/t-$kind --metadata $TMPDIR/metadata.json \
            > $out/report-$kind || ok=0
          echo "seed ${toString seed} $kind: $(head -1 $out/report-$kind)"
          # The negative control: with search paths not ordered by class,
          # the comparison must find differences (when the seed has both
          # classes); counted by the aggregate check.
          if ! ${tools.breakbulk-plan}/bin/breakbulk-plan-golden --env --negative-control "''${!docs}" \
            --plan $out/plan-$kind.json --log $out/$kind.log \
            --target-dir $TMPDIR/t-$kind --metadata $TMPDIR/metadata.json \
            > $out/negative-$kind; then
            echo "$kind" >> $out/negative-detected
          fi
        done
        if [ $ok = 0 ]; then
          cat $out/summary $out/report-build $out/report-test
          echo "reproduce: python3 tests/differential/gen.py --seed ${toString seed} --out DIR"
          exit 1
        fi
      '';

  seeds = lib.listToAttrs (map (s: lib.nameValuePair "s${toString s}" (one s)) (lib.range 1 count));
in
{
  inherit seeds one;
  differential = pkgs.runCommand "differential-check" { reports = lib.attrValues seeds; } ''
    mkdir -p $out
    n=0; detected=0
    for r in $reports; do
      cat $r/summary >> $out/summary
      head -1 $r/report-build $r/report-test >> $out/reports
      n=$((n + 1))
      if [ -e $r/negative-detected ]; then detected=$((detected + 1)); fi
    done
    cat $out/reports
    echo "negative control: differences found in $detected of $n seeds" | tee $out/negative
    # Not vacuous: most seeds print search paths of both classes.
    [ $((detected * 2)) -ge $n ]
  '';
}
