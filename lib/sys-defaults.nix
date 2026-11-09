# Curated per-package defaults for common `-sys` crates (and a few others
# with native dependencies), seeded from nixpkgs'
# pkgs/build-support/rust/default-crate-overrides.nix (nixpkgs p7yx739q,
# the flake's pinned nixos-unstable). Only what breakbulk can express is
# copied: `nativeBuildInputs` -> nativeInputs, `buildInputs` -> inputs,
# derivation env -> env. Applied by mkRepository when
# `sysDefaults.enable` (the default); user values merge with these by the
# module system's rules (lists concatenate, `lib.mkForce` replaces).
#
# Left out, because they are not per-package inputs or env in breakbulk:
#  - `extraLinkFlags = [ "-L${zlib.out}/lib" ]` (cairo-sys-rs, libz-sys,
#    curl-sys, glib-sys, soup3-sys, webkit2gtk-sys): a link flag for the
#    crate's own rustc call, which buildRustCrate links with. The search
#    path a final binary needs comes from the build script's
#    `rustc-link-search`, which breakbulk splices like Cargo does.
#  - `propagatedBuildInputs` (curl-sys): nothing propagates between
#    breakbulk packages; each declares its own inputs.
#  - `prePatch`/`postPatch` (evdev-sys touching libevdev/.git when cross
#    compiling; proc-macro-crate >= 2.0 replacing `env::var("CARGO")`):
#    sources are never patched. proc-macro-crate does not need it here,
#    because units keep Cargo's `CARGO`.
#  - evdev-sys's cross-only native inputs (python3, autoconf, automake,
#    libtool; `buildPlatform != hostPlatform`): cross presets supply them.
#  - nettle-sys's `clang` build input and `LIBCLANG_PATH` become
#    `rustPlatform.bindgenHook` on its host units, which sets both.
#  - `crateBin` (rink): target discovery is Cargo's own.
#  - prost-build's `protobuf`: prost-build is a library that other crates'
#    build scripts call, so `protoc` is needed by those packages' build
#    scripts, not prost-build's units. Declare
#    `packages.<the crate whose build.rs calls prost-build>.nativeInputs`.
#    The entries for opentelemetry-proto, prost-wkt-types and
#    tonic-reflection are kept as nixpkgs has them (their own build
#    scripts compile protos).
#  - Switches that make a crate use a system library instead of the one it
#    bundles. They change what gets built behind the
#    project's back (for example rusqlite's `bundled` feature would be
#    ignored), so the library inputs are kept and the choice is left to
#    the crate's own features and the project. Removed from nixpkgs'
#    entries: `AWS_LC_SYS_USE_SYSTEM` (aws-lc-sys >= 0.42),
#    `LIBGIT2_SYS_USE_PKG_CONFIG` (libgit2-sys),
#    `LIBSQLITE3_SYS_USE_PKG_CONFIG` (libsqlite3-sys) and
#    `ZSTD_SYS_USE_PKG_CONFIG` (zstd-sys). Set them per package to opt
#    in, e.g. `packages.libsqlite3-sys.env.LIBSQLITE3_SYS_USE_PKG_CONFIG
#    = "1";`. `AWS_LC_SYS_CMAKE_BUILDER` (aws-lc-sys < 0.42) is kept: it
#    picks how the bundled library is built, not which library.
{ config, lib, ... }:
let
  pc = p: [ p.pkg-config ];
in
{
  _file = "breakbulk/lib/sys-defaults.nix";

  config = lib.mkIf config.sysDefaults.enable {
    packages = {
      alsa-sys = {
        nativeInputs = pc;
        inputs = p: [ p.alsa-lib ];
      };
      "aws-lc-sys@>=0.42.0" = {
        nativeInputs = pc;
        inputs = p: [ p.aws-lc ];
      };
      "aws-lc-sys@<0.42.0" = {
        # nixpkgs: force the cmake backend.
        nativeInputs = p: [ p.cmake ];
        env.AWS_LC_SYS_CMAKE_BUILDER = "1";
      };
      cairo-rs.inputs = p: [ p.cairo ];
      cairo-sys-rs = {
        nativeInputs = pc;
        inputs = p: [ p.cairo ];
      };
      capnp-rpc.nativeInputs = p: [ p.capnproto ];
      cargo.inputs = p: [
        p.openssl
        p.zlib
        p.curl
      ];
      libz-sys = {
        nativeInputs = pc;
        inputs = p: [ p.zlib ];
      };
      curl-sys = {
        nativeInputs = pc;
        inputs = p: [
          p.zlib
          p.curl
        ];
      };
      dbus = {
        nativeInputs = pc;
        inputs = p: [ p.dbus ];
      };
      evdev-sys = {
        nativeInputs = pc;
        inputs = p: [ p.libevdev ];
      };
      expat-sys.nativeInputs = p: [ p.cmake ];
      foundationdb-sys.inputs = p: [ p.foundationdb ];
      foundationdb.inputs = p: [ p.foundationdb ];
      freetype-sys = {
        nativeInputs = p: [ p.cmake ];
        inputs = p: [ p.freetype ];
      };
      fuser = {
        nativeInputs = pc;
        inputs = p: [ p.fuse3 ];
      };
      glib-sys = {
        nativeInputs = pc;
        inputs = p: [ p.glib ];
      };
      gobject-sys = {
        nativeInputs = pc;
        inputs = p: [ p.dbus-glib ];
      };
      gio-sys = {
        nativeInputs = pc;
        inputs = p: [ p.dbus-glib ];
      };
      gdk-pixbuf.inputs = p: [
        p.dbus-glib
        p.gdk-pixbuf
      ];
      gdk-pixbuf-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gdk-pixbuf ];
      };
      gdk-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk3 ];
      };
      gdkx11-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk3 ];
      };
      gtk-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk3 ];
      };
      gtk4-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk4 ];
      };
      gdk4-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk4 ];
      };
      gsk4-sys = {
        nativeInputs = pc;
        inputs = p: [ p.gtk4 ];
      };
      libgit2-sys = {
        nativeInputs = pc;
        inputs = p: [
          p.openssl
          p.zlib
          p.libgit2
        ];
      };
      libseat-sys = {
        nativeInputs = pc;
        inputs = p: [ p.seatd ];
      };
      libsqlite3-sys = {
        nativeInputs = pc;
        inputs = p: [ p.sqlite ];
      };
      libssh2-sys = {
        nativeInputs = pc;
        inputs = p: [
          p.openssl
          p.zlib
          p.libssh2
        ];
      };
      libdbus-sys = {
        nativeInputs = pc;
        inputs = p: [ p.dbus ];
      };
      libudev-sys = {
        nativeInputs = pc;
        inputs = p: [ p.udev ];
      };
      graphene-sys = {
        nativeInputs = p: [
          p.pkg-config
          p.gobject-introspection
        ];
        inputs = p: [ p.graphene ];
      };
      javascriptcore-rs-sys = {
        nativeInputs = pc;
        inputs = p: [ p.webkitgtk_4_1 ];
      };
      nettle-sys = {
        nativeInputs = pc;
        inputs = p: [ p.nettle ];
        # nixpkgs adds clang and LIBCLANG_PATH for bindgen. bindgen runs in
        # the build script (a host unit), and rustPlatform.bindgenHook sets
        # LIBCLANG_PATH plus the clang arguments bindgen needs to find the
        # C headers.
        host.nativeInputs = p: [ p.rustPlatform.bindgenHook ];
      };
      openssl.inputs = p: [ p.openssl ];
      openssl-sys = {
        nativeInputs = pc;
        inputs = p: [ p.openssl ];
      };
      opentelemetry-proto.nativeInputs = p: [ p.protobuf ];
      pam-sys.inputs = p: [ p.linux-pam ];
      pango-sys = {
        nativeInputs = pc;
        inputs = p: [ p.pango ];
      };
      pq-sys = {
        nativeInputs = pc;
        inputs = p: [ p.libpq ];
      };
      prost-wkt-types.nativeInputs = p: [ p.protobuf ];
      rdkafka-sys = {
        nativeInputs = pc;
        inputs = p: [ p.rdkafka ];
      };
      rink.inputs = p: [ p.gmp ];
      sequoia-openpgp.inputs = p: [ p.gmp ];
      sequoia-openpgp-ffi.inputs = p: [ p.gmp ];
      sequoia-ipc.inputs = p: [ p.gmp ];
      sequoia-guide.inputs = p: [ p.gmp ];
      pangocairo-sys = {
        nativeInputs = pc;
        inputs = p: [ p.pango ];
      };
      sequoia-store = {
        nativeInputs = p: [ p.capnproto ];
        inputs = p: [
          p.sqlite
          p.gmp
        ];
      };
      sequoia-sq.inputs = p: [
        p.sqlite
        p.gmp
      ];
      sequoia-tool = {
        nativeInputs = p: [ p.capnproto ];
        inputs = p: [
          p.sqlite
          p.gmp
        ];
      };
      servo-fontconfig-sys = {
        nativeInputs = pc;
        inputs = p: [
          p.freetype
          p.fontconfig
        ];
      };
      soup3-sys = {
        nativeInputs = pc;
        inputs = p: [ p.libsoup_3 ];
      };
      thrussh-libsodium = {
        nativeInputs = pc;
        inputs = p: [ p.libsodium ];
      };
      tonic-reflection.nativeInputs = p: [ p.protobuf ];
      webkit2gtk-sys = {
        nativeInputs = pc;
        inputs = p: [ p.webkitgtk_4_1 ];
      };
      xcb.inputs = p: [ p.python3 ];
      zstd-sys = {
        nativeInputs = pc;
        inputs = p: [ p.zstd ];
      };
      atk-sys = {
        nativeInputs = pc;
        inputs = p: [ p.atk ];
      };
    };
  };
}
