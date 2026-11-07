# Replay driver: plain builder (no stdenv). Runs real cargo over the
# fixture; every unit gets base env + the replayed capture for its
# (platform, package), via rustc-wrapper.sh.
#
# Inputs (derivation attributes): src, vendor, cargoConfig, toolPath,
# BB_* (see overlay.sh), triple, collect.
set -eu
export PATH="$toolPath"
cd "$NIX_BUILD_TOP"
# Same layout as buildRustPackage (cargoSetupHook copies the vendor dir into
# the build dir), so source paths in C debug info match.
cp -r "$src" fixture
chmod -R u+w fixture
cp -Lr "$vendor" cargo-vendor-dir
chmod -R u+w cargo-vendor-dir
cd fixture

export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
mkdir -p "$CARGO_HOME"
printf '%s\n' "$cargoConfig" > "$CARGO_HOME/config.toml"

shim="$NIX_BUILD_TOP/rustc-wrapper"
printf '#!%s\nexec %s %s "$@"\n' "$BB_BASH" "$BB_BASH" "$BB_DRIVER/rustc-wrapper.sh" > "$shim"
chmod +x "$shim"
export RUSTC_WRAPPER="$shim"
export BB_LOG="$NIX_BUILD_TOP/captures.log"

# Same flags as nixpkgs' cargoBuildHook (pkgs/build-support/rust/hooks/cargo-build-hook.sh)
export CARGO_PROFILE_RELEASE_STRIP=false
cargo build -j "$NIX_BUILD_CORES" --target "$triple" --offline --profile release

bash "$collect" "$triple"
sort -u "$BB_LOG" > "$out/captures-applied.txt"
