# M7 fixtures: later targets through mkRepository (IFD). Imported by
# ./default.nix; every attribute is a flake check. All are HEAVY-ish: they
# download rust-overlay toolchains with extra targets and build (or
# substitute) cross toolchains.
#
#   wasip2-*          wasm32-wasip2 std component (rustc's wasm-component-ld),
#                     C against the headers of the wasi-sdk release whose
#                     wasi-libc Rust bundles (lib/wasi-sdk.nix); tests under
#                     wasmtime
#   riscv64-*         riscv64gc-unknown-linux-gnu via linuxGnu (nixpkgs cross,
#                     mold), openssl-sys and zstd-sys from the cross env
#                     capture; product and tests under qemu-riscv64
#   windows-gnu-*     x86_64-pc-windows-gnu (mingw gcc, msvcrt) and
#   windows-gnullvm-* x86_64-pc-windows-gnullvm (LLVM mingw, ucrt), lld,
#                     +crt-static: only system DLLs, PE time stamp 0; run
#                     and tests under wine. Determinism was checked by hand
#                     (`nix-build --check` on the .exe link units)
#   windows-dll-*     a windows-gnu test binary importing a DLL its build
#                     script built: the test run finds it through WINEPATH;
#                     without it, wine fails (missing DLL)
#   zig-*             host triple against glibc 2.17 with zig cc; newest
#                     GLIBC symbol version 2.17 (objdump -T); host units
#                     keep the host linker (asserted on the plan)
#   zig-centos7-*     HEAVY (network: the CentOS 7.9 image, ~75 MB): the
#                     product and the test binaries run inside a CentOS 7
#                     userland (glibc 2.17 and its own loader) with bwrap,
#                     not through the build machine's ld.so
#   zig-native-*      HEAVY (builds OpenSSL and zlib with zig cc, ~5 min):
#                     presets.zig's rebuildInputs; openssl-sys and libz-sys
#                     link the rebuilt libraries; product and tests in the
#                     CentOS 7 container
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
      # The linker wrapper finds rustc's wasm-component-ld on PATH, passes
      # rustc's arguments through unchanged (crt1 objects and libc from
      # rustc's self-contained directory), keeps `-flavor wasm` first and
      # adds the wasm-ld. C code gets the headers of the wasi-sdk release
      # whose libc.a rustc bundles, byte for byte (decision 99).
      wasip2-linker =
        let
          spec = presets.wasip2 {
            inherit pkgs;
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
    // windowsGnuChecksFor "windows-gnullvm" "x86_64-pc-windows-gnullvm"
    // windowsDllChecks;

  # A test binary that imports a DLL its build script built into OUT_DIR.
  # The test run finds it through WINEPATH (the wine runner's
  # dynamic-library variable); the negative control runs the same binary
  # under the runner without it, which fails as a missing DLL (status 53).
  windowsDllRepo = mkRepo (fixtures + "/windows-dll") [
    {
      workspaces.main = wsWith (rustWith [ "x86_64-pc-windows-gnu" ]) [ "x86_64-pc-windows-gnu" ];
      targets."x86_64-pc-windows-gnu".preset = presets.windowsGnu;
    }
  ];
  windowsDllChecks =
    let
      t = windowsDllRepo.workspaces.main.target."x86_64-pc-windows-gnu";
      run = t.testRuns.windows-dll."lib/windows_dll";
    in
    {
      windows-dll-test = run;
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
            ls $dirs | grep -q bbdll.dll
            set +e
            LD_LIBRARY_PATH=$dirs ${lib.escapeShellArgs t.runner} "$exe" > out.txt 2>&1
            status=$?
            set -e
            cat out.txt
            [ "$status" = 53 ] || { echo "expected a missing-DLL failure (53), got $status"; exit 1; }
            grep -q 'test result: ok' ${run}/log
            mkdir -p $out
            cp dlls.txt $out/
          '';
    };

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
            grep -qE "^zig: headers=2.17 args=3 runtime=2\.[0-9]+$" out.txt
            mkdir -p $out
            cp versions.txt out.txt $out/
          '';
      zig-test = t.testRuns.app."bin/app";
    }
    // zigContainerChecks;

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
  zigContainerRepo = mkRepo (fixtures + "/zig") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native} = {
        preset = presets.zig { glibc = "2.17"; };
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
      tz = zigRepo.workspaces.main.target.${native};
      bin = "${t.packages.app}/bin/app";
    in
    assert lib.assertMsg (
      t.tests.app.bin-app.drvPath == tz.tests.app.bin-app.drvPath
    ) "zig: the container runner changed the test binary";
    {
      zig-centos7-run = pkgs.runCommand "zig-centos7-run" { } ''
        mkdir -p $out
        ${centos7Runner} /usr/bin/ldd --version > $out/ldd.txt
        head -n1 $out/ldd.txt
        grep -qx 'ldd (GNU libc) 2\.17' $out/ldd.txt
        # Exec'd directly: the binary's interpreter is CentOS's loader.
        ${centos7Runner} ${bin} a b | tee $out/out.txt
        grep -qx "zig: headers=2.17 args=3 runtime=2.17" $out/out.txt
      '';
      # libtest under CentOS 7, `runs_on_expected_glibc` included.
      zig-centos7-test = t.testRuns.app."bin/app";
    }
    // zigNativeChecks;

  # Native libraries rebuilt with zig cc against glibc 2.17 (decision 102):
  # openssl-sys and libz-sys find them through breakbulk's sysDefaults
  # (pkg-config, `inputs = p: [ p.openssl … ]`), called with the preset's
  # package set. KNOWN GAP: zlib's configure does not recognise the
  # wrapped zig cc as gcc and finds "no shared library support", so the
  # rebuilt zlib is static only and libz-sys links its libz.a (still built
  # by zig cc). OpenSSL is shared. The product links libssl dynamically; zig adds no rpath, so
  # runs set LD_LIBRARY_PATH to the rebuilt libraries, as a deployment
  # would ship them next to the program.
  zigNativePreset = presets.zig {
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
  zigNativeLdPath = lib.makeLibraryPath [
    zigNativeLibs.openssl
    zigNativeLibs.zlib
  ];
  zigNativeRepo = mkRepo (fixtures + "/zig-native") [
    {
      workspaces.main = wsWith zigRust [ native ];
      targets.${native} = {
        preset = zigNativePreset;
        runner = centos7Runner;
      };
      packages.app.test.env.LD_LIBRARY_PATH = zigNativeLdPath;
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
      # The product and the libraries it loads need GLIBC_2.17 at most;
      # it runs in the CentOS 7 container.
      zig-native-centos7-run =
        pkgs.runCommand "zig-native-centos7-run"
          {
            nativeBuildInputs = [ pkgs.buildPackages.binutils ];
          }
          ''
            mkdir -p $out
            for f in ${bin} ${lib.getLib openssl}/lib/libssl.so.3 ${lib.getLib openssl}/lib/libcrypto.so.3; do
              v=$(objdump -T "$f" | { grep -o 'GLIBC_[0-9.]*' || true; } | sort -uV | tail -n1)
              echo "$f: $v" | tee -a $out/versions.txt
              newest=$(printf '%s\n' "$v" GLIBC_2.17 | sort -V | tail -n1)
              [ "$newest" = GLIBC_2.17 ] || { echo "$f needs $v"; exit 1; }
            done
            readelf -dW ${bin} | grep NEEDED | tee $out/needed.txt
            grep -q libcrypto.so.3 $out/needed.txt
            readelf -dW ${lib.getLib openssl}/lib/libssl.so.3 | grep -q 'SONAME.*libssl.so.3'
            LD_LIBRARY_PATH=${zigNativeLdPath} ${centos7Runner} ${bin} | tee $out/out.txt
            grep -qx "zig-native: OpenSSL 3\.[0-9.]* sha256(abc)=ba7816bf zlib=1\.[0-9.]* adler32=11e60398" $out/out.txt
          '';
      zig-native-centos7-test = t.testRuns.app."lib/app";
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
