# wasm-bindgen-cli versions breakbulk can build from crates.io when the
# user's nixpkgs has no `wasm-bindgen-cli_<version>` (lib/wasm-bindgen.nix).
#
#   "<version>" = {
#     hash = …;       # fetchCrate { pname = "wasm-bindgen-cli"; version; }
#     cargoHash = …;  # rustPlatform.fetchCargoVendor of that crate
#   };
#
# Both are fixed-output hashes, so they are the same whichever builder uses
# them; entries that nixpkgs also packages carry nixpkgs' values, checked by
# fetching both (tests/presets: wasm-bindgen-table). To add a version, build
# `breakbulk.wasmBindgen.forVersion { pkgs; version; hashes.<v> = { hash = ""; cargoHash = ""; }; preferNixpkgs = false; }`
# twice and copy the hashes Nix reports.
{
  # Not in nixpkgs (nixos-unstable, 2026-11).
  "0.2.123" = {
    hash = "sha256-ymeAEYsr7OnupWYJWjSeVGvq3+s+zxSNkODbzY62rYs=";
    cargoHash = "sha256-d7x6gtx5OqEE4MyT6yjYn/qtgjx7GroTpXJewnBV2dU=";
  };
  "0.2.125" = {
    hash = "sha256-zRawtjxMOdTMX+mZaiNR3YYfTiZJhf9qj7kXSSeMxrc=";
    cargoHash = "sha256-aZCfgR23Qb0Pn4Mm4ToMtuuRQqSJjXCR9li/VvP5CTM=";
  };
  "0.2.126" = {
    hash = "sha256-H6Is3fiZVxZCfOMWK5dWMSrtn50VGv0sfdnsT+cTtyk=";
    cargoHash = "sha256-VucqkXbCi4qtQzY/HrXiDnbSURsagPsdNVMn1Tw3UiY=";
  };
  "0.2.127" = {
    hash = "sha256-di+qBAdd7pENLiIB9CoZoab+W5xeDoByMREcCGTSzWo=";
    cargoHash = "sha256-FTv2GZIAQs0ePdIZXIXil7JbZ6kIT05VG6vqC1qNFxQ=";
  };
  "0.2.128" = {
    hash = "sha256-a7lcXJnnZkYReja+iUO7NqqrWyv3toxnUgQb8s4IS5s=";
    cargoHash = "sha256-R1Tas33Ursy8kqsxguAkG0ZhNed2n5uFTAhw1l2qlLY=";
  };
  "0.2.129" = {
    hash = "sha256-pcecKQd7E8Opw6bkFoE569epUi7gh5qpQF1e5PJY6V8=";
    cargoHash = "sha256-vmUrWVU7kPJJxO5qIVeAkwQyWDELO1Z4Z5gitz2kco8=";
  };
  "0.2.130" = {
    hash = "sha256-9Og1O/6/VC3sc5hBjoIWBErmLW2UHGMsTQO+6+m/dng=";
    cargoHash = "sha256-j81sUf1m5yXU4FJfGj7GV+hdqVCV8mRmNb0QIsMCjqw=";
  };
}
