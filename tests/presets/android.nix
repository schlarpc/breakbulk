# Android cross-built from Linux with presets.android and the NDK
# (tests/fixtures/android), through mkRepository (IFD). Imported by
# ./default.nix; every attribute of `checks` is a flake check.
#
# The NDK: these checks fetch it (~800 MB) through breakbulk.androidNdk,
# which is unfree (the Android SDK License Agreement). That is the
# author's own licence decision for this repository's tests, not a
# breakbulk default: the preset requires `ndk`. `ndkPkgs` is the package
# set admitting it, and only it.
#
#   android-aarch64     aarch64-linux-android, API level 26: the cdylibs
#                       and the binary are aarch64 ELF files for Android's
#                       loader (/system/bin/linker64), needing exactly the
#                       libraries listed (readelf NEEDED), with no RUNPATH;
#                       cc-rs's C is in `native`, its C++ in `cpp`, whose
#                       product ships the NDK's libc++_shared.so and no
#                       other library; `cpp` calls bindings bindgen made
#                       from the NDK's <android/log.h> (alog-sys); debug
#                       info is in the `debug` outputs by build ID; the
#                       products' noSourceReferences checks pass; the test
#                       binaries link. Determinism:
#                       `nix run .#test-rebuild -- android`
#   android-no-runner   nothing runs Android programs in the sandbox:
#                       canRunTests is false, repo.checks has no test runs,
#                       and a run built anyway fails naming the device it
#                       did not find. The runs on an emulator:
#                       `nix run .#test-android-emulator`
#   android-eval        evaluation: the linker kind, the default API level
#                       (the NDK's oldest), the missing-NDK and old-API
#                       errors, the traits, the default-preset choice
{
  pkgs,
  breakbulk,
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
  ndkPkgs ? import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = p: pkgs.lib.getName p == "android-ndk";
  },
}:
let
  inherit (pkgs) lib;
  presets = breakbulk.presets;
  triple = "aarch64-linux-android";
  rust = pkgs.rust-bin.stable."1.99.0".minimal.override { targets = [ triple ]; };
  ndkVersion = "29.0.14206865";
  ndk = breakbulk.androidNdk {
    pkgs = ndkPkgs;
    version = ndkVersion;
  };

  repo = breakbulk.mkRepository {
    inherit pkgs;
    tools = breakbulk.mkTools pkgs;
    root = ../fixtures/android;
    modules = [
      {
        workspaces.main = {
          toolchain = {
            rustc = rust;
            cargo = rust;
          };
          targets.${triple} = { };
          variants.default.profile = "release";
        };
        targets.${triple}.preset = presets.android {
          inherit ndk;
          apiLevel = 26;
        };
      }
    ]
    ++ extraModules;
  };
  t = repo.workspaces.main.target.${triple};
  p = t.packages.native;
  c = t.packages.cpp;

  aarch64 =
    pkgs.runCommand "android-aarch64"
      {
        nativeBuildInputs = [
          pkgs.binutils-unwrapped-all-targets
          pkgs.file
        ];
        testBins = lib.concatMap lib.attrValues (lib.attrValues t.variants.default.tests);
        checks = lib.concatMap (q: lib.attrValues q.checks) [
          p
          c
        ];
      }
      ''
        set -euo pipefail
        # checkFile <file> <debug output> <the sonames it needs, sorted>
        checkFile() {
          local f=$1 debug=$2 needed=$3
          echo "== $f"
          file "$f" | tee -a file.txt | grep 'ELF 64-bit LSB .*ARM aarch64' > /dev/null
          readelf -d "$f" > dyn.txt
          if grep -E 'RUNPATH|RPATH' dyn.txt; then echo "$f has a run path"; exit 1; fi
          # Exactly these libraries, by soname.
          got=$(grep NEEDED dyn.txt | sed 's/.*\[\(.*\)\]/\1/' | LC_ALL=C sort | tr '\n' ' ')
          echo "needs: $got"
          [ "$got" = "$needed " ] || { echo "$f needs $got, expected $needed"; exit 1; }
          # The NDK's crtbegin notes the API level.
          readelf -n "$f" | grep -A2 'Android' | tee note.txt | grep -q 'description data: 1a 00 00 00'
          # Debug info is in the debug output, by build ID.
          id=$(readelf -n "$f" | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
          [ -f $debug/lib/debug/.build-id/''${id:0:2}/''${id:2}.debug ]
          if readelf -S -W "$f" | grep -q ' \.debug_info '; then echo "$f keeps its debug info"; exit 1; fi
        }
        checkFile ${p}/bin/native ${p.debug} "libc.so libdl.so"
        readelf -l ${p}/bin/native | grep -q '/system/bin/linker64'
        # cc-rs's C, compiled by the NDK's clang against bionic's stdio.h.
        nm ${p}/bin/native | grep -q ' T describe$'
        grep -qa 'c scales %d to %d' ${p}/bin/native
        checkFile ${p}/lib/libnative.so ${p.debug} "libc.so libdl.so"
        nm -D --defined-only ${p}/lib/libnative.so | grep -q ' T native_scale$'
        nm ${p}/lib/libnative.so | grep -q ' t scale$'
        # No C++, so no C++ runtime.
        [ ! -e ${p}/lib/libc++_shared.so ]

        # C++ through cc-rs, against libc++_shared.so, which the product
        # ships next to it; liblog for alog-sys, whose bindings bindgen
        # generated from the NDK's <android/log.h>.
        checkFile ${c}/lib/libcpp.so ${c.debug} "libc++_shared.so libc.so libdl.so liblog.so"
        nm -D --defined-only ${c}/lib/libcpp.so | grep -q ' T cpp_count_words$'
        nm -D ${c}/lib/libcpp.so | grep -q ' U __android_log_write$'
        file ${c}/lib/libc++_shared.so | grep 'ELF 64-bit LSB shared object, ARM aarch64' > /dev/null
        readelf -d ${c}/lib/libc++_shared.so | grep -q 'SONAME.*\[libc++_shared.so\]'
        ls ${c}/lib > cpp-lib.txt
        [ "$(LC_ALL=C sort cpp-lib.txt | tr '\n' ' ')" = "libc++_shared.so libcpp.so " ]

        # The test binaries link for the target too.
        find -L $testBins -type f -perm -u+x > tests.txt
        [ -s tests.txt ]
        while read -r f; do file -L "$f" | grep 'ELF 64-bit LSB .*ARM aarch64' > /dev/null; done < tests.txt
        mkdir -p $out
        cp file.txt $out/
      '';

  noRunner =
    let
      checkNames = lib.attrNames repo.checks;
      runChecks = lib.filter (
        n: lib.hasInfix "/${triple}/" n && (lib.hasInfix "/test/" n || lib.hasSuffix "/doctest" n)
      ) checkNames;
      run = lib.head (lib.attrValues t.variants.default.testRuns.native);
    in
    assert lib.assertMsg (!t.canRunTests) "android: canRunTests is true";
    assert lib.assertMsg (runChecks == [ ]) "android: repo.checks has test runs: ${toString runChecks}";
    pkgs.runCommand "android-no-runner" { failure = pkgs.testers.testBuildFailure run; } ''
      cat $failure/testBuildFailure.log
      grep -qF 'adb finds no Android device or emulator' $failure/testBuildFailure.log
      touch $out
    '';

  # Evaluation only. An NDK stand-in: a store-path-like value with a
  # version and a toolchain, never built.
  fakeNdk = {
    version = ndkVersion;
    outPath = "/nix/store/00000000000000000000000000000000-android-ndk-${ndkVersion}";
    toolchain = "/nix/store/00000000000000000000000000000000-android-ndk-${ndkVersion}/toolchains/llvm/prebuilt/linux-x86_64";
  };
  direct =
    args:
    (breakbulk.evalTargetSpec {
      inherit pkgs triple;
      toolchain.rustc = rust;
      modules = [ { preset = presets.android args; } ];
    }).config;
  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  traits = breakbulk.targetTraits.resolve { inherit triple; };
  armTraits = breakbulk.targetTraits.resolve { triple = "armv7-linux-androideabi"; };
  evalChecks = {
    linkerKind = breakbulk.presetHelpers.linkerKind { inherit triple; } == "ndk";
    # The NDK's oldest API level by default; the driver names it.
    defaultApi = lib.hasSuffix "/aarch64-linux-android21-clang" (direct { ndk = fakeNdk; }).cc;
    apiLevel =
      lib.hasSuffix "/aarch64-linux-android26-clang"
        (direct {
          ndk = fakeNdk;
          apiLevel = 26;
        }).cc;
    linker =
      lib.hasSuffix "/aarch64-linux-android26-clang"
        (direct {
          ndk = fakeNdk;
          apiLevel = 26;
        }).linker;
    tooOld =
      fails
        (direct {
          ndk = fakeNdk;
          apiLevel = 19;
        }).cc;
    noNdk = fails (direct { }).linker;
    notAndroid = fails (
      (breakbulk.evalTargetSpec {
        inherit pkgs;
        triple = "aarch64-unknown-linux-gnu";
        toolchain.rustc = rust;
        modules = [ { preset = presets.android { ndk = fakeNdk; }; } ];
      }).config.linker
    );
    noSandboxRuns = !(direct { ndk = fakeNdk; }).canRunTests;
    traits =
      !traits.isLinux
      && traits.isAndroid
      && traits.kernel == "linux"
      && traits.debugInfo == "split"
      && traits.ndkTriple == "aarch64-linux-android"
      && traits.androidAbi == "arm64-v8a"
      && armTraits.ndkTriple == "armv7a-linux-androideabi"
      && armTraits.androidAbi == "armeabi-v7a";
    choosePreset = breakbulk.targetTraits.presetRule { inherit pkgs triple; } ? choose;
    apiLevels = breakbulk.androidNdk.apiLevelsOf ndkVersion == { min = 21; };
    pinnedVersionsOnly =
      fails
        (breakbulk.androidNdk {
          pkgs = ndkPkgs;
          version = "29.0.1";
        }).drvPath;
  };
  failedEval = lib.filterAttrs (_: ok: !ok) evalChecks;
in
{
  inherit repo;
  checks = {
    android-aarch64 = aarch64;
    android-no-runner = noRunner;
    android-eval =
      if failedEval == { } then
        pkgs.runCommand "android-eval" { } "touch $out"
      else
        throw "android-eval: failed: ${toString (lib.attrNames failedEval)}";
  };
}
