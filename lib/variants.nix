# Variants ("Variants" in docs/src/explanation/configuration.md): the
# feature-matrix generator for `workspaces.<ws>.variants`, and the
# derivations mkRepository makes for variants that link nothing.
#
#   workspaces.main.imports = [
#     (breakbulk.variants.featurePowerset {
#       scope = "package";       # or "workspace"
#       variant.mode = "check";  # a module for each generated variant
#     })
#   ];
#
# is a workspace module that defines one variant per feature set. Its
# arguments, one vocabulary for both scopes:
#
#   scope                     "package": cargo-hack's per-package matrix,
#                             `cargo hack <mode> --workspace
#                             --feature-powerset`, each set its own `-p
#                             <pkg>` plan. "workspace": one list of
#                             features combined for the whole workspace.
#   features                  "workspace" only, required: the features to
#                             combine (`pkg/feat` spellings included).
#                             "package" combines each package's own
#                             `[features]` (`workspaces.<ws>.members`).
#   packages                  "package": the packages that get runs (null:
#                             every member; a list, or `{ exclude = … }`).
#                             "workspace": each variant's `packages`.
#   eachFeature               each feature alone, not every combination
#                             (`--each-feature`).
#   depth                     at most this many features per set (`--depth`).
#   excludeFeatures           features in no set (`--exclude-features`).
#   excludeSets               sets to leave out, each a list of features.
#   excludeNoDefaultFeatures  no run without any features
#                             (`--exclude-no-default-features`; in the
#                             workspace scope, `<prefix>-none`).
#   excludeAllFeatures        "package" only: no `--all-features` run
#                             (`--exclude-all-features`).
#   prefix                    variant names start `<prefix>-` (default
#                             "hack" for "package", "features" for
#                             "workspace").
#   variant                   a module for each generated variant: any
#                             `variants.<v>` setting (`mode`, `profile`,
#                             `targets`, `checks`, more `features`, …).
#
# Generated variants have `checks = lib.mkDefault false`: their test runs
# stay out of repo.checks unless `variant` or another definition says
# otherwise. The generator defines only what a run needs, as plain
# definitions (`noDefaultFeatures = true`, `allFeatures = true`, its
# `features` and `packages`), so every other definition of a generated
# variant applies to it: `features` concatenate, `noDefaultFeatures = true`
# turns off the default features of the runs that keep them, and a
# definition that contradicts what a run needs is a conflict.
#
# Workspace scope: one variant per subset of `features`, each with
# `noDefaultFeatures = true` and `features` set to the subset, named
# `<prefix>-none`, `<prefix>-json+tls` (`pkg/feat` spelled `pkg_feat`).
# Units identical between variants are shared, so the cost is the crates
# whose features differ.
#
# Package scope follows cargo-hack's `determine_kind` and
# `exec_on_package` (taiki-e/cargo-hack 0.6.46, src/main.rs,
# src/features.rs, src/cli.rs): per package, `--all-features` (left out
# with excludeAllFeatures or any excludeFeatures, when the package has no
# optional dependencies that are implicit features, and for eachFeature
# also when it has at most one feature), `--no-default-features`, and
# `--no-default-features --features <set>` for each feature alone
# (eachFeature) or each non-empty set of its `[features]`, leaving out sets
# in which one feature already enables another. A package with no features
# and no optional dependencies gets one plain run. Optional dependencies
# are not features in the sets (cargo-hack's default without
# --optional-deps). Names: `<prefix>-<pkg>`, `<prefix>-<pkg>.all-features`,
# `<prefix>-<pkg>.no-default-features`, `<prefix>-<pkg>.<f1>+<f2>`. The
# `variantDefaults` apply as to any variant.
#
#   breakbulk.variants.unitsCheck { pkgs; name; units = [ … ]; }
#
# is a derivation that depends on every unit derivation given (all outputs),
# and lists them. mkRepository uses it for check and clippy variants:
# `target.<triple>.variants.<v>.check`, which builds every unit of both
# plans, so clippy's lints run on every workspace member.
{
  lib,
  manifest,
}:
let
  # All subsets of a list, in order, smallest first; each subset keeps the
  # list's order.
  subsets = l: lib.foldr (x: acc: acc ++ map (s: [ x ] ++ s) acc) [ [ ] ] l;

  # A store-name-safe spelling of a feature (`pkg/feat` → `pkg_feat`).
  safe = lib.replaceStrings [ "/" ":" " " ] [ "_" "_" "_" ];

  # Sets of features smallest first, then by name.
  bySize = lib.sort (a: b: lib.length a < lib.length b || (lib.length a == lib.length b && a < b));

  sameSet = a: b: lib.sort lib.lessThan a == lib.sort lib.lessThan b;

  # One package's runs as cargo-hack makes them: a list of
  # { suffix; settings; } (see the file's header).
  packageRuns =
    {
      features,
      optionalDeps,
      eachFeature ? false,
      depth ? null,
      excludeFeatures ? [ ],
      excludeSets ? [ ],
      excludeNoDefaultFeatures ? false,
      excludeAllFeatures ? false,
    }:
    let
      names = lib.attrNames features;
      candidates = lib.filter (f: !(lib.elem f excludeFeatures)) names;
      # Features each feature enables, transitively, within the package
      # (cargo-hack `feature_deps`; `dep:` entries are not features).
      enables =
        f:
        let
          go =
            seen: todo:
            if todo == [ ] then
              seen
            else
              let
                cur = lib.head todo;
                next = lib.filter (x: !(lib.hasPrefix "dep:" x) && x != f && !(lib.elem x seen)) (
                  features.${cur} or [ ]
                );
              in
              go (seen ++ next) (lib.tail todo ++ next);
        in
        go [ ] [ f ];
      redundant = s: lib.any (f: lib.any (g: lib.elem g s) (enables f)) s;
      sets = lib.filter (s: !(lib.any (sameSet s) excludeSets)) (
        if eachFeature then
          map (f: [ f ]) candidates
        else
          lib.filter (s: s != [ ] && (depth == null || lib.length s <= depth) && !redundant s) (
            subsets candidates
          )
      );
      # cargo-hack's cli.rs turns --exclude-all-features on with any
      # --exclude-features.
      skipAll =
        excludeAllFeatures
        || excludeFeatures != [ ]
        || (if eachFeature then optionalDeps == [ ] && lib.length names <= 1 else optionalDeps == [ ]);
    in
    if names == [ ] && optionalDeps == [ ] then
      [
        {
          suffix = "";
          settings = { };
        }
      ]
    else
      lib.optional (!skipAll) {
        suffix = ".all-features";
        settings.allFeatures = true;
      }
      ++ lib.optional (!excludeNoDefaultFeatures) {
        suffix = ".no-default-features";
        settings.noDefaultFeatures = true;
      }
      ++ map (s: {
        suffix = ".${lib.concatStringsSep "+" s}";
        settings = {
          noDefaultFeatures = true;
          features = s;
        };
      }) (bySize sets);

  # The workspace scope's runs: a list of { suffix; settings; }.
  workspaceRuns =
    {
      features,
      packages,
      eachFeature,
      depth,
      excludeFeatures,
      excludeSets,
      excludeNoDefaultFeatures,
    }:
    let
      candidates = lib.filter (f: !(lib.elem f excludeFeatures)) features;
      sets = if eachFeature then [ [ ] ] ++ map (f: [ f ]) candidates else subsets candidates;
      keep =
        s:
        (depth == null || lib.length s <= depth)
        && !(lib.any (sameSet s) excludeSets)
        && !(excludeNoDefaultFeatures && s == [ ]);
    in
    map (s: {
      suffix = "-${if s == [ ] then "none" else lib.concatMapStringsSep "+" safe s}";
      settings = {
        noDefaultFeatures = true;
        features = s;
      }
      // lib.optionalAttrs (packages != null) { inherit packages; };
    }) (bySize (lib.filter keep sets));

  featurePowerset =
    {
      scope,
      features ? null,
      packages ? null,
      eachFeature ? false,
      depth ? null,
      excludeFeatures ? [ ],
      excludeSets ? [ ],
      excludeNoDefaultFeatures ? false,
      excludeAllFeatures ? false,
      prefix ? if scope == "package" then "hack" else "features",
      variant ? { },
    }:
    let
      fail = msg: throw "breakbulk.variants.featurePowerset: ${msg}";
      checked =
        if scope != "package" && scope != "workspace" then
          fail "`scope` is \"package\" or \"workspace\", not ${builtins.toJSON scope}"
        else if scope == "workspace" && features == null then
          fail "the workspace scope needs `features`, the features to combine"
        else if scope == "package" && features != null then
          fail "the package scope combines each package's own features; for features in every run, set `variant.features`"
        else if scope == "workspace" && excludeAllFeatures then
          fail "the workspace scope has no --all-features run to exclude"
        else if eachFeature && depth != null then
          fail "`depth` limits combinations, and `eachFeature` makes none"
        else
          true;
    in
    assert checked;
    { config, ... }:
    let
      known = lib.attrNames config.members;
      selected =
        if packages == null then
          known
        else if builtins.isList packages then
          let
            unknown = lib.filter (p: !(config.members ? ${p})) packages;
          in
          if unknown != [ ] then
            fail "${lib.concatStringsSep ", " unknown} not among the workspace's members (${lib.concatStringsSep ", " known})"
          else
            packages
        else
          let
            r = manifest.excludeMembers known packages.exclude;
          in
          if r.errors != [ ] then
            fail "packages.exclude: ${lib.concatStringsSep "; " r.errors}"
          else
            r.selected;
      # Optional dependencies not named as `dep:<name>` in a feature are
      # implicit features (cargo-hack `Features::new`).
      implicit =
        m:
        let
          referenced = lib.concatMap (
            vs: lib.concatMap (v: lib.optional (lib.hasPrefix "dep:" v) (lib.removePrefix "dep:" v)) vs
          ) (lib.attrValues m.features);
        in
        lib.filter (d: !(lib.elem d referenced) && !(m.features ? ${d})) m.optionalDependencies;
      runs =
        if scope == "workspace" then
          map (r: r // { name = "${prefix}${r.suffix}"; }) (workspaceRuns {
            inherit
              features
              packages
              eachFeature
              depth
              excludeFeatures
              excludeSets
              excludeNoDefaultFeatures
              ;
          })
        else
          lib.concatMap (
            p:
            map
              (r: {
                name = "${prefix}-${p}${r.suffix}";
                settings = r.settings // {
                  packages = [ p ];
                };
              })
              (packageRuns {
                inherit (config.members.${p}) features;
                optionalDeps = implicit config.members.${p};
                inherit
                  eachFeature
                  depth
                  excludeFeatures
                  excludeSets
                  excludeNoDefaultFeatures
                  excludeAllFeatures
                  ;
              })
          ) selected;
    in
    {
      _file = "breakbulk.variants.featurePowerset";
      config.variants = lib.listToAttrs (
        map (
          r:
          # A function, so that the definition can import `variant`: an
          # attribute set there is only settings.
          lib.nameValuePair r.name (_: {
            imports = [ variant ];
            config = r.settings // {
              # Generated variants' test runs stay out of repo.checks
              # unless asked for.
              checks = lib.mkDefault false;
            };
          })
        ) runs
      );
    };

  unitsCheck =
    {
      pkgs,
      name,
      units,
    }:
    let
      outs = lib.concatMap (u: map (o: u.${o}) (u.outputs or [ "out" ])) units;
    in
    pkgs.runCommand "${name}-check"
      {
        units = outs;
        __structuredAttrs = true;
      }
      ''
        mkdir -p $out
        printf '%s\n' "''${units[@]}" | sort > $out/units
        echo "${toString (lib.length units)} units built"
      '';
in
{
  inherit
    featurePowerset
    packageRuns
    unitsCheck
    subsets
    ;
}
