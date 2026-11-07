{ pkgs ? import (import ./nixpkgs.nix) { system = "x86_64-linux"; } }:
let
  inherit (pkgs) lib;
  captureEnv = import ./capture.nix { inherit (pkgs) buildPackages; };
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  crossCapture = import ./capture.nix { inherit (cross) buildPackages; };
in
rec {
  inherit pkgs cross;

  captures = {
    # No inputs: what every package without inputs gets.
    base = captureEnv { stdenv = pkgs.stdenv; survey = true; };
    # openssl-sys
    openssl = captureEnv {
      stdenv = pkgs.stdenv; name = "openssl"; survey = true;
      nativeInputs = [ pkgs.pkg-config ]; inputs = [ pkgs.openssl ];
    };
    # zstd-sys with bindgen
    bindgen = captureEnv {
      stdenv = pkgs.stdenv; name = "bindgen"; survey = true;
      nativeInputs = [ pkgs.rustPlatform.bindgenHook pkgs.pkg-config ];
      inputs = [ pkgs.zstd ];
    };
    # Common setup hooks, to survey non-env state.
    broad = captureEnv {
      stdenv = pkgs.stdenv; name = "broad"; survey = true;
      nativeInputs = with pkgs; [
        pkg-config cmake perl python3 protobuf nasm autoconf automake libtool
        gettext rustPlatform.bindgenHook gobject-introspection glib makeWrapper
        meson ninja
      ];
      inputs = with pkgs; [ openssl zstd sqlite glib dbus ];
    };

    # Cross: target units of an aarch64 build use the cross stdenv.
    crossBase = crossCapture { stdenv = cross.stdenv; name = "cross-base"; survey = true; };
    crossOpenssl = crossCapture {
      stdenv = cross.stdenv; name = "cross-openssl"; survey = true;
      nativeInputs = [ cross.buildPackages.pkg-config ];
      inputs = [ cross.openssl ];
    };
    crossBindgen = crossCapture {
      stdenv = cross.stdenv; name = "cross-bindgen"; survey = true;
      nativeInputs = [ cross.buildPackages.rustPlatform.bindgenHook cross.buildPackages.pkg-config ];
      inputs = [ cross.zstd ];
    };
  };

  # Run probe.sh in a live stdenv and against a replayed capture.
  probePair = { stdenv, capture, nativeInputs ? [ ], inputs ? [ ], probePkg ? "", probeLib ? "", probeNoRun ? "" }:
    let
      common = {
        inherit probePkg probeLib probeNoRun;
        readelf = "${pkgs.binutils-unwrapped}/bin/readelf";
      };
    in {
      live = stdenv.mkDerivation (common // {
        name = "probe-live-${capture.name}";
        nativeBuildInputs = nativeInputs;
        buildInputs = inputs;
        buildCommand = ''bash -eu ${./probe.sh} > $out 2>&1 || { cat $out; exit 1; }'';
      });
      replay = derivation (common // {
        name = "probe-replay-${capture.name}";
        inherit (pkgs) system;
        builder = "${pkgs.bash}/bin/bash";
        args = [ ./replay.sh ];
        envJson = "${capture}/env.json";
        jq = "${pkgs.jq}/bin/jq";
        replayCommand = ./probe.sh;
      });
    };

  # End to end: the fixture (openssl-sys, ring, zstd-sys+bindgen) built
  #  - live: nixpkgs buildRustPackage, all inputs in one live stdenv;
  #  - replay: real cargo in a plain derivation; each unit gets only the
  #    replayed capture for its (platform, package).
  mkE2E = tp:
    let
      bp = tp.buildPackages;
      hostTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;
      targetTriple = tp.stdenv.hostPlatform.rust.rustcTarget;
      isCross = hostTriple != targetTriple;
      cap = import ./capture.nix { buildPackages = pkgs; };
      seed = "bbseed0000";
      captures = {
        # Host units (build scripts, proc macros, their deps) need no inputs here.
        host."*" = cap { stdenv = pkgs.stdenv; name = "e2e-host-base"; };
        target."*" = cap { stdenv = tp.stdenv; name = "e2e-target-base"; };
        target.openssl-sys = cap {
          stdenv = tp.stdenv; name = "e2e-openssl-sys";
          nativeInputs = [ bp.pkg-config ]; inputs = [ tp.openssl ];
        };
        target.zstd-sys = cap {
          stdenv = tp.stdenv; name = "e2e-zstd-sys";
          nativeInputs = [ bp.rustPlatform.bindgenHook bp.pkg-config ]; inputs = [ tp.zstd ];
        };
      };
      # Mirrors cargoSetupHook's generated config (pkgs/build-support/rust/hooks/default.nix).
      linkerConfig = lib.optionalString isCross ''
        [target."${targetTriple}"]
        "linker" = "${tp.stdenv.cc}/bin/${tp.stdenv.cc.targetPrefix}cc"
        "rustflags" = [ "-Ctarget-feature=-crt-static", "-Cforce-frame-pointers=yes" ]
      '' + ''
        [target."${hostTriple}"]
        "linker" = "${pkgs.stdenv.cc}/bin/cc"
        "rustflags" = [ "-Cforce-frame-pointers=yes" ]
      '';
      vendor = pkgs.rustPlatform.importCargoLock { lockFile = ./fixture/Cargo.lock; };
    in
    {
      inherit captures;
      live = tp.rustPlatform.buildRustPackage {
        pname = "e2e-live";
        version = "0.1.0";
        src = ./fixture;
        cargoLock.lockFile = ./fixture/Cargo.lock;
        nativeBuildInputs = [ bp.pkg-config bp.rustPlatform.bindgenHook ];
        buildInputs = [ tp.openssl tp.zstd ];
        NIX_OUTPATH_USED_AS_RANDOM_SEED = seed;
        doCheck = false;
        dontFixup = true;
        # cargo-auditable embeds a dependency list; keep binaries comparable.
        auditable = false;
        installPhase = "bash ${./driver/collect.sh} ${targetTriple}";
      };
      # Control: the live build without stdenv's "-rpath $out/lib", the one
      # difference the capture introduces on purpose.
      liveNoSelfRpath = (mkE2E tp).live.overrideAttrs { NIX_NO_SELF_RPATH = "1"; };
      replay = derivation {
        name = "e2e-replay-${targetTriple}";
        inherit (pkgs) system;
        builder = "${pkgs.bash}/bin/bash";
        args = [ ./driver/build.sh ];
        src = ./fixture;
        cargoConfig = ''
          [source.crates-io]
          replace-with = "vendored-sources"
          [source.vendored-sources]
          directory = "/build/cargo-vendor-dir"
        '' + linkerConfig;
        inherit vendor;
        toolPath = lib.makeBinPath [ bp.cargo bp.rustc pkgs.coreutils pkgs.bash pkgs.gnused ];
        BB_CAPTURES = builtins.toJSON (lib.mapAttrs (_: lib.mapAttrs (_: c: "${c}/env.json")) captures);
        # Toolchain-spec layer: the same variables nixpkgs' cargoBuildHook
        # passes (pkgs/build-support/rust/lib/default.nix, envVars.setEnv).
        "CC_${pkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}" = "${pkgs.stdenv.cc}/bin/cc";
        "CXX_${pkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}" = "${pkgs.stdenv.cc}/bin/c++";
        HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
        HOST_CXX = "${pkgs.stdenv.cc}/bin/c++";
        ${if isCross then "CC_${tp.stdenv.hostPlatform.rust.cargoEnvVarTarget}" else null} =
          "${tp.stdenv.cc}/bin/${tp.stdenv.cc.targetPrefix}cc";
        ${if isCross then "CXX_${tp.stdenv.hostPlatform.rust.cargoEnvVarTarget}" else null} =
          "${tp.stdenv.cc}/bin/${tp.stdenv.cc.targetPrefix}c++";
        BB_JQ = "${pkgs.jq}/bin/jq";
        BB_SEED = seed;
        BB_BASH = "${pkgs.bash}/bin/bash";
        BB_DRIVER = ./driver;
        BB_HOST_TRIPLE = hostTriple;
        BB_TARGET_TRIPLE = targetTriple;
        triple = targetTriple;
        collect = ./driver/collect.sh;
      };
    };

  e2e = {
    native = mkE2E pkgs;
    cross = mkE2E cross;
  };

  probes = {
    base = probePair { stdenv = pkgs.stdenv; capture = captures.base; };
    openssl = probePair {
      stdenv = pkgs.stdenv; capture = captures.openssl;
      nativeInputs = [ pkgs.pkg-config ]; inputs = [ pkgs.openssl ];
      probePkg = "openssl"; probeLib = "-lssl -lcrypto";
    };
    bindgen = probePair {
      stdenv = pkgs.stdenv; capture = captures.bindgen;
      nativeInputs = [ pkgs.rustPlatform.bindgenHook pkgs.pkg-config ]; inputs = [ pkgs.zstd ];
      probePkg = "libzstd"; probeLib = "-lzstd";
    };
    crossBase = probePair { stdenv = cross.stdenv; capture = captures.crossBase; probeNoRun = "1"; };
    crossOpenssl = probePair {
      stdenv = cross.stdenv; capture = captures.crossOpenssl;
      nativeInputs = [ cross.buildPackages.pkg-config ]; inputs = [ cross.openssl ];
      probePkg = "openssl"; probeLib = "-lssl -lcrypto"; probeNoRun = "1";
    };
  };
}
