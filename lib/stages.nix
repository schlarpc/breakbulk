# Products and post-link stages (docs/src/explanation/products.md;
# docs/src/explanation/internals/products.md).
#
#   p = breakbulk.stages.mkProduct {
#     name = "server";
#     linked = <derivation: the raw link output, a directory holding the
#               binary, cdylib or .wasm>;
#     stages = breakbulk.stages.chain [ "splitDebug" ] // {
#       sign = { after = "splitDebug"; run = mySigner; };
#     };
#     checks.isa = { on = "linked"; run = isaCheck; };
#     target = { triple = "x86_64-unknown-linux-gnu"; };
#     inherit pkgs;
#     # optional:
#     sourcePaths = [ … ];   # source-view and crate-source store paths
#     toolchainPaths = [ … ];   # rustc, its sysroot, cargo, toolchain components
#     info = { lockfile = ./Cargo.lock; };  # extra `product` attributes
#     drvName = "server-1.2.0";  # the product's derivation name (null:
#                            # its last stage's own)
#     meta = { mainProgram = "server"; };  # added to the product's `meta`
#     ca = breakbulk.nixFeatures.defaultCa;   # true; false
#     nixFeatures = breakbulk.nixFeatures.standalone { inherit ca; };
#                            # the record `ca` is checked against
#                            # (repo.nixFeatures, from mkRepository)
#   };
#
#   p                  the product (the last stage's output), named
#                      `drvName`, with `meta`
#   p.stages.<name>    every stage, `linked` included
#   p.stageOrder       stage names in order, without `linked`
#   p.debug            the `debug` output of the last stage that has one
#                      (packDwo, splitDebug or strip; install, for the
#                      link units' `.pdb` and other debuginfo side files
#                      when no earlier stage has one)
#   p.checks.<name>    every check
#
# Stages are `{ after ? null; before ? null; run; ca ? true; enable ? true; }`
# (the `targets.<t>.stages` submodules, lib/modules/types.nix `stage`, or
# plain sets of those fields):
#   - `after`/`before` name a stage, a list of stages, or null. A stage with
#     neither runs after `linked`. A stage with no `after` also runs after
#     the `leading` stages (mkProducts: those the target's `debugInfo`
#     inserts) unless it is ordered before one of them.
#   - `run = { input, product, target, pkgs }: <derivation>`; `input` is the
#     previous stage's output, `product` is `{ name; sourcePaths; toolchainPaths; } // info`,
#     plus `linkedDebug` (the `debug` output of `linked`, when it has one:
#     the link units' debuginfo side files), `earlierDebug` (the `debug`
#     output of the last earlier stage that has one, or null) and
#     `debugSplit` (whether there is one). Every attribute a product of
#     mkRepository has is documented in
#     docs/src/reference/stage-functions.md, which the
#     `products-product-attributes` check compares with a real product.
#   - A stage set to `null`, or with `enable = false`, is removed.
#     Constraints that name a removed stage are dropped.
#   - `install` (helpers.install) is added unless the set has `install`;
#     `install = null` removes it. A stage runs before `install` unless it
#     is ordered after it, by `after = "install"` or after a stage that is.
#     Stages before `install` see the flat link output (what the helpers
#     expect); stages after it see the installed layout (bin/, lib/, pkg/).
#   - The order must be total: every stage must be ordered relative to the
#     next by its constraints. A cycle, a missing reference or two stages
#     whose relative order is not given fail evaluation, listing every stage
#     with its constraints.
#
# Checks are `{ on ? <the product>; run = { input, product, target, pkgs }:
# drv; ca ? true; enable ? true; }`; a check's `product` also has
# `checkName`, the name it runs under (for its failure message). `null`
# removes one. mkProduct adds none of its own: mkRepository's default
# checks are the first layer of its check sets (lib/products.nix).
#
# Every stage and check runs through a guard: when its
# input holds `noBinariesMarker` (a `linked` stage of a product Cargo
# built no binary of, in dynamic-derivation mode), it copies the marker to
# its outputs and succeeds without running its own builder. A stage or
# check made with a bare `derivation` call (no `overrideAttrs`) is guarded
# too: it is rebuilt from its `drvAttrs` with the guard as builder.
#
# Content addressing: with `ca`, every stage and check derivation gets
# the floating content-addressed attributes (lib/nix-features.nix
# `caAttrs`, through overrideAttrs, or from `drvAttrs` for a bare
# `derivation`, as for the guard), unless the stage or check says `ca =
# false`. `linked` is left as it is. Nix rejects
# such a derivation at evaluation unless the evaluator has the
# `ca-derivations` experimental feature, and the build fails unless the
# daemon has it too; Nix code cannot test for the feature, so the default
# is `nixFeatures.defaultCa`, on exactly when dynamic-derivation mode is
# the default mode (which needs `ca-derivations` as well).
{
  lib,
  util,
  wasmBindgen,
  targetTraits,
  featureGates,
}:
let
  inherit (lib)
    attrNames
    concatMapStringsSep
    concatStringsSep
    elem
    filter
    filterAttrs
    length
    mapAttrs
    ;

  helpers = import ./stage-helpers {
    inherit
      lib
      util
      targetTraits
      ;
    wasmBindgenCli = wasmBindgen;
  };

  # The file a product's `linked` stage holds instead of
  # binaries when Cargo built none of them (dynamic-derivation mode, where
  # that is known only at build time; it holds the reasons). Every stage
  # and check is guarded (`guard`): given an input with this file, it
  # copies the file into each of its outputs and succeeds without running
  # its own builder, so a product with nothing to ship builds, with its
  # checks, to the marker.
  noBinariesMarker = "breakbulk-no-binaries";

  # The builder wrapper: `bash guard <input> <builder> <args…>`.
  guardScript =
    pkgs:
    let
      bp = pkgs.buildPackages;
    in
    bp.writeText "breakbulk-stage-guard.sh" ''
      input=$1
      shift
      if [ -e "$input/${noBinariesMarker}" ]; then
        dirs=()
        if [ -n "''${NIX_ATTRS_SH_FILE-}" ]; then
          # Structured attributes: `outputs` maps names to paths.
          . "$NIX_ATTRS_SH_FILE"
          dirs=("''${outputs[@]}")
        else
          for o in $outputs; do dirs+=("''${!o}"); done
        fi
        for d in "''${dirs[@]}"; do
          ${bp.coreutils}/bin/mkdir -p "$d"
          ${bp.coreutils}/bin/cp "$input/${noBinariesMarker}" "$d/"
        done
        echo "breakbulk: skipped: Cargo built none of this product's binaries:" >&2
        ${bp.coreutils}/bin/cat "$input/${noBinariesMarker}" >&2
        exit 0
      fi
      exec "$@"
    '';

  # A derivation changed by `f` over its attributes: through
  # `overrideAttrs` when it has one (mkDerivation, runCommand; their paths
  # stay those of the plain override), else rebuilt with `derivation` from
  # its `drvAttrs` (a bare `derivation` call), keeping any
  # attributes the caller added to the result. `f` gets the attributes and
  # whether they are mkDerivation's.
  modifyDrv =
    drv: f:
    if drv ? overrideAttrs then
      drv.overrideAttrs (old: f old true)
    else
      drv // derivation (drv.drvAttrs // f drv.drvAttrs false);

  # A stage's or check's derivation, run through the guard above for its
  # input. Anything that is not a derivation is left as it is.
  guard =
    pkgs: input: drv:
    if !(drv ? drvAttrs) then
      drv
    else
      let
        inherit (drv.drvAttrs) builder;
        args = drv.drvAttrs.args or [ ];
        guarded = [
          (guardScript pkgs)
          "${input}"
          builder
        ]
        ++ args;
      in
      modifyDrv drv (
        _: mk:
        {
          args = guarded;
        }
        # mkDerivation sets `builder` from `realBuilder`.
        // (
          if mk then
            { realBuilder = pkgs.stdenv.shell; }
          else
            {
              builder = pkgs.stdenv.shell;
              # The guard reads `$outputs`, which a bare `derivation` sets
              # only when it names its outputs.
              outputs = drv.drvAttrs.outputs or [ "out" ];
            }
        )
      );

  # A chain of helper names as stage modules, each after the previous.
  chain =
    names:
    lib.listToAttrs (
      lib.imap0 (
        i: n:
        lib.nameValuePair n {
          after = if i == 0 then "linked" else lib.elemAt names (i - 1);
          before = null;
          run = helpers.${n};
        }
      ) names
    );

  # Whether a stage or check of a set is there: not `null`, not
  # `enable = false`.
  isLive = v: v != null && (v.enable or true);

  toNames =
    stage: what: v:
    if v == null then
      [ ]
    else if builtins.isString v then
      [ v ]
    else if builtins.isList v && lib.all builtins.isString v then
      v
    else
      throw "breakbulk: stage `${stage}`: `${what}` must be a stage name, a list of stage names, or null";

  # Order a stage set. Returns { order; live; removed; } or { error; }.
  explainOrder =
    {
      name ? "<product>",
      stages,
      leading ? [ ],
    }:
    let
      withInstall = {
        install = {
          run = helpers.install;
        };
      }
      // stages;
      live = filterAttrs (_: isLive) withInstall;
      removed = attrNames (filterAttrs (_: v: !(isLive v)) withInstall);
      names = attrNames live;
      isLiveName = n: live ? ${n};

      cons = mapAttrs (
        n: m:
        let
          a = toNames n "after" (m.after or null);
          b = toNames n "before" (m.before or null);
        in
        {
          rawAfter = a;
          rawBefore = b;
          after = filter isLiveName a;
          before = filter isLiveName b;
          missing = filter (x: x != "linked" && !(isLiveName x) && !(elem x removed)) (a ++ b);
        }
      ) live;

      # x must come before y by the stages' own constraints.
      explicit = x: y: x != y && (elem x cons.${y}.after || elem y cons.${x}.before);
      reachBy =
        rel: x:
        map (e: e.key) (
          builtins.genericClosure {
            startSet = map (key: { inherit key; }) (filter (rel x) names);
            operator = e: map (key: { inherit key; }) (filter (rel e.key) names);
          }
        );
      # The stages ordered after `install`, directly or through another
      # stage. Counting only those that name `install` would also put a
      # stage that is `after` one of them before `install`: a cycle.
      afterInstall = if isLiveName "install" then reachBy explicit "install" else [ ];
      # x must come before y: by constraint, or because every other stage
      # runs before `install` by default.
      baseEdge = x: y: explicit x y || (y == "install" && x != "install" && !(elem x afterInstall));
      # A `leading` stage comes before a stage with no `after` that is not
      # already ordered before it (a leading stage moved after `install`
      # stays after a stage that runs before `install`): otherwise such a
      # stage would be ambiguous against the stages `debugInfo` inserts,
      # which differ by target.
      leadingLive = filter isLiveName leading;
      leadsTo =
        x: y:
        elem x leadingLive
        && !(elem y leadingLive)
        && cons.${y}.rawAfter == [ ]
        && !(elem x (reachBy baseEdge y));
      edge = x: y: baseEdge x y || leadsTo x y;

      fmtList = l: if l == [ ] then "-" else concatStringsSep ", " l;
      width = lib.foldl' (w: n: lib.max w (lib.stringLength n)) 6 names;
      pad = s: s + lib.fixedWidthString (width - lib.stringLength s) " " "";
      table = concatStringsSep "\n" (
        [ "  ${pad "linked"}  first (fixed)" ]
        ++ map (
          n:
          let
            c = cons.${n};
          in
          "  ${pad n}  after: ${fmtList c.rawAfter}; before: ${fmtList c.rawBefore}${
              lib.optionalString (n == "install") "; others run before it unless ordered after it"
            }${lib.optionalString (elem n leadingLive) "; stages with no `after` run after it unless ordered before it"}"
        ) names
        ++ lib.optional (removed != [ ]) "  removed: ${concatStringsSep ", " removed}"
      );
      fail = reason: {
        error = "breakbulk: cannot order the post-link stages of `${name}`: ${reason}\nStages and their constraints:\n${table}";
      };

      missing = lib.concatMap (
        n: map (m: "`${n}` refers to `${m}`, which is not a stage") cons.${n}.missing
      ) names;
      beforeLinked = filter (n: elem "linked" cons.${n}.rawBefore) names;
      sorted = lib.toposort edge names;
      # The stages on some cycle: those that can reach themselves.
      onCycle = filter (x: elem x (reachBy edge x)) names;
      order = sorted.result;
      pairs = if length order < 2 then [ ] else lib.zipLists (lib.init order) (lib.tail order);
      unordered = filter (p: !(edge p.fst p.snd)) pairs;
    in
    if stages ? linked then
      fail "`linked` is the fixed first stage and cannot be defined or removed"
    else if missing != [ ] then
      fail (concatStringsSep "; " missing)
    else if beforeLinked != [ ] then
      fail "nothing can run before `linked` (${concatStringsSep ", " beforeLinked})"
    else if sorted ? cycle then
      fail "the constraints form a cycle among ${concatStringsSep ", " onCycle}"
    else if unordered != [ ] then
      fail "the order is ambiguous: ${
        concatMapStringsSep "; " (p: "nothing orders `${p.fst}` and `${p.snd}`") unordered
      }; add `after` or `before`"
    else
      { inherit order live removed; };

  order =
    args:
    let
      r = explainOrder args;
    in
    if r ? error then throw r.error else r;

  mkProduct =
    {
      name,
      linked,
      stages ? { },
      checks ? { },
      target ? { },
      pkgs,
      info ? { },
      sourcePaths ? [ ],
      toolchainPaths ? [ ],
      ca ? featureGates.defaultCa,
      nixFeatures ? featureGates.standalone { inherit ca; },
      # The stages a stage with no `after` runs after (explainOrder).
      leading ? [ ],
      drvName ? null,
      meta ? { },
    }:
    let
      ordered = order { inherit name stages leading; };
      lastStage = if ordered.order == [ ] then null else lib.last ordered.order;
      # The last stage's derivation is the product: it gets the product's
      # name. Not each stage helper naming itself so: a stage after
      # `install` (`adhocSign`, `zip`) would have to know it is the last.
      named =
        s: drv:
        if drvName != null && s == lastStage && drv ? drvAttrs then
          modifyDrv drv (_: _: { name = drvName; })
        else
          drv;
      product = {
        inherit name sourcePaths toolchainPaths;
      }
      # The link units' debuginfo side files, for the stage
      # that writes the product's `debug` output.
      // lib.optionalAttrs (linked ? debug) { linkedDebug = linked.debug; }
      // info;

      caify =
        what: m: drv:
        if !ca || !(m.ca or true) then
          drv
        else if drv ? drvAttrs then
          modifyDrv drv (_: _: featureGates.caAttrs nixFeatures "${what} of `${name}` (`ca`)")
        else
          throw "breakbulk: ${what} of `${name}` returned something that is not a derivation, so it cannot be made content-addressed; set its `ca = false`";

      built =
        lib.foldl'
          (
            acc: s:
            let
              drv = caify "stage `${s}`" ordered.live.${s} (
                named s (
                  guard pkgs acc.last (
                    ordered.live.${s}.run {
                      input = acc.last;
                      product = product // {
                        earlierDebug = acc.debug;
                        debugSplit = acc.debug != null;
                      };
                      inherit target pkgs;
                    }
                  )
                )
              );
            in
            {
              last = drv;
              debug = if elem "debug" (drv.outputs or [ ]) then drv.debug else acc.debug;
              stages = acc.stages // {
                ${s} = drv;
              };
            }
          )
          {
            last = linked;
            debug = null;
            stages = {
              inherit linked;
            };
          }
          ordered.order;

      final = built.last;

      # The `debug` output of the last stage that has one.
      inherit (built) debug;

      builtChecks = mapAttrs (
        c: m:
        let
          on = m.on or null;
          input =
            if on == null then
              final
            else if built.stages ? ${on} then
              built.stages.${on}
            else
              throw "breakbulk: check `${c}` of `${name}` is on stage `${on}`, which is not a stage of this product (stages: linked${
                concatMapStringsSep "" (s: ", " + s) ordered.order
              })";
        in
        caify "check `${c}`" m (
          guard pkgs input (
            m.run {
              inherit input pkgs target;
              # The stage names after `linked`, in order, and the check's
              # own name, for messages.
              product = product // {
                stageOrder = ordered.order;
                checkName = c;
              };
            }
          )
        )
      ) (filterAttrs (_: isLive) checks);
    in
    # `meta` is no input of the derivation: setting it here, not with
    # overrideAttrs, builds nothing again.
    lib.extendDerivation true (
      {
        stages = built.stages;
        stageOrder = ordered.order;
        checks = builtChecks;
        inherit ca;
        meta = (final.meta or { }) // meta;
      }
      // lib.optionalAttrs (debug != null && !(final ? debug)) { inherit debug; }
    ) final;
in
{
  inherit
    mkProduct
    helpers
    chain
    isLive
    explainOrder
    order
    noBinariesMarker
    ;
}
