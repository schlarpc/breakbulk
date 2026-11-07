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
