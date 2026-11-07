# Nix-level smoke test of breakbulk-unit: the units of plan.json as real
# derivations, built in the sandbox with breakbulk-unit as their builder.
#
#   nix-build tests/unit-smoke -A check
#
# units.json is plan.json rendered with path tokens by the smoke test in
# crates/breakbulk-unit/tests/smoke.rs (which also checks it is current).
# This file plays the part of instantiation in IFD mode: it replaces each
# token with a store path and passes the result to `derivation`.
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
}:
let
  inherit (pkgs) lib;
  root = ../..;

  breakbulk-unit = pkgs.rustPlatform.buildRustPackage {
    pname = "breakbulk-unit";
    version = "0.1.0";
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/Cargo.toml")
        (root + "/Cargo.lock")
        (root + "/crates")
      ];
    };
    cargoLock.lockFile = root + "/Cargo.lock";
    cargoBuildFlags = [ "-p" "breakbulk-unit" ];
    doCheck = false;
  };

  # Both packages' source views are the fixture's repository root.
  src = builtins.path {
    path = ./fixture;
    name = "unit-smoke-source";
  };

  # The real base env capture (lib/env-capture.nix). On this native build
  # host and target units share it.
  capture = (import ../../lib/env-capture.nix { inherit lib; }).base { inherit pkgs; };

  specials = {
    src = "${src}";
    rustc = "${pkgs.rustc}/bin/rustc";
    capture = "${capture}";
  };

  spec = builtins.fromJSON (builtins.readFile ./units.json);

  resolve = r: if r ? special then specials.${r.special} else "${units.${r.unit}.${r.output}}";

  units = builtins.mapAttrs (
    id: u:
    derivation {
      name = "unit-smoke-${id}";
      system = pkgs.stdenv.buildPlatform.system;
      builder = "${breakbulk-unit}/bin/breakbulk-unit";
      args = [ "unit" ];
      inherit (u) outputs;
      BREAKBULK_UNIT = builtins.replaceStrings (map (r: r.token) u.refs) (map resolve u.refs) u.unit;
    }
  ) spec;

  app = units.c-a6654c0a89d81026;
  run = units.r-smokelib-63aa584f9c6a6c6c;
in
{
  inherit
    breakbulk-unit
    units
    src
    capture
    ;

  # Runs the binary, and fails if it references its sources or the build
  # script's OUT_DIR (path remapping covers every scope here). The build
  # script compiled C through the capture's compiler wrapper: the unit's
  # -frandom-seed and -ffile-prefix-map reached it, and the C archive names
  # its source only by the remapped path.
  check =
    pkgs.runCommand "unit-smoke-check"
      {
        disallowedReferences = [
          src
          run.out
        ];
      }
      ''
        mkdir -p $out/bin
        cp ${app}/smokeapp-b0ba845afe70cf35 $out/bin/smokeapp
        $out/bin/smokeapp | tee $out/log
        grep -qx 'smoke ok: hello-from-build 42 c=6' $out/log
        grep -q 'smoke_cfg' ${run.flags}/directives.json

        cflags=$(cat ${run.out}/nix-cflags-compile.txt)
        echo "NIX_CFLAGS_COMPILE seen by the build script: $cflags"
        # The seed is the run's plan key, not derived from its output path.
        seed=r-smokelib-63aa584f9c6a6c6c
        case "$cflags" in
          " -frandom-seed=$seed "*) ;;
          *) echo "FAIL: the unit's seed is not first"; exit 1 ;;
        esac
        for map in "-ffile-prefix-map=${src}=." \
                   "-ffile-prefix-map=${run.out}=/breakbulk/build/r-smokelib-63aa584f9c6a6c6c"; do
          case "$cflags" in
            *" $map"*) ;;
            *) echo "FAIL: $map missing"; exit 1 ;;
          esac
        done

        # gcc compresses the objects' debug sections, and nixpkgs' gcc
        # writes __FILE__ under the store with an upper-cased hash; look at
        # decompressed bytes, ignoring case.
        objcopy=${pkgs.binutils-unwrapped}/bin/objcopy
        $objcopy --decompress-debug-sections ${run.out}/native/libsmokec.a smokec.a
        if grep -q -a -i -F ${src} smokec.a; then
          echo "FAIL: libsmokec.a contains the source path"; exit 1
        fi
        grep -q -a -F ./smokelib/csrc/smoke.c smokec.a
        # Control: without the prefix map the same compile embeds the path.
        ${pkgs.stdenv.cc}/bin/cc -c -g3 -O1 -fPIC ${src}/smokelib/csrc/smoke.c -o control.o
        $objcopy --decompress-debug-sections control.o control-plain.o
        grep -q -a -F ${src} control-plain.o
      '';
}
