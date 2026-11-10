# More target fixtures (riscv64, windows-gnu, wasip2, zig) through
# mkRepository (IFD). Imported by ./default.nix; every attribute is a flake
# check. All are HEAVY-ish: they
# download rust-overlay toolchains with extra targets and build (or
# substitute) cross toolchains.
#
#   wasip2-*          wasm32-wasip2 std component (rustc's wasm-component-ld),
#                     C against the headers of the wasi-sdk release whose
#                     wasi-libc Rust bundles (lib/wasi-sdk.nix); tests under
#                     wasmtime
#   riscv64-*         riscv64gc-unknown-linux-gnu via linux (nixpkgs cross,
#                     mold), openssl-sys and zstd-sys from the cross env
#                     capture; product and tests under qemu-riscv64
#   windows-gnu-*     x86_64-pc-windows-gnu (mingw gcc, msvcrt) and
#   windows-gnullvm-* x86_64-pc-windows-gnullvm (LLVM mingw, ucrt), lld,
#                     +crt-static: only system DLLs, PE time stamp 0; run
#                     and tests under wine. Determinism was checked by hand
#                     (`nix-build --check` on the .exe link units)
#   windows-gnullvm-aarch64-build   aarch64-pc-windows-gnullvm: product
#                     and test binary link as ARM64 PE32+, time stamp 0,
#                     only system DLLs; nothing runs them. Rebuilds checked
#                     by hand (`nix build --rebuild` on every unit and stage)
#   uefi-*            x86_64- and aarch64-unknown-uefi with no preset (the
#                     target spec's rust-lld as lld-link): an EFI application
#                     PE with a PDB in the debug output
#   windows-dll-*     a windows-gnu test binary importing a DLL its build
#                     script built: the test run finds it through WINEPATH;
#                     without it, wine fails (missing DLL); -beside-exe:
#                     the copy its build script puts next to the binaries
#                     goes beside the .exe with the buildScriptFiles stage
#   linux-portable-*  linuxPortable (zig backend): the host triple against
#                     glibc 2.17 with zig cc; newest GLIBC symbol version
#                     2.17 (objdump -T); host units keep the host linker
#                     (asserted on the plan); the preset's
#                     `portableLibraries` check passes (NEEDED: glibc's
#                     libraries only), and fails, naming the library, when
#                     only libc.so.6 is allowed; it allows libgcc_s and
#                     libstdc++ (a g++-built program passes)
#   linux-portable-container-eval   evaluation only: the container runner
#                     below leaves the test binary's derivation unchanged
#   linux-portable-native-glibc   HEAVY (builds OpenSSL and zlib with zig
#                     cc, ~5 min): linuxPortable's rebuildInputs, static
#                     libraries only; openssl-sys and libz-sys link them
#                     statically (static pkg-config), so the product needs
#                     no library but glibc's and GLIBC_2.17 at most
#                     (objdump -T); `portableLibraries` passes
#
# Not flake checks: `containerChecks`, built by
# `nix run .#test-linux-portable-container` (network: the CentOS 7.9 image
# from Docker Hub, ~75 MB):
#   linux-portable-centos7-*   the product and the test binaries run inside
#                     a CentOS 7 userland (glibc 2.17 and its own loader)
#                     with bwrap, not through the build machine's ld.so
#   linux-portable-native-centos7-*   the linux-portable-native product and
#                     tests in the container
#
# build-std (tests/fixtures/build-std, build-std-deps) is in ./build-std.nix.
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
      modules = modules ++ extraModules;
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
      targets.${wasip2}.preset = presets.wasmComponent {
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
      # The linker wrapper finds rustc's wasm-component-ld on PATH, passes
      # rustc's arguments through unchanged (crt1 objects and libc from
      # rustc's self-contained directory), keeps `-flavor wasm` first and
      # adds the wasm-ld. C code gets the headers of the wasi-sdk release
      # whose libc.a rustc bundles, byte for byte.
      wasip2-linker =
        let
          spec = presets.wasmComponent {
            inherit pkgs;
            triple = wasip2;
            rustc = wasip2Rust;
            withC = true;
          };
          sysroot = breakbulk.wasiSdk.sysrootFor {
            inherit pkgs;
            rustc = wasip2Rust;
          };
          sc = "/x/lib/rustlib/wasm32-wasip2/lib/self-contained";
          wasmLd =
            (breakbulk.llvmVersions.packagesFor {
              inherit pkgs;
              rustc = wasip2Rust;
            }).lld;
        in
        assert lib.assertMsg (
          spec.rustflags or [ ] == [ ]
        ) "wasip2-linker: rustflags ${toString spec.rustflags}";
        assert lib.assertMsg (
          spec.cflags == [ "-isystem ${sysroot}/include/wasm32-wasip2" ]
        ) "wasip2-linker: cflags ${toString spec.cflags}";
        assert breakbulk.wasiSdk.versionFor wasip2Rust.version == "33";
        pkgs.runCommand "wasip2-linker" { } ''
          mkdir -p fake
          printf '#!${pkgs.runtimeShell}\nfor a in "$@"; do case $a in @*) cat "''${a#@}";; *) echo "$a";; esac; done\n' > fake/wasm-component-ld
          chmod +x fake/wasm-component-ld
          echo ${sc}/crt1-reactor.o > args.rsp
          PATH=$PWD/fake:$PATH ${spec.linker.content} -flavor wasm ${sc}/crt1-command.o x.o @args.rsp > got.txt
          cat got.txt
          printf '%s\n' -flavor wasm ${sc}/crt1-command.o x.o ${sc}/crt1-reactor.o \
            --wasm-ld-path ${wasmLd}/bin/wasm-ld > want.txt
          diff want.txt got.txt
          # The headers' library is the toolchain's own.
          cmp ${sysroot}/lib/wasm32-wasip2/libc.a \
            ${wasip2Rust}/lib/rustlib/wasm32-wasip2/lib/self-contained/libc.a
          test -f ${sysroot}/include/wasm32-wasip2/stdio.h
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
      targets.${rv}.preset = presets.linux;
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
        preset = presets.windows;
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
    // windowsGnuChecksFor "windows-gnullvm" "x86_64-pc-windows-gnullvm"
    // windowsDllChecks
    // windowsGnullvmAarch64Checks;

  # aarch64 gnullvm: nixpkgs' ucrtAarch64 (LLVM mingw-w64). Its own
  # repository, so the x86_64 checks keep their toolchain. wine runs no
  # ARM64 code, so the product and the test binary are only linked.
  wgnuA64 = "aarch64-pc-windows-gnullvm";
  windowsGnullvmA64Repo = mkRepo (fixtures + "/windows-gnu") [
    {
      workspaces.main = wsWith (rustWith [ wgnuA64 ]) [ wgnuA64 ];
      targets.${wgnuA64}.preset = presets.windows;
    }
  ];
  windowsGnullvmAarch64Checks =
    let
      t = windowsGnullvmA64Repo.workspaces.main.target.${wgnuA64};
      exe = "${t.packages.gnu-smoke}/bin/gnu-smoke.exe";
    in
    {
      # An ARM64 PE32+ linked by lld (no time stamp), importing only
      # system DLLs; the test binary links too.
      windows-gnullvm-aarch64-build =
        pkgs.runCommand "windows-gnullvm-aarch64-build"
          {
            nativeBuildInputs = [
              pkgs.file
              pkgs.llvmPackages.llvm
            ];
            tests = lib.attrValues t.tests.gnu-smoke;
          }
          ''
            set -euo pipefail
            file ${exe} | tee file.txt
            grep -q 'PE32+ executable.*ARM64' file.txt
            llvm-readobj --file-headers --coff-imports ${exe} > pe.txt
            grep -q 'Machine: IMAGE_FILE_MACHINE_ARM64 ' pe.txt
            grep -q 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' pe.txt || { grep TimeDateStamp pe.txt; echo "PE time stamp is not 0"; exit 1; }
            sed -n 's/^ *Name: \(.*\.dll\)$/\1/Ip' pe.txt | tee dlls.txt
            [ -s dlls.txt ]
            if grep -viE 'kernel32|api-ms-win|ntdll|user32|ws2_32|bcrypt|advapi32|userenv' dlls.txt; then
              echo "imports a non-system DLL"; exit 1
            fi
            find -L $tests -type f -name '*.exe' > tests.txt
            [ -s tests.txt ]
            while read -r f; do file -L "$f" | grep -q 'PE32+ executable.*ARM64'; done < tests.txt
            mkdir -p $out
            cp file.txt dlls.txt $out/
          '';
    };

  # --- uefi ----------------------------------------------------------------------

  # No preset: `targets.<t> = { }` and rustc's target spec links with its
  # own rust-lld as lld-link.
  uefiTriples = [
    "x86_64-unknown-uefi"
    "aarch64-unknown-uefi"
  ];
  uefiRepo = mkRepo (fixtures + "/uefi") [
    { workspaces.main = wsWith (rustWith uefiTriples) uefiTriples; }
  ];
  uefiCheckFor =
    triple: machine:
    let
      product = uefiRepo.workspaces.main.target.${triple}.packages.app;
    in
    pkgs.runCommand "uefi-${triple}"
      {
        nativeBuildInputs = [ pkgs.llvmPackages.llvm ];
        inherit product;
        debug = product.debug;
      }
      ''
        set -euo pipefail
        efi=$product/bin/app.efi
        llvm-readobj --file-headers "$efi" > headers.txt
        grep -q 'Machine: ${machine} ' headers.txt
        grep -q 'Subsystem: IMAGE_SUBSYSTEM_EFI_APPLICATION ' headers.txt
        # The PDB is in the debug output, under the name the .efi gives.
        pdb=$(echo $debug/bin/*.pdb)
        grep -qaF "$(basename "$pdb")" "$efi"
        mkdir -p $out
        cp headers.txt $out/
      '';
  uefiChecks = {
    uefi-x86_64 = uefiCheckFor "x86_64-unknown-uefi" "IMAGE_FILE_MACHINE_AMD64";
    uefi-aarch64 = uefiCheckFor "aarch64-unknown-uefi" "IMAGE_FILE_MACHINE_ARM64";
  };

  # A test binary that imports a DLL its build script built into OUT_DIR.
  # The test run finds it through WINEPATH (the wine runner's
  # dynamic-library variable); the negative control runs the same binary
  # under the runner without it, which fails as a missing DLL (status 53).
  windowsDllRepo = mkRepo (fixtures + "/windows-dll") [
    {
      workspaces.main = wsWith (rustWith [ "x86_64-pc-windows-gnu" ]) [ "x86_64-pc-windows-gnu" ];
      targets."x86_64-pc-windows-gnu".preset = presets.windows;
    }
  ];
  # The same with the `buildScriptFiles` stage (#23): the DLL the build
  # script copied next to the binaries goes into the product.
  windowsDllStagedRepo = mkRepo (fixtures + "/windows-dll") [
    {
      workspaces.main = wsWith (rustWith [ "x86_64-pc-windows-gnu" ]) [ "x86_64-pc-windows-gnu" ];
      targets."x86_64-pc-windows-gnu".preset = presets.windows;
      packages.windows-dll.stages.buildScriptFiles = {
        before = "install";
        run = breakbulk.stages.helpers.buildScriptFiles { };
      };
    }
  ];
  windowsDllChecks =
    let
      t = windowsDllRepo.workspaces.main.target."x86_64-pc-windows-gnu";
      run = t.testRuns.windows-dll."lib/windows_dll";
      plain = t.packages.windows-dll;
      staged = windowsDllStagedRepo.workspaces.main.target."x86_64-pc-windows-gnu".packages.windows-dll;
    in
    {
      windows-dll-test = run;
      # #23: the build script copies bbdll.dll next to the binaries. The
      # product's default `buildScriptFiles` check fails naming it, and the
      # .exe alone fails as a missing DLL (53); with the stage, install
      # puts the DLL beside the .exe in bin/, and the .exe runs under wine
      # without WINEPATH, as from Cargo's target/<triple>/<profile>.
      windows-dll-beside-exe =
        pkgs.runCommand "windows-dll-beside-exe"
          {
            failure = pkgs.testers.testBuildFailure plain.checks.buildScriptFiles;
            stagedCheck = staged.checks.buildScriptFiles;
          }
          ''
            cat $failure/testBuildFailure.log
            grep -qF 'bbdll.dll (from ' $failure/testBuildFailure.log
            grep -qF 'packages.windows-dll.stages.buildScriptFiles = { before = "install"; run = ' $failure/testBuildFailure.log
            ls ${plain}/bin ${staged}/bin
            [ ! -e ${plain}/bin/bbdll.dll ]
            set +e
            ${lib.escapeShellArgs t.runner} ${plain}/bin/windows-dll.exe > plain.txt 2>&1
            status=$?
            set -e
            cat plain.txt
            [ "$status" = 53 ] || { echo "expected a missing-DLL failure (53), got $status"; exit 1; }
            [ -f ${staged}/bin/bbdll.dll ]
            unset WINEPATH
            ${lib.escapeShellArgs t.runner} ${staged}/bin/windows-dll.exe > staged.txt
            tr -d '\r' < staged.txt | tee staged2.txt
            grep -qx 'answer=42' staged2.txt
            mkdir -p $out
            cp staged2.txt $out/
          '';
      windows-dll-needs-dll =
        pkgs.runCommand "windows-dll-needs-dll"
          {
            nativeBuildInputs = [
              pkgs.buildPackages.binutils
              pkgs.jq
            ];
          }
          ''
            exe=$(echo ${run.binary}/*)
            objdump -p "$exe" | grep -i 'DLL Name' | tee dlls.txt
            grep -q 'bbdll.dll' dlls.txt
            # Before WINEPATH, the run set LD_LIBRARY_PATH to the same
            # directories, as Cargo does on a Linux host: wine does not
            # search it for DLLs.
            # (Without content addressing, which copies them elsewhere.)
            dirs=$(jq -rn ${lib.escapeShellArg breakbulk.testRuns.dylibJq} ${
              lib.concatMapStringsSep " " (f: "${f}/directives.json") run.breakbulkTest.dylib.flags
            })
            echo "LD_LIBRARY_PATH=$dirs"
            # OUT_DIR, and since #23 the copy of <profile> the build script
            # also put the DLL in.
            listing=$(tr : '\n' <<< "$dirs" | while IFS= read -r d; do ls "$d"; done)
            grep -q bbdll.dll <<< "$listing"
            set +e
            LD_LIBRARY_PATH=$dirs ${lib.escapeShellArgs t.runner} "$exe" > out.txt 2>&1
            status=$?
            set -e
            cat out.txt
            [ "$status" = 53 ] || { echo "expected a missing-DLL failure (53), got $status"; exit 1; }
            grep -q 'test result: ok' ${run}/log
            # The test binary attribute is named as Cargo names it, with the
            # target's executable suffix (traits.executableSuffix).
            test -x ${t.tests.windows-dll.lib}/bin/windows_dll.exe
            mkdir -p $out
            cp dlls.txt $out/
          '';
    };

  # --- linux-portable (zig) ---------------------------------------------------

  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  zigRust = rustWith [ ];
  zigRepo = mkRepo (fixtures + "/linux-portable") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native}.preset = presets.linuxPortable { glibc = "2.17"; };
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
      linux-portable-glibc =
        pkgs.runCommand "linux-portable-glibc"
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
            grep -qE "^zig: headers=2.17 args=3 runtime=2\.[0-9]+$" out.txt
            mkdir -p $out
            cp versions.txt out.txt $out/
          '';
      linux-portable-test = t.testRuns.app."bin/app";
      # The preset's check: NEEDED names only glibc's libraries.
      linux-portable-libraries = t.packages.app.checks.portableLibraries;
      # The product names no Nix store path.
      linux-portable-no-store-paths = t.packages.app.checks.portableNoStorePaths;
      # Negative control: with only libc.so.6 allowed, the check fails
      # and names a library the product needs (libpthread.so.0, …).
      linux-portable-libraries-negative =
        let
          strict = breakbulk.stageHelpers.neededLibraries {
            allowed = [ "libc.so.6" ];
            why = "only libc";
          };
        in
        pkgs.runCommand "linux-portable-libraries-negative"
          {
            failure = pkgs.testers.testBuildFailure (strict {
              input = t.packages.app;
              product.name = "app";
              inherit pkgs;
            });
          }
          ''
            cat $failure/testBuildFailure.log
            grep -q 'neededLibraries: app: bin/app needs ld-linux-x86-64.so.2, which is not an allowed run-time library: only libc' $failure/testBuildFailure.log
            test "$(tail -n1 $failure/testBuildFailure.log)" = 'or, when app may load them: packages.app.checks.neededLibraries = null;'
            touch $out
          '';
      # The preset's check allows GCC's runtime libraries,
      # as manylinux does: a g++-built program that needs libstdc++.so.6
      # and libgcc_s.so.1 passes, and both are listed as needed.
      linux-portable-libraries-cxx =
        let
          cxx = pkgs.runCommandCC "cxx-program" { } ''
            mkdir -p $out/bin
            printf '#include <iostream>\nint main() { try { throw 1; } catch (int) { std::cout << "ok"; } }\n' > m.cpp
            g++ -shared-libgcc m.cpp -o $out/bin/cxx
          '';
          check = (presets.linuxPortable { glibc = "2.17"; } { inherit pkgs; }).checks.portableLibraries.run {
            input = cxx;
            product.name = "cxx";
            inherit pkgs;
          };
        in
        pkgs.runCommand "linux-portable-libraries-cxx" { } ''
          cat ${check}/needed
          grep -qxF 'bin/cxx: libstdc++.so.6' ${check}/needed
          grep -qxF 'bin/cxx: libgcc_s.so.1' ${check}/needed
          touch $out
        '';
      # Evaluation only: the container runner reaches test runs, not units.
      linux-portable-container-eval =
        assert lib.assertMsg (
          zigContainerRepo.workspaces.main.target.${native}.tests.app.bin-app.drvPath
          == t.tests.app.bin-app.drvPath
        ) "zig: the container runner changed the test binary";
        pkgs.runCommand "linux-portable-container-eval" { } "touch $out";
    }
    // zigNativeChecks;

  # A real glibc 2.17 system: CentOS 7.9's userland from its Docker Hub
  # image (a fixed-output pull by digest), unpacked into the store. The
  # runner starts a program inside it with bubblewrap, which works inside
  # the Nix sandbox (a nested user namespace): the image is the root, as a
  # temporary overlay so mount points can be created; the store, $TMPDIR,
  # /tmp and $out are bound in. Programs are exec'd directly, so the
  # kernel loads the binary's own interpreter, /lib64/ld-linux-x86-64.so.2,
  # which is CentOS's, and that finds CentOS's libc.so.6.
  centos7Image = pkgs.dockerTools.pullImage {
    imageName = "docker.io/library/centos";
    # 7.9.2009, linux/amd64 (the manifest list is sha256:be65f488…).
    imageDigest = "sha256:dead07b4d8ed7e29e98de0f4504d87e8880d4347859d839686a31da35a3b532f";
    finalImageTag = "7.9.2009";
    os = "linux";
    arch = "amd64";
    sha256 = "sha256-cb3pSApk6OB4P1rYNnR0rOxZdjTq9WaT0qwKb2b8Klk=";
  };
  centos7Rootfs = pkgs.runCommand "centos-7.9-rootfs" { nativeBuildInputs = [ pkgs.jq ]; } ''
    tar -xf ${centos7Image} manifest.json
    mkdir $out
    for l in $(jq -r '.[0].Layers[]' manifest.json); do
      tar -xf ${centos7Image} "$l"
      tar -xf "$l" -C $out --no-same-owner --no-same-permissions --exclude='dev/*'
    done
    chmod -R u+rwX $out
    test -e $out/usr/lib64/libc-2.17.so
  '';
  centos7Runner = pkgs.writeShellScript "breakbulk-runner-centos7" ''
    args=(--overlay-src ${centos7Rootfs} --tmp-overlay / --dev /dev --proc /proc
      --ro-bind /nix/store /nix/store)
    for d in "''${TMPDIR:-}" /tmp "''${out:-}"; do
      [[ -n $d && -e $d ]] && args+=(--bind "$d" "$d")
    done
    exec ${pkgs.bubblewrap}/bin/bwrap "''${args[@]}" --chdir "$PWD" "$@"
  '';
  # The same workspace and preset with the container as runner. Units are
  # the same derivations as zigRepo's (a runner reaches only test runs).
  zigContainerRepo = mkRepo (fixtures + "/linux-portable") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native} = {
        preset = presets.linuxPortable { glibc = "2.17"; };
        runner = centos7Runner;
      };
      # The fixture's `runs_on_expected_glibc` test compares the runtime
      # glibc (gnu_get_libc_version) with this.
      packages.app.test.env.BB_EXPECT_RUNTIME_GLIBC = "2.17";
    }
  ];
  zigContainerChecks =
    let
      t = zigContainerRepo.workspaces.main.target.${native};
      bin = "${t.packages.app}/bin/app";
    in
    {
      linux-portable-centos7-run = pkgs.runCommand "linux-portable-centos7-run" { } ''
        mkdir -p $out
        ${centos7Runner} /usr/bin/ldd --version > $out/ldd.txt
        head -n1 $out/ldd.txt
        grep -qx 'ldd (GNU libc) 2\.17' $out/ldd.txt
        # Exec'd directly: the binary's interpreter is CentOS's loader.
        ${centos7Runner} ${bin} a b | tee $out/out.txt
        grep -qx "zig: headers=2.17 args=3 runtime=2.17" $out/out.txt
      '';
      # libtest under CentOS 7, `runs_on_expected_glibc` included.
      linux-portable-centos7-test = t.testRuns.app."bin/app";
    }
    // zigNativeContainerChecks;

  # Native libraries rebuilt with zig cc against glibc 2.17 (decisions
  # 102, 122): openssl-sys and libz-sys find them through breakbulk's
  # sysDefaults (pkg-config, `inputs = p: [ p.openssl … ]`), called with
  # the preset's package set. The rebuilds are static libraries only and
  # pkg-config runs in static mode, so the product links them statically
  # and needs nothing at run time but glibc's libraries.
  zigNativePreset = presets.linuxPortable {
    glibc = "2.17";
    rebuildInputs = [
      "openssl"
      "zlib"
    ];
  };
  zigNativeLibs =
    let
      set = (zigNativePreset { inherit pkgs; }).packageSet.content;
    in
    {
      inherit (set.breakbulkZigRebuilt) openssl zlib;
      # The package set hands out the rebuilt packages, nixpkgs' otherwise
      # (any other derivation with an evaluation warning; checked by hand:
      # reading `set.curl` warns "a package input uses nixpkgs' `curl`…").
      check =
        set.openssl == set.breakbulkZigRebuilt.openssl
        && set.openssl.drvPath != pkgs.openssl.drvPath
        && set ? lib
        && set.stdenv == pkgs.stdenv;
    };
  zigNativeRepo = mkRepo (fixtures + "/linux-portable-native") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native} = {
        preset = zigNativePreset;
        runner = centos7Runner;
      };
    }
  ];
  zigNativeChecks =
    let
      t = zigNativeRepo.workspaces.main.target.${native};
      bin = "${t.packages.app}/bin/app";
      inherit (zigNativeLibs) openssl zlib;
    in
    assert lib.assertMsg zigNativeLibs.check "zig: rebuildInputs package set";
    {
      # HEAVY: builds OpenSSL with zig cc (about 5 minutes on 4 cores).
      # OpenSSL and zlib are archives only, linked into the product, which
      # needs GLIBC_2.17 at most and no library but glibc's.
      linux-portable-native-glibc =
        pkgs.runCommand "linux-portable-native-glibc"
          {
            nativeBuildInputs = [ pkgs.buildPackages.binutils ];
          }
          ''
            mkdir -p $out
            test -f ${lib.getLib openssl}/lib/libcrypto.a
            test -f ${lib.getLib zlib}/lib/libz.a
            v=$(objdump -T ${bin} | { grep -o 'GLIBC_[0-9.]*' || true; } | sort -uV | tail -n1)
            echo "${bin}: $v" | tee $out/versions.txt
            newest=$(printf '%s\n' "$v" GLIBC_2.17 | sort -V | tail -n1)
            [ "$newest" = GLIBC_2.17 ] || { echo "${bin} needs $v"; exit 1; }
            readelf -dW ${bin} | grep NEEDED | tee $out/needed.txt
            if grep -E 'libssl|libcrypto|libz' $out/needed.txt; then
              echo "the product loads OpenSSL or zlib at run time" >&2
              exit 1
            fi
          '';
      linux-portable-native-libraries = t.packages.app.checks.portableLibraries;
      # OpenSSL's compiled-in directories are system paths
      # (the rebuild's OPENSSLDIR), so the product names no store path.
      linux-portable-native-no-store-paths = t.packages.app.checks.portableNoStorePaths;
    };
  zigNativeContainerChecks =
    let
      t = zigNativeRepo.workspaces.main.target.${native};
      bin = "${t.packages.app}/bin/app";
    in
    {
      # The product runs in the CentOS 7 container.
      linux-portable-native-centos7-run = pkgs.runCommand "linux-portable-native-centos7-run" { } ''
        mkdir -p $out
        ${centos7Runner} ${bin} | tee $out/out.txt
        grep -qx "zig-native: OpenSSL 3\.[0-9.]* sha256(abc)=ba7816bf zlib=1\.[0-9.]* adler32=11e60398" $out/out.txt
      '';
      linux-portable-native-centos7-test = t.testRuns.app."lib/app";
    };
in
{
  repos = {
    inherit
      wasip2Repo
      riscv64Repo
      windowsGnuRepo
      windowsGnullvmA64Repo
      uefiRepo
      windowsDllRepo
      windowsDllStagedRepo
      zigRepo
      zigNativeRepo
      ;
  };
  checks = wasip2Checks // riscv64Checks // windowsGnuChecks // zigChecks // uefiChecks;
  # Opt-in, network: `nix run .#test-linux-portable-container`.
  containerChecks = zigContainerChecks;
}
