# Stable test-run inputs for content-addressed cutoff (decision 61), over
# tests/fixtures/test-cutoff: `alpha` has a test and a build script that
# sets `rustc-env`; `beta`, unrelated, has a build script whose OUT_DIR is a
# search path (so it is on every test's dynamic-library path, as Cargo
# does) and holds a subdirectory.
#
#   nix build -f tests/test-cutoff stable-inputs
#   tests/test-cutoff/run.sh        content-addressed, in a private store
#
#   stable-inputs   (flake check) alpha's test passes with the stable
#                   inputs of lib/test-runs.nix `stableSpec` (built here
#                   input-addressed, as stock Nix cannot build CA): its
#                   dynamic-library path holds copies of beta's library
#                   files, not beta's OUT_DIR, and no subdirectory;
#                   ALPHA_STAMP comes from the copied `rustc-env` values.
#                   With `ca` off, test runs do not use the stable inputs.
#   runs.before, runs.after
#                   the test runs, before and after an edit to beta's
#                   source (which rebuilds beta's build script but changes
#                   nothing alpha's test reads); run.sh builds them with
#                   `ca = true` and checks alpha's test run is not re-run.
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
  # null: automatic (off on stock Nix); run.sh passes true.
  ca ? null,
}:
let
  inherit (pkgs) lib;
  fixture = ../fixtures/test-cutoff;
  tools = breakbulk.mkTools pkgs;

  mk =
    root:
    breakbulk.mkWorkspace pkgs {
      inherit root tools ca;
      name = "test-cutoff";
    };

  # A copy of the fixture with beta's function body changed.
  editedRoot =
    let
      drv = pkgs.runCommand "test-cutoff-edited" { } ''
        cp -r --no-preserve=mode ${fixture} $out
        sed -i 's/^    1$/    2/' $out/beta/src/lib.rs
        grep -q '^    2$' $out/beta/src/lib.rs
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  before = mk fixture;
  after = mk editedRoot;
  runsOf = ws: {
    alpha = ws.testRuns.alpha."lib/alpha";
    beta = ws.testRuns.beta."lib/beta";
  };

  # alpha's test with the stable inputs, input-addressed.
  plainRun = (runsOf before).alpha;
  plainSpec = plainRun.passthru.breakbulkTest;
  stable = breakbulk.testRuns.stableSpec {
    inherit pkgs;
    spec = plainSpec;
    caAttrs = { };
    name = "test-cutoff";
  };
in
{
  runs = {
    before = runsOf before;
    after = runsOf after;
  };

  stable-inputs =
    assert lib.assertMsg (
      !(plainSpec.dylib ? stable) && plainSpec.dylib.flags != [ ]
    ) "test-cutoff: with ca off, the test run uses the stable inputs";
    assert lib.assertMsg (
      stable.dylib.flags == [ ] && stable.dylib.stable != null && lib.length stable.envFlags == 1
    ) "test-cutoff: stableSpec did not replace the run inputs";
    pkgs.runCommand "test-cutoff-stable-inputs" { } ''
      ${breakbulk.testRuns.envScript {
        spec = stable;
        jq = "${pkgs.jq}/bin/jq";
      }}
      echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
      # Every entry is a copy (or the sysroot), holding beta's library file
      # and no subdirectory.
      IFS=: read -ra ps <<< "$LD_LIBRARY_PATH"
      found=0
      for p in "''${ps[@]}"; do
        case $p in
          ${stable.dylib.stable}/dylib/*)
            [ -z "$(find "$p" -mindepth 1 -type d)" ]
            [ -f "$p/libbeta_marker.so" ] && found=1 ;;
          */lib/rustlib/*) ;;
          *) echo "unexpected entry $p" >&2; exit 1 ;;
        esac
      done
      [ $found = 1 ]
      [ "$ALPHA_STAMP" = alpha-stamp ]
      files=(${plainSpec.unitOut}/*)
      cd ${lib.escapeShellArg plainSpec.sourceDir}
      "''${files[0]}" | tee $TMPDIR/log
      grep -q 'test tests::runtime_env ... ok' $TMPDIR/log
      mkdir -p $out
      cp $TMPDIR/log $out/
    '';
}
