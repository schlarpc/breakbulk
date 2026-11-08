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
#                    128-bit division (__udivti3)
#   build-std-deps   std (`build-std = ["std", "panic_abort"]`) on the host
#                    triple: the standard library's own crates.io
#                    dependencies (hashbrown, libc, …) come from rust-src's
#                    vendored copies, are planned, built, and linked into a
#                    program that runs
{
  pkgs,
  breakbulk,
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
              rustc = rust;
              cargo = rust;
            };
            targets.${triple} = { };
            variants.default.profile = "dev";
          };
        }
      ]
      ++ modules;
    };

  planOf =
    repo: triple:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (
        builtins.readFile "${repo.workspaces.main.plans.${triple}.default.build}/plan.json"
      )
    );
  # Compile units by crate name, and runs by package name.
  cratesOf =
    plan:
    lib.unique (
      map (u: if u.kind == "compile" then u.crate.name else "run:${lib.last (lib.splitString "#" u.package)}") (
        lib.attrValues plan.units
      )
    );

  none = "x86_64-unknown-none";
  # No preset: the target spec's own linker (rust-lld, self-contained);
  # there is no C toolchain for this target.
  bare = mkRepo (fixtures + "/build-std") none [ ];
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
  build-std =
    pkgs.runCommand "build-std"
      {
        nativeBuildInputs = [ pkgs.buildPackages.binutils ];
        bin = bare.workspaces.main.target.${none}.packages.bare;
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
        mkdir -p $out
        cp header.txt syms.txt $out/
      '';

  build-std-deps =
    pkgs.runCommand "build-std-deps" { app = hosted.workspaces.main.packages.app; } ''
      $app/bin/app | tee out.txt
      grep -qx 'hashmap has 3 entries' out.txt
      mkdir -p $out
      cp out.txt $out/
    '';
}
