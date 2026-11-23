# Stable test-run inputs for content-addressed cutoff, over
# tests/fixtures/test-cutoff: `alpha` has a test and a build script that
# sets `rustc-env`, and depends on `beta`, whose build script's OUT_DIR is
# a search path (so it is on the dynamic-library path of alpha's test,
# which has beta's run in its closure) and holds a subdirectory.
#
#   nix build -f tests/test-cutoff stable-inputs
#   tests/test-cutoff/run.sh        content-addressed, in a private store
#
#   stable-inputs   (flake check) alpha's test passes with the stable
#                   inputs of lib/test-runs.nix `runInfo` (built here
#                   input-addressed, as stock Nix cannot build CA): its
#                   dynamic-library path holds copies of beta's library
#                   files, not beta's OUT_DIR, and no subdirectory;
#                   ALPHA_STAMP comes from the copied `rustc-env` values.
#                   With `ca` off, test runs do not use the stable inputs.
#   runs.before, runs.after
#                   the test runs, before and after a change to BETA_SUB in
#                   beta's env, which only decides what beta's build script
#                   writes into the subdirectory. beta's run, beta's
#                   library and alpha's test binary are rebuilt, but
#                   nothing alpha's test reads changes (the binary is
#                   byte-identical, and the copies hold the run's files,
#                   not subdirectories); run.sh builds them with
#                   `ca = true` and checks alpha's test run is not re-run.
#   source.before.alpha, source.after.alpha
#                   alpha's test run before and after an edit to the body
#                   of a function in beta's source that alpha's test never
#                   calls, which also moves it down. Libraries get the
#                   remap scope of a split-debug target (macro,diagnostics,
#                   as mkRepository gives Linux), so beta's debug info
#                   names its source view and holds its line table, and
#                   alpha's test binary changes. With `ca` the run executes
#                   a debug-stripped copy (`test.stages`' default),
#                   which does not; run.sh checks the run is not re-run.
#   run-inputs      (flake check; run.sh with `ca = true`) alpha's test run
#                   has breakbulk-hints among its inputs (for its hints
#                   after a failure) and not breakbulk-unit, so a
#                   breakbulk-unit change leaves it cut off.
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
  # The default: off on stock Nix; run.sh passes true.
  ca ? breakbulk.nixFeatures.defaultCa,
}:
let
  inherit (pkgs) lib;
  mkWorkspace = import ../lib/workspace.nix { inherit lib breakbulk; };
  fixture = ../fixtures/test-cutoff;
  tools = breakbulk.mkTools pkgs;

  mkWith =
    root: args:
    mkWorkspace pkgs (
      {
        inherit tools ca root;
        name = "test-cutoff";
      }
      // args
    );
  mk = sub: mkWith fixture { packageOverrides."beta@0.1.0".target.env.BETA_SUB = sub; };

  before = mk "1";
  after = mk "2";

  # The fixture with beta's `unused` edited and moved down a line.
  sourceEdited =
    let
      drv = pkgs.runCommand "test-cutoff-source-edit" { } ''
        cp -r --no-preserve=mode ${fixture} $out
        sed -i -e 's/^    2$/    \/\/ edited\n    3/' -e 's/^pub fn unused/\npub fn unused/' $out/beta/src/lib.rs
        grep -q edited $out/beta/src/lib.rs
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);
  sourceRun =
    root:
    (mkWith root {
      remapScope = {
        host = "macro,diagnostics";
        target = "macro,diagnostics";
        test = null;
      };
    }).testRuns.alpha."lib/alpha";
  runsOf = ws: {
    alpha = ws.testRuns.alpha."lib/alpha";
    beta = ws.testRuns.beta."lib/beta";
  };

  # alpha's test with the stable inputs, input-addressed.
  plainRun = (runsOf before).alpha;
  root = plainRun.passthru.root;
  # The names of the derivations a derivation's attributes refer to.
  inputNames =
    drv:
    map (p: builtins.unsafeDiscardStringContext (baseNameOf p)) (
      lib.attrNames (builtins.getContext (builtins.toJSON drv.drvAttrs))
    );
  hasTool = n: lib.any (i: builtins.match "[a-z0-9]{32}-${n}-[0-9.]+\\.drv" i != null);

  stable = breakbulk.testRuns.runInfo {
    inherit pkgs;
    name = "test-cutoff-test-spec";
    inherit (root.breakbulkRoot) wrapper;
    dylibPath = {
      var = "LD_LIBRARY_PATH";
      sep = ":";
    };
    stable = true;
  };
in
{
  runs = {
    before = runsOf before;
    after = runsOf after;
  };
  source = {
    before.alpha = sourceRun fixture;
    after.alpha = sourceRun sourceEdited;
  };

  run-inputs =
    let
      names = inputNames (runsOf before).alpha;
    in
    assert lib.assertMsg (hasTool "breakbulk-hints" names)
      "test-cutoff: alpha's test run has no breakbulk-hints input: ${toString names}";
    assert lib.assertMsg (
      !hasTool "breakbulk-unit" names
    ) "test-cutoff: alpha's test run has breakbulk-unit as an input";
    pkgs.runCommand "test-cutoff-run-inputs" { } ''
      echo ${lib.escapeShellArg (toString names)} > $out
    '';

  stable-inputs =
    assert lib.assertMsg (
      !(plainRun.drvAttrs ? specDylibs)
    ) "test-cutoff: with ca off, the test run uses the stable inputs";
    pkgs.runCommand "test-cutoff-stable-inputs"
      {
        spec = stable.out;
        specDylibs = stable.dylibs;
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        info=$spec/breakbulk-root.json
        # The run reads neither `flags` list, only the copies.
        [ "$(jq -c '.testSpec | [.dylibFlags, .envFlags]' "$info")" = '[[],[]]' ]
        [ -f $spec/rustc-env/directives.json ]
        ${breakbulk.testRuns.envScript {
          jq = "${pkgs.jq}/bin/jq";
          extra = [ ];
          stable = true;
          dylibPath = {
            var = "LD_LIBRARY_PATH";
            sep = ":";
          };
        }}
        echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
        # Every entry is a copy (or the sysroot), holding beta's library file
        # and no subdirectory.
        IFS=: read -ra ps <<< "$LD_LIBRARY_PATH"
        found=0
        for p in "''${ps[@]}"; do
          case $p in
            $specDylibs/dylib/*)
              [ -z "$(find "$p" -mindepth 1 -type d)" ]
              [ -f "$p/libbeta_marker.so" ] && found=1 ;;
            */lib/rustlib/*) ;;
            *) echo "unexpected entry $p" >&2; exit 1 ;;
          esac
        done
        [ $found = 1 ]
        [ "$ALPHA_STAMP" = alpha-stamp ]
        files=(${root}/*)
        cd "$CARGO_MANIFEST_DIR"
        "''${files[0]}" | tee $TMPDIR/log
        grep -q 'test tests::runtime_env ... ok' $TMPDIR/log
        mkdir -p $out
        cp $TMPDIR/log $out/
      '';
}
