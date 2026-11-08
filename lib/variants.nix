# Variants ("Variants" in docs/design.md): helpers for
# `workspaces.<ws>.variants`, and the derivations mkRepository makes for
# variants that link nothing.
#
#   workspaces.main.variants =
#     { default = { }; }
#     // breakbulk.variants.featurePowerset {
#       features = [ "json" "tls" "cli" ];
#       mode = "check";          # any variant setting, applied to each
#       profile = "release";
#       maxSize = 2;             # optional: subsets of at most 2 features
#       exclude = [ [ "tls" "cli" ] ];   # optional: subsets to leave out
#       prefix = "features";     # variant names: features-none, features-json+tls, …
#     };
#
# gives one variant per subset of `features`, each with
# `noDefaultFeatures = true` (as `cargo hack --feature-powerset` does) and
# `features` set to the subset. Units identical between variants are
# shared, so the cost is the crates whose features differ. That is a
# workspace-wide matrix; cargo-hack's own is per package:
#
#   workspaces.main.variants =
#     { default = { }; }
#     // breakbulk.variants.packageFeaturePowerset {
#       inherit root;            # the repository root (a module's `root`)
#       path = ".";              # the workspace, relative to root
#       packages = null;         # null: every member; or a list of names
#       eachFeature = false;     # true: --each-feature; false: --feature-powerset
#       depth = null;            # --depth: at most this many features per set
#       excludeFeatures = [ ];   # --exclude-features
#       excludeNoDefaultFeatures = false;   # --exclude-no-default-features
#       excludeAllFeatures = false;         # --exclude-all-features
#       prefix = "hack";
#       mode = "check";          # any variant setting, applied to each
#       targets = [ "x86_64-unknown-linux-gnu" ];
#     };
#
# gives the variants `cargo hack <mode> --workspace --feature-powerset`
# runs, each its own `-p <pkg>` plan (`variants.<v>.packages`), following
# cargo-hack's `determine_kind` and `exec_on_package` (taiki-e/cargo-hack
# e2406853, src/main.rs, src/features.rs): per package, `--all-features`
# (left out when the package has no optional dependencies that are
# implicit features, and for --each-feature also when it has at most one
# feature), `--no-default-features`, and `--no-default-features
# --features <set>` for each feature alone (--each-feature) or each
# non-empty set of its `[features]` (--feature-powerset), leaving out sets
# in which one feature already enables another. A package with no features
# and no optional dependencies gets one plain run. Optional dependencies
# are not features in the sets (cargo-hack's default without
# --optional-deps). Names: `<prefix>-<pkg>`, `<prefix>-<pkg>.all-features`,
# `<prefix>-<pkg>.no-default-features`, `<prefix>-<pkg>.<f1>+<f2>`.
#
#   breakbulk.variants.unitsCheck { pkgs; name; units = [ … ]; }
#
# is a derivation that depends on every unit derivation given (all outputs),
# and lists them. mkRepository uses it for check and clippy variants:
# `target.<triple>.variants.<v>.check`, which builds every unit of both
# plans, so clippy's lints run on every workspace member.
{
  lib,
  util,
  manifest,
}:
let
  # All subsets of a list, in order, smallest first; each subset keeps the
  # list's order.
  subsets = l: lib.foldr (x: acc: acc ++ map (s: [ x ] ++ s) acc) [ [ ] ] l;

  # A store-name-safe spelling of a feature (`pkg/feat` → `pkg_feat`).
  safe = lib.replaceStrings [ "/" ":" " " ] [ "_" "_" "_" ];

  featurePowerset =
    {
      features,
      prefix ? "features",
      maxSize ? null,
      exclude ? [ ],
      ...
    }@args:
    let
      settings = removeAttrs args [
        "features"
        "prefix"
        "maxSize"
        "exclude"
      ];
      sorted = lib.sort (a: b: lib.length a < lib.length b || (lib.length a == lib.length b && a < b)) (
        subsets features
      );
      excluded = s: lib.any (e: lib.sort lib.lessThan e == lib.sort lib.lessThan s) exclude;
      keep = s: (maxSize == null || lib.length s <= maxSize) && !excluded s;
      nameOf = s: "${prefix}-${if s == [ ] then "none" else lib.concatMapStringsSep "+" safe s}";
    in
    lib.listToAttrs (
      map (
        s:
        lib.nameValuePair (nameOf s) (
          {
            noDefaultFeatures = true;
          }
          // settings
          // {
            features = s;
          }
        )
      ) (lib.filter keep sorted)
    );

  # One package's runs as cargo-hack makes them: a list of
  # { suffix; settings; } (see the file's header).
  packageRuns =
    {
      features,
      optionalDeps,
      eachFeature,
      depth,
      excludeFeatures,
      excludeNoDefaultFeatures,
      excludeAllFeatures,
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
      sets =
        if eachFeature then
          map (f: [ f ]) candidates
        else
          lib.filter (s: s != [ ] && (depth == null || lib.length s <= depth) && !redundant s) (
            subsets candidates
          );
      sorted = lib.sort (a: b: lib.length a < lib.length b || (lib.length a == lib.length b && a < b)) sets;
      skipAll =
        excludeAllFeatures
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
      }) sorted;

  packageFeaturePowerset =
    {
      root,
      path ? ".",
      packages ? null,
      eachFeature ? false,
      depth ? null,
      excludeFeatures ? [ ],
      excludeNoDefaultFeatures ? false,
      excludeAllFeatures ? false,
      prefix ? "hack",
      ...
    }@args:
    let
      settings = removeAttrs args [
        "root"
        "path"
        "packages"
        "eachFeature"
        "depth"
        "excludeFeatures"
        "excludeNoDefaultFeatures"
        "excludeAllFeatures"
        "prefix"
      ];
      rootPath = util.rootPath root;
      ws = manifest.workspace {
        root = rootPath;
        wsDir = util.normalizeRel path;
      };
      members = map (
        dir:
        let
          m = manifest.readManifest rootPath dir;
          # Optional dependencies not named as `dep:<name>` in a feature
          # are implicit features (cargo-hack `Features::new`).
          referenced = lib.concatMap (
            vs: lib.concatMap (v: lib.optional (lib.hasPrefix "dep:" v) (lib.removePrefix "dep:" v)) vs
          ) (lib.attrValues (m.features or { }));
          optional = lib.concatMap (
            t: lib.attrNames (lib.filterAttrs (_: d: builtins.isAttrs d && d.optional or false) t)
          ) (manifest.dependencyTables m);
        in
        {
          name = m.package.name;
          features = m.features or { };
          optionalDeps = lib.filter (d: !(lib.elem d referenced) && !((m.features or { }) ? ${d})) (
            lib.unique optional
          );
        }
      ) ws.members;
      known = map (p: p.name) members;
      unknown = lib.filter (p: !(lib.elem p known)) (if packages == null then [ ] else packages);
      selected = if packages == null then members else lib.filter (p: lib.elem p.name packages) members;
    in
    if unknown != [ ] then
      throw "breakbulk.variants.packageFeaturePowerset: ${lib.concatStringsSep ", " unknown} not among the workspace's members (${lib.concatStringsSep ", " known})"
    else
      lib.listToAttrs (
        lib.concatMap (
          p:
          map
            (
              r:
              lib.nameValuePair "${prefix}-${p.name}${r.suffix}" (
                settings
                // r.settings
                // {
                  packages = [ p.name ];
                }
              )
            )
            (packageRuns {
              inherit (p) features optionalDeps;
              inherit
                eachFeature
                depth
                excludeFeatures
                excludeNoDefaultFeatures
                excludeAllFeatures
                ;
            })
        ) selected
      );

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
    packageFeaturePowerset
    packageRuns
    unitsCheck
    subsets
    ;
}
