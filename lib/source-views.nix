# Source views: a workspace package's source is a lib.fileset view of the
# repository root, so relative paths that leave the crate directory
# (`../../wit`, `../shared/assets`) resolve unchanged.
#
# Which files a view holds is a pipeline of named steps per package (its
# `sources` entries, built-in ones first: `steps` has their
# constructors), run once per unit descriptor:
#
#   { unit = "compile" | "build-script-run" | "doctest" | "test-run";
#     test; cargoTarget; root; packageDir; workspaceDir; targets;
#     memberDirs; }
#
# Each step gets the descriptor and `default`, the previous step's result,
# and returns a file set. A unit's view is then
# overlay(predict(pipeline(unit))): source prediction narrows a compile or
# build-script run to the files it reads, out of the package's widest
# view, and the `sourceOverlay` entries go on top.
{
  lib,
  util,
  manifest,
}:
let
  inherit (builtins)
    attrNames
    filter
    isFunction
    isPath
    isString
    readDir
    typeOf
    ;
  fs = lib.fileset;

  # An argument every step gets, so that a function without `...` fails on
  # its first call, not when breakbulk adds an argument. Nix's error names
  # the unexpected argument, so its name is the message.
  sentinel = "breakbulk: add ... to this function's arguments, as in { default, unit, ... }";

  # The built-in entries, in their order.
  builtinNames = [
    "package"
    "extraSources"
    "sourceScope"
    "testsDir"
    "targetRoots"
    "runFiles"
  ];
in
rec {
  inherit sentinel builtinNames;

  # A repository path from a path value or a string relative to the
  # package directory `pkgDir` (relative to the root).
  pathOf =
    root: pkgDir: what: x:
    if isPath x then
      x
    else if isString x then
      manifest.at root (util.joinRel pkgDir x)
    else
      throw "breakbulk: ${what} entries must be paths or strings relative to the package directory";

  # `x` (a path or a string relative to `pkgDir`) relative to the root,
  # or null for a path outside it.
  relOf =
    root: pkgDir: x:
    if isPath x then
      (if lib.path.hasPrefix root x then util.normalizeRel (lib.path.removePrefix root x) else null)
    else
      util.joinRel pkgDir x;

  # The entries at the top level of `dir` (relative to the root) that no
  # view holds, relative to the root: `target/`, `.git`, and the symlinks
  # `nix build` writes (`result`, `result-<output>`). By name and type,
  # not by prefix, so `results/` or `result.json` stay.
  junkPaths =
    { root, dir }:
    let
      entries = readDir (manifest.at root dir);
      junk =
        n:
        n == "target"
        || n == ".git"
        || entries.${n} == "symlink" && (n == "result" || lib.hasPrefix "result-" n);
    in
    map (util.joinRel dir) (filter junk (attrNames entries));

  # The package directory, minus its `junkPaths`, and minus the
  # directories of other workspace members nested inside it (`memberDirs`,
  # relative to the root). Other nested Cargo.toml files (test fixtures,
  # examples of generated projects) stay, because the package may read
  # them.
  packageFileset =
    {
      root,
      pkgDir,
      memberDirs ? [ ],
    }:
    let
      at = manifest.at root;
      junk = junkPaths {
        inherit root;
        dir = pkgDir;
      };
      nested = filter (d: d != pkgDir && util.isUnder pkgDir d) memberDirs;
    in
    fs.difference (at pkgDir) (fs.unions (map at (junk ++ nested)));

  # The `sourceScope` entries inside the package, relative to the root:
  # the ones its non-test units do not see. Entries outside the package
  # only widen its test views.
  scopeInside =
    {
      root,
      pkgDir,
      sourceScope ? [ ],
    }:
    filter (r: r != null && util.isUnder pkgDir r) (map (relOf root pkgDir) sourceScope);

  # The package's `tests/` directory relative to the root, when it
  # exists, else null. Cargo builds it only as integration tests.
  testsDirOf =
    { root, pkgDir }:
    if (readDir (manifest.at root pkgDir)).tests or null == "directory" then
      util.joinRel pkgDir "tests"
    else
      null;

  # A target's own root, relative to the package directory: its crate
  # root file, or the directory of a `<dir>/main.rs` root outside the
  # conventional directories (`tests/it/main.rs`: `tests/it`), which holds
  # its modules.
  targetRoot =
    t:
    let
      dir = util.normalizeRel (builtins.dirOf t.path);
    in
    if
      baseNameOf t.path == "main.rs"
      && !lib.elem dir [
        ""
        "src"
        "src/bin"
        "tests"
        "benches"
        "examples"
      ]
    then
      dir
    else
      t.path;

  # The paths of the package (relative to the package directory) that the
  # view of `cargoTarget`'s compiles leaves out: the roots of the
  # package's other bins, examples, tests and benches, and for a library,
  # bin or build script the whole `examples/` and `benches/` directories.
  # Never a path that holds the target's own root, the library's or a
  # build script's, and never one inside the target's own root directory.
  targetExcluded =
    {
      root,
      pkgDir,
      targets,
      cargoTarget,
    }:
    let
      own = targetRoot cargoTarget;
      isOwn = t: t.kind == cargoTarget.kind && t.name == cargoTarget.name;
      roots = map targetRoot (
        filter (
          t:
          lib.elem t.kind [
            "bin"
            "example"
            "test"
            "bench"
          ]
          && !isOwn t
        ) targets
      );
      dirs =
        lib.optionals
          (lib.elem cargoTarget.kind [
            "lib"
            "bin"
            "custom-build"
          ])
          (
            filter (d: (readDir (manifest.at root pkgDir)).${d} or null == "directory") [
              "examples"
              "benches"
            ]
          );
      protected = [
        cargoTarget.path
      ]
      ++ map (t: t.path) (filter (t: t.kind == "lib" || t.kind == "custom-build") targets);
      keep =
        e:
        e != ""
        && e != ".."
        && !lib.hasPrefix "../" e
        && !lib.any (p: util.isUnder e p) protected
        && !(own != cargoTarget.path && util.isUnder own e);
    in
    lib.unique (filter keep (map util.normalizeRel (roots ++ dirs)));

  # The constructors of the built-in steps (`breakbulk.lib.sourceSteps`).
  # Each returns a step: a function of a descriptor and `default` to
  # `{ files; removed; }`, the file set and the paths (relative to the
  # root) it left out, for hints.
  steps = {
    # The package directory, minus junk and nested members, plus
    # `extraFiles` (relative to the root).
    package =
      {
        extraFiles ? [ ],
      }:
      {
        default,
        root,
        packageDir,
        memberDirs,
        ...
      }:
      {
        files = fs.unions (
          [
            default
            (packageFileset {
              inherit root memberDirs;
              pkgDir = packageDir;
            })
          ]
          ++ map (manifest.at root) extraFiles
        );
        removed =
          junkPaths {
            inherit root;
            dir = packageDir;
          }
          ++ filter (d: d != packageDir && util.isUnder packageDir d) memberDirs;
      };

    # `paths` (paths, or strings relative to the package directory), for
    # every unit.
    add =
      paths:
      {
        default,
        root,
        packageDir,
        ...
      }:
      {
        files = fs.unions ([ default ] ++ map (pathOf root packageDir "extraSources") paths);
        removed = [ ];
      };

    # `paths` for test units only: added to their views, and the ones
    # inside the package taken out of every other view.
    testScope =
      paths:
      {
        default,
        test,
        root,
        packageDir,
        ...
      }:
      let
        inside = scopeInside {
          inherit root;
          pkgDir = packageDir;
          sourceScope = paths;
        };
      in
      if test then
        {
          files = fs.unions ([ default ] ++ map (pathOf root packageDir "test.sourceScope") paths);
          removed = [ ];
        }
      else
        {
          files = fs.difference default (fs.unions (map (manifest.at root) inside));
          removed = inside;
        };

    # The package's `tests/` directory out of the views of its non-test
    # units.
    testsDir =
      {
        default,
        test,
        root,
        packageDir,
        ...
      }:
      let
        tests = testsDirOf {
          inherit root;
          pkgDir = packageDir;
        };
      in
      if !test && tests != null then
        {
          files = fs.difference default (manifest.at root tests);
          removed = [ tests ];
        }
      else
        {
          files = default;
          removed = [ ];
        };

    # The roots of the package's other targets out of one target's
    # compiles (`targetExcluded`).
    targetRoots =
      {
        default,
        unit,
        cargoTarget,
        targets,
        root,
        packageDir,
        ...
      }:
      let
        excluded = map (util.joinRel packageDir) (targetExcluded {
          inherit root targets cargoTarget;
          pkgDir = packageDir;
        });
      in
      if unit != "compile" || cargoTarget == null then
        {
          files = default;
          removed = [ ];
        }
      else
        {
          files = fs.difference default (fs.unions (map (e: fs.maybeMissing (manifest.at root e)) excluded));
          removed = excluded;
        };

    # Test runs see only `paths` (relative to the package directory);
    # null: every step's files. It may leave out anything: `""`.
    runFiles =
      paths:
      {
        default,
        unit,
        root,
        packageDir,
        ...
      }:
      if unit != "test-run" || paths == null then
        {
          files = default;
          removed = [ ];
        }
      else
        {
          files = fs.unions (map (p: manifest.at root (util.joinRel packageDir p)) paths);
          removed = [ "" ];
        };
  };

  # The built-in entries of one package's `sources`, from its settings
  # (`extraSources` and `test`, as `packages.<name>` has them), each after
  # every built-in before it.
  defaultEntries =
    {
      settings ? { },
      extraFiles ? [ ],
    }:
    let
      test = settings.test or { };
      steps' = {
        package = steps.package { inherit extraFiles; };
        extraSources = steps.add (settings.extraSources or [ ]);
        sourceScope = steps.testScope (test.sourceScope or [ ]);
        inherit (steps) testsDir targetRoots;
        runFiles = steps.runFiles (test.runFiles or null);
      };
    in
    lib.listToAttrs (
      lib.imap0 (
        i: n:
        lib.nameValuePair n {
          step = steps'.${n};
          after = lib.take i builtinNames;
        }
      ) builtinNames
    );

  # One package's `sources` entries over the built-in ones: a value of
  # `settings.sources.<name>` is null (removes it), a step function, or
  # `{ step; after; before; enable; }` (the module's), whose non-null
  # fields replace the built-in entry's. Returns the live entries by name
  # and the names of the removed ones.
  entriesOf =
    {
      name,
      settings ? { },
      extraFiles ? [ ],
    }:
    let
      builtin = defaultEntries { inherit settings extraFiles; };
      user = settings.sources or { };
      norm =
        n: v:
        if v == null then
          { enable = false; }
        else if isFunction v then
          { step = v; }
        else if builtins.isAttrs v then
          lib.filterAttrs (_: x: x != null) v
        else
          throw "breakbulk: packages.${name}.sources.${n} must be null, a function or an attribute set, not a ${typeOf v}";
      merged =
        builtin // lib.mapAttrs (n: v: removeAttrs (builtin.${n} or { }) [ "enable" ] // norm n v) user;
      isLive = e: e.enable or true;
      live = lib.filterAttrs (_: isLive) merged;
    in
    if !builtins.isAttrs user then
      throw "breakbulk: packages.${name}.sources must be an attribute set of named entries, not a ${typeOf user}"
    else
      {
        entries = lib.mapAttrs (
          n: e:
          if e ? step && isFunction e.step then
            e
          else
            throw "breakbulk: packages.${name}.sources.${n} has no `step` function"
        ) live;
        removed = attrNames (lib.filterAttrs (_: e: !(isLive e)) merged);
      };

  # The live entries of `entriesOf` in order: each after the entries its
  # `after` names and before those its `before` names; an entry with
  # neither after every built-in one. Entries the constraints leave
  # unordered run built-in ones first, in their order, then by name.
  orderEntries =
    {
      name,
      entries,
      removed ? [ ],
    }:
    let
      names = attrNames entries;
      refs =
        n: what: v:
        let
          l = if v == null then [ ] else lib.toList v;
          bad = filter (x: !(entries ? ${x}) && !(lib.elem x removed)) l;
        in
        if !(builtins.isList l && lib.all isString l) then
          throw "breakbulk: packages.${name}.sources.${n}.${what} must be an entry name or a list of them"
        else if bad != [ ] then
          throw "breakbulk: packages.${name}.sources.${n}.${what} names `${lib.head bad}`, which is not an entry"
        else
          filter (x: entries ? ${x}) l;
      cons = lib.mapAttrs (
        n: e:
        let
          a = refs n "after" (e.after or null);
          b = refs n "before" (e.before or null);
          free = (e.after or null) == null && (e.before or null) == null && !(lib.elem n builtinNames);
        in
        {
          after = a ++ lib.optionals free (filter (x: entries ? ${x}) builtinNames);
          before = b;
        }
      ) entries;
      edge = x: y: x != y && (lib.elem x cons.${y}.after || lib.elem y cons.${x}.before);
      rank =
        n:
        let
          i = lib.lists.findFirstIndex (x: x == n) null builtinNames;
        in
        if i == null then
          {
            b = 1;
            inherit n;
          }
        else
          {
            b = 0;
            n = lib.fixedWidthNumber 3 i;
          };
      less = x: y: (rank x).b < (rank y).b || (rank x).b == (rank y).b && (rank x).n < (rank y).n;
      go =
        done: left:
        if left == [ ] then
          done
        else
          let
            ready = filter (y: !(lib.any (x: x != y && edge x y) left)) left;
          in
          if ready == [ ] then
            throw "breakbulk: the `after` and `before` of packages.${name}.sources form a cycle among ${
              lib.concatMapStringsSep ", " (n: "`${n}`") left
            }"
          else
            let
              next = lib.head (lib.sort less ready);
            in
            go (done ++ [ next ]) (filter (x: x != next) left);
    in
    map (n: {
      inherit n;
      inherit (entries.${n}) step;
    }) (go [ ] names);

  # The deepest directory holding every path of `ps` (relative paths;
  # `""` for the root).
  commonDir =
    ps:
    let
      split = map (lib.splitString "/") ps;
      go =
        i:
        let
          heads = map (s: if lib.length s > i then lib.elemAt s i else null) split;
          h = lib.head heads;
        in
        if h != null && lib.all (x: x == h) heads then [ h ] ++ go (i + 1) else [ ];
    in
    lib.concatStringsSep "/" (go 0);

  # One unit's view (`descriptor`): every step in turn, from the empty
  # set. `files`, and `removed`: `{ step; paths; }` for each step that
  # left something out, the paths relative to the root. A step returns a
  # file set or `{ files; removed; }`; for a bare file set, what it left
  # out is the deepest directory holding every file it took away (or the
  # file): a list of every file would change with each file added under
  # it, and the hint data is part of every unit. `name`: the package's,
  # for errors.
  pipeline =
    {
      name,
      ordered,
      descriptor,
    }:
    let
      root = descriptor.root;
      rel = p: util.normalizeRel (lib.path.removePrefix root p);
    in
    lib.foldl'
      (
        acc: e:
        let
          r = e.step (
            descriptor
            // {
              default = acc.files;
              ${sentinel} = null;
            }
          );
          explicit = builtins.isAttrs r && r ? files && fs.isFileset r.files && !(fs.isFileset r);
          files = if explicit then r.files else r;
          gone = map rel (fs.toList (fs.difference acc.files files));
          removed = if explicit then r.removed or [ ] else lib.optional (gone != [ ]) (commonDir gone);
        in
        if !(explicit || fs.isFileset r) then
          throw "breakbulk: packages.${name}.sources.${e.n} returned a ${typeOf r}, not a file set (lib.fileset) or { files; removed; }"
        else
          {
            inherit files;
            removed =
              acc.removed
              ++ lib.optional (removed != [ ]) {
                step = e.n;
                paths = removed;
              };
          }
      )
      {
        files = fs.empty;
        removed = [ ];
      }
      ordered;

  # Whether two file sets hold the same files. Not by `fs.toList` of
  # each: the differences are empty without reading a directory both hold
  # whole.
  sameFiles = a: b: fs.toList (fs.difference a b) == [ ] && fs.toList (fs.difference b a) == [ ];

  # The store path of a view of the repository root: the files of
  # `fileset` at their places, and the package directory even when none of
  # its files are chosen. Not lib.fileset.toSource alone: a file set holds
  # files only, and a unit's working directory is its package directory,
  # which `runFiles = [ ]` (or any step) can leave empty.
  realize =
    {
      root,
      pkgDir,
      fileset,
    }:
    let
      files = fs.toSource { inherit root fileset; };
      dir = toString (manifest.at root pkgDir);
    in
    lib.sources.cleanSourceWith {
      name = "source";
      src = root;
      filter =
        path: type:
        files.filter path type || (type == "directory" && (path == dir || lib.hasPrefix "${path}/" dir));
    };

  # `view` with each `sourceOverlay` entry in place: a symbolic link at
  # the entry's path (relative to the package directory) to its value,
  # replacing what the view has there. Not a step of the pipeline: a file
  # set holds files of the evaluation's file system, and a derivation
  # output exists only once built, so a step that took one would make
  # every evaluation build it (import from derivation). Here the product
  # is only a reference in a derivation of its own, which instantiation
  # names by key and never reads. A link, not a copy: the view stays a
  # copy of the repository plus references, and canonical paths (as
  # rust-embed takes them) name the product itself.
  overlay =
    {
      runCommand,
      name,
      pkgDir,
      entries,
      view,
    }:
    let
      places = map (
        rel:
        let
          p = util.joinRel pkgDir rel;
        in
        if util.normalizeRel rel == "" then
          throw "breakbulk: packages.${name}.sourceOverlay: \"${rel}\" is the package directory itself"
        else if p == ".." || lib.hasPrefix "../" p then
          throw "breakbulk: packages.${name}.sourceOverlay: \"${rel}\" leaves the repository root"
        else
          {
            inherit p rel;
            value = entries.${rel};
          }
      ) (attrNames entries);
      nested = lib.filter (a: lib.any (b: a.p != b.p && util.isUnder b.p a.p) places) places;
    in
    if entries == { } then
      view
    else if nested != [ ] then
      throw "breakbulk: packages.${name}.sourceOverlay: \"${(lib.head nested).rel}\" is inside another entry's path"
    else
      runCommand "source"
        {
          # The entries' values, for instantiation's check that no setting
          # names a derivation of the plan taking the view (instantiate.nix
          # `samePlanCheck`).
          passthru.breakbulkMadeFrom = map (e: e.value) places;
        }
        (
          ''
            cp -r ${view} $out
            chmod -R u+w $out
          ''
          + lib.concatMapStrings (e: ''
            rm -rf $out/${lib.escapeShellArg e.p}
            mkdir -p "$(dirname $out/${lib.escapeShellArg e.p})"
            ln -s ${lib.escapeShellArg "${e.value}"} $out/${lib.escapeShellArg e.p}
          '') places
        );

  # The crate names in a package's `[build-dependencies]` (`kind =
  # "build"`) or `[dependencies]` (`"normal"`), and the
  # `target.<cfg>.` tables of that kind, by the package they name.
  dependencyNames =
    {
      root,
      pkgDir,
      kind,
    }:
    let
      m = builtins.fromTOML (builtins.readFile (manifest.at root (util.joinRel pkgDir "Cargo.toml")));
      of =
        t:
        if kind == "build" then
          [
            (t.build-dependencies or { })
            (t.build_dependencies or { })
          ]
        else
          [ (t.dependencies or { }) ];
      tables = of m ++ lib.concatMap of (lib.attrValues (m.target or { }));
    in
    lib.unique (
      lib.concatMap (
        t: lib.mapAttrsToList (k: v: if builtins.isAttrs v && v ? package then v.package else k) t
      ) tables
    );

  # The paths `predictSources.keep` gives for one descriptor, relative to
  # the root: strings relative to the package directory, paths, and the
  # files of the file sets its functions return.
  keepPaths =
    {
      root,
      name,
      pkgDir,
      keep,
      descriptor,
    }:
    let
      rel = relOf root pkgDir;
    in
    lib.concatMap (
      k:
      if isString k || isPath k then
        lib.toList (rel k)
      else
        let
          r = k (descriptor // { ${sentinel} = null; });
        in
        if fs.isFileset r then
          filter (x: x != null) (map rel (fs.toList r))
        else
          throw "breakbulk: a function in packages.${name}.predictSources.keep returned a ${typeOf r}, not a file set (lib.fileset)"
    ) keep;

  # A package's views, rooted at the repository root (`<view>/<pkgDir>`
  # is the package directory):
  #
  # - `src`: its non-test units' view (a compile with `test = false` and no
  #   Cargo target: what a unit the planner matched to no target reads);
  #   for a package that is `tested`, `testSrc`, its test compiles' (and
  #   test runs' working directory unless `runDirs` says otherwise).
  # - `targetSrc` and `targetTestSrc`: the views of single units by
  #   identity (`<kind>/<name>` for a Cargo target's compiles,
  #   `run/custom-build/<name>` for a build-script run, `doctest`), for
  #   the units whose view differs from the package's, and the predicted
  #   ones (`predicted`'s specs say how; the value here is the view they
  #   narrow).
  # - `runDirs."<kind>/<name>"`: the package directory of a test binary's
  #   run view, or null when it is `testSrc`'s; `runSrc`, the view of a
  #   run of no known binary.
  #
  # `settings`: `extraSources`, `test`, `sources`, `predictSources` and
  # `sourceOverlay`, as `packages.<name>` has them. `targets`: the
  # package's Cargo targets (`{ kind; name; path; }`, `path` relative to
  # the package directory; lib/roots.nix `packageTargets`). `runCommand`:
  # for a package with a `sourceOverlay`; `predictOne`: a spec to its
  # predicted view as a derivation, for such a package's predicted units.
  packageViews =
    {
      root,
      name,
      pkgDir,
      wsDir ? "",
      memberDirs ? [ ],
      settings ? { },
      targets ? [ ],
      tested ? true,
      runCommand ? null,
      predictOne ? null,
      # Paths every predicted view of the package keeps, relative to the
      # root, besides `predictSources.keep` (the files the variant's
      # workspace wrapper reads: `wrapperConfig.workingDirFiles`).
      extraKeep ? [ ],
      # Paths every view of the package holds, relative to the root (the
      # variant's `wrapperConfig.workingDirFiles`).
      extraFiles ? [ ],
    }:
    let
      cargoTargets = map (t: { inherit (t) kind name path; }) targets;
      es = entriesOf { inherit name settings extraFiles; };
      ordered = orderEntries {
        inherit name;
        inherit (es) entries removed;
      };
      descriptor = unit: test: cargoTarget: {
        inherit
          unit
          test
          cargoTarget
          root
          memberDirs
          ;
        packageDir = pkgDir;
        workspaceDir = wsDir;
        targets = cargoTargets;
      };
      filesOf =
        d:
        pipeline {
          inherit name ordered;
          descriptor = d;
        };
      realizeFiles =
        fileset:
        realize {
          inherit root pkgDir fileset;
        };
      overlayEntries = settings.sourceOverlay or { };
      overlaid = overlayEntries != { };
      withOverlay =
        view:
        overlay {
          inherit runCommand name pkgDir;
          entries = overlayEntries;
          view = view;
        };

      # The package's views: non-test compiles', test compiles', test
      # runs'. Their files, the files realized, and that with the overlay.
      pkgFiles = {
        build = filesOf (descriptor "compile" false null);
        test = filesOf (descriptor "compile" true null);
        run = filesOf (descriptor "test-run" true null);
      };
      pkgBase = lib.mapAttrs (_: v: realizeFiles v.files) pkgFiles;
      pkgView = lib.mapAttrs (_: withOverlay) pkgBase;

      ofKind = ks: filter (t: lib.elem t.kind ks) cargoTargets;
      buildTargets = ofKind [
        "lib"
        "bin"
        "custom-build"
      ];
      testTargets = filter (t: t.kind != "custom-build") cargoTargets;
      libTarget = lib.findFirst (t: t.kind == "lib") null cargoTargets;

      # Every unit with a view of its own: `ident`, its descriptor, and
      # the package view (`pkg`: "build" or "test") it stands in for.
      units =
        map (t: {
          ident = "${t.kind}/${t.name}";
          d = descriptor "compile" false t;
          pkg = "build";
        }) buildTargets
        ++ map (t: {
          ident = "run/${t.kind}/${t.name}";
          d = descriptor "build-script-run" false t;
          pkg = "build";
        }) (ofKind [ "custom-build" ])
        ++ lib.optionals tested (
          map (t: {
            ident = "${t.kind}/${t.name}";
            d = descriptor "compile" true t;
            pkg = "test";
          }) testTargets
          ++ lib.optional (libTarget != null) {
            ident = "doctest";
            d = descriptor "doctest" true libTarget;
            pkg = "test";
          }
        );

      ps = settings.predictSources or { };
      predictOn = ps.enable or null == true;
      predictRuns = ps.buildScriptRuns or null == true;
      predictTests = ps.testCompiles or null == true;
      isPredicted =
        u:
        predictOn
        && (
          u.d.unit == "compile" && (!u.d.test || predictTests)
          || u.d.unit == "build-script-run" && predictRuns
        )
        && u.d.cargoTarget != null;

      # What a predicted view says it left out, for hints: the deepest
      # directory holding the package's non-test view (the package
      # directory, unless `extraSources` reach outside it), not the whole
      # repository. So a missing file outside it gets the hint that adds it
      # to the view, which `predictSources.keep` cannot. Not the widest
      # (test) view's: it is in every predicted unit, and widening the
      # tests' scope would then rebuild the library.
      predictRemoved = commonDir (
        map (p: util.normalizeRel (lib.path.removePrefix root p)) (fs.toList pkgFiles.build.files)
      );
      unitOf =
        u:
        let
          own = filesOf u.d;
          files = own.files;
          same = sameFiles files pkgFiles.${u.pkg}.files;
          base = if same then pkgBase.${u.pkg} else realizeFiles files;
          # What prediction reads: the package's test compiles' view, the
          # widest of its own, with any file of the unit's own view it
          # lacks. So a predicted read wins over a step that left the file
          # out of this unit's view.
          wider = fs.union pkgFiles.test.files files;
          # The files of its own view outside the package directory: a
          # step put them there on purpose (`extraSources`, a test
          # `sourceScope`), and what reads them is usually something
          # prediction cannot follow (a proc macro, a build script). Not
          # left to `predictSources.keep`: every such path would then be
          # named twice.
          outside = map (p: util.normalizeRel (lib.path.removePrefix root p)) (
            fs.toList (fs.difference files (manifest.at root pkgDir))
          );
          spec = {
            view = "${if sameFiles wider pkgFiles.test.files then pkgBase.test else realizeFiles wider}";
            fallback = "${base}";
            packageDir = pkgDir;
            kind = if u.d.unit == "build-script-run" then "run" else "crate";
            root = util.joinRel pkgDir u.d.cargoTarget.path;
            keep = lib.unique (
              extraKeep
              ++ outside
              ++ keepPaths {
                inherit root name pkgDir;
                keep = ps.keep or [ ];
                descriptor = u.d;
              }
            );
          };
          predicted = isPredicted u;
        in
        u
        // {
          inherit spec predicted;
          # What its view left out (pipeline's `removed`): prediction may
          # leave out anything the widest view holds.
          removed =
            if predicted then
              pkgFiles.test.removed
              ++ [
                {
                  step = "predictSources";
                  paths = [ predictRemoved ];
                }
              ]
            else
              own.removed;
          # The view instantiation names for it, or null for the
          # package's.
          view =
            if predicted then
              (if overlaid then withOverlay (predictOne spec) else base)
            else if same then
              null
            else
              withOverlay base;
        };
      resolved = map unitOf units;
      viewsOf =
        pkg:
        lib.listToAttrs (
          map (u: lib.nameValuePair u.ident u.view) (filter (u: u.pkg == pkg && u.view != null) resolved)
        );
      specsOf =
        withOverlaid: pkg:
        lib.listToAttrs (
          map (u: lib.nameValuePair u.ident u.spec) (
            filter (u: u.pkg == pkg && u.predicted && (withOverlaid || !overlaid)) resolved
          )
        );
      # What each view of its own left out, by identity.
      removedOf =
        pkg:
        lib.listToAttrs (
          map (u: lib.nameValuePair u.ident u.removed) (filter (u: u.pkg == pkg && u.view != null) resolved)
        );

      # Test runs: one binary's run view, or null for the test compiles'.
      runShared = if sameFiles pkgFiles.run.files pkgFiles.test.files then null else pkgView.run;
      # `{ view; removed; }`.
      runViewOf =
        t:
        let
          own = filesOf (descriptor "test-run" true t);
        in
        {
          inherit (own) removed;
          view =
            if sameFiles own.files pkgFiles.test.files then
              null
            else if sameFiles own.files pkgFiles.run.files then
              runShared
            else
              withOverlay (realizeFiles own.files);
        };
      runViews = lib.listToAttrs (
        map (t: lib.nameValuePair "${t.kind}/${t.name}" (runViewOf t)) testTargets
      );
      dirIn =
        view:
        if view == null then
          null
        else if pkgDir == "" then
          "${view}"
        else
          "${view}/${pkgDir}";

    in
    {
      src = pkgView.build;
      # The predicted views' specs (lib/instantiate.nix
      # `sources.predicted`), by identity, for "build" and "test" units;
      # not a package with a `sourceOverlay`, whose predicted views are
      # derivations (`predictOne`) in `targetSrc`.
      predicted = lib.optionalAttrs predictOn (
        {
          build = specsOf false "build";
        }
        // lib.optionalAttrs tested { test = specsOf false "test"; }
      );
      # Every predicted unit's spec, a `sourceOverlay` package's too, in
      # `predicted`'s shape: what `explainPredictions` reports on.
      explained = lib.optionalAttrs predictOn (
        {
          build = specsOf true "build";
        }
        // lib.optionalAttrs tested { test = specsOf true "test"; }
      );
      targetSrc = viewsOf "build";
      # What each view left out (pipeline's `removed`), for hints: the
      # package's (`""`) and each in `targetSrc` or `targetTestSrc`, by
      # package view.
      removed = {
        build = {
          "" = pkgFiles.build.removed;
        }
        // removedOf "build";
      }
      // lib.optionalAttrs tested {
        test = {
          "" = pkgFiles.test.removed;
        }
        // removedOf "test";
      };
    }
    // lib.optionalAttrs tested {
      testSrc = pkgView.test;
      targetTestSrc = viewsOf "test";
      runSrc = if runShared == null then pkgView.test else runShared;
      runDirs = lib.mapAttrs (_: r: dirIn r.view) runViews;
      # What each test binary's run view left out, by `<kind>/<name>`:
      # its own view's, or the test view's (`removed.test.""`).
      runRemoved = lib.mapAttrs (
        _: r: if r.view == null then pkgFiles.test.removed else r.removed
      ) runViews;
    };

  # A member's tree of a workspace wrapper's config files, rooted at the
  # repository root: every file named in `names` in `pkgDir` and its
  # ancestors up to the root, at their places (clippy's `.clippy.toml` and
  # `clippy.toml`). The wrapper gets `<tree>/<pkgDir>` in its variable
  # (`CLIPPY_CONF_DIR`) and does its own lookup there, so breakbulk picks
  # no file. `<pkgDir>` exists with no file of its own (`realize`): clippy
  # canonicalizes its start directory, but reads the manifest from its
  # working directory, not this one, so holding the package's `Cargo.toml`
  # here would only make every edit to it rebuild the member's wrapped
  # units. Not in the source views, because then every edit to a config
  # file would rebuild every unit below it, those of variants without the
  # wrapper too.
  wrapperConfigTree =
    {
      root,
      pkgDir,
      names,
    }:
    let
      at = manifest.at root;
      ancestors = d: [ d ] ++ lib.optionals (d != "") (ancestors (util.normalizeRel (builtins.dirOf d)));
      configs = lib.concatMap (d: map (n: fs.maybeMissing (at (util.joinRel d n))) names) (
        ancestors pkgDir
      );
    in
    realize {
      inherit root pkgDir;
      fileset = fs.unions configs;
    };

  # Views for every member of a workspace, keyed by package name
  # (`packageViews`, plus `dir`). `packages.<package name>`: its settings.
  # `runCommand`, `predictOne`: as packageViews takes them.
  workspaceViews =
    {
      root,
      wsDir ? "",
      packages ? { },
      # The Cargo targets of the member at a directory (packageViews'
      # `targets`).
      targetsOf ? (_: [ ]),
      runCommand ? null,
      predictOne ? null,
      # packageViews' `extraKeep` and `extraFiles`, for every member.
      extraKeep ? [ ],
      extraFiles ? [ ],
    }:
    let
      ws = manifest.workspace { inherit root wsDir; };
    in
    lib.listToAttrs (
      map (
        dir:
        let
          info = manifest.packageInfo {
            inherit root dir;
            wsManifest = ws.manifest;
          };
        in
        lib.nameValuePair info.name (
          {
            inherit dir;
          }
          // packageViews {
            inherit
              root
              wsDir
              runCommand
              predictOne
              extraKeep
              extraFiles
              ;
            inherit (info) name;
            pkgDir = dir;
            memberDirs = ws.members;
            settings = packages.${info.name} or { };
            targets = targetsOf dir;
          }
        )
      ) ws.members
    );
}
