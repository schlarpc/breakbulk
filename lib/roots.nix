# Predicting a package's targets, and the roots of the build, test and bench
# plans, from its manifest and directory listings.
#
# This implements Cargo's documented target auto-discovery. The code follows
# cargo src/workspace/parser/targets.rs at rust-1.99.0 (commit
# 5f94df4789f005f9a352888e8355ffc645b7ed0e) function by function:
#   normalize_lib / inferred_lib            -> libTarget
#   normalize_bins / inferred_bins          -> binTargets
#   normalize_examples, _tests, _benches    -> otherTargets
#   infer_from_directory / infer_any        -> inferFromDirectory
#   toml_targets_and_inferred               -> mergeInferred
#   target_path (+ legacy 2015 paths)       -> targetPath
#   normalize_build                         -> buildScripts
# and the per-kind defaults of `Target::{lib,bin,example,test,bench}_target`
# in cargo src/workspace/manifest.rs.
#
# Plan roots follow `UnitGenerator::filter_default_targets` and `new_units`
# in cargo src/ops/cargo_compile/unit_generator.rs:
#   build (`cargo build`):        lib and bins
#   test  (`cargo test --no-run`): targets with test = true, plus examples
#                                  (built in build mode unless test = true)
#   bench (`cargo bench --no-run`): targets with bench = true
# `required-features` is reported but never used to drop a root.
{
  lib,
  util,
  manifest,
}:
let
  inherit (builtins)
    attrNames
    filter
    length
    pathExists
    readDir
    readFileType
    ;

  # Accept both spellings Cargo accepts (`deprecated_underscore`).
  get2 = t: a: b: if t ? ${a} then t.${a} else t.${b} or null;
in
rec {
  # Directory listing helpers over (root, package dir).
  existsRel = root: rel: pathExists (manifest.at root rel);
  isDirRel = root: rel: existsRel root rel && readFileType (manifest.at root rel) == "directory";
  isFileRel = root: rel: existsRel root rel && readFileType (manifest.at root rel) != "directory";

  # infer_from_directory: (name, path) pairs for `<dir>/*.rs` and
  # `<dir>/*/main.rs`, skipping dotfiles. Paths are relative to the package.
  inferFromDirectory =
    root: pkgDir: rel:
    let
      full = util.joinRel pkgDir rel;
      entries = if isDirRel root full then readDir (manifest.at root full) else { };
      one =
        n:
        let
          type = entries.${n};
        in
        if lib.hasPrefix "." n then
          [ ]
        # DirEntry::file_type does not follow symlinks, so only real
        # directories are searched for main.rs.
        else if type == "directory" then
          (if existsRel root "${full}/${n}/main.rs" then [ { name = n; path = "${rel}/${n}/main.rs"; } ] else [ ])
        else if lib.hasSuffix ".rs" n then
          [ { name = lib.removeSuffix ".rs" n; path = "${rel}/${n}"; } ]
        else
          [ ];
    in
    lib.concatMap one (attrNames entries);

  # toml_targets_and_inferred
  mergeInferred =
    {
      tomlTargets,
      inferred,
      autodiscover,
      edition,
    }:
    let
      inferredToml = map (i: { inherit (i) name path; }) inferred;
      result =
        if tomlTargets == null then
          (if autodiscover == false then [ ] else inferredToml)
        else
          let
            seenNames = map (t: t.name or null) tomlTargets;
            seenPaths = map (t: if t ? path then util.normalizeRel t.path else null) tomlTargets;
            rem = filter (
              t: !(lib.elem t.name seenNames) && !(lib.elem (util.normalizeRel t.path) seenPaths)
            ) inferredToml;
            auto = if autodiscover != null then autodiscover else edition != "2015";
          in
          tomlTargets ++ lib.optionals auto rem;
    in
    lib.sort (a: b: (a.name or "") < (b.name or "")) result;

  # target_path
  targetPath =
    {
      target,
      inferred,
      kind,
      edition,
      legacyPath ? _: null,
      pkgDir,
    }:
    if target ? path then
      util.normalizeRel target.path
    else
      let
        matching = filter (i: i.name == target.name) inferred;
        legacy = if edition == "2015" then legacyPath target else null;
      in
      if length matching == 1 then
        util.normalizeRel (builtins.head matching).path
      else if legacy != null then
        legacy
      else if matching == [ ] then
        throw "breakbulk: ${pkgDir}: can't find `${target.name}` ${kind} (Cargo would fail to load this manifest)"
      else
        throw "breakbulk: ${pkgDir}: cannot infer path for `${target.name}` ${kind}: several candidates";

  # Shared by bins, examples, tests and benches (normalize_targets_with_legacy_path,
  # with normalize_bins' differences folded in).
  normalizeTargets =
    {
      root,
      pkgDir,
      kind,
      tomlTargets,
      inferred,
      autodiscover,
      edition,
      legacyPath ? _: null,
    }:
    let
      allNamed = tomlTargets == null || lib.all (t: t ? name && t ? path) tomlTargets;
    in
    if autodiscover == false && allNamed then
      map (t: t // { path = util.normalizeRel t.path; }) (if tomlTargets == null then [ ] else tomlTargets)
    else
      map (
        t:
        if !(t ? name) then
          throw "breakbulk: ${pkgDir}: ${kind} target ${kind}.name is required"
        else
          t
          // {
            path = targetPath {
              inherit
                inferred
                kind
                edition
                legacyPath
                pkgDir
                ;
              target = t;
            };
          }
      ) (mergeInferred { inherit tomlTargets inferred autodiscover edition; });

  # normalize_lib + to_lib_target
  libTarget =
    {
      root,
      pkgDir,
      packageName,
      edition,
      tomlLib,
      autolib,
    }:
    let
      inferred = if existsRel root (util.joinRel pkgDir "src/lib.rs") then "src/lib.rs" else null;
      normalized =
        if autolib == false && (tomlLib == null || (tomlLib ? name && tomlLib ? path)) then
          tomlLib
        else
          let
            base =
              if tomlLib != null then
                tomlLib
              else if inferred != null then
                { path = inferred; }
              else
                null;
          in
          if base == null then
            null
          else
            let
              name = base.name or (builtins.replaceStrings [ "-" ] [ "_" ] packageName);
              legacy = "src/${name}.rs";
              path =
                if base ? path then
                  base.path
                else if inferred != null then
                  inferred
                else if edition == "2015" && existsRel root (util.joinRel pkgDir legacy) then
                  legacy
                else
                  throw "breakbulk: ${pkgDir}: can't find library `${name}`";
            in
            base // { inherit name path; };
    in
    if normalized == null then
      null
    else
      let
        t = normalized;
        crateTypes = get2 t "crate-type" "crate_type";
        procMacro = get2 t "proc-macro" "proc_macro";
        kinds =
          if crateTypes != null && lib.elem "proc-macro" crateTypes then
            [ "proc-macro" ]
          else if crateTypes != null then
            crateTypes
          else if procMacro == true then
            [ "proc-macro" ]
          else
            [ "lib" ];
      in
      mkTarget t {
        kind = "lib";
        crateTypes = kinds;
        tested = true;
        benched = true;
        doctest = true;
      };

  mkTarget =
    t: defaults:
    {
      inherit (t) name;
      path = util.normalizeRel t.path;
      inherit (defaults) kind crateTypes;
      test = t.test or defaults.tested;
      bench = t.bench or defaults.benched;
      doctest = t.doctest or defaults.doctest;
      harness = t.harness or true;
      requiredFeatures = get2 t "required-features" "required_features";
    };

  # normalize_build
  buildScripts =
    { root, pkgDir, pkg }:
    let
      b = pkg.build or null;
    in
    if b == null then
      (if isFileRel root (util.joinRel pkgDir "build.rs") then [ "build.rs" ] else [ ])
    else if b == false then
      [ ]
    else if b == true then
      [ "build.rs" ]
    else if builtins.isString b then
      [ (util.normalizeRel b) ]
    else
      b;

  # All targets of the package at `pkgDir` (relative to `root`).
  # `wsManifest` resolves `edition.workspace = true`.
  packageTargets =
    {
      root,
      pkgDir,
      wsManifest ? null,
    }:
    let
      info = manifest.packageInfo {
        inherit root wsManifest;
        dir = pkgDir;
      };
      m = info.manifest;
      pkg = m.package or m.project;
      edition = info.edition;
      packageName = info.name;

      libT = libTarget {
        inherit root pkgDir packageName edition;
        tomlLib = m.lib or null;
        autolib = pkg.autolib or null;
      };
      hasLib = libT != null;

      binInferred =
        (if existsRel root (util.joinRel pkgDir "src/main.rs") then [ { name = packageName; path = "src/main.rs"; } ] else [ ])
        ++ inferFromDirectory root pkgDir "src/bin";

      # legacy_bin_path
      legacyBin =
        t:
        let
          candidates =
            lib.optional (!hasLib) "src/${t.name}.rs"
            ++ [
              "src/main.rs"
              "src/bin/main.rs"
            ];
        in
        lib.findFirst (c: existsRel root (util.joinRel pkgDir c)) null candidates;

      legacyBench =
        t:
        if t.name == "bench" && existsRel root (util.joinRel pkgDir "src/bench.rs") then "src/bench.rs" else null;

      norm =
        kind: tomlKey: autoKey: dir: legacy:
        normalizeTargets {
          inherit root pkgDir kind edition;
          tomlTargets = m.${tomlKey} or null;
          inferred = if dir == null then binInferred else inferFromDirectory root pkgDir dir;
          autodiscover = pkg.${autoKey} or null;
          legacyPath = legacy;
        };

      bins = map (
        t:
        mkTarget t {
          kind = "bin";
          crateTypes = [ "bin" ];
          tested = true;
          benched = true;
          doctest = false;
        }
      ) (norm "bin" "bin" "autobins" null legacyBin);

      examples = map (
        t:
        let
          ct = get2 t "crate-type" "crate_type";
          isBin = ct == null || ct == [ ] || lib.all (c: c == "bin") ct;
        in
        mkTarget t {
          kind = "example";
          crateTypes = if isBin then [ "bin" ] else ct;
          tested = false;
          benched = false;
          doctest = false;
        }
      ) (norm "example" "example" "autoexamples" "examples" (_: null));

      tests = map (
        t:
        mkTarget t {
          kind = "test";
          crateTypes = [ "bin" ];
          tested = true;
          benched = false;
          doctest = false;
        }
      ) (norm "test" "test" "autotests" "tests" (_: null));

      benches = map (
        t:
        mkTarget t {
          kind = "bench";
          crateTypes = [ "bin" ];
          tested = false;
          benched = true;
          doctest = false;
        }
      ) (norm "bench" "bench" "autobenches" "benches" legacyBench);

      builds = map (p: {
        kind = "custom-build";
        name = "build-script-${lib.removeSuffix ".rs" (baseNameOf p)}";
        path = p;
        crateTypes = [ "bin" ];
        test = false;
        bench = false;
        doctest = false;
        harness = true;
        requiredFeatures = null;
      }) (buildScripts { inherit root pkgDir pkg; });

      targets = lib.optional hasLib libT ++ bins ++ examples ++ tests ++ benches ++ builds;
    in
    {
      inherit (info) name version edition;
      dir = pkgDir;
      inherit targets;
    };

  # Plan roots for one package's targets.
  planRoots =
    targets:
    let
      root = mode: t: {
        inherit (t) kind name crateTypes requiredFeatures;
        inherit mode;
      };
      isLib = t: t.kind == "lib";
      isBin = t: t.kind == "bin";
      isExample = t: t.kind == "example";
      ordinary = filter (t: t.kind != "custom-build") targets;
    in
    {
      build = map (root "build") (filter (t: isLib t || isBin t) ordinary);
      test = map (t: root (if isExample t && !t.test then "build" else "test") t) (
        filter (t: t.test || isExample t) ordinary
      );
      bench = map (root "bench") (filter (t: t.bench) ordinary);
      # `cargo test` doc-tests the library when doctest = true and its
      # crate types can be doctested (Target::doctestable: lib, rlib, proc-macro).
      doc = map (root "doctest") (
        filter (
          t: isLib t && t.doctest && lib.any (c: lib.elem c [ "lib" "rlib" "proc-macro" ]) t.crateTypes
        ) ordinary
      );
    };

  # Predicted roots for every member of the workspace at `wsDir`.
  #
  # Returns { <package name> = { name, version, dir, targets, roots = { build,
  # test, bench, doc } }; }.
  workspaceRoots =
    {
      root,
      wsDir ? "",
    }:
    let
      ws = manifest.workspace { inherit root wsDir; };
      pkgs = map (
        dir:
        let
          p = packageTargets {
            inherit root;
            pkgDir = dir;
            wsManifest = ws.manifest;
          };
        in
        p // { roots = planRoots p.targets; }
      ) ws.members;
    in
    lib.listToAttrs (map (p: lib.nameValuePair p.name p) pkgs);
}
