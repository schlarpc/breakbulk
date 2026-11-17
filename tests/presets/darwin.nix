# macOS targets cross-built from Linux with presets.darwin
# (tests/fixtures/darwin), through mkRepository (IFD). Imported by
# ./default.nix; every attribute is a flake check.
#
# The SDK: these checks fetch Apple's macOS SDK 14.4 on a Linux machine,
# through breakbulk.appleSdk (nixpkgs' fixed-output fetch, unfree). That
# is the author's own licence decision for this repository's tests, not a
# default of breakbulk: the preset requires `sdk` on a machine that is not
# a Mac. `sdkPkgs` is the package set admitting it, and only it.
#
#   darwin-aarch64        aarch64-apple-darwin: every product is an arm64
#                         Mach-O for macOS 11.0, signed ad hoc under its
#                         own name, with no debug map; its `.dSYM` (same
#                         UUID, DWARF inside) is in the `debug` output next
#                         to where the file lands; `with-c` holds cc-rs's
#                         C, `framework` links CoreFoundation from the SDK
#                         (bin and cdylib); the products'
#                         noSourceReferences checks pass; the test binary
#                         links. Determinism was checked by hand (`nix
#                         build --rebuild` on the link units and stages)
#   darwin-x86_64         x86_64-apple-darwin: the pure product, x86_64,
#                         macOS 10.12, signed
#   darwin-no-runner      nothing runs macOS code here: canRunTests is
#                         false, repo.checks has no test runs, and a run
#                         fails naming targets.<t>.runner and testSystem
#   darwin-eval           evaluation: the linker rule (rust-lld for a
#                         rust-lang toolchain, ld64.lld for nixpkgs'), the
#                         SDK requirement (27.0 needs LLD 23.1.3 or
#                         nixpkgs' patch: rust-overlay 1.99.0's rust-lld,
#                         LLD 23.1.1, fails naming the ways out; nixpkgs'
#                         lld passes), the missing-SDK error naming Apple's
#                         agreement, `deploymentTarget`
{
  pkgs,
  breakbulk,
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
  sdkPkgs ? import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = p: pkgs.lib.getName p == "macOS-SDK";
  },
}:
let
  inherit (pkgs) lib;
  presets = breakbulk.presets;
  a64 = "aarch64-apple-darwin";
  x64 = "x86_64-apple-darwin";
  triples = [
    a64
    x64
  ];
  rust = pkgs.rust-bin.stable."1.99.0".minimal.override { targets = triples; };
  sdk = breakbulk.appleSdk {
    pkgs = sdkPkgs;
    version = "14.4";
  };

  repo = breakbulk.mkRepository {
    inherit pkgs;
    tools = breakbulk.mkTools pkgs;
    root = ../fixtures/darwin;
    modules = [
      {
        workspaces.main = {
          toolchain = {
            rustc = rust;
            cargo = rust;
          };
          targets = lib.genAttrs triples (_: { });
          variants.default.profile = "release";
        };
        targets = lib.genAttrs triples (_: {
          preset = presets.darwin { inherit sdk; };
        });
      }
    ]
    ++ extraModules;
  };
  ta = repo.workspaces.main.target.${a64};
  tx = repo.workspaces.main.target.${x64};

  tools = [
    pkgs.llvmPackages.llvm
    pkgs.rcodesign
    pkgs.file
  ];

  # Shell lines checking one product file: Mach-O of `arch` with minos
  # `minos`, signed ad hoc as `id`, no debug map; with `dsym`, that
  # bundle has its UUID and DWARF.
  checkFile = ''
    checkFile() {
      local f=$1 arch=$2 minos=$3 id=$4 dsym=''${5:-}
      echo "== $f"
      file "$f" | tee -a file.txt | grep "Mach-O 64-bit.*$arch" > /dev/null
      llvm-otool -l "$f" > lc.txt
      # LC_BUILD_VERSION, or before macOS 10.14 LC_VERSION_MIN_MACOSX.
      grep -A4 "LC_BUILD_VERSION\|LC_VERSION_MIN_MACOSX" lc.txt | grep -q "minos $minos\|version $minos"
      grep -q LC_CODE_SIGNATURE lc.txt
      rcodesign print-signature-info "$f" > sig.txt
      grep -q "identifier: $id\$" sig.txt || { cat sig.txt; echo "$f: not signed as $id"; exit 1; }
      if llvm-nm -a "$f" | grep '^[0-9a-f]* - '; then
        echo "$f keeps a debug map"; exit 1
      fi
      if [ -n "$dsym" ]; then
        [ "$(llvm-dwarfdump --uuid "$f" | cut -d' ' -f2)" = "$(llvm-dwarfdump --uuid "$dsym" | cut -d' ' -f2)" ]
        llvm-dwarfdump --debug-info "$dsym" | grep DW_TAG_compile_unit > /dev/null
      fi
    }
  '';

  aarch64 =
    let
      p = ta.packages;
      testBins = lib.attrValues ta.tests.pure;
    in
    pkgs.runCommand "darwin-aarch64"
      {
        nativeBuildInputs = tools;
        inherit testBins;
        checks = map (q: q.checks.noSourceReferences) [
          p.pure
          p.with-c
          p.framework
        ];
      }
      ''
        set -euo pipefail
        ${checkFile}
        checkFile ${p.pure}/bin/pure arm64 11.0 pure ${p.pure.debug}/bin/pure.dSYM
        checkFile ${p.with-c}/bin/with-c arm64 11.0 with-c ${p.with-c.debug}/bin/with-c.dSYM
        checkFile ${p.framework}/bin/framework arm64 11.0 framework ${p.framework.debug}/bin/framework.dSYM
        checkFile ${p.framework}/lib/libframework.dylib arm64 11.0 libframework.dylib \
          ${p.framework.debug}/lib/libframework.dylib.dSYM
        # cc-rs's C, compiled against the SDK's stdio.h.
        llvm-nm ${p.with-c}/bin/with-c | grep ' _greet$'
        grep -qa 'c says %d' ${p.with-c}/bin/with-c
        # CoreFoundation from the SDK's frameworks.
        llvm-otool -L ${p.framework}/bin/framework | tee dylibs.txt
        grep -q '/System/Library/Frameworks/CoreFoundation.framework/' dylibs.txt
        grep -q '/usr/lib/libSystem.B.dylib' dylibs.txt
        # The test binary links for the target too.
        find -L $testBins -type f -perm -u+x > tests.txt
        [ -s tests.txt ]
        while read -r f; do file -L "$f" | grep 'Mach-O 64-bit.*arm64' > /dev/null; done < tests.txt
        mkdir -p $out
        cp file.txt dylibs.txt $out/
      '';

  x86_64 =
    pkgs.runCommand "darwin-x86_64" { nativeBuildInputs = tools; } ''
      set -euo pipefail
      ${checkFile}
      checkFile ${tx.packages.pure}/bin/pure x86_64 10.12 pure ${tx.packages.pure.debug}/bin/pure.dSYM
      mkdir -p $out
      cp file.txt $out/
    '';

  noRunner =
    let
      checkNames = lib.attrNames repo.checks;
      runChecks = lib.filter (
        n: lib.hasInfix "/${a64}/" n && (lib.hasInfix "/test-" n || lib.hasSuffix "/doctest" n)
      ) checkNames;
      run = lib.head (lib.attrValues ta.testRuns.pure);
    in
    assert lib.assertMsg (!ta.canRunTests) "darwin: canRunTests is true";
    assert lib.assertMsg (runChecks == [ ]) "darwin: repo.checks has test runs: ${toString runChecks}";
    pkgs.runCommand "darwin-no-runner" { failure = pkgs.testers.testBuildFailure run; } ''
      cat $failure/testBuildFailure.log
      grep -qF 'targets."${a64}".runner' $failure/testBuildFailure.log
      grep -qF 'targets."${a64}".testSystem' $failure/testBuildFailure.log
      touch $out
    '';

  # Evaluation only. An SDK stand-in: a store-path-like value with a
  # version, never built.
  fakeSdk = v: {
    version = v;
    outPath = "/nix/store/00000000000000000000000000000000-macOS-SDK-${v}";
  };
  direct =
    args:
    presets.darwin (
      {
        inherit pkgs;
        triple = a64;
        rustc = rust;
      }
      // args
    );
  errorOf =
    v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then null else true;
  kindFor =
    rustc:
    presets.linkerKind {
      triple = a64;
      rustc = presets.rustcFacts { inherit pkgs rustc; };
    };
  evalChecks = {
    rustLldForRustLang = kindFor rust == "rust-lld";
    ld64LldForNixpkgs = kindFor pkgs.rustc == "ld64.lld";
    # 14.4 has no requirement; 27.0 needs arm64e.x1.
    sdk14 = breakbulk.appleSdk.requirementsOf "14.4" == [ ];
    sdk27 = map (r: r.feature) (breakbulk.appleSdk.requirementsOf "27.0") == [ "arm64e.x1" ];
    # rust-overlay 1.99.0's rust-lld is LLD 23.1.1: refused.
    rustLld27Fails = errorOf (direct { sdk = fakeSdk "27.0"; }).linker == true;
    rustLld26 = lib.hasSuffix "/bin/rust-lld" (direct { sdk = fakeSdk "26.5"; }).linker.content;
    # nixpkgs' lld reads it (LLD 23.1.3, or the backport in older majors).
    ld64Lld27 =
      (direct {
        sdk = fakeSdk "27.0";
        linkerKind = "ld64.lld";
      }).linker.content == "${pkgs.llvmPackages_23.lld}/bin/lld";
    ld64Lld27Llvm21 =
      (direct {
        sdk = fakeSdk "27.0";
        linkerKind = "ld64.lld";
        llvmPackages = pkgs.llvmPackages_21;
      }).linker.content == "${pkgs.llvmPackages_21.lld}/bin/lld";
    noSdkFails = errorOf (direct { }).linker == true;
    deploymentTarget =
      (direct {
        sdk = fakeSdk "14.4";
        deploymentTarget = "12.0";
      }).env.MACOSX_DEPLOYMENT_TARGET.content == "12.0";
    packed = (direct { sdk = fakeSdk "14.4"; }).rustflags == [
      "-C"
      "split-debuginfo=packed"
    ];
    sdkVersionString = (breakbulk.appleSdk { pkgs = sdkPkgs; version = "14.4"; }).version == "14.4";
    pinnedVersionsOnly = errorOf (breakbulk.appleSdk { pkgs = sdkPkgs; version = "14.5"; }).drvPath == true;
  };
  failedEval = lib.filterAttrs (_: ok: !ok) evalChecks;
  # The messages, which tryEval cannot read: checked by hand with
  # `nix-instantiate --eval` (the agreement's URL; the SDK, the
  # requirement, the LLD version and the ways out).
in
{
  inherit repo;
  checks = {
    darwin-aarch64 = aarch64;
    darwin-x86_64 = x86_64;
    darwin-no-runner = noRunner;
    darwin-eval =
      if failedEval == { } then
        pkgs.runCommand "darwin-eval" { } "touch $out"
      else
        throw "darwin-eval: failed: ${toString (lib.attrNames failedEval)}";
  };
}
