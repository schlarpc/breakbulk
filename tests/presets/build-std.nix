# -Zbuild-std (tests/fixtures/build-std) through mkRepository (IFD), with
# rust-overlay's nightly and its rust-src component. Imported by
# ./default.nix; every attribute is a flake check.
#
#   build-std        a no_std x86_64-unknown-none binary with core and
#                    compiler_builtins rebuilt from rust-src: the plan has
#                    their units (sources in the toolchain's store path,
#                    compiler_builtins' build script run included); the
#                    linked ELF has the fixture's `_start`, needs no
#                    interpreter or libraries, and contains compiler_builtins'
#                    128-bit division (__udivti3). The target's default
#                    preset is bareMetal: rust-overlay's toolchain links
#                    with its own rust-lld; told it ships none
#                    (`toolchain.facts.bundledLld = false`, as nixpkgs'
#                    rustc), with nixpkgs' ld.lld of its LLVM major
#   build-std-deps   std (`build-std = ["std", "panic_abort"]`) on the host
#                    triple: the standard library's own crates.io
#                    dependencies (hashbrown, libc, …) come from rust-src's
#                    vendored copies, are planned, built, and linked into a
#                    program that runs
#   build-std-tests  both fixtures' test plans instantiate: each has its
#                    test root's wrapper with a test spec, whose
#                    path-package graph (what testRunners.nextest builds
#                    its cargo metadata from) lists the fixture's own
#                    package only, as `cargo metadata` does (the standard
#                    library's packages are not in its resolve)
{
  pkgs,
  breakbulk,
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  tools = breakbulk.mkTools pkgs;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  rust = pkgs.rust-bin.nightly.latest.minimal.override { extensions = [ "rust-src" ]; };

  mkRepo =
    root: triple: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      modules = [
        {
          workspaces.main = {
            toolchain = {
              rustc = lib.mkDefault rust;
              cargo = lib.mkDefault rust;
            };
            targets.${triple} = { };
            variants.default.profile = "dev";
          };
        }
      ]
      ++ modules
      ++ extraModules;
    };

  planOf =
    repo: triple:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (
        builtins.readFile "${repo.workspaces.main.target.${triple}.variants.default.plans.build}/plan.json"
      )
    );
  # Compile units by crate name, and runs by package name.
  cratesOf =
    plan:
    lib.unique (
      map (
        u: if u.kind == "compile" then u.crate.name else "run:${lib.last (lib.splitString "#" u.package)}"
      ) (lib.attrValues plan.units)
    );

  none = "x86_64-unknown-none";
  # The default preset, bareMetal: the toolchain's own rust-lld, as the
  # target spec has it; there is no C toolchain for this target.
  bare = mkRepo (fixtures + "/build-std") none [ ];
  # The same toolchain taken for one without rust-lld: nixpkgs' ld.lld.
  bareNixpkgsLld = mkRepo (fixtures + "/build-std") none [
    { workspaces.main.toolchain.facts.bundledLld = false; }
  ];
  barePlan = planOf bare none;
  bareCrates = cratesOf barePlan;

  hosted = mkRepo (fixtures + "/build-std-deps") native [
    { targets.${native}.preset = breakbulk.presets.linux; }
  ];
  hostedPlan = planOf hosted native;
  hostedCrates = cratesOf hostedPlan;
in
assert lib.assertMsg (lib.all (c: lib.elem c bareCrates) [
  "core"
  "compiler_builtins"
  "bare"
]) "build-std: crates ${builtins.toJSON bareCrates}";
assert lib.assertMsg (lib.all (c: lib.elem c hostedCrates) [
  "std"
  "alloc"
  "hashbrown"
  "libc"
]) "build-std-deps: crates ${builtins.toJSON hostedCrates}";
{
  repos = {
    inherit bare bareNixpkgsLld hosted;
  };
  checks = {
    build-std =
      pkgs.runCommand "build-std"
        {
          nativeBuildInputs = [ pkgs.buildPackages.binutils ];
          bin = bare.workspaces.main.target.${none}.packages.bare;
          nixpkgsLld = bareNixpkgsLld.workspaces.main.target.${none}.packages.bare;
        }
        ''
          set -euo pipefail
          f=$(find -L $bin -type f -name bare | head -n1)
          readelf -hW $f | tee header.txt
          grep -q 'Machine:.*X86-64' header.txt
          if readelf -lW $f | grep -q INTERP; then echo "has an interpreter" >&2; exit 1; fi
          if readelf -dW $f 2>/dev/null | grep -q NEEDED; then echo "needs libraries" >&2; exit 1; fi
          nm $f > syms.txt
          grep -q ' T _start$' syms.txt
          grep -q ' [Tt] __udivti3$' syms.txt
          # rust-lld names Rust's LLVM fork in its .comment, nixpkgs' lld
          # does not.
          readelf -p .comment $f | tee comment.txt
          grep -q 'Linker: LLD.*llvm-project' comment.txt
          g=$(find -L $nixpkgsLld -type f -name bare | head -n1)
          readelf -p .comment $g | tee comment-nixpkgs.txt
          grep -q 'Linker: LLD' comment-nixpkgs.txt
          if grep -q llvm-project comment-nixpkgs.txt; then echo "$g was linked by rust-lld" >&2; exit 1; fi
          nm $g | grep -q ' T _start$'
          mkdir -p $out
          cp header.txt syms.txt comment.txt comment-nixpkgs.txt $out/
        '';

    build-std-tests =
      pkgs.runCommand "build-std-tests"
        {
          nativeBuildInputs = [ pkgs.buildPackages.jq ];
          bare = "${bare.workspaces.main.internal.instances.${none}.default.unitsJson.test}";
          hosted = "${hosted.workspaces.main.internal.instances.${native}.default.unitsJson.test}";
        }
        ''
          set -euo pipefail
          check() {
            # The wrapper's breakbulk-root.json, its references (`{"unit": …}`
            # and `{"input": …}` parts) blanked.
            jq -e --arg wrapper "$2" --arg pkg "$3" --arg id "$4" '
              .wrappers[$wrapper].attrs.rootJson
              | [.parts[] | if type == "string" then . else "X" end] | add | fromjson
              | .testSpec
              | (.packageId == $id) and ((.pathPackages | keys) == [$pkg])
            ' "$1" >/dev/null || {
              echo "$1: the package graph of $2 lists more than $3, or $2 is missing" >&2
              jq '.wrappers | keys' "$1" >&2
              exit 1
            }
          }
          check $bare bare.bin-test.bare.drv bare 'path+file:///build/skeleton#bare@0.1.0'
          check $hosted app.bin-test.app.drv app 'path+file:///build/skeleton#app@0.1.0'
          touch $out
        '';

    build-std-deps = pkgs.runCommand "build-std-deps" { app = hosted.workspaces.main.packages.app; } ''
      $app/bin/app | tee out.txt
      grep -qx 'hashmap has 3 entries' out.txt
      mkdir -p $out
      cp out.txt $out/
    '';
  };
}
