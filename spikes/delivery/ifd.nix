# IFD mode: an instantiate derivation writes units.json, Nix imports it
# (import-from-derivation) and applies `derivation` to each unit.
{ common ? import ./common.nix { } }:
let
  inherit (common) tools system;

  # The instantiate derivation. Here it only copies the stand-in output.
  instantiate = derivation {
    name = "breakbulk-instantiate-ifd";
    inherit system;
    builder = "${tools.bash}/bin/bash";
    args = [ "-c" "${tools.coreutils}/bin/cp ${common.unitsJson} $out" ];
  };

  plan = builtins.fromJSON (builtins.readFile instantiate); # IFD

  render = seg:
    if builtins.isString seg then seg
    else if seg ? unit then "${units.${seg.unit}.${seg.output}}${seg.file or ""}"
    else if seg ? tool then "${common.${seg.tool}}"
    else if seg ? src then "${common.sources.${seg.src}}"
    else throw "bad segment";

  units = builtins.mapAttrs (_: u: derivation ({
    inherit (u) name outputs;
    inherit system;
    builder = common.unitBuilder;
    args = common.unitArgs;
    PATH = common.unitPath;
  } // builtins.mapAttrs (_: segs: builtins.concatStringsSep "" (map render segs)) u.env)) plan.units;

  roots = builtins.mapAttrs (_: id: units.${id}) plan.roots;
in
{
  inherit instantiate units roots;
}
