# Products of mkRepository: each package's build-plan roots through the
# target's post-link stages ("Products and stages" in docs/design.md;
# "Products, stages and tests" in docs/implementation.md).
#
#   products = breakbulk.products.mkProducts {
#     pkgs;
#     inst;                 # a mkWorkspace result (roots, sources)
#     select = null;        # the target's package selection, or a list
#     triple;               # the target triple
#     stagePreset = null;   # a name in stages.defaultStageNames, or null
#                           # for the triple's default (stagePresetFor)
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
# attribute; `null` removes a stage): the preset's default stages, the
# target's `stages`, and for each matching `packages.<name>` (unversioned
# keys first) its `stages` then its `target.<triple>.stages`. Checks merge
# the same way over the default `noSourceReferences`.
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
{ lib, stages }:
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

  # The default stage chain for a triple when no preset names one: Linux
  # ELF targets split debug info; Windows msvc keeps PDBs as they are;
  # others (wasm without a preset, unknown targets) get no stages, because
  # the browser and component chains need to know which one the user
  # wants.
  stagePresetFor =
    triple:
    if lib.hasInfix "-linux-" triple || lib.hasSuffix "-linux" triple then
      "linuxGnu"
    else if lib.hasInfix "-windows-msvc" triple then
      "msvc"
    else
      null;

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
  # when not built.
  mkLinked =
    pkgs: pkg: built:
    let
      # Only dynamic-derivation roots need the build-time bookkeeping; IFD
      # mode's script stays as it was.
      anyDyn = lib.any isDynamic built;
    in
    pkgs.runCommand "${pkg}-linked"
      {
        outputs = [
          "out"
          "debug"
        ];
      }
      (
        ''
          mkdir -p $out $debug
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

  # The scope of non-test units for a target: debug info keeps real store
  # paths only when the target's products split it off.
  shippedRemapScope =
    {
      stagePreset ? null,
      triple,
      targetStages ? { },
      coverage ? false,
    }:
    let
      preset = if stagePreset == null then stagePresetFor triple else stagePreset;
      merged = stages.merge [
        (presetStages preset)
        targetStages
      ];
    in
    if (merged.splitDebug or null) != null then
      "macro,diagnostics${lib.optionalString coverage ",coverage"}"
    else
      null;

  mkProducts =
    {
      pkgs,
      inst,
      select ? null,
      triple,
      stagePreset ? null,
      targetStages ? { },
      targetChecks ? { },
      packageConfig ? _: [ ],
      ca ? null,
      lockfile ? null,
      sourcePaths ? attrValues inst.sources.workspace ++ attrValues inst.sources.crates,
    }:
    let
      preset = if stagePreset == null then stagePresetFor triple else stagePreset;
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
            [
              (presetStages preset)
              targetStages
            ]
            ++ map (c: c.stages or { }) confs
          );
          checkSet = stages.merge ([ targetChecks ] ++ map (c: c.checks or { }) confs);
          p = stages.mkProduct {
            name = pkg;
            linked = mkLinked pkgs pkg built;
            stages = stageSet;
            checks = checkSet;
            target = { inherit triple; };
            inherit pkgs ca sourcePaths;
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
    stagePresetFor
    shippedRemapScope
    presetStages
    ;
}
