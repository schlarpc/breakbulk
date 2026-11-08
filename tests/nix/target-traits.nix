# Target traits (lib/target-traits.nix; "Target traits" in
# docs/implementation.md).
#
#   target-traits        evaluation assertions: built-in traits of the
#                        targets breakbulk has presets for, a user's
#                        traits merged over them (and for a target with no
#                        built-in ones) reaching the linker choice, the
#                        stage chain and the resolved repository target,
#                        and an unknown target failing only when a trait
#                        is read
#   target-traits-rustc  `parse` against `rustc --print cfg --target <t>`
#                        for every built-in target of nixpkgs' rustc (IFD):
#                        each name it knows has rustc's vendor, os, env
#                        and families (and abi, where the name spells one)
{
  pkgs,
  bb,
  runTests,
}:
let
  inherit (pkgs) lib;
  tt = bb.targetTraits;
  r = triple: tt.resolve { inherit triple; };
  pick = fields: t: lib.getAttrs fields t;
  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;

  # A target breakbulk knows nothing about, declared by the user, as
  # mkRepository resolves it.
  repo = bb.mkRepository {
    inherit pkgs;
    root = ../fixtures/walking-skeleton;
    modules = [
      {
        workspaces.main.targets."my-board" = { };
        targets."my-board".traits = {
          arch = "x86_64";
          os = "linux";
          env = "musl";
          exeSuffix = ".elf";
        };
        # A known triple with one trait corrected.
        workspaces.main.targets."x86_64-unknown-linux-gnu".traits.dylibPathVar = "MY_LIBS";
      }
    ];
  };
  board = repo.workspaces.main.target."my-board".traits;
  native = repo.workspaces.main.target."x86_64-unknown-linux-gnu".traits;

  rustcCfgs = pkgs.runCommand "rustc-target-cfgs" { nativeBuildInputs = [ pkgs.rustc ]; } ''
    for t in $(rustc --print target-list); do
      # Targets whose LLVM backend nixpkgs' LLVM lacks fail; skip them.
      rustc --print cfg --target "$t" > cfg 2>/dev/null || continue
      printf '%s' "$t"
      for k in vendor os env abi; do
        printf '\t%s' "$(sed -n "s/^target_$k=\"\(.*\)\"$/\1/p" cfg)"
      done
      printf '\t%s\n' "$(sed -n 's/^target_family="\(.*\)"$/\1/p' cfg | paste -sd, -)"
    done > $out
  '';
  rows = map (
    l:
    let
      f = lib.splitString "\t" l;
    in
    {
      triple = lib.elemAt f 0;
      vendor = lib.elemAt f 1;
      os = lib.elemAt f 2;
      env = lib.elemAt f 3;
      abi = lib.elemAt f 4;
      families = lib.elemAt f 5;
    }
  ) (lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile rustcCfgs)));
  check =
    row:
    let
      p = tt.parse row.triple;
    in
    if p == null then
      null
    else if
      p.vendor == row.vendor
      && p.os == row.os
      && p.env == row.env
      && lib.concatStringsSep "," p.families == row.families
      # rustc infers some abis the name does not spell (powerpc64's elfv1
      # and elfv2); a spelled one must match.
      && (p.abi == "" || p.abi == row.abi)
    then
      true
    else
      "${row.triple}: parsed ${builtins.toJSON (removeAttrs p [ "arch" "triple" ])}, rustc says ${builtins.toJSON row}";
  results = map check rows;
  mismatches = lib.filter builtins.isString results;
  known = lib.count (x: x == true) results;
in
{
  target-traits = runTests "target-traits" {
    testLinuxGnu = {
      expr = pick [
        "arch"
        "vendor"
        "os"
        "env"
        "isLinux"
        "objectFormat"
        "exeSuffix"
        "dylibPathVar"
        "stagePreset"
        "debugSideFile"
        "linkerWritesDebugFile"
      ] (r "x86_64-unknown-linux-gnu");
      expected = {
        arch = "x86_64";
        vendor = "unknown";
        os = "linux";
        env = "gnu";
        isLinux = true;
        objectFormat = "elf";
        exeSuffix = "";
        dylibPathVar = "LD_LIBRARY_PATH";
        stagePreset = "linuxGnu";
        debugSideFile = "dwp";
        linkerWritesDebugFile = false;
      };
    };
    testMsvc = {
      expr = pick [
        "isWindows"
        "isMsvc"
        "isMingw"
        "objectFormat"
        "exeSuffix"
        "dylibPrefix"
        "dylibSuffix"
        "staticlibPrefix"
        "staticlibSuffix"
        "debugSideFile"
        "linkerWritesDebugFile"
        "dylibPathVar"
        "dylibPathSep"
        "stagePreset"
      ] (r "aarch64-pc-windows-msvc");
      expected = {
        isWindows = true;
        isMsvc = true;
        isMingw = false;
        objectFormat = "pe";
        exeSuffix = ".exe";
        dylibPrefix = "";
        dylibSuffix = ".dll";
        staticlibPrefix = "";
        staticlibSuffix = ".lib";
        debugSideFile = "pdb";
        linkerWritesDebugFile = true;
        dylibPathVar = "PATH";
        dylibPathSep = ";";
        stagePreset = "msvc";
      };
    };
    testMingw = {
      expr = map (t: pick [ "isMingw" "abi" "staticlibSuffix" "stagePreset" ] (r t)) [
        "x86_64-pc-windows-gnu"
        "x86_64-pc-windows-gnullvm"
      ];
      expected = [
        {
          isMingw = true;
          abi = "";
          staticlibSuffix = ".a";
          stagePreset = null;
        }
        {
          isMingw = true;
          abi = "llvm";
          staticlibSuffix = ".a";
          stagePreset = null;
        }
      ];
    };
    testWasm = {
      expr = map (t: pick [ "os" "env" "isWasm" "isWasi" "exeSuffix" "dylibPathVar" "objectFormat" ] (r t)) [
        "wasm32-unknown-unknown"
        "wasm32-wasip2"
      ];
      expected = [
        {
          os = "unknown";
          env = "";
          isWasm = true;
          isWasi = false;
          exeSuffix = ".wasm";
          dylibPathVar = null;
          objectFormat = "wasm";
        }
        {
          os = "wasi";
          env = "p2";
          isWasm = true;
          isWasi = true;
          exeSuffix = ".wasm";
          dylibPathVar = null;
          objectFormat = "wasm";
        }
      ];
    };
    testOthers = {
      expr = map (t: pick [ "os" "env" "abi" "objectFormat" "isLinux" "stagePreset" ] (r t)) [
        "aarch64-unknown-linux-musl"
        "riscv64gc-unknown-linux-gnu"
        "x86_64-unknown-none"
        "thumbv7em-none-eabihf"
        "aarch64-linux-android"
        "aarch64-apple-darwin"
      ];
      expected = [
        {
          os = "linux";
          env = "musl";
          abi = "";
          objectFormat = "elf";
          isLinux = true;
          stagePreset = "linuxGnu";
        }
        {
          os = "linux";
          env = "gnu";
          abi = "";
          objectFormat = "elf";
          isLinux = true;
          stagePreset = "linuxGnu";
        }
        {
          os = "none";
          env = "";
          abi = "";
          objectFormat = "elf";
          isLinux = false;
          stagePreset = null;
        }
        {
          os = "none";
          env = "";
          abi = "eabihf";
          objectFormat = "elf";
          isLinux = false;
          stagePreset = null;
        }
        {
          os = "android";
          env = "";
          abi = "";
          objectFormat = "elf";
          isLinux = true;
          stagePreset = "linuxGnu";
        }
        {
          os = "macos";
          env = "";
          abi = "";
          objectFormat = "macho";
          isLinux = false;
          stagePreset = null;
        }
      ];
    };
    # The linker kinds of the targets presets cover, from traits alone.
    testLinkerKinds = {
      expr = map (t: bb.presets.linkerKind { triple = t; }) [
        "x86_64-unknown-linux-gnu"
        "aarch64-unknown-linux-musl"
        "x86_64-pc-windows-msvc"
        "wasm32-wasip2"
        "wasm32-unknown-unknown"
        "x86_64-pc-windows-gnullvm"
      ];
      expected = [
        "mold"
        "mold"
        "lld-link"
        "wasm-component-ld"
        "wasm-ld"
        "mingw-lld"
      ];
    };
    # The test runner kinds (lib/presets/runner.nix), from traits alone.
    testRunnerKinds = {
      expr = map (c: bb.presets.runnerKind ({ traits = r c.t; } // removeAttrs c [ "t" ])) [
        {
          t = "x86_64-unknown-linux-gnu";
          canExecute = true;
        }
        {
          t = "aarch64-unknown-linux-gnu";
          canExecute = false;
        }
        {
          t = "aarch64-unknown-linux-gnu";
          canExecute = false;
          nativeBuilder = true;
        }
        {
          t = "x86_64-pc-windows-msvc";
          canExecute = false;
        }
        {
          t = "aarch64-pc-windows-msvc";
          canExecute = false;
        }
        {
          t = "i686-pc-windows-gnu";
          canExecute = false;
        }
        {
          t = "wasm32-wasip2";
          canExecute = false;
        }
        {
          t = "wasm32-unknown-unknown";
          canExecute = false;
        }
        {
          t = "wasm32-unknown-unknown";
          canExecute = false;
          flavor = "wasm-bindgen";
        }
        {
          t = "x86_64-unknown-linux-gnu";
          canExecute = true;
          flavor = "zig";
        }
        {
          t = "x86_64-unknown-none";
          canExecute = false;
        }
      ];
      expected = [
        "native"
        "qemu-user"
        "native-builder"
        "wine"
        "none"
        "wine"
        "wasmtime"
        "none"
        "wasm-bindgen"
        "ld-so"
        "none"
      ];
    };
    # Unknown names: no built-in traits, and every field fails only when
    # read.
    testUnknownParse = {
      expr = map tt.parse [
        "thumbv7em-none-eabihf.json"
        "x86_64-unknown-hermit"
        "my-board"
      ];
      expected = [
        null
        null
        null
      ];
    };
    testUnknownFailsLazily = {
      expr =
        let
          u = r "my-board";
        in
        [
          (builtins.isAttrs u)
          (fails u.isLinux)
          (fails (bb.presets.linkerKind { triple = "my-board"; }))
        ];
      expected = [
        true
        true
        true
      ];
    };
    # A user's base fields recompute the derived ones; a derived field set
    # directly wins.
    testUserTraits = {
      expr = pick [ "triple" "os" "env" "vendor" "isLinux" "objectFormat" "exeSuffix" "dylibPathVar" "stagePreset" ] (
        tt.resolve {
          triple = "my-board";
          traits = {
            os = "linux";
            env = "musl";
            exeSuffix = ".elf";
          };
        }
      );
      expected = {
        triple = "my-board";
        os = "linux";
        env = "musl";
        vendor = "unknown";
        isLinux = true;
        objectFormat = "elf";
        exeSuffix = ".elf";
        dylibPathVar = "LD_LIBRARY_PATH";
        stagePreset = "linuxGnu";
      };
    };
    # Through mkRepository: `targets.<t>.traits` reaches the resolved
    # target, and decisions made from it.
    testRepositoryTraits = {
      expr = {
        board = pick [ "os" "env" "exeSuffix" "isLinux" "stagePreset" ] board;
        linker = bb.presets.linkerKind {
          triple = "my-board";
          traits = board;
        };
        scope = bb.products.shippedRemapScope {
          triple = "my-board";
          traits = board;
        };
        nativeVar = native.dylibPathVar;
        nativeOs = native.os;
      };
      expected = {
        board = {
          os = "linux";
          env = "musl";
          exeSuffix = ".elf";
          isLinux = true;
          stagePreset = "linuxGnu";
        };
        linker = "mold";
        scope = "macro,diagnostics";
        nativeVar = "MY_LIBS";
        nativeOs = "linux";
      };
    };
  };

  target-traits-rustc =
    assert lib.assertMsg (mismatches == [ ])
      "target-traits-rustc: parse disagrees with rustc:\n${lib.concatStringsSep "\n" mismatches}";
    # Every target breakbulk has a preset or a test for is known.
    assert lib.assertMsg (known >= 200) "target-traits-rustc: only ${toString known} targets known";
    pkgs.runCommand "target-traits-rustc" { } ''
      echo "${toString known} of ${toString (lib.length rows)} rustc targets parsed, all agreeing with rustc --print cfg" > $out
    '';
}
