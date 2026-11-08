# Option types and helpers shared by breakbulk's modules.
{ lib }:
let
  inherit (lib) types mkOption;
  req = import ./version-req.nix { inherit lib; };
in
rec {
  # A Cargo version requirement (`^1.2`, `>=0.42, <0.50`), checked when
  # the option is read, so that a bad one is an error on its option.
  versionReq = types.addCheck types.str req.isReq // {
    name = "versionReq";
    description = "Cargo version requirement";
  };

  # A list of packages, or a function from a package set to one. The
  # function form (`p: [ p.openssl ]`) is called with the package set that
  # matches each platform (decision 20); a plain list is used as given.
  # Several definitions concatenate, whatever form each one has.
  inputs = types.coercedTo (types.listOf types.package) (l: _: l) (
    types.functionTo (types.listOf types.package)
  );

  # An environment value: a string, or anything that turns into one (a
  # path, a derivation such as another workspace's product, a number or a
  # boolean). Derivations reach instantiation by reference.
  envValue = types.oneOf [
    types.str
    types.path
    types.package
    types.int
    types.bool
  ];

  envAttrs = types.attrsOf envValue;

  # An env value as the string a unit sees. Booleans as "1" and "" (as
  # derivation attributes are).
  envString =
    v:
    if builtins.isBool v then
      (if v then "1" else "")
    else if builtins.isInt v then
      toString v
    else
      v;

  mkEnv =
    description:
    mkOption {
      type = envAttrs;
      default = { };
      inherit description;
    };

  mkInputs =
    description:
    mkOption {
      type = inputs;
      default = [ ];
      example = lib.literalExpression "p: [ p.openssl ]";
      inherit description;
    };

  # A stage or check definition (products come in M4). Kept as raw values
  # so `lib.mkForce null` can remove one.
  stages = types.attrsOf (types.nullOr types.raw);

  # Mark an option as declared ahead of its milestone. `milestone` is the
  # milestone that implements it, e.g. "M4".
  notImplemented =
    milestone: opt:
    opt
    // {
      description = (opt.description or "") + "\n\nNot implemented yet (${milestone}): setting it only gives an evaluation warning.";
    };

  # The paths (lists of attribute names) of options in `paths` that some
  # module set, as opposed to their defaults. Defaults have priority 1500
  # (mkOptionDefault); anything set with a plain definition, mkDefault
  # (1000) or mkForce is a definition.
  setPaths =
    options: paths:
    lib.filter (
      p:
      let
        o = lib.getAttrFromPath p options;
      in
      o.highestPrio < 1500
    ) paths;

  # An internal option collecting warnings from a submodule.
  warningsOption = mkOption {
    type = types.listOf types.str;
    default = [ ];
    internal = true;
    visible = false;
    description = "Warnings from this part of the configuration.";
  };

  # An internal option collecting cross-option checks from a submodule, as
  # NixOS's `assertions`: mkRepository fails with every false one's message
  # before it returns anything.
  assertionsOption = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          assertion = mkOption { type = types.bool; };
          message = mkOption { type = types.str; };
        };
      }
    );
    default = [ ];
    internal = true;
    visible = false;
    description = "Checks from this part of the configuration.";
  };

  # " (set in `a.nix')" for an option, for messages that name where a value
  # came from; empty when only anonymous modules set it.
  setIn =
    opt:
    let
      files = lib.filter (f: f != "<unknown-file>") opt.files;
    in
    lib.optionalString (files != [ ]) " (set in ${lib.concatMapStringsSep " and " (f: "`${toString f}'") files})";

  # Warnings for options of a submodule that are set but not implemented:
  # `prefix` names the submodule instance (e.g. `targets.wasm32-unknown-unknown`).
  unimplementedWarnings =
    prefix: options: byMilestone:
    lib.concatLists (
      lib.mapAttrsToList (
        milestone: paths:
        map (
          p: "breakbulk: `${prefix}.${lib.concatStringsSep "." p}` is set but not implemented yet (${milestone}); it has no effect."
        ) (setPaths options paths)
      ) byMilestone
    );
}
