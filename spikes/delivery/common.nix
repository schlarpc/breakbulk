# Shared pieces of both delivery modes.
{ tools ? import (/. + builtins.getEnv "SPIKE_DIR" + "/tools.nix") }:
rec {
  inherit tools;
  system = "x86_64-linux";

  # Every unit uses this builder; breakbulk-unit in the real design.
  unitBuilder = "${tools.bash}/bin/bash";
  unitArgs = [
    "-c"
    ''
      set -eu
      for o in $outputs; do
        mkdir -p "''${!o}"
        printf '%s\n' "$BREAKBULK_UNIT" > "''${!o}/unit.json"
      done
    ''
  ];
  unitPath = "${tools.coreutils}/bin";

  # A "toolchain": an input-addressed derivation the units reference.
  # Instantiation must only name it, never build it.
  toolchain = derivation {
    name = "toolchain";
    inherit system;
    builder = "${tools.bash}/bin/bash";
    args = [ "-c" "${tools.coreutils}/bin/mkdir -p $out/bin; echo fake > $out/bin/rustc" ];
  };

  # A "source view" (opaque store path).
  sources.a = builtins.path {
    name = "a-src";
    path = ./fixture-src;
  };

  unitsJson = ./units.json;
}
