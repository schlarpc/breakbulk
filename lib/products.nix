# Products of mkRepository: each package's build-plan roots through the
# target's post-link stages (docs/src/explanation/products.md;
# docs/src/explanation/internals/products.md).
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
#                           # traits' default
#     targetStages = { };   # targets.<triple>.stages
#     targetChecks = { };   # targets.<triple>.checks
#     packageConfig = pkg: [ { stages; checks; } … ];  # matching package
#                           # overrides, least specific first, each with
#                           # its target.<triple> settings applied after it
#     ca = null;            # null: automatic (stages.caAuto)
#     lockfile = null;      # the workspace's Cargo.lock (bindgen stage)
#     defaultChecks = true; # false: no noSourceReferences (sourcePaths = "keep")
#   };
#
#   products.<pkg>                 the product: linked -> stages -> install
#   products.<pkg>.stages.<name>   every stage (`linked` included)
#   products.<pkg>.stageOrder      stage names after `linked`, in order
#   products.<pkg>.debug           split debug info, when a stage split it
#                                  (or install, for `.pdb` and other
#                                  debuginfo side files of the link units)
#   products.<pkg>.checks.<name>   checks (`noSourceReferences` by default,
#                                  `buildScriptFiles` and
#                                  `buildScriptPaths` on every product)
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
# decision (`debugInfo`): a stage set that removes the stage
# it inserts, or adds `splitDebug` where it inserts none, is an
# evaluation error.
#
# `linked` is one directory holding every built root's files, as
# symlinks, under Cargo's uplifted names: a bin under its target name and
# executable suffix, as its unit stores it; a staticlib under its library
# name (rustc's `-C extra-filename` hash removed, the extension kept); a
# cdylib or dylib under rustc's name, which has no hash. `install` lays
# them out by root kind (`rootFiles`): bin/, lib/, or the traits'
# `sharedLibraryDir`. A package whose roots were all
# skipped (required features) is the first root's stub, which fails with
# the reason.
#
# In dynamic-derivation mode whether Cargo built a root is known only at
# build time, from its wrapper (`not-built`, lib/dynamic.nix): `linked`
# leaves such roots out then. When it is left with none, it holds only
# the no-binaries marker (`stages.noBinariesMarker`, with the reasons),
# and every stage and check passes the marker on without running, so the
# product and its checks build in repo.checks
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

  # A root's debuginfo side files: its unit's
  # `debug` output, and those of the libraries below it (`.dwo` files with
  # split-debuginfo = "unpacked"), as paths that may not exist: in
  # dynamic-derivation mode the wrapper's `debug` directory links them all.
  debugOf =
    r:
    if r.breakbulkRoot.dynamic or false then
      [ "${r.breakbulkRoot.wrapper}/debug" ]
    else
      lib.optional (r ? debug) "${r.debug}" ++ map toString (r.breakbulkRoot.debugBelow or [ ]);

  isDynamic = r: r.breakbulkRoot.dynamic or false;

  # The `linked` stage of one package: a directory of symlinks (`out`), and
  # the root units' debuginfo side files (`debug`) under the names Cargo
  # uplifts them to: a bin's `.dwp` renamed as the bin is (`<bin>.dwp`),
  # `.pdb` and `.dwo` under rustc's names, which the binaries record, with
  # the `.dwo` files of the libraries below each root.
  # Dynamic-derivation roots are read through their wrappers and left out
  # when not built. `debug` is declared only when a root can have side
  # files: a root unit or a library below it with a `debug`
  # output, or any dynamic-derivation root (its unit's outputs are not
  # known at evaluation).
  mkLinked =
    pkgs: traits: pkg: built:
    let
      # A staticlib's file as Cargo uplifts it: rustc names it with the
      # `-C extra-filename` hash Cargo gives it (cdylibs and dylibs of
      # path packages get none).
      staticPrefix = lib.escapeShellArg traits.staticLibraryPrefix;
      staticSuffix = lib.escapeShellArg traits.staticLibrarySuffix;
      # Only dynamic-derivation roots need the build-time bookkeeping; IFD
      # mode's script stays as it was.
      anyDyn = lib.any isDynamic built;
      hasDebug = lib.any (r: debugOf r != [ ]) built;
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
          + ''
            for f in ${src}/*; do
              b=''${f##*/}
              case "$b" in
                ${staticPrefix}${target}-*${staticSuffix}) link "$f" ${staticPrefix}${target}${staticSuffix} ;;
                *) link "$f" "$b" ;;
              esac
            done
          ''
          + concatMapStrings (dbg: ''
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
          '') dbg
          + lib.optionalString dyn ''
            fi
          ''
        ) built
        + lib.optionalString anyDyn ''
          for s in "''${skipped[@]}"; do
            printf 'breakbulk: left out of ${pkg}: %s\n' "$s" >&2
          done
          # Nothing to ship. The marker, with the reasons,
          # makes every later stage and check pass it on.
          if [ "$linked" -eq 0 ] && [ ''${#skipped[@]} -gt 0 ]; then
            printf '%s\n' "''${skipped[@]}" > $out/${stages.noBinariesMarker}
            echo "breakbulk: Cargo built none of ${pkg}'s binaries; the product holds only ${stages.noBinariesMarker}" >&2
          fi
        ''
      );

  # What happens to a target's debug info is one property of
  # the target, `targets.<triple>.debugInfo` (default: the traits'
  # `debugInfo`), and three things follow from it: the stage it puts first
  # in every product's chain (`splitDebug` for "split", `strip` for
  # "strip", none for "keep"), the remap scope of the target's units
  # (`shippedRemapScope`: debug info keeps real store paths only when it is
  # split off) and the GNU build ID of its links (`NIX_SET_BUILD_ID`, which
  # splitDebug needs). The units are shared by every package of the target,
  # so neither the target's nor a package's `stages` may remove that stage,
  # or add `splitDebug` where the target does not split: either is an
  # evaluation error naming `debugInfo`.
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
      fix = "debug splitting is decided per target, for every package of it: set `targets.\"${triple}\".debugInfo` (\"split\", \"keep\" or \"strip\")";
    in
    if auto != null && set ? ${auto} && set.${auto} == null then
      throw "breakbulk: ${where} removes the `${auto}` stage on ${triple}, which `debugInfo = \"${debugInfo}\"` inserts; ${fix}"
    else if auto != "splitDebug" && (set.splitDebug or null) != null then
      throw "breakbulk: ${where} adds a `splitDebug` stage on ${triple}, whose `debugInfo` is \"${debugInfo}\": the target's units remap every source path and their links get no GNU build ID; ${fix}"
    else
      set;

  # The target's stage set: the debug stage, the stage preset's defaults
  # (`stagePreset`, a chain such as `wasmWeb`; none by default), then
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
      # Package name -> its `[package]` table, workspace fields resolved
      # (manifest.packageInfo's `package`), for `product.package`.
      cargoPackages ? { },
      # false: no default noSourceReferences check (`sourcePaths = "keep"`).
      defaultChecks ? true,
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
          # The `flags` outputs of the target-platform runs the product's
          # roots depend on, whose `directives.json` names the files their
          # scripts placed next to the binaries (`targetDirs`, #23), for the
          # `buildScriptFiles` stage and check: a list in IFD mode (each
          # root's `buildScriptRuns` from units.json); in dynamic-derivation
          # mode `{ rootInfo; }`, the roots' `breakbulk-root.json` files,
          # which list them (`buildScriptFlags`) at build time.
          dynamicRoots = filter (r: r.breakbulkRoot.dynamic or false) built;
          buildScriptFlags =
            if dynamicRoots != [ ] then
              { rootInfo = map (r: "${r.breakbulkRoot.wrapper}/breakbulk-root.json") dynamicRoots; }
            else
              lib.unique (
                lib.concatMap (r: map (id: inst.units.build.${id}.flags) (r.breakbulkRoot.buildScriptRuns or [ ])) built
              );
          unbuilt = filter (r: r.breakbulkRoot.unit == null) rs;
          # Each root's file in `linked`, by name, to its root kind, for
          # `install` (and the same names in dynamic-derivation mode, whose
          # predicted roots carry the kind and target). mkLinked fails when
          # two roots produce one name, so the map is unambiguous.
          rootFiles = lib.listToAttrs (
            lib.concatMap (
              r:
              let
                inherit (r.breakbulkRoot) kind target;
                file =
                  {
                    bin = target + traits.executableSuffix;
                    staticlib = traits.staticLibraryPrefix + target + traits.staticLibrarySuffix;
                    cdylib = traits.sharedLibraryPrefix + target + traits.sharedLibrarySuffix;
                    dylib = traits.sharedLibraryPrefix + target + traits.sharedLibrarySuffix;
                  }
                  .${kind} or null;
              in
              lib.optional (file != null) (nameValuePair file kind)
            ) built
          );
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
          checkSet = stages.merge (
            [
              # On every product (passing when no build script placed
              # files or declared a missing path): in dynamic mode whether
              # there are runs is known only at build time, and both modes
              # have the same checks. `buildScriptPaths` reads only the
              # runs, so it waits for `linked`, not for the stages.
              {
                buildScriptFiles.run = stages.helpers.buildScriptFilesIncluded;
                buildScriptPaths = {
                  on = "linked";
                  run = stages.helpers.buildScriptPaths;
                };
              }
              targetChecks
            ]
            ++ map (c: c.checks or { }) confs
          );
          p = stages.mkProduct {
            name = pkg;
            linked = mkLinked pkgs traits pkg built;
            stages = stageSet;
            checks = checkSet;
            target = { inherit triple traits; };
            inherit
              pkgs
              ca
              sourcePaths
              toolchainPaths
              defaultChecks
              ;
            # `product` attributes; docs/src/reference/stage-functions.md
            # lists each (checked by products-product-attributes).
            info =
              lib.optionalAttrs (lockfile != null) { inherit lockfile; }
              // lib.optionalAttrs (cargoPackages ? ${pkg}) { package = cargoPackages.${pkg}; }
              // {
                inherit buildScriptFlags;
                # A staticlib's objects keep their debug information with
                # real source paths: the final link, not this product,
                # decides whether to split or strip it.
                sourcesAllowedIn = lib.attrNames (lib.filterAttrs (_: k: k == "staticlib") rootFiles);
                inherit rootFiles;
              };
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
    targetStageSet
    debugInfoOf
    targetSplitsDebug
    shippedRemapScope
    presetStages
    ;
}
