# M7 fixtures: later targets through mkRepository (IFD). Imported by
# ./default.nix; every attribute is a flake check. All are HEAVY-ish: they
# download rust-overlay toolchains with extra targets and build (or
# substitute) cross toolchains.
#
#   wasip2-*          wasm32-wasip2 std component (rustc's wasm-component-ld),
#                     C against nixpkgs' wasi-libc built for wasip2 (built
#                     here, not cached by Hydra); tests under wasmtime
#   riscv64-*         riscv64gc-unknown-linux-gnu via linuxGnu (nixpkgs cross,
#                     mold), openssl-sys and zstd-sys from the cross env
#                     capture; product and tests under qemu-riscv64
#   windows-gnu-*     x86_64-pc-windows-gnu (mingw gcc, msvcrt) and
#   windows-gnullvm-* x86_64-pc-windows-gnullvm (LLVM mingw, ucrt), lld,
#                     +crt-static: only system DLLs, PE time stamp 0; run
#                     and tests under wine. Determinism was checked by hand
#                     (`nix-build --check` on the .exe link units)
#   zig-*             host triple against glibc 2.17 with zig cc; newest
#                     GLIBC symbol version 2.17 (objdump -T); host units
#                     keep the host linker (asserted on the plan)
#
# build-std (tests/fixtures/build-std, build-std-deps) is in ./build-std.nix.
{
  pkgs,
  breakbulk,
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  tools = breakbulk.mkTools pkgs;
  presets = breakbulk.presets;

  rustWith =
    targets:
    pkgs.rust-bin.stable."1.99.0".minimal.override {
      inherit targets;
    };

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      inherit modules;
    };

  wsWith = rust: triples: {
    toolchain = {
      rustc = rust;
      cargo = rust;
    };
    targets = lib.genAttrs triples (_: { });
    variants.default.profile = "release";
  };

  # --- wasip2 --------------------------------------------------------------------

  wasip2 = "wasm32-wasip2";
  wasip2Rust = rustWith [ wasip2 ];
  wasip2Repo = mkRepo (fixtures + "/wasip2") [
    {
      workspaces.main = wsWith wasip2Rust [ wasip2 ];
      targets.${wasip2}.preset = presets.wasip2 {
        rustc = wasip2Rust;
        withC = true;
      };
    }
  ];
  wasip2Checks =
    let
      t = wasip2Repo.workspaces.main.target.${wasip2};
    in
    {
      # The product is a component that runs under wasmtime; its C code
      # went through wasi-libc's snprintf.
      wasip2-run =
        pkgs.runCommand "wasip2-run"
          {
            nativeBuildInputs = [
              pkgs.wasm-tools
              pkgs.wasmtime
            ];
          }
          ''
            # install puts every wasm target's files under pkg/.
            wasm=${t.packages.app}/pkg/app.wasm
            wasm-tools validate --features component-model "$wasm"
            wasm-tools component wit "$wasm" > app.wit
            grep -q 'import wasi:cli/environment@0.2' app.wit
            ${lib.escapeShellArgs t.runner} "$wasm" x y | tee out.txt
            grep -qx "c says 42 to p2 (2) args=3" out.txt
            mkdir -p $out
            cp app.wit out.txt $out/
          '';
      # The linker wrapper finds rustc's wasm-component-ld on PATH, swaps
      # rustc's self-contained crt1 objects for wasilibc's (also inside a
      # response file), keeps `-flavor wasm` first and adds the wasm-ld.
      wasip2-linker =
        let
          spec = presets.wasip2 {
            inherit pkgs;
            rustc = wasip2Rust;
            withC = true;
          };
          sc = "/x/lib/rustlib/wasm32-wasip2/lib/self-contained";
          wasmLd =
            (breakbulk.llvmVersions.packagesFor {
              inherit pkgs;
              rustc = wasip2Rust;
            }).lld;
        in
        pkgs.runCommand "wasip2-linker" { } ''
          mkdir -p fake
          printf '#!${pkgs.runtimeShell}\nfor a in "$@"; do case $a in @*) cat "''${a#@}";; *) echo "$a";; esac; done\n' > fake/wasm-component-ld
          chmod +x fake/wasm-component-ld
          echo ${sc}/crt1-reactor.o > args.rsp
          PATH=$PWD/fake:$PATH ${spec.linker.content} -flavor wasm ${sc}/crt1-command.o x.o @args.rsp > got.txt
          cat got.txt
          libdir=${lib.removePrefix "native=" (lib.last spec.rustflags)}
          printf '%s\n' -flavor wasm $libdir/crt1-command.o x.o $libdir/crt1-reactor.o \
            --wasm-ld-path ${wasmLd}/bin/wasm-ld > want.txt
          diff want.txt got.txt
          test -f $libdir/crt1-command.o
          touch $out
        '';
      wasip2-test-lib = t.testRuns.app."lib/app";
      wasip2-test-bin = t.testRuns.app."bin/app";
      wasip2-test-it = t.testRuns.app.it;
    };

  # --- riscv64 -------------------------------------------------------------------

  rv = "riscv64gc-unknown-linux-gnu";
  rvRust = rustWith [ rv ];
  riscv64Repo = mkRepo (fixtures + "/riscv64") [
    {
      workspaces.main = wsWith rvRust [ rv ];
      targets.${rv}.preset = presets.linuxGnu;
      # openssl-sys and zstd-sys get pkg-config and the riscv64 openssl and
      # zstd from breakbulk's sysDefaults (lib/sys-defaults.nix), captured
      # with the riscv64 cross stdenv.
    }
  ];
  riscv64Checks =
    let
      t = riscv64Repo.workspaces.main.target.${rv};
    in
    {
      # A RISC-V ELF linked by mold, against the riscv64 OpenSSL, running
      # under qemu-riscv64.
      riscv64-run =
        pkgs.runCommand "riscv64-run" { nativeBuildInputs = [ pkgs.buildPackages.binutils ]; }
          ''
            f=${t.packages.app}/bin/app
            readelf -hW $f | grep -q 'Machine:.*RISC-V'
            readelf -p .comment $f | grep -q mold
            readelf -dW $f | grep NEEDED | tee needed.txt
            grep -q libcrypto.so needed.txt; grep -q libzstd.so needed.txt
            ${lib.escapeShellArgs t.runner} $f | tee out.txt
            grep -qx "arch=riscv64 openssl=3+ zstd=ok" out.txt
            mkdir -p $out
            cp needed.txt out.txt $out/
          '';
      riscv64-test-lib = t.testRuns.app."lib/app";
    };

  # --- windows-gnu ---------------------------------------------------------------

  wgnuTriples = [
    "x86_64-pc-windows-gnu"
    "x86_64-pc-windows-gnullvm"
  ];
  wgnuRust = rustWith wgnuTriples;
  windowsGnuRepo = mkRepo (fixtures + "/windows-gnu") [
    {
      workspaces.main = wsWith wgnuRust wgnuTriples;
      targets = lib.genAttrs wgnuTriples (_: {
        preset = presets.windowsGnu;
      });
    }
  ];
  # gnu: mingw-w64 gcc, msvcrt. gnullvm: LLVM mingw-w64 (clang, ucrt,
  # libunwind).
  windowsGnuChecksFor =
    name: triple:
    let
      t = windowsGnuRepo.workspaces.main.target.${triple};
      exe = "${t.packages.gnu-smoke}/bin/gnu-smoke.exe";
    in
    {
      # A PE32+ linked by lld (no time stamp), importing only system DLLs,
      # running under wine.
      "${name}-run" =
        pkgs.runCommand "${name}-run"
          {
            nativeBuildInputs = [
              pkgs.file
              pkgs.buildPackages.binutils
            ];
          }
          ''
            file ${exe} | tee file.txt
            grep -q 'PE32+ executable.*x86-64' file.txt
            objdump -p ${exe} > pe.txt
            grep -i 'DLL Name' pe.txt | tee dlls.txt
            if grep -viE 'kernel32|msvcrt|api-ms-win|ntdll|user32|ws2_32|bcrypt|advapi32|userenv' dlls.txt; then
              echo "imports a non-system DLL"; exit 1
            fi
            grep -q 'Time/Date.*00:00:00 1970' pe.txt || { grep Time/Date pe.txt; echo "PE time stamp is not 0"; exit 1; }
            ${lib.escapeShellArgs t.runner} ${exe} > out.txt
            tr -d '\r' < out.txt | tee out2.txt
            grep -qx "gnu-smoke: c_add=42 pid_match=true unwind=true" out2.txt
            mkdir -p $out
            cp file.txt dlls.txt out2.txt $out/
          '';
      "${name}-test" = t.testRuns.gnu-smoke."bin/gnu-smoke";
    };
  windowsGnuChecks =
    windowsGnuChecksFor "windows-gnu" "x86_64-pc-windows-gnu"
    // windowsGnuChecksFor "windows-gnullvm" "x86_64-pc-windows-gnullvm";

  # --- zig -----------------------------------------------------------------------

  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  zigRust = rustWith [ ];
  zigRepo = mkRepo (fixtures + "/zig") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native}.preset = presets.zig { glibc = "2.17"; };
    }
  ];
  zigChecks =
    let
      t = zigRepo.workspaces.main.target.${native};
      bin = "${t.packages.app}/bin/app";
      inst = zigRepo.workspaces.main.instances.${native}.default;
      plan = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (builtins.readFile "${inst.plans.build}/plan.json")
      );
      hostCompiles = lib.filter (u: u.platform == "host" && u.kind == "compile") (
        lib.attrValues plan.units
      );
      zigInHost = lib.filter (u: lib.hasInfix "zig-cc" (builtins.toJSON u)) hostCompiles;
    in
    assert lib.assertMsg (hostCompiles != [ ]) "zig: expected host compiles";
    assert lib.assertMsg (zigInHost == [ ]) "zig: host units use the zig linker";
    {
      # Every versioned GLIBC symbol the product imports is 2.17 or older;
      # it runs on the build machine's newer glibc.
      zig-glibc =
        pkgs.runCommand "zig-glibc"
          {
            nativeBuildInputs = [ pkgs.buildPackages.binutils ];
          }
          ''
            objdump -T ${bin} | grep -o 'GLIBC_[0-9.]*' | sort -uV | tee versions.txt
            max=$(tail -n1 versions.txt)
            echo "newest: $max"
            newest=$(printf '%s\n' "$max" GLIBC_2.17 | sort -V | tail -n1)
            [ "$newest" = GLIBC_2.17 ] || { echo "$max is newer than GLIBC_2.17"; exit 1; }
            ${lib.escapeShellArgs t.runner} ${bin} a b | tee out.txt
            grep -qx "zig: headers=2.17 args=3 runtime-ok=true" out.txt
            mkdir -p $out
            cp versions.txt out.txt $out/
          '';
      zig-test = t.testRuns.app."bin/app";
    };
in
{
  repos = {
    inherit
      wasip2Repo
      riscv64Repo
      windowsGnuRepo
      zigRepo
      ;
  };
  checks = wasip2Checks // riscv64Checks // windowsGnuChecks // zigChecks;
}
