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

  # The `linked` stage of one package: a directory of symlinks.
  mkLinked =
    pkgs: pkg: built:
    pkgs.runCommand "${pkg}-linked" { } (
      ''
        mkdir -p $out
        link() {
          if [ -e "$out/$2" ]; then
            echo "breakbulk: two roots of ${pkg} produce $2" >&2
            exit 1
          fi
          ln -s "$1" "$out/$2"
        }
      ''
      + concatMapStrings (
        r:
        if r.breakbulkRoot.kind == "bin" then
          ''
            for f in ${r}/*; do
              b=''${f##*/}
              stem=''${b%%.*}
              link "$f" ${lib.escapeShellArg r.breakbulkRoot.target}"''${b#"$stem"}"
            done
          ''
        else
          ''
            for f in ${r}/*; do
              link "$f" "''${f##*/}"
            done
          ''
      ) built
    );

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
          extra = {
            inherit roots;
            unbuilt = map (r: {
              root = rootName r;
              inherit (r.breakbulkRoot) reason;
            }) unbuilt;
          };
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
