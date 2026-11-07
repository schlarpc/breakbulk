# Git dependencies locked at different revisions by different workspaces
# (tests/fixtures/git-revisions), through mkRepository in IFD mode. Wired
# into the flake's checks as `git-revisions-*`.
#
#   nix build -f tests/git-revisions sharing
#
#   repo        the fixture's git repository, made from repo-r1/ and repo-r2/
#               as two commits on `main` with fixed dates, so the commit ids
#               are the ones the lockfiles name
#   lockfiles   Cargo.lock of each workspace as real Cargo writes it against
#               that repository (a, c, d with only the first commit, b after
#               the second); `sharing` checks the fixture's are the same
#   sharing     each workspace builds and runs with its own revision; units
#               are shared exactly between the workspaces whose commands are
#               identical
#   package-ids the package ids of git crates in the plans equal real
#               Cargo's (`cargo metadata` over the real repository, no
#               source replacement), and breakbulk's crate source keys
#
# The repository sits at file:///build/gitdep, inside the sandbox's build
# directory, where `repo` is copied before real Cargo fetches from it.
# breakbulk never fetches it: `gitTrees` maps each locked source to its tree.
#
# `repos` exposes the repository for debugging.
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
  fixture = ../fixtures/git-revisions;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;

  url = "file:///build/gitdep";
  r1 = "86f6ab89dd0b476b6dc623b87344bbb04dee8b78";
  r2 = "6364495c6bed7ed69deb5d5a6d1bb3aaa08c64c9";
  workspaces = [
    "a"
    "b"
    "c"
    "d"
  ];

  gitEnv = ''
    export HOME=$TMPDIR GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=breakbulk GIT_AUTHOR_EMAIL=breakbulk@example.invalid
    export GIT_COMMITTER_NAME=breakbulk GIT_COMMITTER_EMAIL=breakbulk@example.invalid
  '';

  # Two commits on `main`: repo-r1/ then repo-r2/. $out/r1 and $out/r2 hold
  # the commit ids; $out/r1.git is the repository at the first commit,
  # $out/repo.git at the second.
  repo = pkgs.runCommand "git-revisions-repo" { nativeBuildInputs = [ pkgs.git ]; } ''
    ${gitEnv}
    mkdir -p $out
    git init -q -b main --bare $out/repo.git
    git init -q -b main work
    cd work
    commit() {
      git rm -rq --cached . > /dev/null 2>&1 || true
      find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
      cp -r --no-preserve=mode ${fixture}/$1/. .
      git add -A
      GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git commit -qm "$1"
      git rev-parse HEAD
    }
    commit repo-r1 "2026-01-01T00:00:00Z" > $out/r1
    git clone -q --bare . $out/r1.git
    commit repo-r2 "2026-01-02T00:00:00Z" > $out/r2
    git push -q $out/repo.git main
    cat $out/r1 $out/r2
  '';
  # Shell lines: put the repository at /build/gitdep as of the first
  # commit (`r1.git`) or the second (`repo.git`), for real Cargo.
  placeRepo = which: ''
    [ "$NIX_BUILD_TOP" = /build ] || { echo "needs sandbox-build-dir = /build" >&2; exit 1; }
    cp -r --no-preserve=mode ${repo}/${which} /build/gitdep
  '';

  # A workspace with real Cargo against the real repository, at the same
  # relative layout as the fixture: /build/fx/{<ws>,common}.
  cargoEnv = which: ws: ''
    ${gitEnv}
    export CARGO_HOME=$TMPDIR/cargo-home
    ${placeRepo which}
    mkdir -p /build/fx
    cp -r --no-preserve=mode ${fixture}/${ws} ${fixture}/common /build/fx/
    cd /build/fx/${ws}
  '';
  revisionOf = ws: if ws == "b" then "repo.git" else "r1.git";

  # What real Cargo locks: a, c and d see only the first commit, b both.
  lockfiles =
    pkgs.runCommand "git-revisions-lockfiles"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.git
        ];
      }
      (
        lib.concatMapStrings (ws: ''
          (
            ${cargoEnv (revisionOf ws) ws}
            rm -f Cargo.lock
            cargo generate-lockfile
            install -D Cargo.lock $out/${ws}/Cargo.lock
          )
          rm -rf /build/gitdep /build/fx
        '') workspaces
      );
  src1 = "git+${url}?branch=main#${r1}";
  src2 = "git+${url}?branch=main#${r2}";
  srcRev1 = "git+${url}?rev=${r1}#${r1}";

  repository = breakbulk.mkRepository {
    inherit pkgs tools;
    root = fixture;
    modules = [
      {
        workspaces = lib.genAttrs workspaces (ws: {
          path = ws;
          variants.default.profile = "dev";
        });
        # The trees of the two commits, by locked source: breakbulk never
        # contacts the URL.
        gitTrees = {
          ${src1} = fixture + "/repo-r1";
          ${src2} = fixture + "/repo-r2";
          ${srcRev1} = fixture + "/repo-r1";
        };
      }
    ];
  };

  inst = ws: repository.workspaces.${ws}.instances.${native}.default;
  readPlan =
    ws:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (builtins.readFile "${(inst ws).plans.build}/plan.json")
    );

  # Unit .drv path -> derivation name, build plan.
  drvs =
    ws:
    lib.mapAttrs' (
      _: u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name
    ) (inst ws).units.build;
  sharedNames =
    wss:
    let
      sets = map drvs wss;
      common = lib.foldl' (acc: s: lib.filterAttrs (d: _: s ? ${d}) acc) (lib.head sets) (
        lib.tail sets
      );
    in
    lib.sort lib.lessThan (lib.attrValues common);

  # Cargo's `-C metadata` of a package's lib compile in a workspace's plan
  # (the unit key).
  libKey =
    ws: name:
    lib.head (
      lib.attrNames (
        lib.filterAttrs (
          _: u: u.kind == "compile" && u.crate.name == name && lib.elem "lib" u.crate.types
        ) (readPlan ws).units
      )
    );

  gitUnits = [
    "gitbase-0.1.0-build-run"
    "gitbase-0.1.0-build-script"
    "gitbase-0.1.0-lib"
    "gitdep-0.1.0-lib"
  ];

  # Package ids of git crates: in each plan (Cargo's, through source
  # replacement), and breakbulk's crate source keys.
  gitIds =
    ws:
    lib.sort lib.lessThan (
      lib.unique (
        lib.filter (lib.hasPrefix "git+") (map (u: u.package) (lib.attrValues (readPlan ws).units))
      )
    );
  crateKeys = ws: lib.sort lib.lessThan (lib.attrNames (inst ws).sources.crates);
in
{
  repos = { inherit repository repo; };
  inherit repo lockfiles;

  # Each workspace runs with its own revision. Shared units: `common` (a
  # path crate outside every root) everywhere; every git unit between a
  # and c, which lock the same source at the same commit; no git unit
  # between a and b (same source, other commit: other trees, although
  # Cargo's `-C metadata` is the same, because it hashes the source
  # without the commit) or between a and d (same commit, other source: a
  # `rev` query instead of `branch`, so other `-C metadata`). The fixture's
  # lockfiles are the ones real Cargo writes against the real repository.
  sharing =
    let
      ac = sharedNames [
        "a"
        "c"
      ];
      ab = sharedNames [
        "a"
        "b"
      ];
      ad = sharedNames [
        "a"
        "d"
      ];
      explain = repository.explainSharing {
        a = "a";
        b = "b";
        package = "gitdep";
      };
      checks = {
        "a and c share every git unit and common" = ac == lib.sort lib.lessThan ([ "common-0.1.0-lib" ] ++ gitUnits);
        "a and b share only common" = ab == [ "common-0.1.0-lib" ];
        "a and d share only common" = ad == [ "common-0.1.0-lib" ];
        "Cargo's -C metadata of gitdep ignores the commit" = libKey "a" "gitdep" == libKey "b" "gitdep";
        "Cargo's -C metadata of gitdep includes the git reference" =
          libKey "a" "gitdep" != libKey "d" "gitdep";
        "explainSharing reports gitdep a/b as not shared" = !explain.shared;
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    assert lib.assertMsg (failed == [ ])
      "git-revisions: ${lib.concatStringsSep "; " failed} (a/c ${builtins.toJSON ac}, a/b ${builtins.toJSON ab}, a/d ${builtins.toJSON ad})";
    pkgs.runCommand "git-revisions-sharing"
      (
        lib.genAttrs workspaces (ws: repository.workspaces.${ws}.packages."app-${ws}")
        // {
          inherit lockfiles;
          text = explain.text;
        }
      )
      ''
        for ws in a b c d; do
          diff -u $lockfiles/$ws/Cargo.lock ${fixture}/$ws/Cargo.lock
          rev=r1; [ $ws = b ] && rev=r2
          got=$(''${!ws}/bin/app-$ws)
          echo "$got"
          [ "$got" = "app-$ws common gitdep $rev base+cfg" ]
        done
        mkdir -p $out
        printf '%s\n' "$text" > $out/explain-gitdep
      '';

  # Package ids of git crates: real Cargo's `cargo metadata` over the real
  # repository (no source replacement), the plans' (Cargo through
  # breakbulk's vendor directory) and breakbulk's crate source keys
  # (lib/workspace.nix `crateId`) are the same, per workspace.
  package-ids =
    let
      expected = lib.genAttrs workspaces (ws: {
        plan = gitIds ws;
        keys = crateKeys ws;
      });
    in
    pkgs.runCommand "git-revisions-package-ids"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.git
          pkgs.jq
        ];
        expected = builtins.toJSON expected;
      }
      ''
        mkdir -p $out
        ${lib.concatMapStrings (ws: ''
          (
            ${cargoEnv (revisionOf ws) ws}
            cargo metadata --format-version 1 --locked \
              | jq -c '[.packages[].id | select(startswith("git+"))] | sort' > $out/${ws}.json
          )
          rm -rf /build/gitdep /build/fx
          echo "${ws}: cargo $(cat $out/${ws}.json)"
          for k in plan keys; do
            want=$(jq -c --arg k $k '.${ws}[$k]' <<< "$expected")
            echo "${ws}: $k $want"
            [ "$want" = "$(cat $out/${ws}.json)" ]
          done
        '') workspaces}
      '';
}
