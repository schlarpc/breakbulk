# MSVC cross spike (docs/spikes/msvc.md): build spikes/msvc for
# <arch>-pc-windows-msvc with plain cargo (no breakbulk), against an xwin
# SDK, and optionally run the result under wine.
#
#   import ./spikes/msvc { inherit pkgs sdk; arch = "x86_64"; }
#
# pkgs needs rust-overlay. `sdk` is a breakbulk.xwinSdk covering `arch`.
# Attributes: `exe` (the built .exe), `run` (runs it under wine and checks
# its output; x86_64 only).
{
  pkgs,
  sdk,
  arch ? "x86_64",
  rustc ? pkgs.rust-bin.stable.latest.minimal.override {
    targets = [ "${arch}-pc-windows-msvc" ];
  },
  # Must match rustc's LLVM major version (`rustc -vV`).
  llvmPackages ? pkgs.llvmPackages_23,
  wine ? pkgs.wineWow64Packages.minimal,
  # Shell run after env.sh, for ablations (docs/spikes/msvc.md), e.g.
  # "unset LIB" or "export EXTRA_RUSTFLAGS=...; . ./env.sh".
  postEnv ? "",
  # Rustflags appended for target units, e.g. "-C target-feature=+crt-static".
  extraRustflags ? "",
  # Link through lld-link-stable-tmp.sh, which keeps rustc's random temp
  # dir name out of the PDB (and so out of the .exe's PDB GUID).
  stableTmp ? true,
  # Expected first line of the program's output under wine.
  expect ? "smoke: c_add=42 pid_match=true resource=resource-ok",
}:
let
  inherit (pkgs) lib;
  triple = "${arch}-pc-windows-msvc";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./build.rs
      ./src
      ./csrc
      ./env.sh
    ];
  };
  linkWrapper = pkgs.writeShellScript "lld-link-stable-tmp" (builtins.readFile ./lld-link-stable-tmp.sh);
  vendor = pkgs.rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };

  exe = pkgs.stdenv.mkDerivation {
    name = "msvc-smoke-${triple}";
    inherit src;
    # stdenv.cc links the build script (a host binary); nothing in the
    # target build uses it.
    nativeBuildInputs = [ rustc ];
    env = {
      SDK = "${sdk}";
      ARCH = arch;
      LLVM = "${llvmPackages.llvm}";
      CLANG = "${llvmPackages.clang-unwrapped}";
      LLD = "${llvmPackages.lld}";
      LIBCLANG = "${lib.getLib llvmPackages.libclang}";
      EXTRA_RUSTFLAGS = extraRustflags;
      CARGO_BUILD_JOBS = "4";
    };
    buildPhase = ''
      runHook preBuild
      export CARGO_HOME=$TMPDIR/cargo-home
      mkdir -p $CARGO_HOME
      cat > $CARGO_HOME/config.toml <<EOF
      [source.crates-io]
      replace-with = "vendored"
      [source.vendored]
      directory = "${vendor}"
      EOF
      . ./env.sh
      ${lib.optionalString stableTmp ''export "CARGO_TARGET_''${T}_LINKER=${linkWrapper}"''}
      ${postEnv}
      env | grep -E '^([A-Za-z0-9_]*(MSVC|msvc)[A-Za-z0-9_]*|RC|RCFLAGS|LIB|INCLUDE|LIBCLANG_PATH)=' | sort
      cargo build --offline --locked --release --target ${triple}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp target/${triple}/release/msvc-smoke.exe $out/bin/
      cp target/${triple}/release/msvc_smoke.pdb $out/bin/
      runHook postInstall
    '';
    dontFixup = true;
  };

  run = pkgs.runCommand "msvc-smoke-${triple}-wine" { nativeBuildInputs = [ wine ]; } ''
    export HOME=$TMPDIR WINEPREFIX=$TMPDIR/wine WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
    wineboot --init >/dev/null 2>&1 || true
    wine ${exe}/bin/msvc-smoke.exe > out.txt
    cat out.txt
    grep -qxF ${lib.escapeShellArg expect} <(tr -d '\r' < out.txt)
    cp out.txt $out
  '';
in
{
  inherit exe run;
}
