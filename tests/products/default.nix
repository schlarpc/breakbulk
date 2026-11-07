# Products, stages, source paths, products as inputs and variants (M4),
# through mkRepository (IFD mode, native target). Wired into the flake's
# checks as `products-*`.
#
#   nix build -f tests/products post-link
#
#   post-link        stage order from target and package stages; a stage
#                    removed with mkForce null; a check on `linked` sees
#                    unstripped bytes; checks in repo.checks
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
in
{
  repos = {
    inherit postLink;
  };

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
