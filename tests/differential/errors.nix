# The directive error paths against real Cargo: the counterpart of the
# value differential test for the outputs Cargo rejects or warns about.
#
# tests/fixtures/directive-errors is one package per case, each build
# script printing fixed bytes (unknown `cargo::` keys, RUSTC_BOOTSTRAP,
# rustc-flags, rustc-link-arg-* naming no target, `cargo::error=` with
# Cargo's streaming rules, the `cargo::` rust-version gate, a failing
# exit, and controls that succeed). For each case the check runs, with the
# same toolchain:
#
#   1. real `cargo build -p <case>`;
#   2. the case's run unit as breakbulk planned it, through
#      `breakbulk-unit unit` (as its derivation would, but in this sandbox,
#      so a failure can be compared);
#
# and requires the same outcome: success or failure, and the same lines
# after Cargo's progress lines, up to the script's output that both print
# after a failure. Cargo describes a path package with its path
# (`app v0.1.0 (/build/skeleton/app)`), breakbulk without, and the build
# script executables lie elsewhere; the comparison drops both paths.
{
  pkgs,
  breakbulk,
  tools,
  # label -> { cargo, rustc, capabilities ? { } }
  toolchains,
}:
let
  inherit (pkgs) lib;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  fixture = ../fixtures/directive-errors;
  cases = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir fixture));

  repoFor =
    toolchain:
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixture;
      modules = [
        {
          workspaces.main = {
            path = ".";
            toolchain = {
              inherit (toolchain) rustc cargo;
              capabilities = toolchain.capabilities or { };
            };
            variants.default.profile = "dev";
          };
        }
      ];
    };

  check =
    label: toolchain:
    let
      units = lib.attrValues (repoFor toolchain).workspaces.main.instances.${native}.default.units.build;
      # The rendered BREAKBULK_UNIT of the case's run unit.
      runOf =
        case:
        let
          matching = lib.filter (
            u:
            let
              r = builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT);
            in
            r.kind == "run" && lib.hasSuffix "/${case}#0.1.0" r.package
          ) units;
        in
        assert lib.assertMsg (lib.length matching == 1) "directive-errors: no single run unit for ${case}";
        (lib.head matching).drvAttrs.BREAKBULK_UNIT;
    in
    pkgs.runCommandCC "differential-errors-${lib.optionalString (label != "default") "${label}-"}check"
      (
        {
          nativeBuildInputs = [
            toolchain.cargo
            toolchain.rustc
          ];
          cases = toString cases;
        }
        // lib.listToAttrs (map (c: lib.nameValuePair "unit_${lib.replaceStrings [ "-" ] [ "_" ] c}" (runOf c)) cases)
      )
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        # The planner's skeleton location, so both name the same paths.
        ws=$NIX_BUILD_TOP/skeleton
        cp -r --no-preserve=mode ${fixture} $ws
        mkdir -p $out

        # A log's outcome: `ok` or `failed`, then its lines without
        # progress lines and from the script's output on.
        outcome() {
          if [ "$1" = 0 ]; then echo ok; else echo failed; fi
          sed -E \
            -e 's/ v([0-9][^ ]*) \([^)]*\)/ v\1/g' \
            -e 's/(exit successfully: )`[^`]*`/\1`<build script>`/' \
            -e '/^ *(Compiling|Finished|Running|Locking|Blocking|Updating) /d' \
            -e '/^  --- (stdout|stderr)/,$d' \
            "$2"
        }

        fail=0
        for case in $cases; do
          rc=0
          (cd $ws && cargo build --offline --frozen -p "$case" --target-dir $TMPDIR/t) \
            > $out/$case.cargo.log 2>&1 || rc=$?
          outcome $rc $out/$case.cargo.log > $out/$case.cargo

          unit=unit_''${case//-/_}
          rc=0
          BREAKBULK_UNIT="''${!unit}" out=$TMPDIR/o-$case flags=$TMPDIR/f-$case \
            ${tools.breakbulk-unit}/bin/breakbulk-unit unit > $out/$case.breakbulk.log 2>&1 || rc=$?
          outcome $rc $out/$case.breakbulk.log > $out/$case.breakbulk

          if diff -u $out/$case.cargo $out/$case.breakbulk > $out/$case.diff; then
            echo "same: $case ($(head -1 $out/$case.cargo))"
          else
            echo "DIFFERENT: $case"
            cat $out/$case.cargo.log $out/$case.diff
            fail=1
          fi
        done
        exit $fail
      '';
in
lib.mapAttrs check toolchains
