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
#                           # for the target's default (traits.stagePreset)
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
# (`targetStageSet`: the preset's default stages, then the target's
# `stages`), and for each matching `packages.<name>` (unversioned keys
# first) its `stages` then its `target.<triple>.stages`. Checks merge the
# same way over the default `noSourceReferences`. Whether debug info is
# split off is the target's decision (decision 90); a package whose stages
# add or remove `splitDebug` gets an evaluation warning
# (`products.<pkg>.warnings`).
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
# leaves such roots out then. When it is left with none, it holds only
# the no-binaries marker (`stages.noBinariesMarker`, with the reasons),
# and every stage and check passes the marker on without running
# (decision 112), so the product and its checks build in repo.checks
# whether or not Cargo built anything. `.unbuilt` is empty.
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

  # The default stage chain for a target when no preset names one: its
  # traits' `stagePreset` (lib/target-traits.nix). Linux ELF targets split
  # debug info; Windows msvc keeps PDBs as they are; others (wasm without
  # a preset, unknown targets) get no stages, because the browser and
  # component chains need to know which one the user wants.
  stagePresetFor = triple: (targetTraits.resolve { inherit triple; }).stagePreset;

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
          # Decision 112: nothing to ship. The marker, with the reasons,
          # makes every later stage and check pass it on.
          if [ "$linked" -eq 0 ] && [ ''${#skipped[@]} -gt 0 ]; then
            printf '%s\n' "''${skipped[@]}" > $out/${stages.noBinariesMarker}
            echo "breakbulk: Cargo built none of ${pkg}'s binaries; the product holds only ${stages.noBinariesMarker}" >&2
          fi
        ''
      );

  # Decision 90: whether debug info is split off is decided per target,
  # from one stage set, and three things follow from it: the products'
  # stages (each package's set merges over this one), the remap scope of
  # the target's units (`shippedRemapScope`: debug info keeps real store
  # paths only when it is split off) and the GNU build ID of its links
  # (`NIX_SET_BUILD_ID`, which splitDebug needs). The units are shared by
  # every package of the target, so a package cannot change this alone:
  # mkProducts warns when a package's own stages add or remove
  # `splitDebug` (`splitDebugWarning`).
  #
  # The target's stage set: the stage preset's defaults (`stagePreset`, or
  # the traits' default chain) with `targets.<triple>.stages` over them.
  targetStageSet =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      stagePreset ? null,
      targetStages ? { },
      ...
    }:
    stages.merge [
      (presetStages (if stagePreset == null then traits.stagePreset else stagePreset))
      targetStages
    ];

  # Whether a stage set splits debug info off.
  splitsDebug = stageSet: (stageSet.splitDebug or null) != null;

  # Whether the target's products split debug info off (targetStageSet's
  # arguments).
  targetSplitsDebug = args: splitsDebug (targetStageSet args);

  # The scope of non-test units for a target (targetStageSet's arguments
  # and `coverage`).
  shippedRemapScope =
    {
      coverage ? false,
      ...
    }@args:
    if targetSplitsDebug args then "macro,diagnostics${lib.optionalString coverage ",coverage"}" else null;

  # The warning for a package whose stages disagree with its target's on
  # `splitDebug`, or null.
  splitDebugWarning =
    {
      pkg,
      triple,
      target,
      package,
    }:
    let
      fix = "set it for the target instead (`targets.\"${triple}\".stages.splitDebug`), or build this package for a target of its own";
    in
    if target == package then
      null
    else if target then
      "breakbulk: packages.${pkg} removes `splitDebug` on ${triple}, but debug splitting is decided per target (decision 90): the units it links still keep real source paths in their debug info, so its product references its sources (its noSourceReferences check fails), with no `debug` output to hold them; ${fix}"
    else
      "breakbulk: packages.${pkg} adds `splitDebug` on ${triple}, but debug splitting is decided per target (decision 90): the units it links remap every source path, so its `debug` output names no sources, and its links get no GNU build ID, which splitDebug needs for a binary with debug info; ${fix}";

  mkProducts =
    {
      pkgs,
      inst,
      select ? null,
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      stagePreset ? null,
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
      targetSet = targetStageSet {
        inherit
          triple
          traits
          stagePreset
          targetStages
          ;
      };
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
          stageSet = stages.merge ([ targetSet ] ++ map (c: c.stages or { }) confs);
          warning = splitDebugWarning {
            inherit pkg triple;
            target = splitsDebug targetSet;
            package = splitsDebug stageSet;
          };
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
          extra = {
            inherit roots;
            # Evaluation warnings about this product (also printed).
            warnings = lib.optional (warning != null) warning;
            unbuilt = map (r: {
              root = rootName r;
              inherit (r.breakbulkRoot) reason;
            }) unbuilt;
          };
        in
        (if warning == null then lib.id else lib.warn warning) ((if built == [ ] then head rs else p) // extra);
    in
    mapAttrs product selected;
in
{
  inherit
    mkProducts
    stagePresetFor
    targetStageSet
    splitsDebug
    targetSplitsDebug
    shippedRemapScope
    presetStages
    ;
}
