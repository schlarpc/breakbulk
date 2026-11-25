# Small helpers shared by the evaluation-time library. No pkgs needed.
{ lib }:
let
  featureGates = import ./nix-features.nix { inherit lib; };
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

  # The module arguments breakbulk passes, in some evaluation, by name:
  # what each is.
  moduleArgs = {
    pkgs = "the package set given to mkRepository";
    root = "the repository root";
    repo = "the mkRepository result";
    breakbulk = "the library";
    breakbulkPresets = "the presets, for the target spec's default preset";
    projectBuildTarget = "the project's `build.target`";
    targetsDefaultTarget = "the default of `targets.<triple>.defaultTarget`";
    toolchain = "a target spec's workspace toolchain";
    workspace = "a target spec's workspace";
    name = "a target spec's triple";
    package = "package settings' lockfile entry";
  };

  # `specialArgs` given to `what`, once none has the name of one of
  # breakbulk's module arguments `names`. Not letting them win: a
  # module of breakbulk's own that reads the argument would then fail
  # far from the cause (a preset reading `toolchain.facts`).
  checkSpecialArgs =
    {
      what,
      names,
      specialArgs,
    }:
    let
      clash = filter (n: specialArgs ? ${n}) names;
    in
    if clash == [ ] then
      specialArgs
    else
      throw "breakbulk: ${what}: ${
        concatStringsSep "; " (
          map (
            n: "specialArgs.${n} has the name of breakbulk's module argument `${n}` (${moduleArgs.${n}})"
          ) clash
        )
      }. breakbulk passes these itself; give yours another name.";

  # Percent-decoding as done by the `url` crate's `query_pairs` (form
  # urlencoded): `%XX` sequences and `+` as space. Only the code points that
  # can appear in git ref names and URLs are covered; anything else is left
  # encoded, which makes a mismatch visible instead of silent.
  percentDecode =
    let
      codes = {
        "%20" = " ";
        "%25" = "%";
        "%21" = "!";
        "%22" = "\"";
        "%23" = "#";
        "%24" = "$";
        "%26" = "&";
        "%27" = "'";
        "%28" = "(";
        "%29" = ")";
        "%2A" = "*";
        "%2B" = "+";
        "%2C" = ",";
        "%2F" = "/";
        "%3A" = ":";
        "%3B" = ";";
        "%3C" = "<";
        "%3D" = "=";
        "%3E" = ">";
        "%3F" = "?";
        "%40" = "@";
        "%5B" = "[";
        "%5C" = "\\";
        "%5D" = "]";
        "%5E" = "^";
        "%60" = "`";
        "%7B" = "{";
        "%7C" = "|";
        "%7D" = "}";
        "%7E" = "~";
      };
      lower = lib.mapAttrs' (k: v: lib.nameValuePair (lib.toLower k) v) codes;
      all = codes // lower;
    in
    s:
    # One left-to-right pass, so `%2541` decodes to `%41`, not `A`.
    (replaceStrings ([ "+" ] ++ attrNames all) ([ " " ] ++ map (k: all.${k}) (attrNames all)) s);

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
        acc: c: if c == ".." && acc != [ ] && lib.last acc != ".." then lib.init acc else acc ++ [ c ];
    in
    concatStringsSep "/" (lib.foldl' step [ ] parts);

  # Join relative path strings and normalize.
  joinRel =
    a: b:
    normalizeRel (
      if a == "" then
        b
      else if b == "" then
        a
      else
        "${a}/${b}"
    );

  # `a` relative to `b`, both normalized relative paths from the same root.
  relativeTo =
    a: b:
    let
      as = filter (c: c != "") (splitOn "/" a);
      bs = filter (c: c != "") (splitOn "/" b);
      common =
        let
          go =
            i:
            if i < length as && i < length bs && builtins.elemAt as i == builtins.elemAt bs i then
              go (i + 1)
            else
              i;
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
            (
              if c == "]" then
                "]"
              else if c == "\\" then
                "\\\\"
              else
                c
            )
            + go rest (c != "]")
          else if c == "*" then
            "[^/]*" + go rest false
          else if c == "?" then
            "[^/]" + go rest false
          else if c == "[" then
            (
              if rest != [ ] && builtins.head rest == "!" then
                "[^" + go (builtins.tail rest) true
              else
                "[" + go rest true
            )
          else
            lib.escapeRegex c + go rest false;
    in
    go chars false;

  hasGlobChars = s: match ".*[][*?].*" s != null;

  # A package pattern of `cargo … -p` and `--exclude` (an entry with `*`,
  # `?`, `[` or `]`), parsed and matched against package names as the
  # `glob` crate's `Pattern::new` and `Pattern::matches` do (glob 0.3.3,
  # default options: case-sensitive). `{ error = null; matches = name:
  # bool; }`, or `error` the reason the pattern is invalid. Package names
  # hold no `/`, so a `**` (valid only as a whole path component) matches
  # either nothing or the rest of the name.
  packagePattern =
    pat:
    let
      cs = lib.stringToCharacters pat;
      n = length cs;
      at = i: builtins.elemAt cs i;
      closeFrom =
        i:
        if i >= n then
          null
        else if at i == "]" then
          i
        else
          closeFrom (i + 1);
      # The character specifiers in [from, to): `a-z` ranges and single
      # characters.
      specs =
        from: to:
        if from >= to then
          [ ]
        else if from + 3 <= to && at (from + 1) == "-" then
          [
            {
              lo = at from;
              hi = at (from + 2);
            }
          ]
          ++ specs (from + 3) to
        else
          [
            {
              lo = at from;
              hi = at from;
            }
          ]
          ++ specs (from + 1) to;
      stars = i: if i < n && at i == "*" then 1 + stars (i + 1) else 0;
      fail = pos: msg: {
        error = "near position ${toString pos}: ${msg}";
        tokens = [ ];
      };
      recursive = "recursive wildcards must form a single path component";
      parse =
        i: toks:
        if i >= n then
          {
            error = null;
            tokens = toks;
          }
        else
          let
            c = at i;
          in
          if c == "?" then
            parse (i + 1) (toks ++ [ { t = "one"; } ])
          else if c == "*" then
            let
              count = stars i;
              j = i + count;
            in
            if count > 2 then
              fail (i + 2) "wildcards are either regular `*` or recursive `**`"
            else if count == 1 then
              parse j (toks ++ [ { t = "seq"; } ])
            else if i != 0 && at (i - 1) != "/" then
              fail (i - 1) recursive
            else if j < n && at j == "/" then
              parse (j + 1) (toks ++ [ { t = "rec"; } ])
            else if j == n then
              parse j (toks ++ [ { t = "rec"; } ])
            else
              fail j recursive
          else if c == "[" then
            let
              negated = i + 4 <= n && at (i + 1) == "!" && closeFrom (i + 3) != null;
              plain = i + 3 <= n && at (i + 1) != "!" && closeFrom (i + 2) != null;
            in
            if negated then
              let
                k = closeFrom (i + 3);
              in
              parse (k + 1) (
                toks
                ++ [
                  {
                    t = "except";
                    specs = specs (i + 2) k;
                  }
                ]
              )
            else if plain then
              let
                k = closeFrom (i + 2);
              in
              parse (k + 1) (
                toks
                ++ [
                  {
                    t = "within";
                    specs = specs (i + 1) k;
                  }
                ]
              )
            else
              fail i "invalid range pattern"
          else
            parse (i + 1) (
              toks
              ++ [
                {
                  t = "char";
                  inherit c;
                }
              ]
            );
      parsed = parse 0 [ ];
      toks = parsed.tokens;
      nt = length toks;
      inSpecs = ss: c: lib.any (s: c >= s.lo && c <= s.hi) ss;
      one =
        tok: c:
        if tok.t == "one" then
          true
        else if tok.t == "within" then
          inSpecs tok.specs c
        else if tok.t == "except" then
          !(inSpecs tok.specs c)
        else
          tok.c == c;
      matches =
        name:
        let
          ns = lib.stringToCharacters name;
          m = length ns;
          go =
            ti: ni:
            if ti == nt then
              ni == m
            else
              let
                tok = builtins.elemAt toks ti;
              in
              if tok.t == "seq" then
                lib.any (k: go (ti + 1) k) (lib.range ni m)
              else if tok.t == "rec" then
                go (ti + 1) ni || go (ti + 1) m
              else
                ni < m && one tok (builtins.elemAt ns ni) && go (ti + 1) (ni + 1);
        in
        parsed.error == null && go 0 0;
    in
    {
      inherit (parsed) error;
      inherit matches;
    };

  # Expand a glob relative to `root` (a path). Returns normalized relative
  # strings of existing entries. Supports `*`, `?`, `[..]` per component and
  # `**` as "any number of directories".
  expandGlob =
    root: pattern:
    let
      comps = filter (c: c != "" && c != ".") (splitOn "/" pattern);
      entries =
        rel:
        let
          p = if rel == "" then root else root + "/${rel}";
        in
        if builtins.pathExists p && builtins.readFileType p == "directory" then builtins.readDir p else { };
      isDirAt =
        rel:
        let
          p = if rel == "" then root else root + "/${rel}";
        in
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
            if rest == [ ] then
              (if builtins.pathExists (if r == "" then root else root + "/${r}") then [ r ] else [ ])
            else if isDirAt r then
              go r rest
            else
              [ ];
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

  # The store paths a string names (`/nix/store/<hash>-<name>`, up to the
  # first `/`, space, `=`, `:`, `;` or `"`), each with the string's
  # context: the inputs of what passes the string on without its context
  # (the planner's spec and `cargoConfig` files).
  # Lazy-tree paths in the string are made real first (`devirtualize`), so
  # the paths match the spec's and config's text.
  storePathsIn =
    s0:
    let
      s = devirtualize s0;
    in
    lib.concatMap (p: if isList p then [ (lib.addContextFrom s (lib.head p)) ] else [ ]) (
      split "(${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-[^/ =:;\"]+)" s
    );

  # A string with every lazy-tree path in it replaced by its real store
  # path, and its context to match. With `lazy-trees = true` (Determinate
  # Nix), a flake input or a `fetchGit`/`fetchTree` result interpolated into
  # a string (`"${inputs.foo}/lib"`) names a virtual store path: Nix
  # replaces it with the real path only where the context reaches a
  # derivation, so the text without its context names nothing and changes
  # with every evaluation. Other values pass unchanged.
  #
  # No builtin returns the real path of a virtual one;
  # `nixFeatures.namesVirtualPaths` finds them. A store path in the context
  # of `substring 0 0 s` plus its own text tests one entry.
  # `builtins.path` then copies the tree under the same name, as Nix's own
  # replacement does, which gives the same real path.
  devirtualize = s: (devirtualized s).withContext;

  # The text of `devirtualize s`, without context: for every place that
  # writes a value without its context (files that planning or
  # instantiation reads, values.json, check patterns), so that a lazy-tree
  # path is written as the real path.
  devirtualizeAndDiscard = s: (devirtualized s).text;

  devirtualized =
    s:
    let
      ctx = builtins.getContext s;
      text = builtins.unsafeDiscardStringContext s;
      differs = featureGates.namesVirtualPaths;
      paths = filter (p: ctx.${p}.path or false) (attrNames ctx);
      noContext = substring 0 0 s;
      virtual = filter (p: differs (noContext + p)) paths;
      real = map (
        p:
        "${builtins.path {
          path = /. + p;
          name = substring 33 (-1) (baseNameOf p);
        }}"
      ) virtual;
      kept = builtins.removeAttrs ctx virtual;
      newText = replaceStrings virtual (map builtins.unsafeDiscardStringContext real) text;
    in
    if !isString s || paths == [ ] || !differs (noContext + concatStringsSep " " paths) then
      {
        withContext = s;
        text = if isString s then text else s;
      }
    else
      {
        withContext = builtins.appendContext newText kept + lib.concatMapStrings (substring 0 0) real;
        text = newText;
      };

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
  #   rustVersion.isNightly v                         -> bool
  rustVersion = rec {
    # "<major>.<minor>" of a version (`rustc.version`, `1.99.0`,
    # `1.101.0-nightly`); the channel suffix is ignored.
    majorMinor = v: lib.versions.majorMinor (lib.head (lib.splitString "-" v));
    # Whether release `v` is `gate` ("<major>.<minor>") or later.
    atLeast = gate: v: lib.versionAtLeast (majorMinor v) gate;
    # A nightly release, or a compiler built from source (`-dev`), which
    # enables the same unstable defaults.
    isNightly = v: lib.hasInfix "-nightly" v || lib.hasInfix "-dev" v;
  };

  # Shell lines (bash) defining `__bb_run COMMAND…`, for a script that must
  # clean up after a command and so cannot `exec` it: it runs the command
  # as a child, passes INT and TERM on to it, waits for it and returns its
  # status. Run in the foreground, the command would get no signal sent to
  # the script alone (`kill`, a test harness's timeout): bash runs a trap
  # only once the foreground child has exited. Run with a plain `&`, it
  # would ignore INT and QUIT and read /dev/null (POSIX, for asynchronous
  # commands without job control), so `env --default-signal` restores the
  # signals and `<&0` keeps the script's input. `env` is coreutils'
  # (8.31 or later).
  forwardSignalsScript = env: ''
    __bb_run() {
      ${env} --default-signal=INT,QUIT "$@" <&0 &
      __bb_child=$!
      trap '__bb_sig=1; kill -INT "$__bb_child" 2>/dev/null || :' INT
      trap '__bb_sig=1; kill -TERM "$__bb_child" 2>/dev/null || :' TERM
      while :; do
        __bb_sig=0
        __bb_status=0
        # A trapped signal ends `wait` early, with the child still running.
        wait "$__bb_child" || __bb_status=$?
        [ "$__bb_sig" = 1 ] || break
      done
      trap - INT TERM
      return "$__bb_status"
    }
  '';
}
