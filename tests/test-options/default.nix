# Test-run options over ./fixture, through mkRepository (IFD, native
# target, the linux preset: workspace libraries keep source paths in
# their debug info). Wired into the flake's checks as `test-options-*`.
#
#   nix build -f tests/test-options strip-for-run
#   tests/test-options/run.sh     content-addressed, in a private store
#
#   strip-for-run   decision 17, `workspaces.<ws>.test.stripForRun`: an edit
#                   to util's README changes the bytes of app's test binary
#                   (util's debug info names its source view; the control),
#                   but not those of the stripped copy the test run
#                   consumes; the run passes.
#   run-files       decision 61, `packages.app.test.runFiles = [ "data" ]`:
#                   the `data` test runs in a view holding only data/, with
#                   CARGO_MANIFEST_DIR pointing at it, and passes; the
#                   `notes` test, which reads the unlisted notes.md, fails;
#                   the run's derivation names the narrowed view, not the
#                   package's source view, and an edit to notes.md leaves the
#                   narrowed view's path unchanged.
#   runs.{before,after}
#                   app's `data` test run with both options, before and
#                   after an edit to util's README and to app's notes.md;
#                   run.sh builds them with `ca = true` and checks the run is
#                   not re-run.
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
  tools = breakbulk.mkTools pkgs;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  fixture = ./fixture;

  # A copy of the fixture with `script` applied.
  edited =
    tag: script:
    let
      drv = pkgs.runCommand "test-options-${tag}" { } ''
        cp -r --no-preserve=mode ${fixture} $out
        cd $out
        ${script}
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);
  readmeEdited = edited "readme" "echo 'More words.' >> util/README.md";
  bothEdited = edited "both" ''
    echo 'More words.' >> util/README.md
    echo 'More notes.' >> app/notes.md
  '';
  notesEdited = edited "notes" "echo 'More notes.' >> app/notes.md";

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs tools root;
      modules = [
        {
          inherit ca;
          workspaces.main.variants.default.profile = "dev";
        }
      ]
      ++ modules;
    };
  instOf = r: r.workspaces.main.instances.${native}.default;
  runsOf = r: (instOf r).testRuns.app;

  strip = {
    workspaces.main.test.stripForRun = true;
  };
  narrow = {
    packages.app.test.runFiles = [ "data" ];
  };

  # Every store path a derivation names directly.
  directInputs = d: lib.attrNames (builtins.getContext (builtins.toJSON d.drvAttrs));
in
{
  runs = {
    before = (runsOf (mkRepo fixture [ strip narrow ])).data;
    after = (runsOf (mkRepo bothEdited [ strip narrow ])).data;
  };

  strip-for-run =
    let
      before = (runsOf (mkRepo fixture [ strip ]))."lib/app";
      after = (runsOf (mkRepo readmeEdited [ strip ]))."lib/app";
      plain = (runsOf (mkRepo fixture [ ]))."lib/app";
    in
    assert lib.assertMsg (
      plain.passthru.binary == plain.passthru.breakbulkTest.unitOut
    ) "strip-for-run: without the option (and ca off) the run should use the unit's output";
    assert lib.assertMsg (lib.hasSuffix "-bin-stripped" before.passthru.binary.name)
      "strip-for-run: the run does not use a stripped copy";
    pkgs.runCommand "test-options-strip-for-run"
      {
        unstrippedBefore = before.passthru.breakbulkTest.unitOut;
        unstrippedAfter = after.passthru.breakbulkTest.unitOut;
        strippedBefore = before.passthru.binary;
        strippedAfter = after.passthru.binary;
        run = before;
      }
      ''
        # The control: util's debug info names its source view.
        if cmp -s $unstrippedBefore/* $unstrippedAfter/*; then
          echo "the README edit did not change app's test binary: the check is vacuous" >&2
          exit 1
        fi
        cmp $strippedBefore/* $strippedAfter/*
        grep -q 'test tests::quads ... ok' $run/log
        mkdir -p $out
      '';

  run-files =
    let
      repo = mkRepo fixture [ narrow ];
      runs = runsOf repo;
      fullView = (instOf repo).sources.workspace.app;
      dir = runs.data.passthru.breakbulkTest.sourceDir;
      editedDir = (runsOf (mkRepo notesEdited [ narrow ])).data.passthru.breakbulkTest.sourceDir;
      inputs = directInputs runs.data;
      viewOf = d: builtins.unsafeDiscardStringContext (lib.head (lib.splitString "/app" d));
    in
    assert lib.assertMsg (
      !(lib.elem (builtins.unsafeDiscardStringContext "${fullView}") inputs)
    ) "run-files: the data test run names app's source view";
    assert lib.assertMsg (lib.elem (viewOf dir) inputs) "run-files: the data test run does not name the narrowed view";
    assert lib.assertMsg (
      builtins.unsafeDiscardStringContext dir == builtins.unsafeDiscardStringContext editedDir
    ) "run-files: editing notes.md changed the narrowed view";
    pkgs.runCommand "test-options-run-files"
      {
        data = runs.data;
        notes = pkgs.testers.testBuildFailure runs.notes;
        inherit dir;
      }
      ''
        grep -q 'test reads_listed_data ... ok' $data/log
        [ ! -e $dir/notes.md ] && [ -f $dir/data/input.txt ]
        grep -q 'reading notes.md' $notes/testBuildFailure.log
        grep -q 'test reads_notes ... FAILED' $notes/testBuildFailure.log
        mkdir -p $out
      '';
}
