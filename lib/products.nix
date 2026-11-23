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
#     debugInfo = null;     # "split" | "keep" | "strip", or null for the
#                           # traits' default
#     targetStages = { };   # targets.<triple>.stages
#     targetChecks = { };   # targets.<triple>.checks
#     packageConfig = pkg: { stages; checks; };  # the package's settings
#                           # (packages.<name>.stages, .checks)
#     ca = breakbulk.nixFeatures.defaultCa;
#     nixFeatures = <standalone>;  # as stages.mkProduct's
#     lockfile = null;      # the workspace's Cargo.lock (wasmBindgen stage)
#     keepSourcePaths = false;  # true (`sourcePaths = "keep"`): no
#                           # noSourceReferences check
#   };
#
# The stage and check sets are plain attribute sets of stages, or
# `definitionsOf` an evaluated option (its definitions and their
# priority), which merge field by field.
#
#   products.<pkg>                 the product: linked -> stages -> install
#   products.<pkg>.stages.<name>   every stage (`linked` included)
#   products.<pkg>.stageOrder      stage names after `linked`, in order
#   products.<pkg>.debug           split debug info, when a stage split it
#                                  (or install, for `.pdb` and other
#                                  debuginfo side files of the link units)
#   products.<pkg>.checks.<name>   checks (`defaultChecks`, then the
#                                  target's and the package's)
#   products.<pkg>.roots."<kind>/<target>"   the raw roots
#
# The stage set of a product is one option's value, merged by the module
# system from three layers, lowest first: the stages `debugInfo` inserts,
# the target's `stages` (a preset's among them), then the package's
# `stages`, whose own settings layers are ranked already
# (lib/package-settings.nix). A higher layer's single values win at equal
# priority (lib/modules/types.nix `layer`), so a package's `after`
# replaces the target's while the target's `run` stays; `null` removes a
# stage. Checks merge the same way over `defaultChecks`. What happens to
# debug info is the target's decision (`debugInfo`): a stage set that
# removes the `splitDebug` or `strip` it inserts, or adds `splitDebug`
# where it inserts none, is an evaluation error.
#
# `linked` is one directory holding every built root's files, as
# symlinks, under Cargo's uplifted names: a bin under its target name and
# executable suffix, as its unit stores it; a staticlib under its library
# name (rustc's `-C extra-filename` hash removed, the extension kept); a
# cdylib or dylib under rustc's name, which has no hash. `install` lays
# them out by root kind (`rootFiles`): bin/, lib/, or the traits'
# `sharedLibraryDir`.
#
# Whether Cargo built a root (required features) is known only at build
# time, from its wrapper (`not-built`, instantiate.nix `rootShape`):
# `linked` leaves such roots out. When it is left with none, it holds
# only the no-binaries marker (`stages.noBinariesMarker`, with the
# reasons), and every stage and check passes the marker on without
# running, so the product and its checks build in repo.checks whether or
# not Cargo built anything.
{
  lib,
  stages,
  targetTraits,
  featureGates,
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

  bt = import ./modules/types.nix { inherit lib; };

  # An evaluated option's definitions, to merge with others as one layer:
  # each value at the option's priority, so that a priority around a whole
  # set (`stages = lib.mkForce { … }`) still drops the lower layers.
  definitionsOf = opt: {
    defs = opt.definitionsWithLocations;
    prio = opt.highestPrio;
  };

  # Stage or check sets (`type`: bt.stages or bt.checks) merged as one
  # option from `layers`, lowest first: each `{ set; rank ? <none>; }`, a
  # plain set or `definitionsOf` an option. `rank` (lib/modules/types.nix
  # `layer`) places a layer below those ranked already: package settings,
  # whose ranks run from 0 up.
  setEval =
    type:
    lib.evalModules {
      modules = [
        {
          options.set = lib.mkOption {
            inherit type;
            default = { };
          };
        }
      ];
    };
  stageSetEval = setEval bt.stages;
  checkSetEval = setEval bt.checks;
  mergeSets =
    base: layers:
    let
      modulesOf =
        l:
        let
          d =
            if l.set ? defs && l.set ? prio then
              l.set
            else
              {
                defs = [
                  {
                    file = "<unknown-file>";
                    value = l.set;
                  }
                ];
                prio = lib.modules.defaultOverridePriority;
              };
          ms = map (x: {
            _file = x.file;
            set = lib.mkOverride d.prio x.value;
          }) d.defs;
        in
        if l ? rank then [ (bt.layer base.options l.rank (_: v: v) { imports = ms; }) ] else ms;
    in
    (base.extendModules { modules = lib.concatMap modulesOf layers; }).config.set;

  # The checks every product of mkRepository gets, as the lowest layer of
  # its check set: `noSourceReferences`, unless the variant keeps source
  # paths (`sourcePaths = "keep"`), and `buildScriptFiles`, which passes
  # when no build script placed files (in dynamic mode whether there are
  # runs is known only at build time, and both modes have the same
  # checks).
  defaultChecks =
    {
      keepSourcePaths ? false,
    }:
    {
      noSourceReferences =
        if keepSourcePaths then
          null
        else
          {
            run = stages.helpers.noSourceReferences;
          };
      buildScriptFiles.run = stages.helpers.buildScriptFilesIncluded;
    };

  rootName = r: "${r.breakbulkRoot.kind}/${r.breakbulkRoot.target}";

  # A root's debuginfo side files: its unit's `debug` output, and those of
  # the libraries below it (`.dwo` files with split-debuginfo =
  # "unpacked"), which the wrapper's `debug` directory links, when there
  # are any.
  debugOf = r: "${r.breakbulkRoot.wrapper}/debug";

  # The `linked` stage of one package: a directory of symlinks (`out`), and
  # the root units' debuginfo side files (`debug`) under the names Cargo
  # uplifts them to: a bin's `.dwp` and Apple `.dSYM` renamed as the bin
  # is (`<bin>.dwp`, `<bin>.dSYM`),
  # `.pdb` and `.dwo` under rustc's names, which the binaries record, with
  # the `.dwo` files of the libraries below each root. Roots are read
  # through their wrappers and left out when not built; which have side
  # files is known at build time only.
  mkLinked =
    pkgs: traits: pkg: built:
    let
      # A staticlib's file as Cargo uplifts it: rustc names it with the
      # `-C extra-filename` hash Cargo gives it (cdylibs and dylibs of
      # path packages get none).
      staticPrefix = lib.escapeShellArg traits.staticLibraryPrefix;
      staticSuffix = lib.escapeShellArg traits.staticLibrarySuffix;
      # The side files rustc packs for one linked output (`.dwp`, `.dSYM`),
      # which Cargo renames with the bin. Not the `.pdb`: the linker
      # names it, and the binary records that name.
      packedSuffixes = map (a: lib.escapeShellArg a.suffix) (
        lib.filter (a: a.when == "split-packed" && !(a.perObject or false)) traits.debugArtifacts
      );
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
        + ''
          linked=0
          skipped=()
        ''
        + concatMapStrings (
          r:
          let
            dbg = debugOf r;
            bin = r.breakbulkRoot.kind == "bin";
            target = lib.escapeShellArg r.breakbulkRoot.target;
            w = r.breakbulkRoot.wrapper;
          in
          ''
            if [ -e ${w}/not-built ]; then
              skipped+=("$(<${w}/not-built)")
            else
            linked=$((linked + 1))
            for f in ${w}/root/*; do
              b=''${f##*/}
              case "$b" in
                ${staticPrefix}${target}-*${staticSuffix}) link "$f" ${staticPrefix}${target}${staticSuffix} ;;
                *) link "$f" "$b" ;;
              esac
            done
          ''
          + ''
            if [ -d ${dbg} ]; then
              for f in ${dbg}/*; do
                [ -e "$f" ] || continue
                b=''${f##*/}
                case "$b" in
                  ${lib.optionalString bin (
                    concatMapStrings (x: ''
                      *${x}) link "$f" ${target}${x} "$debug" ;;
                    '') packedSuffixes
                  )}
                  *) link "$f" "$b" "$debug" ;;
                esac
              done
            fi
            fi
          ''
        ) built
        + ''
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

  # What happens to a target's debug info is one property of the target,
  # `targets.<triple>.debugInfo` (default: the traits' `debugInfo`), and
  # three things follow from it: the stages it puts first in every
  # product's chain (the traits' `debugStages` entry for the value: on ELF
  # `packDwo` then `splitDebug` for "split", `strip` for "strip", `packDwo`
  # for "keep"), the remap scope of the target's units
  # (`shippedRemapScope`: debug info keeps real store paths only when it is
  # split off) and the GNU build ID of its links (`NIX_SET_BUILD_ID`, which
  # splitDebug needs). The units are shared by every package of the target,
  # so neither the target's nor a package's `stages` may remove a stage
  # the entry inserts, or add one only the "split" entry has where the
  # value is another: either is an evaluation error naming `debugInfo`. A
  # `removable` stage (`packDwo`: it changes no unit and leaves no source
  # path in the product) is an ordinary one: `null` removes it.
  # Overriding the inserted stages' fields (`run`, `after`) is allowed.
  #
  # `targetLayers`' arguments: { triple; traits; debugInfo; targetStages; }.
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
    if !(traits.debugStages ? ${v}) then
      throw "breakbulk: targets.\"${triple}\".debugInfo = \"${toString v}\" needs stages for it, and the traits of ${triple} (${traits.objectFormat}) have none: their `debugStages` has ${
        lib.concatMapStringsSep ", " (n: "\"${n}\"") (lib.attrNames traits.debugStages)
      }; use one of those, or give the stages as `targets.\"${triple}\".traits.debugStages.${toString v}`"
    else
      v;

  # The stages of a `debugStages` entry: `{ name; run; removable; }`.
  entryStages = map (
    s:
    let
      x = if builtins.isString s then { name = s; } else s;
    in
    {
      inherit (x) name;
      run =
        x.run or stages.helpers.${x.name}
          or (throw "breakbulk: the debug stage `${x.name}` is no stage helper; give its `run`");
      removable = x.removable or false;
    }
  );
  entryOf = v: traits: entryStages traits.debugStages.${v};

  # The chain `debugInfo` puts first after `linked`, each stage after the
  # one before.
  debugStages =
    v: traits:
    let
      e = entryOf v traits;
    in
    lib.listToAttrs (
      lib.imap0 (
        i: s:
        nameValuePair s.name {
          after = if i == 0 then "linked" else (lib.elemAt e (i - 1)).name;
          before = null;
          inherit (s) run;
        }
      ) e
    );

  # The names of an entry's stages that no stage set may remove.
  kept = v: traits: map (s: s.name) (filter (s: !s.removable) (entryOf v traits));

  # A merged stage set (`where` names the layer in messages) may not
  # remove a stage the target's entry keeps, or add one that only the
  # "split" entry has: such a stage needs the units' split setup (the
  # remap scope, the build ID).
  checkDebugStages =
    {
      triple,
      traits,
      debugInfo,
      where,
    }:
    set:
    let
      keep = kept debugInfo traits;
      splitOnly =
        if debugInfo == "split" || !(traits.debugStages ? split) then
          [ ]
        else
          lib.subtractLists (map (s: s.name) (entryOf debugInfo traits)) (kept "split" traits);
      removed = filter (n: !(stages.isLive (set.${n} or null))) keep;
      added = filter (n: stages.isLive (set.${n} or null)) splitOnly;
      fix = "debug splitting is decided per target, for every package of it: set `targets.\"${triple}\".debugInfo` (\"split\", \"keep\" or \"strip\")";
    in
    if removed != [ ] then
      throw "breakbulk: ${where} removes the `${lib.head removed}` stage on ${triple}, which `debugInfo = \"${debugInfo}\"` inserts; ${fix}"
    else if added != [ ] then
      throw "breakbulk: ${where} adds a `${lib.head added}` stage on ${triple}, whose `debugInfo` is \"${debugInfo}\": the target's units remap every source path and their links get no GNU build ID; ${fix}"
    else
      set;
  # The layers of a target's stage set: the stages `debugInfo` inserts,
  # then `targets.<triple>.stages`.
  targetLayers =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      targetStages ? { },
      ...
    }@args:
    [
      {
        set = debugStages (debugInfoOf args) traits;
        rank = -0.75;
      }
      {
        set = targetStages;
        rank = -0.5;
      }
    ];

  # The target's stage set, merged (`targetLayers`' arguments).
  targetStageSet =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      ...
    }@args:
    checkDebugStages {
      inherit triple traits;
      debugInfo = debugInfoOf args;
      where = "targets.\"${triple}\".stages";
    } (mergeSets stageSetEval (targetLayers args));

  # Whether the target's debug info is split off (targetLayers'
  # arguments).
  targetSplitsDebug = args: debugInfoOf args == "split";

  # The env of the target's units that its debug-info stages need
  # (targetLayers' arguments): splitDebug needs a GNU build ID, which
  # nixpkgs' linker wrapper adds, content-derived (`--build-id=sha1`),
  # when NIX_SET_BUILD_ID is set, as stdenv's separateDebugInfo does.
  targetUnitEnv = args: lib.optionalAttrs (targetSplitsDebug args) { NIX_SET_BUILD_ID = "1"; };

  # The scope of non-test units for a target (targetLayers' arguments):
  # when debug info is split off, every scope but `debuginfo`, which keeps
  # the real source paths the debug output is read against. `coverage`
  # too where nothing is instrumented: one scope for every variant, so
  # instrumenting (`-C instrument-coverage` in a variant's `rustflags`)
  # needs no scope of its own.
  shippedRemapScope = args: if targetSplitsDebug args then "macro,diagnostics,coverage" else null;

  mkProducts =
    {
      pkgs,
      inst,
      select ? null,
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      debugInfo ? null,
      targetStages ? { },
      targetChecks ? { },
      packageConfig ? _: { },
      ca ? featureGates.defaultCa,
      nixFeatures ? featureGates.standalone { inherit ca; },
      lockfile ? null,
      # Package name -> its `[package]` table, workspace fields resolved
      # (manifest.packageInfo's `package`), for `product.package`.
      cargoPackages ? { },
      keepSourcePaths ? false,
      sourcePaths ?
        attrValues inst.sources.workspace
        ++ lib.concatMap attrValues (attrValues (inst.sources.workspaceTargets or { }))
        ++ attrValues (inst.sources.predicted or { })
        ++ attrValues inst.sources.crates,
      # The toolchain's store paths: noSourceReferences fails when a
      # product's closure has one (field-trial gap 9).
      toolchainPaths ? inst.toolchainPaths or [ ],
    }:
    let
      setArgs = {
        inherit
          triple
          traits
          debugInfo
          targetStages
          ;
      };
      effectiveDebugInfo = debugInfoOf setArgs;
      # Checked once for the target, before any package's layer.
      targetChecked = builtins.seq (targetStageSet setArgs) true;
      byPkg = groupBy (r: r.breakbulkRoot.package) (
        filter (r: !r.breakbulkRoot.test) (attrValues inst.roots)
      );
      selected = if select == null then byPkg else filterAttrs (n: _: elem n select) byPkg;

      product =
        pkg: rs:
        let
          built = rs;
          # The `flags` outputs of the target-platform runs the product's
          # roots depend on, whose `directives.json` names the files their
          # scripts placed next to the binaries (`targetDirs`, #23), for the
          # `buildScriptFiles` stage and check: `{ rootInfo; }`, the roots'
          # `breakbulk-root.json` files, which list them
          # (`buildScriptFlags`) at build time.
          buildScriptFlags = {
            rootInfo = map (r: "${r.breakbulkRoot.wrapper}/breakbulk-root.json") built;
          };
          # Each root's file in `linked`, by name, to its root kind, for
          # `install`, from the predicted roots' kind and target. mkLinked
          # fails when two roots produce one name, so the map is
          # unambiguous.
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
          conf = packageConfig pkg;
          stageSet =
            assert targetChecked;
            checkDebugStages {
              inherit triple traits;
              debugInfo = effectiveDebugInfo;
              where = "packages.${pkg}.stages";
            } (mergeSets stageSetEval (targetLayers setArgs ++ [ { set = conf.stages or { }; } ]));
          checkSet = mergeSets checkSetEval [
            {
              set = defaultChecks { inherit keepSourcePaths; };
              rank = -0.75;
            }
            {
              set = targetChecks;
              rank = -0.5;
            }
            { set = conf.checks or { }; }
          ];
          p = stages.mkProduct {
            name = pkg;
            linked = mkLinked pkgs traits pkg built;
            stages = stageSet;
            leading = lib.attrNames (debugStages effectiveDebugInfo traits);
            checks = checkSet;
            target = { inherit triple traits; };
            inherit
              pkgs
              ca
              nixFeatures
              sourcePaths
              toolchainPaths
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
        in
        p // { inherit roots; };
    in
    mapAttrs product selected;
in
{
  inherit
    mkProducts
    definitionsOf
    defaultChecks
    targetStageSet
    debugInfoOf
    targetUnitEnv
    shippedRemapScope
    ;
}
