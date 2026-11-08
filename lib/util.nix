# Small helpers shared by the evaluation-time library. No pkgs needed.
{ lib }:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    hashString
    isAttrs
    isBool
    isFloat
    isInt
    isList
    isString
    length
    match
    replaceStrings
    split
    substring
    toJSON
    ;
in
rec {
  sha256 = hashString "sha256";

  # Percent-decoding as done by the `url` crate's `query_pairs` (form
  # urlencoded): `%XX` sequences and `+` as space. Only the code points that
  # can appear in git ref names and URLs are covered; anything else is left
  # encoded, which makes a mismatch visible instead of silent.
  percentDecode =
    let
      codes = {
        "%20" = " "; "%25" = "%"; "%21" = "!"; "%22" = "\""; "%23" = "#"; "%24" = "$";
        "%26" = "&"; "%27" = "'"; "%28" = "("; "%29" = ")"; "%2A" = "*";
        "%2B" = "+"; "%2C" = ","; "%2F" = "/"; "%3A" = ":"; "%3B" = ";";
        "%3C" = "<"; "%3D" = "="; "%3E" = ">"; "%3F" = "?"; "%40" = "@";
        "%5B" = "["; "%5C" = "\\"; "%5D" = "]"; "%5E" = "^"; "%60" = "`";
        "%7B" = "{"; "%7C" = "|"; "%7D" = "}"; "%7E" = "~";
      };
      lower = lib.mapAttrs' (k: v: lib.nameValuePair (lib.toLower k) v) codes;
      all = codes // lower;
    in
    s:
    # One left-to-right pass, so `%2541` decodes to `%41`, not `A`.
    (
      replaceStrings ([ "+" ] ++ attrNames all) ([ " " ] ++ map (k: all.${k}) (attrNames all)) s
    );

  # Split a string on a literal separator.
  splitOn = sep: s: filter isString (split (lib.escapeRegex sep) s);

  # Normalize a relative path string: drop "." and empty components, resolve
  # ".." against earlier components. Leading ".." that cannot be resolved are
  # kept. Returns "" for the current directory.
  normalizeRel =
    p:
    let
      parts = filter (c: c != "" && c != ".") (splitOn "/" p);
      step =
        acc: c:
        if c == ".." && acc != [ ] && lib.last acc != ".." then lib.init acc else acc ++ [ c ];
    in
    concatStringsSep "/" (lib.foldl' step [ ] parts);

  # Join relative path strings and normalize.
  joinRel = a: b: normalizeRel (if a == "" then b else if b == "" then a else "${a}/${b}");

  # `a` relative to `b`, both normalized relative paths from the same root.
  relativeTo =
    a: b:
    let
      as = filter (c: c != "") (splitOn "/" a);
      bs = filter (c: c != "") (splitOn "/" b);
      common =
        let
          go = i: if i < length as && i < length bs && builtins.elemAt as i == builtins.elemAt bs i then go (i + 1) else i;
        in
        go 0;
      ups = lib.genList (_: "..") (length bs - common);
      downs = lib.drop common as;
    in
    concatStringsSep "/" (ups ++ downs);

  # Whether relative path `p` is `dir` or below it (both normalized).
  isUnder =
    dir: p:
    let
      r = relativeTo p dir;
    in
    r != ".." && !(lib.hasPrefix "../" r);

  # Glob matching for one path component, as the `glob` crate does for
  # workspace `members`: `*`, `?`, `[...]` and `[!...]`.
  globComponentRegex =
    pat:
    let
      chars = lib.stringToCharacters pat;
      go =
        cs: inClass:
        if cs == [ ] then
          ""
        else
          let
            c = builtins.head cs;
            rest = builtins.tail cs;
          in
          if inClass then
            (if c == "]" then "]" else if c == "\\" then "\\\\" else c) + go rest (c != "]")
          else if c == "*" then
            "[^/]*" + go rest false
          else if c == "?" then
            "[^/]" + go rest false
          else if c == "[" then
            (if rest != [ ] && builtins.head rest == "!" then "[^" + go (builtins.tail rest) true else "[" + go rest true)
          else
            lib.escapeRegex c + go rest false;
    in
    go chars false;

  hasGlobChars = s: match ".*[][*?].*" s != null;

  # Expand a glob relative to `root` (a path). Returns normalized relative
  # strings of existing entries. Supports `*`, `?`, `[..]` per component and
  # `**` as "any number of directories".
  expandGlob =
    root: pattern:
    let
      comps = filter (c: c != "" && c != ".") (splitOn "/" pattern);
      entries = rel: let p = if rel == "" then root else root + "/${rel}"; in
        if builtins.pathExists p && builtins.readFileType p == "directory" then builtins.readDir p else { };
      isDirAt = rel: let p = if rel == "" then root else root + "/${rel}"; in
        builtins.pathExists p && builtins.readFileType p == "directory";
      go =
        rel: cs:
        if cs == [ ] then
          [ rel ]
        else
          let
            c = builtins.head cs;
            rest = builtins.tail cs;
            sub = n: joinRel rel n;
          in
          if c == "**" then
            # zero or more directories
            go rel rest
            ++ lib.concatMap (n: go (sub n) cs) (
              filter (n: (entries rel).${n} == "directory") (attrNames (entries rel))
            )
          else if c == ".." then
            go (joinRel rel "..") rest
          else if hasGlobChars c then
            let
              re = globComponentRegex c;
              # Cargo calls `glob::glob`, whose default MatchOptions have
              # require_literal_leading_dot = false: wildcards match dotfiles.
              names = filter (n: match re n != null) (attrNames (entries rel));
            in
            lib.concatMap (n: go (sub n) rest) (lib.sort (a: b: a < b) names)
          else
            let
              r = sub c;
            in
            if rest == [ ] then (if builtins.pathExists (if r == "" then root else root + "/${r}") then [ r ] else [ ])
            else if isDirAt r then go r rest
            else [ ];
    in
    lib.unique (go "" comps);

  # Serialize a value as produced by builtins.fromTOML back to TOML. Every
  # table below the top level is written inline, which keeps the writer tiny
  # and is valid TOML 1.0. Strings use JSON escapes, which are a subset of
  # TOML basic-string escapes.
  toTOML =
    attrs:
    let
      key = k: toJSON k;
      value =
        v:
        if isString v then
          toJSON v
        else if isBool v then
          (if v then "true" else "false")
        else if isInt v || isFloat v then
          toJSON v
        else if isList v then
          "[" + concatStringsSep ", " (map value v) + "]"
        else if isAttrs v then
          "{ " + concatStringsSep ", " (lib.mapAttrsToList (k: x: "${key k} = ${value x}") v) + " }"
        else
          throw "toTOML: unsupported value of type ${builtins.typeOf v}";
    in
    concatStringsSep "" (lib.mapAttrsToList (k: v: "${key k} = ${value v}\n") attrs);

  # A short, stable identifier for a string, for directory and source names.
  shortHash = s: substring 0 16 (sha256 s);

  # mkRepository's `root` as a path value. A path is kept. A flake's `self`
  # (an attribute set with `outPath`), or a string naming a store path
  # (`self.outPath`, `"${self}"`), becomes the path of that store
  # location: lib.fileset rejects string-like roots, and the path reads
  # the same tree in place (no extra copy; source views copy only their
  # filtered subsets). Anything else is an error.
  rootPath =
    root:
    let
      what = "breakbulk: mkRepository: `root` must be a path (`root = ./.;`), a flake's `self`, or a store path such as `lib.fileset.toSource { root = ./.; fileset = …; }`";
      s = if isAttrs root && root ? outPath then root.outPath else root;
      str = builtins.unsafeDiscardStringContext s;
      inStore = lib.hasPrefix "${builtins.storeDir}/" str;
    in
    if builtins.isPath root then
      root
    else if builtins.isPath s then
      s
    else if isString s && inStore then
      /. + str
    else if isString s then
      throw "${what}; got the string \"${str}\", which is not in ${builtins.storeDir}. Use a path value instead (`./.`, or `/. + \"/abs/dir\"` outside pure evaluation)."
    else if isAttrs root then
      throw "${what}; got an attribute set without `outPath` (attributes: ${concatStringsSep ", " (attrNames root)})"
    else
      throw "${what}; got a value of type ${builtins.typeOf root}";

  # Per-target environment variable names, one helper each:
  #
  # Cargo's `CARGO_TARGET_<TRIPLE>_<KEY>`: the triple uppercased, with `-`
  # and `.` as `_` (Cargo's `ConfigKey::as_env_key`; breakbulk-plan's
  # spec.rs `target_env_var` is the Rust side).
  cargoTargetEnvVar =
    triple: key: "CARGO_TARGET_${lib.toUpper (replaceStrings [ "-" "." ] [ "_" "_" ] triple)}_${key}";
  # The suffix of cc-rs's and bindgen's per-target variables
  # (`CC_<suffix>`, `CFLAGS_<suffix>`, `BINDGEN_EXTRA_CLANG_ARGS_<suffix>`):
  # the triple with `-` as `_`, case kept (cc-rs tries this spelling and
  # the one with dashes).
  tripleEnvSuffix = triple: replaceStrings [ "-" ] [ "_" ] triple;

  # Rust and Cargo releases: one parse. The features breakbulk turns on per
  # toolchain are its capabilities (lib/toolchain-facts.nix), decided there.
  #
  #   rustVersion.majorMinor "1.101.0-nightly (…)"   -> "1.101"
  #   rustVersion.atLeast "1.95" v                    -> bool
  rustVersion = rec {
    # "<major>.<minor>" of a version (`rustc.version`, `1.99.0`,
    # `1.101.0-nightly`); the channel suffix is ignored.
    majorMinor = v: lib.versions.majorMinor (lib.head (lib.splitString "-" v));
    # Whether release `v` is `gate` ("<major>.<minor>") or later.
    atLeast = gate: v: lib.versionAtLeast (majorMinor v) gate;
  };
}
