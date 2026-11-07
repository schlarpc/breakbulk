# Dynamic-derivation mode: a CA, text-hashed outer derivation with
# requiredSystemFeatures = [ "builder-rpc-v0" ] writes the unit derivations and
# submits each root .drv as an output. Downstream derivations reach the roots
# with builtins.outputOf.
{ common ? import ./common.nix { } }:
let
  inherit (common) tools system;
  inherit (builtins) outputOf unsafeDiscardOutputDependency unsafeDiscardStringContext;
  rootNames = builtins.attrNames (builtins.fromJSON (builtins.readFile common.unitsJson)).roots;

  outerName = "breakbulk-instantiate-requires-builder-rpc-v0";
  outer = derivation {
    name = outerName;
    OUTER_NAME = outerName;
    SUBMIT_UNWRAPPED = builtins.getEnv "SUBMIT_UNWRAPPED";
    inherit system;
    builder = "${tools.bash}/bin/bash";
    args = [ ./instantiate.sh ];
    outputs = map (r: "${r}.drv") rootNames;

    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
    requiredSystemFeatures = [ "builder-rpc-v0" ];

    ADD_METHOD = builtins.getEnv "ADD_METHOD";
    PATH = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ tools.coreutils tools.jq tools.sed tools.python tools.nix ]);
    UNITS = common.unitsJson;
    DRVHASH = ./drvhash.py;
    UNIT_SYSTEM = system;
    UNIT_BUILDER = common.unitBuilder;
    UNIT_ARGS = builtins.toJSON common.unitArgs;
    UNIT_PATH = common.unitPath;
    UNIT_BASH = tools.bash;
    UNIT_COREUTILS = tools.coreutils;
    # Drv-only context: the toolchain .drv closure is an input, its output is
    # not built.
    TOOLCHAIN_DRV = unsafeDiscardOutputDependency common.toolchain.drvPath;
    TOOLCHAIN_OUT = unsafeDiscardStringContext common.toolchain.outPath;
    SRC_a = common.sources.a;
  };

  # outputOf (outer."<root>.drv") "out": the root unit's output, resolved at
  # build time.
  rootOut = r: outputOf outer."${r}.drv".outPath "out";

  # The `linked` stage, in two flavours.
  mkLinked = extra: r: derivation ({
    name = "${r}-linked";
    inherit system;
    builder = "${tools.bash}/bin/bash";
    args = [ "-c" "${tools.coreutils}/bin/ln -s ${rootOut r} $out" ];
  } // extra);
  linkedCA = mkLinked { __contentAddressed = true; outputHashMode = "nar"; outputHashAlgo = "sha256"; };
  linkedIA = mkLinked { };
in
{
  inherit outer;
  rootOut = builtins.listToAttrs (map (r: { name = r; value = rootOut r; }) rootNames);
  linked = builtins.listToAttrs (map (r: { name = r; value = linkedCA r; }) rootNames);
  linkedIA = builtins.listToAttrs (map (r: { name = r; value = linkedIA r; }) rootNames);
}
