# Check groups ("Check groups" in docs/src/reference/outputs.md): one
# aggregate derivation per proper prefix of a check name, `all`, and the
# user's `checkGroups`. Building a group builds the checks it holds, as
# one installable: listing many checks by name costs one flake evaluation
# each when the evaluation cache is off.
#
#   checkGroups.matches "*/fmt" "main/fmt"               -> true
#   checkGroups.groups { pkgs; checks; user; }           -> { <group> = drv; }
#
# Patterns are over `/`-separated segments: `*`, `?` and `[...]` within
# one segment (util.globComponentRegex), `**` for any number of segments.
{ lib, util }:
let
  inherit (lib)
    splitString
    concatStringsSep
    filterAttrs
    attrNames
    ;

  segmentsMatch =
    pats: names:
    if pats == [ ] then
      names == [ ]
    else
      let
        p = builtins.head pats;
        rest = builtins.tail pats;
      in
      if p == "**" then
        segmentsMatch rest names || (names != [ ] && segmentsMatch pats (builtins.tail names))
      else
        names != [ ]
        && builtins.match (util.globComponentRegex p) (builtins.head names) != null
        && segmentsMatch rest (builtins.tail names);

  matches = pattern: name: segmentsMatch (splitString "/" pattern) (splitString "/" name);

  # "a/b/c" -> [ "a" "a/b" ]
  properPrefixes =
    name:
    let
      s = splitString "/" name;
    in
    map (n: concatStringsSep "/" (lib.take n s)) (lib.range 1 (lib.length s - 1));

  storeName = name: "checks-" + lib.replaceStrings [ "/" ] [ "-" ] name;

  # `breakbulkCheckGroup` tells a group from a leaf check.
  aggregate =
    pkgs: name: entries:
    pkgs.linkFarm (storeName name) entries // { breakbulkCheckGroup = true; };

  groups =
    {
      pkgs,
      # The leaf checks, by name.
      checks,
      # checkGroups: name -> list of patterns (strings) and derivations.
      user ? { },
    }:
    let
      leafNames = attrNames checks;
      prefixNames = lib.unique (lib.concatMap properPrefixes leafNames);
      builtIn = prefixNames ++ [ "all" ];
      clash = lib.filter (n: checks ? ${n}) builtIn;
      userClash = lib.filter (n: lib.elem n builtIn || checks ? ${n}) (attrNames user);

      under = p: filterAttrs (n: _: lib.hasPrefix "${p}/" n) checks;

      userGroup =
        gName: items:
        let
          patterns = lib.filter builtins.isString items;
          drvs = lib.filter (x: !builtins.isString x) items;
          selected = map (
            pat:
            let
              m = filterAttrs (n: _: matches pat n) checks;
            in
            if m == { } then
              throw "breakbulk: checkGroups.${gName}: the pattern `${pat}` matches no check; the checks are ${concatStringsSep ", " leafNames}"
            else
              m
          ) patterns;
        in
        aggregate pkgs gName (
          lib.foldl' (a: b: a // b) { } selected
          // lib.listToAttrs (lib.imap0 (i: d: lib.nameValuePair "derivations/${toString i}-${d.name or "item"}" d) drvs)
        );
    in
    if clash != [ ] then
      throw "breakbulk: the check names ${concatStringsSep ", " clash} are also group names (a prefix of another check, or `all`); rename the workspace or check"
    else if userClash != [ ] then
      throw "breakbulk: checkGroups ${concatStringsSep ", " userClash}: the name is already a check, a group of every check under that prefix, or `all`; choose another"
    else
      lib.genAttrs prefixNames (p: aggregate pkgs p (under p))
      // {
        all = aggregate pkgs "all" checks;
      }
      // lib.mapAttrs userGroup user;
in
{
  inherit matches properPrefixes groups;
}
