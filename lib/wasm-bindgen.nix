# A wasm-bindgen-cli that matches a workspace's Cargo.lock ("wasm" in
# docs/src/explanation/internals/toolchains.md).
#
# wasm-bindgen's CLI and the `wasm-bindgen` crate must be the same version
# exactly: the crate embeds a schema version in the custom section the CLI
# reads, and the CLI refuses a mismatch.
#
#   wb = breakbulk.wasmBindgen;
#
#   wb.versionFromLockfile ./Cargo.lock      # "0.2.130"; throws if absent/ambiguous
#   wb.forLockfile { inherit pkgs; lockfile = ./Cargo.lock; }
#   wb.forVersion  { inherit pkgs; version = "0.2.123"; }
#
# Resolution, for version X.Y.Z:
#   1. nixpkgs' `wasm-bindgen-cli_X_Y_Z`, when the given pkgs has it;
#   2. otherwise wasm-bindgen-cli X.Y.Z from crates.io, built with
#      rustPlatform.buildRustPackage, with the source and vendor hashes from
#      `hashes` (default: ./wasm-bindgen-hashes.nix);
#   3. otherwise an evaluation error naming the version.
# Pass `hashes = { "0.2.123" = { hash = …; cargoHash = …; }; }` to add
# versions without editing the library (merged over the shipped table).
#
# The result is a derivation with bin/wasm-bindgen (plus
# wasm-bindgen-test-runner and wasm2es6js) and `passthru.wasmBindgenVersion`.
{ lib, lockfile }:
let
  lockfileLib = lockfile;
  shippedHashes = import ./wasm-bindgen-hashes.nix;

  # The `wasm-bindgen` versions in a lockfile's entries. Registry packages
  # only (crates.io or a mirror of it): a wasm-bindgen from a repository
  # checkout or a path has no published CLI to match.
  isWasmBindgen = e: e.name == "wasm-bindgen";
  fromRegistry = e: e.parsed.kind == "registry";
  versionsIn =
    entries: lib.unique (map (e: e.version) (lib.filter (e: isWasmBindgen e && fromRegistry e) entries));

  versionFromEntries =
    what: entries:
    let
      vs = versionsIn entries;
      other = lib.filter (e: isWasmBindgen e && !(fromRegistry e)) entries;
      otherSource =
        let
          e = lib.head other;
        in
        if e.source == null then "a path" else e.source;
    in
    if lib.length vs == 1 then
      lib.head vs
    else if vs == [ ] && other != [ ] then
      throw "breakbulk.wasmBindgen: ${what} locks wasm-bindgen from ${otherSource}, not a registry; there is no published CLI to match, so pass one explicitly"
    else if vs == [ ] then
      throw "breakbulk.wasmBindgen: ${what} has no wasm-bindgen package"
    else
      throw "breakbulk.wasmBindgen: ${what} locks several wasm-bindgen versions (${lib.concatStringsSep ", " vs}); one CLI cannot serve them all";

  attrName = version: "wasm-bindgen-cli_" + lib.replaceStrings [ "." ] [ "_" ] version;

  fromCratesIo =
    pkgs: version: h:
    pkgs.rustPlatform.buildRustPackage {
      pname = "wasm-bindgen-cli";
      inherit version;
      src = pkgs.fetchCrate {
        pname = "wasm-bindgen-cli";
        inherit version;
        inherit (h) hash;
      };
      inherit (h) cargoHash;
      # As nixpkgs' buildWasmBindgenCli (pkgs/build-support/wasm-bindgen-cli).
      nativeBuildInputs = [ pkgs.pkg-config ];
      buildInputs = [ pkgs.openssl ] ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.curl ];
      # The tests need the wasm-bindgen monorepo.
      doCheck = false;
      meta = {
        homepage = "https://wasm-bindgen.github.io/wasm-bindgen/";
        license = with lib.licenses; [
          asl20
          mit
        ];
        description = "wasm-bindgen CLI ${version} (built by breakbulk from crates.io)";
        mainProgram = "wasm-bindgen";
      };
    };

  forVersion =
    {
      pkgs,
      version,
      hashes ? { },
      # Skip nixpkgs' attribute even when it exists (used to test the table).
      preferNixpkgs ? true,
    }:
    let
      table = shippedHashes // hashes;
      name = attrName version;
      drv =
        if preferNixpkgs && pkgs ? ${name} then
          pkgs.${name}
        else if table ? ${version} then
          fromCratesIo pkgs version table.${version}
        else
          throw "breakbulk.wasmBindgen: no wasm-bindgen-cli ${version}: nixpkgs has no `${name}` and breakbulk's hash table (lib/wasm-bindgen-hashes.nix) has no entry for it; add one with `hashes = { \"${version}\" = { hash = …; cargoHash = …; }; }`";
    in
    drv.overrideAttrs (old: {
      passthru = (old.passthru or { }) // {
        wasmBindgenVersion = version;
      };
    });
in
{
  inherit forVersion attrName;
  hashes = shippedHashes;

  versionFromEntries = versionFromEntries "the lockfile";
  versionFromLockfile = path: versionFromEntries (toString path) (lockfileLib.read path);

  forLockfile =
    {
      pkgs,
      lockfile ? null,
      # Already-parsed entries (breakbulk.lockfile.read) instead of a path.
      entries ? null,
      hashes ? { },
      preferNixpkgs ? true,
    }:
    let
      version =
        if entries != null then
          versionFromEntries "the lockfile" entries
        else if lockfile != null then
          versionFromEntries (toString lockfile) (lockfileLib.read lockfile)
        else
          throw "breakbulk.wasmBindgen.forLockfile: pass `lockfile` or `entries`";
    in
    forVersion {
      inherit
        pkgs
        version
        hashes
        preferNixpkgs
        ;
    };
}
