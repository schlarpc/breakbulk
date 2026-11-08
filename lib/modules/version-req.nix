# Cargo version requirements (`^1.2`, `~1.2.3`, `>=0.42, <0.50`, `1.*`,
# `=1.2.3`, `*`) matched against locked versions, for
# `packages.<name>.version`.
#
# Semantics follow the semver crate's `VersionReq::matches` (semver 1.0.28,
# src/eval.rs: `matches_req`, `matches_impl`, `pre_is_compatible`): every
# comparator must match, each operator expands with missing minor/patch as
# in `matches_exact`/`matches_greater`/`matches_less`/`matches_tilde`/
# `matches_caret`, and a pre-release version matches only when some
# comparator names the same major.minor.patch with a pre-release.
# Build metadata is ignored.
{ lib }:
let
  inherit (builtins)
    elemAt
    filter
    length
    match
    ;

  num = s: lib.toInt s;

  # "1.2.3-rc.1+meta" -> { major; minor; patch; pre }
  parseVersion =
    v:
    let
      m = match "([0-9]+)\\.([0-9]+)\\.([0-9]+)(-([^+]*))?(\\+.*)?" v;
    in
    if m == null then
      throw "breakbulk: `${v}` is not a semver version"
    else
      {
        major = num (elemAt m 0);
        minor = num (elemAt m 1);
        patch = num (elemAt m 2);
        pre = if elemAt m 4 == null then "" else elemAt m 4;
      };

  # Pre-release identifiers compare numerically when both are numeric,
  # numeric ones sort first, and a shorter list sorts first on a tie.
  cmpPre =
    a: b:
    if a == b then
      0
    else if a == "" then
      1
    else if b == "" then
      -1
    else
      let
        as = lib.splitString "." a;
        bs = lib.splitString "." b;
        isNum = s: match "[0-9]+" s != null;
        go =
          i:
          if i >= length as && i >= length bs then
            0
          else if i >= length as then
            -1
          else if i >= length bs then
            1
          else
            let
              x = elemAt as i;
              y = elemAt bs i;
              c =
                if isNum x && isNum y then
                  (if num x < num y then -1 else if num x > num y then 1 else 0)
                else if isNum x then
                  -1
                else if isNum y then
                  1
                else if x < y then
                  -1
                else if x > y then
                  1
                else
                  0;
            in
            if c != 0 then c else go (i + 1);
      in
      go 0;

  cmp =
    a: b:
    let
      c3 = lib.findFirst (c: c != 0) 0 (
        map (k: if a.${k} < b.${k} then -1 else if a.${k} > b.${k} then 1 else 0) [
          "major"
          "minor"
          "patch"
        ]
      );
    in
    if c3 != 0 then c3 else cmpPre a.pre b.pre;

  # One comparator: { op; major; minor (or null); patch (or null); pre }.
  parseComparator =
    s:
    let
      t = lib.trim s;
      m = match "(=|>=|<=|>|<|~|\\^)?[[:space:]]*v?([0-9]+|[*xX])(\\.([0-9]+|[*xX]))?(\\.([0-9]+|[*xX]))?(-([^+]*))?(\\+.*)?" t;
      part = i: if elemAt m i == null || lib.elem (elemAt m i) [ "*" "x" "X" ] then null else num (elemAt m i);
      wild = i: elemAt m i != null && lib.elem (elemAt m i) [ "*" "x" "X" ];
    in
    if t == "*" || t == "x" || t == "X" then
      { op = "*"; }
    else if m == null then
      throw "breakbulk: `${s}` is not a version requirement"
    else
      let
        op0 = if elemAt m 0 == null then "^" else elemAt m 0;
        anyWild = wild 1 || wild 3 || wild 5;
      in
      {
        # semver: a wildcard in a bare requirement makes it a wildcard
        # comparator, which matches like `=` with the missing parts.
        op = if anyWild && elemAt m 0 == null then "=" else op0;
        major = part 1;
        minor = part 3;
        patch = part 5;
        pre = if elemAt m 7 == null then "" else elemAt m 7;
      };

  matchesExact =
    c: v:
    v.major == c.major
    && (c.minor == null || v.minor == c.minor)
    && (c.patch == null || v.patch == c.patch)
    && v.pre == c.pre;

  matchesGreater =
    c: v:
    if v.major != c.major then
      v.major > c.major
    else if c.minor == null then
      false
    else if v.minor != c.minor then
      v.minor > c.minor
    else if c.patch == null then
      false
    else if v.patch != c.patch then
      v.patch > c.patch
    else
      cmpPre v.pre c.pre > 0;

  matchesLess =
    c: v:
    if v.major != c.major then
      v.major < c.major
    else if c.minor == null then
      false
    else if v.minor != c.minor then
      v.minor < c.minor
    else if c.patch == null then
      false
    else if v.patch != c.patch then
      v.patch < c.patch
    else
      cmpPre v.pre c.pre < 0;

  matchesTilde =
    c: v:
    v.major == c.major
    && (c.minor == null || v.minor == c.minor)
    && (
      if c.patch != null && v.patch != c.patch then v.patch > c.patch else cmpPre v.pre c.pre >= 0
    );

  matchesCaret =
    c: v:
    if v.major != c.major then
      false
    else if c.minor == null then
      true
    else if c.patch == null then
      (if c.major > 0 then v.minor >= c.minor else v.minor == c.minor)
    else if c.major > 0 then
      v.minor > c.minor || (v.minor == c.minor && (v.patch > c.patch || (v.patch == c.patch && cmpPre v.pre c.pre >= 0)))
    else if c.minor > 0 then
      v.minor == c.minor && (v.patch > c.patch || (v.patch == c.patch && cmpPre v.pre c.pre >= 0))
    else
      v.minor == c.minor && v.patch == c.patch && cmpPre v.pre c.pre >= 0;

  matchesComparator =
    c: v:
    if c.op == "*" then
      true
    else if c.op == "=" then
      matchesExact c v
    else if c.op == ">" then
      matchesGreater c v
    else if c.op == ">=" then
      matchesExact c v || matchesGreater c v
    else if c.op == "<" then
      matchesLess c v
    else if c.op == "<=" then
      matchesExact c v || matchesLess c v
    else if c.op == "~" then
      matchesTilde c v
    else
      matchesCaret c v;

  preIsCompatible =
    c: v:
    c.op != "*"
    && c.major == v.major
    && c.minor == v.minor
    && c.patch == v.patch
    && c.pre != "";
in
rec {
  inherit parseVersion cmp;

  parse = req: map parseComparator (filter (s: lib.trim s != "") (lib.splitString "," req));

  # Is `req` a version requirement `parse` takes? (`types.nix`'s
  # `versionReq` type.)
  isReq =
    req:
    let
      cs = filter (s: lib.trim s != "") (lib.splitString "," req);
    in
    cs != [ ] && lib.all (s: (builtins.tryEval (parseComparator s)).success) cs;

  # Does the locked `version` satisfy the requirement string `req`?
  matches =
    req: version:
    let
      cs = parse req;
      v = parseVersion version;
    in
    lib.all (c: matchesComparator c v) cs
    && (v.pre == "" || lib.any (c: preIsCompatible c v) cs);
}
