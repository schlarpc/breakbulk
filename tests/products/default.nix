# Products, stages, source paths, products as inputs and variants (M4),
# through mkRepository (IFD mode, native target). Wired into the flake's
# checks as `products-*`.
#
#   nix build -f tests/products post-link
#
#   post-link        stage order from target and package stages; a stage
#                    removed with mkForce null; a check on `linked` sees
#                    unstripped bytes; checks in repo.checks
#   source-paths     no source reference in the product's main output
#                    (noSourceReferences passes); panics and file!() in a
#                    dependency print remapped paths; the debug output
#                    references the dependency's source view and the
#                    registry crate's source; gdb lists source lines from
#                    it; non-test units remap macro,diagnostics, test
#                    harnesses every scope; dep's tests pass
#   source-paths-readme   editing dep's README changes its test binary's
#                    derivation but not its bytes
#
# `repos` exposes each repository for debugging.
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
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  helpers = breakbulk.stageHelpers;

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      inherit modules;
    };

  oneWs = path: profile: {
    workspaces.main = {
      inherit path;
      variants.default = { inherit profile; };
    };
  };

  evalCheck =
    name: report:
    pkgs.runCommand name { inherit report; } ''
      mkdir -p $out
      printf '%s\n' "$report" > $out/report
    '';

  # A copy of a fixture with an edit applied, usable as a repository root.
  edited =
    fixture: script:
    let
      drv = pkgs.runCommand "${fixture}-edited" { } ''
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} $out
        cd $out
        ${script}
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  inst = repo: repo.workspaces.main.instances.${native}.default;

  # Rendered BREAKBULK_UNIT of each unit of a plan kind, by derivation name.
  renderedUnits =
    repo: kind:
    lib.listToAttrs (
      map (
        u:
        lib.nameValuePair u.name (builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT))
      ) (lib.attrValues (inst repo).units.${kind})
    );

  # --- post-link ---------------------------------------------------------------

  # A custom stage: copies its input and writes a marker file listing the
  # stages seen so far (each stage appends its name).
  marker =
    stage:
    { input, product, pkgs, ... }:
    pkgs.runCommand "${product.name}-${stage}" { } ''
      cp -RL --no-preserve=mode,ownership ${input} $out
      chmod -R u+w $out
      find $out -type f ! -name '*.txt' -exec chmod +x {} +
      echo ${stage} >> $out/stages.txt
    '';

  # A check that fails unless every ELF file in its input still has debug
  # info: on `linked` it sees the bytes before splitDebug and strip.
  hasDebugInfo =
    { input, product, pkgs, ... }:
    pkgs.runCommand "${product.name}-has-debug-info" { nativeBuildInputs = [ pkgs.binutils-unwrapped ]; } ''
      for f in ${input}/*; do
        readelf -S -W "$f" > sections
        grep -q ' \.debug_info ' sections || { echo "$f: no debug info" >&2; exit 1; }
      done
      touch $out
    '';

  postLink = mkRepo (fixtures + "/post-link") [
    (oneWs "." "dev")
    {
      # Target level: strip after splitDebug (removes the debuglink's
      # remaining symbol tables too) for every product.
      targets.${native} = {
        stages.strip = {
          after = "splitDebug";
          run = helpers.strip { all = true; };
        };
        checks.unstripped = {
          on = "linked";
          run = hasDebugInfo;
        };
      };
      packages.server = {
        stages = {
          # Signing breaks if stripped: remove the target's strip stage.
          strip = lib.mkForce null;
          stamp = {
            after = "splitDebug";
            run = marker "stamp";
          };
          sign = {
            after = "stamp";
            run = marker "sign";
          };
        };
      };
    }
    # A second module sets strip again at normal priority; mkForce wins.
    {
      packages.server.stages.strip = {
        after = "sign";
        run = helpers.strip;
      };
    }
  ];
  plServer = postLink.workspaces.main.packages.server;
  plTool = postLink.workspaces.main.packages.tool;

  # --- source-paths ------------------------------------------------------------

  spModules = [ (oneWs "." "dev") ];
  sourcePaths = mkRepo (fixtures + "/source-paths") spModules;
  sourcePathsReadme = mkRepo (edited "source-paths" "echo 'More words.' >> dep/README.md") spModules;
  spApp = sourcePaths.workspaces.main.packages.app;
in
{
  repos = {
    inherit postLink sourcePaths sourcePathsReadme;
  };

  source-paths =
    let
      i = inst sourcePaths;
      depView = i.sources.workspace.dep;
      itoaSrc = lib.head (lib.attrValues (lib.filterAttrs (id: _: lib.hasSuffix "#itoa@1.0.11" id) i.sources.crates));
      build = renderedUnits sourcePaths "build";
      test = renderedUnits sourcePaths "test";
      scopes = lib.mapAttrs (_: u: u.remapScope or null) (lib.filterAttrs (_: u: u.kind == "compile") (build // test));
      want = {
        "app-0.1.0-bin" = "macro,diagnostics";
        "dep-0.1.0-lib" = "macro,diagnostics";
        "itoa-1.0.11-lib" = "macro,diagnostics";
        "app-0.1.0-test" = null;
        "dep-0.1.0-test" = null;
      };
      bad = lib.filterAttrs (n: s: (scopes.${n} or "missing") != s) want;
    in
    assert lib.assertMsg (bad == { }) "source-paths: remap scopes ${builtins.toJSON scopes}";
    assert lib.assertMsg (spApp.stageOrder == [
      "splitDebug"
      "install"
    ]) "source-paths: stages ${builtins.toJSON spApp.stageOrder}";
    pkgs.runCommand "source-paths"
      {
        nativeBuildInputs = [ pkgs.gdb ];
        app = spApp;
        debug = spApp.debug;
        debugClosure = pkgs.closureInfo { rootPaths = [ spApp.debug ]; };
        # Negative control: before splitDebug, the binary does reference
        # the sources (debug info keeps real paths), so noSourceReferences
        # is not passing vacuously.
        linkedClosure = pkgs.closureInfo { rootPaths = [ spApp.stages.linked ]; };
        noSrc = spApp.checks.noSourceReferences;
        depView = builtins.unsafeDiscardStringContext "${depView}";
        itoaSrc = builtins.unsafeDiscardStringContext "${itoaSrc}";
        depTests = sourcePaths.workspaces.main.testRuns.dep.lib;
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        cat run.txt
        grep -qxF 'dep is dep/src/lib.rs' run.txt
        grep -qxF 'formatted 42' run.txt
        grep -qxF 'panicked at dep/src/lib.rs:16' run.txt
        # The debug output references exactly the sources a debugger needs.
        grep -qxF "$depView" $debugClosure/store-paths
        grep -qxF "$itoaSrc" $debugClosure/store-paths
        grep -qxF "$depView" $linkedClosure/store-paths
        # gdb finds the split debug info by build ID and lists the source.
        gdb -batch -nx -iex "set debug-file-directory $debug/lib/debug" \
          -ex 'list dep::boom' $app/bin/app > gdb.txt 2>&1 || true
        cat gdb.txt
        grep -qF 'panic!("boom {n}");' gdb.txt
        cat $depTests/log
        touch $out
      '';

  source-paths-readme =
    let
      before = sourcePaths.workspaces.main.tests.dep.lib;
      after = sourcePathsReadme.workspaces.main.tests.dep.lib;
    in
    assert lib.assertMsg (before.drvPath != after.drvPath) "source-paths-readme: the README edit changed no derivation";
    pkgs.runCommand "source-paths-readme" { inherit before after; } ''
      cmp $before/bin/dep $after/bin/dep
      touch $out
    '';

  post-link =
    let
      checkNames = lib.attrNames postLink.checks;
      want = map (n: "main/${native}/${n}") [
        "server/build"
        "server/noSourceReferences"
        "server/unstripped"
        "tool/build"
        "tool/noSourceReferences"
        "tool/unstripped"
      ];
    in
    assert lib.assertMsg (plServer.stageOrder == [
      "splitDebug"
      "stamp"
      "sign"
      "install"
    ]) "post-link: server stages ${builtins.toJSON plServer.stageOrder}";
    assert lib.assertMsg (plTool.stageOrder == [
      "splitDebug"
      "strip"
      "install"
    ]) "post-link: tool stages ${builtins.toJSON plTool.stageOrder}";
    assert lib.assertMsg (lib.all (n: lib.elem n checkNames) want) "post-link: checks ${builtins.toJSON checkNames}";
    pkgs.runCommand "post-link"
      {
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
        server = plServer;
        serverLinked = plServer.stages.linked;
        serverDebug = plServer.debug;
        tool = plTool;
        unstripped = plServer.checks.unstripped;
        toolUnstripped = plTool.checks.unstripped;
        noSrc = plServer.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        # has FILE SECTION: whether FILE has SECTION (no pipe into grep -q,
        # which can fail with SIGPIPE under pipefail).
        has() { readelf -S -W "$1" > sections; grep -qF " $2 " sections; }
        [ "$($server/bin/server)" = "server 1" ]
        [ "$($tool/bin/tool)" = tool ]
        # Stage order as the marker stages saw it.
        [ "$(cat $server/stages.txt)" = "$(printf 'stamp\nsign')" ]
        # linked holds the unstripped binary under its target name.
        has $serverLinked/server .debug_info
        # splitDebug moved it to the debug output; no strip ran on server
        # (its symbol table is still there), but tool was stripped.
        ! has $server/bin/server .debug_info
        has $server/bin/server .symtab
        ! has $tool/bin/tool .symtab
        has $server/bin/server .gnu_debuglink
        ls $serverDebug/lib/debug/.build-id/*/*.debug
        touch $out
      '';
}
