# Products and post-link stages ("Products, stages and tests" in
# docs/implementation.md; "Products and stages" in docs/design.md).
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
#     ca = null;             # null: automatic (see `caAuto`); true; false
#   };
#
#   p                  the product (the last stage's output)
#   p.stages.<name>    every stage, `linked` included
#   p.stageOrder       stage names in order, without `linked`
#   p.debug            the split debug output, when a stage produced one
#                      (splitDebug; install, for the link units' `.pdb` and
#                      other debuginfo side files when nothing split before)
#   p.checks.<name>    every check, `noSourceReferences` included
#
# Stage modules are `{ after ? null; before ? null; run; }`:
#   - `after`/`before` name a stage, a list of stages, or null. A stage with
#     neither runs after `linked`.
#   - `run = { input, product, target, pkgs }: <derivation>`; `input` is the
#     previous stage's output, `product` is `{ name; sourcePaths; toolchainPaths; } // info`,
#     plus `linkedDebug` (the `debug` output of `linked`, when it has one:
#     the link units' debuginfo side files) and `debugSplit` (whether an
#     earlier stage has a `debug` output).
#   - A stage set to `null` (e.g. `lib.mkForce null` in the module system)
#     is removed. Constraints that name a removed stage are dropped.
#   - `install` (helpers.install) is added unless the set has `install`;
#     it always runs last; `install = null` removes it.
#   - The order must be total: every stage must be ordered relative to the
#     next by its constraints. A cycle, a missing reference or two stages
#     whose relative order is not given fail evaluation, listing every stage
#     with its constraints.
#
# Checks are `{ on ? <the product>; run = { input, product, pkgs }: drv; }`;
# `null` removes one. `noSourceReferences` is added by default
# (`defaultChecks = false` turns it off).
#
# Every stage and check runs through a guard (decision 112): when its
# input holds `noBinariesMarker` (a `linked` stage of a product Cargo
# built no binary of, in dynamic-derivation mode), it copies the marker to
# its outputs and succeeds without running its own builder. A stage or
# check made with a bare `derivation` call (no `overrideAttrs`) is guarded
# too: it is rebuilt from its `drvAttrs` with the guard as builder
# (decision 147).
#
# Content addressing: with `ca`, every stage and check derivation gets
# `__contentAddressed = true; outputHashMode = "recursive";
# outputHashAlgo = "sha256"` (through overrideAttrs, or from `drvAttrs` for a
# bare `derivation`, as for the guard). `linked` is left as it
# is. Nix rejects such a derivation at evaluation unless the evaluator has
# the `ca-derivations` experimental feature, and the build fails unless the
# daemon has it too. Nix offers no way for an expression to test for the
# feature (`builtins.tryEval` does not catch the missing-feature error, and
# no builtin is gated on it), so `ca = null` follows the closest signal:
# `builtins ? outputOf`, which exists only when `dynamic-derivations` is
# enabled. breakbulk's dynamic-derivation mode needs `ca-derivations` as well
# (its instantiate derivation has a floating CA output), so this is on
# exactly when `mode = "auto"` picks dynamic-derivation mode, and off on a
# stock Nix.
{
  lib,
  wasmBindgen,
  targetTraits,
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

  helpers = import ./stage-helpers { inherit lib wasmBindgen targetTraits; };

  caAttrs = {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };

  caAuto = builtins ? outputOf;

  # Decision 112: the file a product's `linked` stage holds instead of
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
  # its `drvAttrs` (a bare `derivation` call, decision 147), keeping any
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

  # Default stage chains per preset (`stagePreset`), as data. Debug
  # handling is not among them: mkRepository puts the stage of the
  # target's `debugInfo` (`splitDebug`, `strip`) first (lib/products.nix,
  # decision 137).
  defaultStageNames = {
    wasmWeb = [
      "bindgen"
      "wasmOpt"
    ];
    wasmComponent = [
      "wasmOpt"
      "componentize"
    ];
  };

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

  defaultStages = mapAttrs (_: chain) defaultStageNames;

  # Merge stage modules attribute-wise (later wins per attribute); `null`
  # removes a stage. A stand-in for module-system merging.
  merge = lib.foldl' (
    acc: set:
    acc
    // mapAttrs (
      n: v: if v == null then null else (if acc ? ${n} && acc.${n} != null then acc.${n} else { }) // v
    ) set
  ) { };

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
    }:
    let
      withInstall = {
        install = {
          run = helpers.install;
        };
      }
      // stages;
      live = filterAttrs (_: v: v != null) withInstall;
      removed = attrNames (filterAttrs (_: v: v == null) withInstall);
      names = attrNames live;
      isLive = n: live ? ${n};

      cons = mapAttrs (
        n: m:
        let
          a = toNames n "after" (m.after or null);
          b = toNames n "before" (m.before or null);
        in
        {
          rawAfter = a;
          rawBefore = b;
          after = filter isLive a;
          before = filter isLive b;
          missing = filter (x: x != "linked" && !(isLive x) && !(elem x removed)) (a ++ b);
        }
      ) live;

      # x must come before y.
      edge =
        x: y:
        x != y && (elem x cons.${y}.after || elem y cons.${x}.before || (y == "install" && x != "install"));

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
              lib.optionalString (n == "install") "; runs last"
            }"
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
      succ = x: filter (edge x) names;
      reach =
        x:
        map (e: e.key) (
          builtins.genericClosure {
            startSet = map (key: { inherit key; }) (succ x);
            operator = e: map (key: { inherit key; }) (succ e.key);
          }
        );
      onCycle = filter (x: elem x (reach x)) names;
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
      ca ? null,
      defaultChecks ? true,
    }:
    let
      useCa = if ca == null then caAuto else ca;
      ordered = order { inherit name stages; };
      product = {
        inherit name sourcePaths toolchainPaths;
      }
      # The link units' debuginfo side files (decision 89), for the stage
      # that writes the product's `debug` output.
      // lib.optionalAttrs (linked ? debug) { linkedDebug = linked.debug; }
      // info;

      caify =
        what: drv:
        if !useCa then
          drv
        else if drv ? drvAttrs then
          modifyDrv drv (_: _: caAttrs)
        else
          throw "breakbulk: ${what} of `${name}` returned something that is not a derivation, so it cannot be made content-addressed; set `ca = false`";

      built =
        lib.foldl'
          (
            acc: s:
            let
              drv = caify "stage `${s}`" (
                guard pkgs acc.last (
                  ordered.live.${s}.run {
                    input = acc.last;
                    # `debugSplit`: an earlier stage has a `debug` output.
                    product = product // {
                      debugSplit = acc.split;
                    };
                    inherit target pkgs;
                  }
                )
              );
            in
            {
              last = drv;
              split = acc.split || elem "debug" (drv.outputs or [ ]);
              stages = acc.stages // {
                ${s} = drv;
              };
            }
          )
          {
            last = linked;
            split = false;
            stages = {
              inherit linked;
            };
          }
          ordered.order;

      final = built.last;

      # The last stage that split debug information.
      splitters = filter (s: elem "debug" (built.stages.${s}.outputs or [ ])) ordered.order;
      debug = if splitters == [ ] then null else built.stages.${lib.last splitters}.debug;

      allChecks =
        lib.optionalAttrs defaultChecks {
          noSourceReferences = {
            run = helpers.noSourceReferences;
          };
        }
        // checks;
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
        caify "check `${c}`" (guard pkgs input (m.run { inherit input product pkgs; }))
      ) (filterAttrs (_: v: v != null) allChecks);
    in
    lib.extendDerivation true (
      {
        stages = built.stages;
        stageOrder = ordered.order;
        checks = builtChecks;
        ca = useCa;
      }
      // lib.optionalAttrs (debug != null && !(final ? debug)) { inherit debug; }
    ) final;
in
{
  inherit
    mkProduct
    helpers
    defaultStageNames
    defaultStages
    chain
    merge
    explainOrder
    order
    caAuto
    caAttrs
    noBinariesMarker
    ;
}
