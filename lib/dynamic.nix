# Dynamic-derivation mode ("Dynamic-derivation mode" and "Mode selection" in
# docs/src/explanation/internals/instantiation.md).
#
#   d = breakbulk.dynamic;
#   d.available                  whether `mode` defaults to dynamic
#                                (breakbulk.nixFeatures.available)
#   d.checkMode mode             mode, or an error for "dynamic" on an
#                                evaluator without dynamic derivations
#   d.mkBreakbulkDrv pkgs        the outer derivation's builder
#   i = d.instantiate {
#     <every argument of breakbulk.instantiate>;   # roots is required
#     breakbulkDrv;              # d.mkBreakbulkDrv pkgs
#     nixFeatures = <standalone>;  # the record the outer derivation and
#                                # outputOf are checked against
#                                # (lib/nix-features.nix; repo.nixFeatures)
#   };
#   i.outer                      the outer derivation (CA, text-hashed,
#                                requiredSystemFeatures = builder-rpc-v0)
#                                that writes every unit of the plan
#   i.roots, i.doctests, i.docs, i.allUnits, i.buildScriptRuns
#                                as in IFD mode (instantiate.nix
#                                `rootShape`), each wrapper an output of
#                                the outer derivation, resolved at build
#                                time
#   i.units                      an error: units are not known at
#                                evaluation time
#   i.ifdUnits                   the same units through IFD mode (importing
#                                units.json), for explainSharing only
#
# The outer derivation runs `breakbulk-drv`, which runs the same
# instantiation as IFD mode over the same input files, resolves each
# derivation with the real paths and their string context (values.json:
# the same input keys lib/instantiate.nix substitutes, with
# `builtins.getContext` of each), and writes units, test-root stubs,
# doctests and one wrapper per root and per doctest through the
# `builder-rpc-v0` socket. Each wrapper is
# submitted as the output `<root>.drv` (with `/` as `.`), named
# `<outer name>-<root>`, as Nix requires.
#
# The outer derivation takes every input of the plan, so a package's
# settings cannot name a product of the same plan: that is a cycle. Such a
# product comes from another variant (`breakbulk.variants.tools`).
#
# Nothing but the plan is built before the outer derivation runs: every
# input's .drv is in the outer derivation's context as a plain path (the
# builder needs the .drv files to hash units), never its outputs.
{
  lib,
  instantiateLib,
  util,
  featureGates,
}:
let
  inherit (builtins)
    getContext
    toFile
    toJSON
    unsafeDiscardStringContext
    ;
  inherit (instantiateLib)
    instantiate
    outerOf
    rootShape
    checkInput
    ;

  inherit (featureGates) available;

  # The same test as the default rule (`available`): an explicit
  # `mode = "dynamic"` is valid exactly where the default would pick it.
  checkMode =
    mode:
    if mode == "dynamic" && !available then
      throw "breakbulk: mode = \"dynamic\" needs an evaluator with the `dynamic-derivations` experimental feature (and `ca-derivations`), on Nix 2.36 or later (this is ${builtins.nixVersion}${
        lib.optionalString (!featureGates.hasOutputOf) ", without the feature"
      }); use mode = \"ifd\""
    else
      mode;

  # getContext as values.json takes it (an all-outputs context is an
  # error in both modes: instantiateLib.checkInput).
  contextList =
    key: v:
    lib.mapAttrsToList (
      p: c:
      if c ? outputs then
        {
          drv = p;
          inherit (c) outputs;
        }
      else
        { path = p; }
    ) (getContext v);

  # For `tools` without a breakbulk-drv.
  mkBreakbulkDrv = pkgs: (import ./tools.nix { inherit lib; } pkgs).breakbulk-drv;

  instantiateDynamic =
    args@{
      breakbulkDrv,
      outerName,
      system,
      plan,
      roots,
      doctests ? { },
      docs ? false,
      nixFeatures ? featureGates.standalone { dynamic = true; },
      ...
    }:
    let
      # Only `ifdUnits` reads base's units.json: explainSharing, which
      # always imports from derivations and is not counted in the record.
      base = instantiate (
        removeAttrs args [ "breakbulkDrv" ]
        // {
          nixFeatures = nixFeatures // {
            importFromDerivation = true;
          };
        }
      );
      # An output of the outer derivation.
      outputOf =
        what: output:
        featureGates.outputOf nixFeatures "the ${what} of `${outer.name}`" outer.${output}.outPath "out";
      # Without predicted roots (check plans) the outer
      # derivation has only its `units.drv` and `runs.drv` outputs.
      predicted = if roots == null then [ ] else roots.roots;
      full = outerOf {
        inherit outerName docs;
        roots = predicted;
        doctests = lib.attrNames doctests;
      };

      # Predicted views are the outer derivation's to make (from their
      # specs): their values in `base.inputs` come from import from
      # derivation.
      values = lib.mapAttrs (_: util.devirtualize) (
        removeAttrs base.inputs (lib.attrNames base.predictedSpecs)
      );
      valuesJson = lib.mapAttrs (k: v: {
        value = unsafeDiscardStringContext v;
        context = contextList k (checkInput k v);
      }) values;
      predictJson = lib.mapAttrsToList (
        key: spec:
        spec
        // {
          inherit key;
          view = unsafeDiscardStringContext (util.devirtualize spec.view);
        }
      ) base.predictedSpecs;
      # Every store path any value depends on, as a plain path: a
      # derivation output becomes its .drv file (drv-only: nothing is
      # built).
      contextPaths = lib.unique (
        lib.concatMap (v: lib.attrNames (getContext v)) (
          lib.attrValues values ++ map (p: util.devirtualize p.view) (lib.attrValues base.predictedSpecs)
        )
      );
      context = builtins.appendContext "" (
        lib.genAttrs contextPaths (_: {
          path = true;
        })
      );

      outer = derivation (
        {
          name = outerName;
          inherit system;
          builder = "${breakbulkDrv}/bin/breakbulk-drv";
          args = [
            "--plan"
            plan
            "--sources"
            base.files.sourcesFile
            "--toolchains"
            base.files.toolchainsFile
            "--overrides"
            base.files.overridesFile
            "--roots"
            base.files.rootsFile
            "--values"
            (toFile "values.json" (toJSON valuesJson))
            "--predict"
            (toFile "predict.json" (toJSON predictJson))
            "--outer"
            (toFile "outer.json" (toJSON full))
          ];
          outputs =
            lib.attrValues full.outputs
            ++ lib.attrValues full.doctests
            ++ [
              full.units
              full.runs
            ]
            ++ lib.optional docs full.docs;
          BREAKBULK_INPUTS = context;
          requiredSystemFeatures = [ "builder-rpc-v0" ];
        }
        // featureGates.caAttrs nixFeatures "the outer derivation `${outerName}`"
        // {
          outputHashMode = "text";
        }
      );

      shape = rootShape {
        inherit
          system
          outerName
          docs
          ;
        inherit (args) coreutils;
        shell = args.tools.shell;
        roots = predicted;
        doctests = lib.attrNames doctests;
        wrapperOf = _: outputOf;
      };
    in
    {
      inherit outer;
      inherit (shape)
        roots
        doctests
        docs
        allUnits
        buildScriptRuns
        ;
      inherit (base) files inputs;
      delivery = "dynamic";
      units = throw "breakbulk: unit derivations are not known at evaluation time in dynamic-derivation mode (repo.explainSharing reads them through IFD mode)";
      # The unit derivations IFD mode would make: the same .drv paths as the
      # outer derivation writes, except downstream of an embedded product.
      # Only explainSharing uses them; reading them imports units.json.
      ifdUnits = base.units;
      unitsJson = null;
    };
in
{
  inherit
    available
    checkMode
    mkBreakbulkDrv
    ;
  instantiate = instantiateDynamic;
}
