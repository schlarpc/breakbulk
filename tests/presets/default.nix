# Checks for the toolchain-preset building blocks (lib/xwin-sdk.nix,
# lib/wasm-bindgen.nix), wired into the flake's `checks.<system>`.
#
#   wasm-bindgen-eval     evaluation-time assertions: version from a fixture
#                         lockfile, nixpkgs attribute preferred, table fallback,
#                         errors for missing/ambiguous/unknown versions
#   wasm-bindgen-table    fetches the crate and vendor directory of every entry
#                         in lib/wasm-bindgen-hashes.nix (network; FODs, mostly
#                         substituted)
#   wasm-bindgen-build    HEAVY-ish: builds wasm-bindgen-cli 0.2.123 (not in
#                         nixpkgs) from the table and checks `--version`
#
# With `xwinPkgs` (a package set that allows the unfree xwin SDK; see
# flake.nix) and on x86_64-linux:
#   msvc-sdk              HEAVY, network, unfree: the xwin CRT + SDK splat
#                         (~250 MB) and its layout and case symlinks
#
# The preset fixtures through mkRepository are in ./fixtures.nix and
# ./extra-targets.nix.
{
  pkgs,
  breakbulk,
  xwinPkgs ? null,
}:
let
  inherit (pkgs) lib;
  wb = breakbulk.wasmBindgen;
  fixtureLock = ./fixtures/wasm-bindgen-0.2.123.lock;

  lockText =
    packages:
    "version = 4\n"
    + lib.concatMapStrings (p: ''

      [[package]]
      name = "${p.name}"
      version = "${p.version}"
      ${lib.optionalString (p ? source) ''source = "${p.source}"''}
    '') packages;
  cratesIo = "registry+https://github.com/rust-lang/crates.io-index";
  entriesOf = packages: breakbulk.lockfile.fromLockText (lockText packages);

  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  failsDrv = d: !(builtins.tryEval d.drvPath).success;

  table = wb.forLockfile {
    inherit pkgs;
    lockfile = fixtureLock;
  };

  evalChecks = {
    versionFromFixture = wb.versionFromLockfile fixtureLock == "0.2.123";
    # 0.2.123 is not in nixpkgs, so it comes from the table.
    fixtureUsesTable =
      !(pkgs ? wasm-bindgen-cli_0_2_123)
      && table.version == "0.2.123"
      && table.wasmBindgenVersion == "0.2.123"
      && lib.hasPrefix "wasm-bindgen-cli-0.2.123" table.src.name;
    # A version nixpkgs packages is taken from nixpkgs.
    prefersNixpkgs =
      !(pkgs ? wasm-bindgen-cli_0_2_130)
      || (wb.forVersion {
        inherit pkgs;
        version = "0.2.130";
      }).drvPath == pkgs.wasm-bindgen-cli_0_2_130.drvPath;
    # ... unless asked not to, which builds the same version from the table.
    tableWhenAsked =
      let
        d = wb.forVersion {
          inherit pkgs;
          version = "0.2.130";
          preferNixpkgs = false;
        };
      in
      d.version == "0.2.130" && d.drvPath != (pkgs.wasm-bindgen-cli_0_2_130.drvPath or "");
    # The table's src hash agrees with nixpkgs' wherever both have a version.
    tableAgreesWithNixpkgs = lib.all (
      v:
      let
        n = wb.attrName v;
      in
      !(pkgs ? ${n})
      || pkgs.${n}.src.outputHash == (wb.forVersion {
        inherit pkgs;
        version = v;
        preferNixpkgs = false;
      }).src.outputHash
    ) (lib.attrNames wb.hashes);
    userHashes =
      (wb.forVersion {
        inherit pkgs;
        version = "0.2.999";
        hashes."0.2.999" = {
          hash = lib.fakeHash;
          cargoHash = lib.fakeHash;
        };
      }).version == "0.2.999";
    unknownVersionFails = failsDrv (
      wb.forVersion {
        inherit pkgs;
        version = "0.2.1";
      }
    );
    noWasmBindgenFails = fails (
      wb.versionFromEntries (entriesOf [
        {
          name = "ui";
          version = "0.1.0";
        }
      ])
    );
    twoVersionsFail = fails (
      wb.versionFromEntries (entriesOf [
        {
          name = "wasm-bindgen";
          version = "0.2.123";
          source = cratesIo;
        }
        {
          name = "wasm-bindgen";
          version = "0.2.130";
          source = cratesIo;
        }
      ])
    );
    pathWasmBindgenFails = fails (
      wb.versionFromEntries (entriesOf [
        {
          name = "wasm-bindgen";
          version = "0.2.123";
        }
      ])
    );
    # The same version locked twice (e.g. merged lockfiles) is one version.
    duplicateIsFine =
      wb.versionFromEntries (entriesOf [
        {
          name = "wasm-bindgen";
          version = "0.2.123";
          source = cratesIo;
        }
        {
          name = "wasm-bindgen";
          version = "0.2.123";
          source = "sparse+https://index.crates.io/";
        }
      ]) == "0.2.123";
  };
  failedEval = lib.filterAttrs (_: ok: !ok) evalChecks;

  tableDrvs = lib.mapAttrs (
    v: _:
    wb.forVersion {
      inherit pkgs;
      version = v;
      preferNixpkgs = false;
    }
  ) wb.hashes;

  msvc =
    let
      sdk = breakbulk.xwinSdk {
        pkgs = xwinPkgs;
        manifestVersion = 17;
        crt = "14.44.17.14";
        sdk = "10.0.26100";
        arches = [
          "x86_64"
          "aarch64"
        ];
        hash = "sha256-22dqk0tKSbC4bnfsnhhsG0aEJfUHb3JJNL3TnZGFVa0=";
      };
    in
    {
      msvc-sdk = pkgs.runCommand "msvc-sdk-layout" { } ''
        set -eu
        for d in ${lib.escapeShellArgs (sdk.includeDirs ++ sdk.libDirs.x86_64 ++ sdk.libDirs.aarch64)}; do
          test -d "$d" || { echo "missing $d"; exit 1; }
        done
        # The case symlinks xwin adds.
        test -L ${sdk.sdkIncludeDir}/um/windows.h
        test -f ${sdk.sdkIncludeDir}/um/Windows.h
        test -e ${lib.head sdk.sdkLibDirs.x86_64}/kernel32.lib
        test -e ${lib.head sdk.sdkLibDirs.x86_64}/KERNEL32.lib
        test -f ${sdk.crtLibDir.aarch64}/msvcrt.lib
        # No dangling links.
        if find ${sdk} -xtype l | grep -q .; then find ${sdk} -xtype l | head; exit 1; fi
        touch $out
      '';
    };
in
{
  wasm-bindgen-eval =
    if failedEval == { } then
      pkgs.runCommand "wasm-bindgen-eval" { } "touch $out"
    else
      throw "wasm-bindgen-eval: failed: ${toString (lib.attrNames failedEval)}";

  wasm-bindgen-table = pkgs.linkFarm "wasm-bindgen-table" (
    lib.concatLists (
      lib.mapAttrsToList (v: d: [
        {
          name = "${v}/src";
          path = d.src;
        }
        {
          name = "${v}/vendor";
          path = d.cargoDeps;
        }
      ]) tableDrvs
    )
  );

  wasm-bindgen-build = pkgs.runCommand "wasm-bindgen-build" { } ''
    v=$(${table}/bin/wasm-bindgen --version)
    echo "$v"
    test "$v" = "wasm-bindgen 0.2.123"
    touch $out
  '';
}
// lib.optionalAttrs (xwinPkgs != null && pkgs.stdenv.buildPlatform.system == "x86_64-linux") msvc
# Preset fixtures through mkRepository (./fixtures.nix): IFD, rust-overlay
# toolchains with cross targets, nixpkgs cross toolchains (cached).
// lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux" && pkgs ? rust-bin) (
  (import ./fixtures.nix { inherit pkgs breakbulk xwinPkgs; }).checks
)
# More target fixtures (./extra-targets.nix), with the same requirements.
// lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux" && pkgs ? rust-bin) (
  (import ./extra-targets.nix { inherit pkgs breakbulk; }).checks
)
# -Zbuild-std (./build-std.nix): rust-overlay's nightly with rust-src.
// lib.optionalAttrs (pkgs.stdenv.buildPlatform.system == "x86_64-linux" && pkgs ? rust-bin) (
  builtins.removeAttrs (import ./build-std.nix { inherit pkgs breakbulk; }) [ "repos" ]
)
