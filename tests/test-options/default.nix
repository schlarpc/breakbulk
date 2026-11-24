# Test-run options over ./fixture, through mkRepository (IFD, native
# target, the linux preset: workspace libraries keep source paths in
# their debug info). Wired into the flake's checks as `test-options-*`.
#
#   nix build -f tests/test-options strip-stage
#   tests/test-options/run.sh     content-addressed, in a private store
#
#   strip-stage     `memberDefaults.test.stages.strip` (the default with
#                   `ca`, here without it): an edit to util's README
#                   changes the bytes of app's test binary (util's debug
#                   info names its source view; the control), but not
#                   those of the stripped copy the test run consumes; the
#                   run passes. The run's derivation closure lacks
#                   binutils-unwrapped-all-targets and LLVM: the native
#                   target strips with its stdenv's binutils.
#   run-files       `packages.app.test.runFiles = [ "data" ]`:
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
  # The default: off on stock Nix; run.sh passes true.
  ca ? breakbulk.nixFeatures.defaultCa,
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
          workspaces.main = {
            variants.default.profile = "dev";
            # Some checks read the runs' output.
            memberDefaults.test.postRun = ''cp "$log" "$out/log"'';
          };
        }
      ]
      ++ modules;
    };
  instOf = r: r.workspaces.main.internal.instances.${native}.default;
  runsOf = r: (instOf r).testRuns.app;

  strip = {
    workspaces.main.memberDefaults.test.stages.strip.run = breakbulk.stageHelpers.strip {
      buildId = false;
    };
  };
  narrow = {
    packages.app.test.runFiles = [ "data" ];
  };

  # Every store path a derivation names directly.
  directInputs = d: lib.attrNames (builtins.getContext (builtins.toJSON d.drvAttrs));
in
{
  runs = {
    before =
      (runsOf (
        mkRepo fixture [
          strip
          narrow
        ]
      )).data;
    after =
      (runsOf (
        mkRepo bothEdited [
          strip
          narrow
        ]
      )).data;
  };

  strip-stage =
    let
      # The README edit changes util's view path and nothing util
      # compiles from; with source prediction util's view would not
      # change at all.
      viewOnly = {
        workspaces.main.memberDefaults.predictSources.enable = false;
      };
      before =
        (runsOf (
          mkRepo fixture [
            strip
            viewOnly
          ]
        ))."lib/app";
      after =
        (runsOf (
          mkRepo readmeEdited [
            strip
            viewOnly
          ]
        ))."lib/app";
      plain = (runsOf (mkRepo fixture [ ]))."lib/app";
    in
    assert lib.assertMsg (
      plain.passthru.binary == "${plain.passthru.spec}/root"
    ) "strip-stage: without a stage (and ca off) the run should use the unit's output";
    assert lib.assertMsg (lib.hasSuffix "-bin-strip" before.passthru.binary.name)
      "strip-stage: the run does not use a stripped copy";
    pkgs.runCommand "test-options-strip-stage"
      {
        unstrippedBefore = before.passthru.root;
        unstrippedAfter = after.passthru.root;
        strippedBefore = before.passthru.binary;
        strippedAfter = after.passthru.binary;
        run = before;
        # The run's derivation and every derivation and source it needs,
        # without building them.
        exportReferencesGraph = [
          "run-drvs"
          (builtins.unsafeDiscardOutputDependency before.drvPath)
        ];
        allTargets = builtins.unsafeDiscardStringContext pkgs.binutils-unwrapped-all-targets.drvPath;
        llvm = builtins.unsafeDiscardStringContext pkgs.llvm.drvPath;
      }
      ''
        for d in "$allTargets" "$llvm"; do
          if grep -qxF "$d" run-drvs; then
            echo "the run needs $d; the native target's strip should not" >&2
            exit 1
          fi
        done
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
      dir = runs.data.passthru.breakbulkTest.runDir;
      editedDir = (runsOf (mkRepo notesEdited [ narrow ])).data.passthru.breakbulkTest.runDir;
      inputs = directInputs runs.data;
      # What the run reads of its root: its "run" view, not the whole one.
      specInputs = directInputs runs.data.passthru.spec;
      viewOf = d: builtins.unsafeDiscardStringContext (lib.head (lib.splitString "/app" d));
    in
    assert lib.assertMsg (
      !(lib.elem (builtins.unsafeDiscardStringContext "${fullView}") inputs)
    ) "run-files: the data test run names app's source view";
    assert lib.assertMsg (lib.elem (viewOf dir) specInputs)
      "run-files: the data test run does not name the narrowed view";
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
