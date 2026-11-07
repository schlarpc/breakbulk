# Dynamic-derivation mode: a CA, text-hashed outer derivation with
# requiredSystemFeatures = [ "builder-rpc-v0" ] writes the unit derivations and
# submits each root .drv as an output. Downstream derivations reach the roots
# with builtins.outputOf.
{ common ? import ./common.nix { } }:
let
  inherit (common) tools system;
  inherit (builtins) outputOf unsafeDiscardOutputDependency unsafeDiscardStringContext;

  mkPlan = { name, unitsJson, products ? { } }:
    let
      rootNames = builtins.attrNames (builtins.fromJSON (builtins.readFile unitsJson)).roots;

      outer = derivation ({
        inherit name system;
        OUTER_NAME = name;
        SUBMIT_UNWRAPPED = builtins.getEnv "SUBMIT_UNWRAPPED";
        builder = "${tools.bash}/bin/bash";
        args = [ ./instantiate.sh ];
        outputs = map (r: "${r}.drv") rootNames;

        __contentAddressed = true;
        outputHashMode = "text";
        outputHashAlgo = "sha256";
        requiredSystemFeatures = [ "builder-rpc-v0" ];

        ADD_METHOD = builtins.getEnv "ADD_METHOD";
        PATH = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ tools.coreutils tools.jq tools.sed tools.python tools.nix tools.bbdrv ]);
        UNITS = unitsJson;
        DRVHASH = ./drvhash.py;
        UNIT_SYSTEM = system;
        UNIT_BUILDER = common.unitBuilder;
        UNIT_ARGS = builtins.toJSON common.unitArgs;
        UNIT_PATH = common.unitPath;
        UNIT_BASH = tools.bash;
        UNIT_COREUTILS = tools.coreutils;
        # Drv-only context: the toolchain .drv closure is an input, its output
        # is not built.
        TOOLCHAIN_DRV = unsafeDiscardOutputDependency common.toolchain.drvPath;
        TOOLCHAIN_OUT = unsafeDiscardStringContext common.toolchain.outPath;
        SRC_a = common.sources.a;
      } // builtins.listToAttrs (builtins.concatLists (builtins.attrValues (builtins.mapAttrs (p: drv: [
        # A product is a CA stage of another plan: name its .drv only, and
        # pass its output placeholder (its outPath, since it is CA).
        { name = "PRODUCT_${p}_DRV"; value = unsafeDiscardOutputDependency drv.drvPath; }
        { name = "PRODUCT_${p}"; value = unsafeDiscardStringContext drv.outPath; }
      ]) products))));

      # outputOf (outer."<root>.drv") "out": the root unit's output, resolved
      # at build time.
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
      forRoots = f: builtins.listToAttrs (map (r: { name = r; value = f r; }) rootNames);
    in
    {
      inherit outer;
      rootOut = forRoots rootOut;
      linked = forRoots linkedCA;
      linkedIA = forRoots linkedIA;
    };

  main = mkPlan {
    name = "breakbulk-instantiate-requires-builder-rpc-v0";
    unitsJson = common.unitsJson;
  };

  # A plan whose unit embeds main's `tool` product (its CA `linked` stage).
  host = mkPlan {
    name = "host-plan";
    unitsJson = ./units-host.json;
    products.tool = main.linked.tool;
  };
in
main // { inherit host; }
