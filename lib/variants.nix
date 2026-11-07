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
# shared, so the cost is the crates whose features differ.
#
#   breakbulk.variants.unitsCheck { pkgs; name; units = [ … ]; }
#
# is a derivation that depends on every unit derivation given (all outputs),
# and lists them. mkRepository uses it for check and clippy variants:
# `target.<triple>.variants.<v>.check`, which builds every unit of both
# plans, so clippy's lints run on every workspace member.
{ lib }:
let
  # All subsets of a list, in order, smallest first; each subset keeps the
  # list's order.
  subsets =
    l:
    lib.foldr (
      x: acc:
      acc ++ map (s: [ x ] ++ s) acc
    ) [ [ ] ] l;

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
  inherit featurePowerset unitsCheck subsets;
}
