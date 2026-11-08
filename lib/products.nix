# Products of mkRepository: each package's build-plan roots through the
# target's post-link stages ("Products and stages" in docs/design.md;
# "Products, stages and tests" in docs/implementation.md).
#
#   products = breakbulk.products.mkProducts {
#     pkgs;
#     inst;                 # a mkWorkspace result (roots, sources)
#     select = null;        # the target's package selection, or a list
#     triple;               # the target triple
#     traits = <built-in>;  # its traits (lib/target-traits.nix), with the
#                           # user's targets.<triple>.traits merged in
#     stagePreset = null;   # a name in stages.defaultStageNames, or null
#     debugInfo = null;     # "split" | "keep" | "strip", or null for the
#                           # traits' default (decision 137)
#     targetStages = { };   # targets.<triple>.stages
#     targetChecks = { };   # targets.<triple>.checks
#     packageConfig = pkg: [ { stages; checks; } … ];  # matching package
#                           # overrides, least specific first, each with
#                           # its target.<triple> settings applied after it
#     ca = null;            # null: automatic (stages.caAuto)
#     lockfile = null;      # the workspace's Cargo.lock (bindgen stage)
#   };
#
#   products.<pkg>                 the product: linked -> stages -> install
#   products.<pkg>.stages.<name>   every stage (`linked` included)
#   products.<pkg>.stageOrder      stage names after `linked`, in order
#   products.<pkg>.debug           split debug info, when a stage split it
#                                  (or install, for `.pdb` and other
#                                  debuginfo side files of the link units)
#   products.<pkg>.checks.<name>   checks (`noSourceReferences` by default)
#   products.<pkg>.roots."<kind>/<target>"   the raw roots (units or stubs)
#   products.<pkg>.unbuilt         roots Cargo did not build, with reasons
#
# The stage set of a product is, merged in this order (later wins per
# attribute; `null` removes a stage): the target's stage set
# (`targetStageSet`: the stage `debugInfo` inserts, the preset's default
# stages, then the target's `stages`), and for each matching
# `packages.<name>` (unversioned keys first) its `stages` then its
# `target.<triple>.stages`. Checks merge the same way over the default
# `noSourceReferences`. What happens to debug info is the target's
# decision (`debugInfo`, decision 137): a stage set that removes the stage
# it inserts, or adds `splitDebug` where it inserts none, is an
# evaluation error.
#
# `linked` is one directory holding every built root's files, as
# symlinks: a bin under its target name (Cargo's uplifted name, the
# `-C extra-filename` hash removed, its extension kept), library outputs
# (cdylib, staticlib, dylib, .wasm) under their own names. `install` lays
# them out (bin/, lib/, pkg/ for wasm). A package whose roots were all
# skipped (required features) is the first root's stub, which fails with
# the reason.
#
# In dynamic-derivation mode whether Cargo built a root is known only at
# build time, from its wrapper (`not-built`, lib/dynamic.nix): `linked`
# leaves such roots out then, and fails with their reasons when it is left
# with none. `.unbuilt` is empty. A product whose every root has required
# features (by the prediction) may be all skipped, so `.uncertain` is set
# and repo.checks uses `.buildCheck` for it instead of the product and its
# checks: a derivation that builds every built root's unit and logs the
# skipped ones, which succeeds in both cases.
{
  lib,
  stages,
  targetTraits,
}:
let
  inherit (lib)
    attrValues
    concatMapStrings
    elem
    filter
    filterAttrs
    groupBy
    head
    listToAttrs
    mapAttrs
    nameValuePair
    ;

  # A stage preset's chain (`stagePreset`): none by default, because the
  # browser and component chains need to know which one the user wants;
  # debug handling is `debugInfo`'s.
  presetStages =
    name:
    if name == null then
      { }
    else
      stages.defaultStages.${name}
        or (throw "breakbulk: unknown stage preset `${name}`; known: ${lib.concatStringsSep ", " (lib.attrNames stages.defaultStages)}");

  rootName = r: "${r.breakbulkRoot.kind}/${r.breakbulkRoot.target}";

  # A root unit's `debug` output (its debuginfo side files, decision 89), as
  # a path that may not exist: in dynamic-derivation mode the wrapper links
  # it as `debug` when the unit has one.
  debugOf =
    r:
    if r.breakbulkRoot.dynamic or false then
      "${r.breakbulkRoot.wrapper}/debug"
    else if r ? debug then
      "${r.debug}"
    else
      null;

  isDynamic = r: r.breakbulkRoot.dynamic or false;

  # The `linked` stage of one package: a directory of symlinks (`out`), and
  # the root units' debuginfo side files (`debug`) under the names Cargo
  # uplifts them to: a bin's `.dwp` renamed as the bin is (`<bin>.dwp`),
  # `.pdb` and `.dwo` under rustc's names, which the binaries record.
  # Dynamic-derivation roots are read through their wrappers and left out
  # when not built. `debug` is declared only when a root can have side
  # files (decision 97): a root unit with a `debug` output, or any
  # dynamic-derivation root (its unit's outputs are not known at
  # evaluation).
  mkLinked =
    pkgs: pkg: built:
    let
      # Only dynamic-derivation roots need the build-time bookkeeping; IFD
      # mode's script stays as it was.
      anyDyn = lib.any isDynamic built;
      hasDebug = lib.any (r: debugOf r != null) built;
    in
    pkgs.runCommand "${pkg}-linked"
      {
        outputs = [ "out" ] ++ lib.optional hasDebug "debug";
      }
      (
        ''
          mkdir -p $out ${lib.optionalString hasDebug "$debug"}
          link() {
            # A library with two linkable crate types (cdylib and staticlib)
            # is one unit and several roots: each root names every file.
            local dir=''${3:-$out}
            if [ -e "$dir/$2" ] && [ "$(readlink -f "$dir/$2")" = "$(readlink -f "$1")" ]; then
              return
            fi
            if [ -e "$dir/$2" ]; then
              echo "breakbulk: two roots of ${pkg} produce $2" >&2
              exit 1
            fi
            ln -s "$1" "$dir/$2"
          }
        ''
        + lib.optionalString anyDyn ''
          linked=0
          skipped=()
        ''
        + concatMapStrings (
          r:
          let
            dbg = debugOf r;
            bin = r.breakbulkRoot.kind == "bin";
            target = lib.escapeShellArg r.breakbulkRoot.target;
            dyn = isDynamic r;
            w = r.breakbulkRoot.wrapper or null;
            src = if dyn then "${w}/root" else "${r}";
          in
          lib.optionalString dyn ''
            if [ -e ${w}/not-built ]; then
              skipped+=("$(<${w}/not-built)")
            else
          ''
          + lib.optionalString dyn ''
            linked=$((linked + 1))
          ''
          + (
            if bin then
              ''
                for f in ${src}/*; do
                  b=''${f##*/}
                  stem=''${b%%.*}
                  link "$f" ${target}"''${b#"$stem"}"
                done
              ''
            else
              ''
                for f in ${src}/*; do
                  link "$f" "''${f##*/}"
                done
              ''
          )
          + lib.optionalString (dbg != null) ''
            if [ -d ${dbg} ]; then
              for f in ${dbg}/*; do
                [ -e "$f" ] || continue
                b=''${f##*/}
                case "$b" in
                  ${if bin then "*.dwp) link \"$f\" ${target}.dwp \"$debug\" ;;" else ""}
                  *) link "$f" "$b" "$debug" ;;
                esac
              done
            fi
          ''
          + lib.optionalString dyn ''
            fi
          ''
        ) built
        + lib.optionalString anyDyn ''
          for s in "''${skipped[@]}"; do
            printf 'breakbulk: left out of ${pkg}: %s\n' "$s" >&2
          done
          if [ "$linked" -eq 0 ] && [ ''${#skipped[@]} -gt 0 ]; then
            printf 'error: %s\n' "''${skipped[@]}" >&2
            exit 1
          fi
        ''
      );

  # Dynamic-derivation mode, for repo.checks: every root's wrapper (which
  # builds its unit, when Cargo built it), with a log naming each root and
  # whether it was built. Succeeds whether or not any root was built.
  mkBuildCheck =
    pkgs: pkg: rs:
    pkgs.runCommand "${pkg}-roots"
      {
        wrappers = map (r: r.breakbulkRoot.wrapper) rs;
        names = map rootName rs;
      }
      ''
        mkdir -p $out
        w=($wrappers)
        n=($names)
        for i in "''${!w[@]}"; do
          if [ -e "''${w[$i]}/not-built" ]; then
            printf '%s: skipped: %s\n' "''${n[$i]}" "$(<"''${w[$i]}/not-built")"
          else
            printf '%s: built\n' "''${n[$i]}"
          fi
        done | tee $out/log
      '';

  # Decision 137: what happens to a target's debug info is one property of
  # the target, `targets.<triple>.debugInfo` (default: the traits'
  # `debugInfo`), and three things follow from it: the stage it puts first
  # in every product's chain (`splitDebug` for "split", `strip` for
  # "strip", none for "keep"), the remap scope of the target's units
  # (`shippedRemapScope`: debug info keeps real store paths only when it is
  # split off) and the GNU build ID of its links (`NIX_SET_BUILD_ID`, which
  # splitDebug needs). The units are shared by every package of the target,
  # so neither the target's nor a package's `stages` may remove that stage,
  # or add `splitDebug` where the target does not split: either is an
  # evaluation error naming `debugInfo` (decision 90 made it a warning).
  # Overriding the inserted stage's attributes (`run`, `after`) is allowed.
  #
  # `targetStageSet`'s arguments: { triple; traits; stagePreset; debugInfo;
  # targetStages; }.
  debugInfoOf =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      debugInfo ? null,
      ...
    }:
    let
      v = if debugInfo == null then traits.debugInfo else debugInfo;
    in
    if
      !(elem v [
        "split"
        "keep"
        "strip"
      ])
    then
      throw "breakbulk: targets.\"${triple}\".debugInfo: `${toString v}` is not one of split, keep, strip"
    else if v != "keep" && traits.objectFormat != "elf" then
      throw "breakbulk: targets.\"${triple}\".debugInfo = \"${v}\" needs an ELF target (the splitDebug and strip stages work on ELF files), and ${triple} is ${traits.objectFormat}; use \"keep\""
    else
      v;

  # The stage `debugInfo` puts in every product's chain, by name, or null.
  debugStageName = v: { split = "splitDebug"; strip = "strip"; keep = null; }.${v};

  # The stage itself: first after `linked`.
  debugStages =
    v:
    let
      n = debugStageName v;
    in
    if n == null then { } else stages.chain [ n ];

  # A stage set (`where` names it in messages) may not remove the target's
  # debug stage or add `splitDebug` where the target does not split.
  checkDebugStages =
    {
      triple,
      debugInfo,
      where,
    }:
    set:
    let
      auto = debugStageName debugInfo;
      fix = "debug splitting is decided per target, for every package of it (decision 137): set `targets.\"${triple}\".debugInfo` (\"split\", \"keep\" or \"strip\")";
    in
    if auto != null && set ? ${auto} && set.${auto} == null then
      throw "breakbulk: ${where} removes the `${auto}` stage on ${triple}, which `debugInfo = \"${debugInfo}\"` inserts; ${fix}"
    else if auto != "splitDebug" && (set.splitDebug or null) != null then
      throw "breakbulk: ${where} adds a `splitDebug` stage on ${triple}, whose `debugInfo` is \"${debugInfo}\": the target's units remap every source path and their links get no GNU build ID; ${fix}"
    else
      set;

  # The target's stage set: the debug stage, the stage preset's defaults
  # (`stagePreset`, a chain such as `wasmBrowser`; none by default), then
  # `targets.<triple>.stages` over them.
  targetStageSet =
    {
      triple,
      stagePreset ? null,
      targetStages ? { },
      ...
    }@args:
    let
      v = debugInfoOf args;
    in
    stages.merge [
      (debugStages v)
      (presetStages stagePreset)
      (checkDebugStages {
        inherit triple;
        debugInfo = v;
        where = "targets.\"${triple}\".stages";
      } targetStages)
    ];

  # Whether the target's debug info is split off (targetStageSet's
  # arguments).
  targetSplitsDebug = args: debugInfoOf args == "split";

  # The scope of non-test units for a target (targetStageSet's arguments
  # and `coverage`).
  shippedRemapScope =
    {
      coverage ? false,
      ...
    }@args:
    if targetSplitsDebug args then "macro,diagnostics${lib.optionalString coverage ",coverage"}" else null;

  mkProducts =
    {
      pkgs,
      inst,
      select ? null,
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      stagePreset ? null,
      debugInfo ? null,
      targetStages ? { },
      targetChecks ? { },
      packageConfig ? _: [ ],
      ca ? null,
      lockfile ? null,
      sourcePaths ? attrValues inst.sources.workspace ++ attrValues inst.sources.crates,
      # The toolchain's store paths: noSourceReferences fails when a
      # product's closure has one (field-trial gap 9).
      toolchainPaths ? inst.toolchainPaths or [ ],
    }:
    let
      setArgs = {
        inherit
          triple
          traits
          stagePreset
          debugInfo
          targetStages
          ;
      };
      targetSet = targetStageSet setArgs;
      effectiveDebugInfo = debugInfoOf setArgs;
      byPkg = groupBy (r: r.breakbulkRoot.package) (
        filter (r: !r.breakbulkRoot.test) (attrValues inst.roots)
      );
      selected = if select == null then byPkg else filterAttrs (n: _: elem n select) byPkg;

      product =
        pkg: rs:
        let
          built = filter (r: r.breakbulkRoot.unit != null) rs;
          unbuilt = filter (r: r.breakbulkRoot.unit == null) rs;
          roots = listToAttrs (map (r: nameValuePair (rootName r) r) rs);
          confs = packageConfig pkg;
          stageSet = stages.merge (
            [ targetSet ]
            ++ map (
              c:
              checkDebugStages {
                inherit triple;
                debugInfo = effectiveDebugInfo;
                where = "packages.${pkg}.stages";
              } (c.stages or { })
            ) confs
          );
          checkSet = stages.merge ([ targetChecks ] ++ map (c: c.checks or { }) confs);
          p = stages.mkProduct {
            name = pkg;
            linked = mkLinked pkgs pkg built;
            stages = stageSet;
            checks = checkSet;
            target = { inherit triple traits; };
            inherit
              pkgs
              ca
              sourcePaths
              toolchainPaths
              ;
            info = lib.optionalAttrs (lockfile != null) { inherit lockfile; };
          };
          # Dynamic-derivation mode: every root may be skipped when each
          # has required features.
          uncertain = lib.all (
            r: isDynamic r && (r.breakbulkRoot.requiredFeatures or null) != null && r.breakbulkRoot.requiredFeatures != [ ]
          ) rs;
          extra = {
            inherit roots uncertain;
            unbuilt = map (r: {
              root = rootName r;
              inherit (r.breakbulkRoot) reason;
            }) unbuilt;
          }
          // lib.optionalAttrs uncertain { buildCheck = mkBuildCheck pkgs pkg rs; };
        in
        (if built == [ ] then head rs else p) // extra;
    in
    mapAttrs product selected;
in
{
  inherit
    mkProducts
    targetStageSet
    debugInfoOf
    targetSplitsDebug
    shippedRemapScope
    presetStages
    ;
}
