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
#     split = null;              # or { packages; owner; }: two outer
#                                # derivations (below); `owner key` is the
#                                # package whose settings an input holds
#   };
#   i.outer                      the outer derivation (CA, text-hashed,
#                                requiredSystemFeatures = builder-rpc-v0)
#                                that writes every unit of the plan
#   i.writers                    every outer derivation of the plan: `outer`,
#                                or with `split` the first and `outer`
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
# With `split` (packages whose settings use products of this plan:
# `productInputs`), a plan has two outer derivations. The first takes no
# input of `split.packages` and leaves their units out (outer.json
# `leave`), so it never depends on their settings, which may name its
# products. The second, `<outer name>-product-users`, takes every input,
# writes every unit (the same .drv files as the first, where both write
# one) and submits the roots and doctests of `split.packages` (outer.json
# `submit`).
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
  inherit (instantiateLib) instantiate outerOf rootShape;

  inherit (featureGates) available;

  checkMode =
    mode:
    if mode == "dynamic" && !featureGates.hasOutputOf then
      throw "breakbulk: mode = \"dynamic\" needs an evaluator with the `dynamic-derivations` experimental feature (and `ca-derivations`), on Nix 2.36 or later; use mode = \"ifd\""
    else
      mode;

  # getContext as values.json takes it.
  contextList =
    key: v:
    lib.mapAttrsToList (
      p: c:
      if c.allOutputs or false then
        throw "breakbulk: the input `${key}` depends on all outputs of ${p} (a `drvPath` string); dynamic-derivation mode cannot pass that to a unit"
      else if c ? outputs then
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
      split ? null,
      ...
    }:
    let
      # Only `ifdUnits` reads base's units.json: explainSharing, which
      # always imports from derivations and is not counted in the record.
      base = instantiate (
        removeAttrs args [
          "breakbulkDrv"
          "split"
        ]
        // {
          nixFeatures = nixFeatures // {
            importFromDerivation = true;
          };
        }
      );
      # An output of outer derivation `w` (`outer`, by default).
      outputOfIn =
        w: what: output:
        featureGates.outputOf nixFeatures "the ${what} of `${w.name}`" w.${output}.outPath "out";
      # Without predicted roots (check and clippy plans) the outer
      # derivation has only its `units.drv` and `runs.drv` outputs.
      predicted = if roots == null then [ ] else roots.roots;
      full = outerOf {
        inherit outerName docs;
        roots = predicted;
        doctests = lib.attrNames doctests;
      };

      # With `split`, the second outer derivation's packages: it writes
      # them, and the first takes none of their inputs.
      second = p: split != null && lib.elem p split.packages;

      # Predicted views are the outer derivation's to make (from their
      # specs): their values in `base.inputs` come from import from
      # derivation.
      allValues = removeAttrs base.inputs (lib.attrNames base.predictedSpecs);

      # One outer derivation: `mine p` says whether it submits package p's
      # roots and doctest; `writesAll` whether it writes every unit (and
      # the docs), else it leaves the second outer derivation's packages
      # out.
      mkOuter =
        {
          name,
          mine,
          writesAll,
        }:
        let
          values = lib.mapAttrs (_: util.devirtualize) (
            if writesAll then allValues else lib.filterAttrs (k: _: !second (split.owner k)) allValues
          );
          valuesJson = lib.mapAttrs (k: v: {
            value = unsafeDiscardStringContext v;
            context = contextList k v;
          }) values;
          predict = lib.filterAttrs (k: _: writesAll || !second (split.owner k)) base.predictedSpecs;
          predictJson = lib.mapAttrsToList (
            key: spec:
            spec
            // {
              inherit key;
              view = unsafeDiscardStringContext (util.devirtualize spec.view);
            }
          ) predict;
          # Every store path any value depends on, as a plain path: a
          # derivation output becomes its .drv file (drv-only: nothing is
          # built).
          contextPaths = lib.unique (
            lib.concatMap (v: lib.attrNames (getContext v)) (
              lib.attrValues values ++ map (p: util.devirtualize p.view) (lib.attrValues predict)
            )
          );
          context = builtins.appendContext "" (
            lib.genAttrs contextPaths (_: {
              path = true;
            })
          );
          outputs = lib.filterAttrs (n: _: mine (lib.head (lib.splitString "/" n))) full.outputs;
          outputList = lib.attrValues outputs;
          doctestOutputs = lib.filterAttrs (p: _: mine p) full.doctests;
          hasDocs = docs && writesAll;
        in
        derivation (
          {
            inherit name system;
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
              (toFile "outer.json" (
                toJSON (
                  removeAttrs full [ "docs" ]
                  // {
                    inherit name outputs;
                    doctests = doctestOutputs;
                  }
                  // lib.optionalAttrs hasDocs { inherit (full) docs; }
                  // lib.optionalAttrs (split != null) (
                    if writesAll then { submit = split.packages; } else { leave = split.packages; }
                  )
                )
              ))
            ];
            outputs =
              outputList
              ++ lib.attrValues doctestOutputs
              ++ [
                full.units
                full.runs
              ]
              ++ lib.optional hasDocs full.docs;
            BREAKBULK_INPUTS = context;
            requiredSystemFeatures = [ "builder-rpc-v0" ];
          }
          // featureGates.caAttrs nixFeatures "the outer derivation `${name}`"
          // {
            outputHashMode = "text";
          }
        );

      # Without `split`, one outer derivation writes everything. With it,
      # the first writes every package but the second's, and the second
      # writes every unit (it cannot read the first's) with every input,
      # and submits its packages' roots and doctests. The first never
      # depends on the second, so the second's packages' settings can use
      # the first's products.
      first = mkOuter {
        name = outerName;
        mine = p: !second p;
        writesAll = split == null;
      };
      outer =
        if split == null then
          first
        else
          mkOuter {
            name = "${outerName}-product-users";
            mine = second;
            writesAll = true;
          };
      # The plan-wide wrappers (package null) are the full writer's.
      outerOfPackage = p: if p != null && second p then outer else first;

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
        wrapperOf =
          p: what: output:
          outputOfIn (if p == null then outer else outerOfPackage p) what output;
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
      writers = [ first ] ++ lib.optional (split != null) outer;
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
