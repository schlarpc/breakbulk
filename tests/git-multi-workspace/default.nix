# A git source whose crates come from two workspaces that both use
# workspace inheritance, with other values for the same keys
# (tests/fixtures/git-multi-workspace).
# Wired into the flake's checks as `git-multi-workspace-*`.
#
#   nix build -f tests/git-multi-workspace golden
#
#   repo          the fixture's repository (repo/) as one commit on `main`
#                 with a fixed date, so its id is the one the lockfile names
#   ws            the consumer's mkWorkspace (tests/rebuild)
#   layout        the vendor directory gives each workspace its own stub in
#                 a dot directory, named by the crates' `package.workspace`
#   build         the consumer built by breakbulk prints what the consumer
#                 built by real Cargo from the real repository prints
#                 (CARGO_PKG_VERSION, _README, _LICENSE_FILE, _LICENSE,
#                 _DESCRIPTION of a crate from each workspace)
#   golden[-<v>]  the build plan, rendered, has the argv of real
#                 `cargo build -v` over the real repository (no source
#                 replacement), unit by unit; `-<v>` on the other releases
#                 of the supported window when the package set has
#                 rust-overlay; with the plan's `--config` for trim-paths
#                 when the planner turned it on (`trimPathsDefault`,
#                 Cargo >= 1.101)
#
# The repository sits at file:///build/gitdep, inside the sandbox's build
# directory, where `repo` is copied before real Cargo fetches from it.
# breakbulk never fetches it: `gitTrees` maps the URL to repo/.
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
  fixture = ../fixtures/git-multi-workspace;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;

  url = "file:///build/gitdep";
  rev = "b7d7b61180f91170f3986ba4ac9598b783230f60";

  expectOutput = ''
    a 1.0.0 readme=../../README.md license-file=../../LICENSE b=1
    c 2.0.0 readme=../TOOLS.md license=MIT description=tools workspace d=2
  '';

  gitEnv = ''
    export HOME=$TMPDIR GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=breakbulk GIT_AUTHOR_EMAIL=breakbulk@example.invalid
    export GIT_COMMITTER_NAME=breakbulk GIT_COMMITTER_EMAIL=breakbulk@example.invalid
  '';

  repo = pkgs.runCommand "git-multi-workspace-repo" { nativeBuildInputs = [ pkgs.git ]; } ''
    ${gitEnv}
    git init -q -b main work
    cd work
    cp -r --no-preserve=mode ${fixture}/repo/. .
    git add -A
    GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git commit -qm repo
    got=$(git rev-parse HEAD)
    [ "$got" = ${rev} ] || { echo "commit is $got, the lockfile names ${rev}" >&2; exit 1; }
    git clone -q --bare . $out
  '';

  toolchains = {
    default = {
      inherit (pkgs) cargo rustc;
    };
  }
  // lib.optionalAttrs (pkgs ? rust-bin) (
    lib.mapAttrs
      (_: tc: {
        cargo = tc;
        rustc = tc;
      })
      {
        "1_95" = pkgs.rust-bin.stable."1.95.0".minimal;
        nightly = pkgs.rust-bin.nightly.latest.minimal;
      }
  );

  mk =
    toolchain:
    breakbulk.mkWorkspace pkgs {
      root = fixture + "/consumer";
      inherit tools toolchain;
      name = "git-multi-workspace";
      fetchArgs.gitTrees.${url} = fixture + "/repo";
    };
  ws = mk toolchains.default;

  # Real Cargo over the real repository, with the consumer at the plan's
  # skeleton root: metadata.json, build.log, output; then the golden
  # comparison against `ws'`s build plan.
  real =
    name: toolchain: ws':
    pkgs.runCommandCC "git-multi-workspace-${name}"
      {
        nativeBuildInputs = [
          toolchain.cargo
          toolchain.rustc
          pkgs.git
        ];
      }
      ''
        ${gitEnv}
        export CARGO_HOME=$TMPDIR/cargo-home
        [ "$NIX_BUILD_TOP" = /build ] || { echo "needs sandbox-build-dir = /build" >&2; exit 1; }
        cp -r --no-preserve=mode ${repo} /build/gitdep
        cp -r --no-preserve=mode ${fixture}/consumer "$NIX_BUILD_TOP/skeleton"
        cd "$NIX_BUILD_TOP/skeleton"
        mkdir -p $out
        common=(--locked)
        # When the planner turned Cargo's trim-paths on (Cargo >= 1.101 and
        # the project did not), the reference build does the same.
        if grep -q '"trimPathsDefault":true' ${ws'.plans.build}/plan.json; then
          common+=(--config 'profile.dev.trim-paths="all"')
        fi
        cargo metadata --format-version 1 "''${common[@]}" > $out/metadata.json
        cargo build -v "''${common[@]}" --target ${native} --profile dev \
          --config "build.target-dir=\"$TMPDIR/target\"" 2> $out/build.log || { cat $out/build.log; exit 1; }
        $TMPDIR/target/${native}/debug/consumer > $out/output
        diff -u ${pkgs.writeText "expected" expectOutput} $out/output
        ${tools.breakbulk-plan}/bin/breakbulk-plan-golden \
          --plan ${ws'.plans.build}/plan.json --log $out/build.log \
          --target-dir $TMPDIR/target --metadata $out/metadata.json | tee $out/report
      '';
  goldens = lib.mapAttrs' (
    v: tc:
    let
      n = if v == "default" then "golden" else "golden-${v}";
    in
    lib.nameValuePair n (real n tc (if v == "default" then ws else mk tc))
  ) toolchains;
in
{
  inherit repo ws;

  layout = pkgs.runCommand "git-multi-workspace-layout" { vendor = ws.vendor.dir; } ''
    cd $vendor/*/
    # No stub one level up; one per workspace, named by the crates.
    [ ! -e Cargo.toml ]
    [ $(ls -d .breakbulk-workspace-* | wc -l) = 2 ]
    for c in a-1.0.0 b-1.0.0 c-2.0.0 d-2.0.0; do
      p=$(sed -n 's/.*"workspace" = "\([^"]*\)".*/\1/p' $c/Cargo.toml)
      echo "$c -> $p"
      [ -f "$c/$p/Cargo.toml" ]
    done
    [ "$(sed -n 's/.*"workspace" = "\([^"]*\)".*/\1/p' a-1.0.0/Cargo.toml)" = \
      "$(sed -n 's/.*"workspace" = "\([^"]*\)".*/\1/p' b-1.0.0/Cargo.toml)" ]
    [ "$(sed -n 's/.*"workspace" = "\([^"]*\)".*/\1/p' a-1.0.0/Cargo.toml)" != \
      "$(sed -n 's/.*"workspace" = "\([^"]*\)".*/\1/p' c-2.0.0/Cargo.toml)" ]
    touch $out
  '';

  build =
    pkgs.runCommand "git-multi-workspace-build"
      {
        consumer = ws.packages.consumer;
        real = goldens.golden;
      }
      ''
        $consumer/bin/consumer > output
        diff -u $real/output output
        touch $out
      '';
}
// goldens
