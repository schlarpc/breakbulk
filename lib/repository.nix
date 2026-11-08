# mkRepository: the module-system entry point ("Nix library" in
# docs/implementation.md).
#
#   repo = breakbulk.mkRepository {
#     inherit pkgs;
#     root = ./.;
#     modules = [ ./nix/rust.nix ];
#   };
#
# It evaluates breakbulk's options (lib/modules) with the user's modules
# and the curated -sys defaults (lib/sys-defaults.nix), then makes one
# mkWorkspace call per (workspace, target, variant). Outputs:
#
#   repo.workspaces.<ws>.packages.<pkg>                  native target, default variant
#   repo.workspaces.<ws>.tests.<pkg>.<test>              the same, test binaries
#   repo.workspaces.<ws>.target.<triple>.packages.<pkg>
#   repo.workspaces.<ws>.target.<triple>.tests.<pkg>.<test>
#   repo.workspaces.<ws>.target.<triple>.variants.<v>.{packages,tests}
#   repo.workspaces.<ws>.plans.<triple>.<v>.{build,test}  the plan derivations
#   repo.workspaces.<ws>.devShell
#   repo.workspaces.<ws>.instances.<triple>.<v>           the mkWorkspace results
#   repo.checks."<ws>/<triple>/<pkg>/<name>"              flattened
#   repo.sources.<crate> / ."<crate>@<version>"           fetched crate sources
#   repo.explainSharing { a; b; package; }                why units differ
#   repo.config, repo.options                             the evaluated modules
#   repo.optionsDoc                                       nixosOptionsDoc of them
#
#   repo.workspaces.<ws>.target.<triple>.testRuns.<pkg>.<test>   test runs
#   repo.workspaces.<ws>.target.<triple>.testApps.<pkg>.<binary>  runnable apps
#   repo.workspaces.<ws>.target.<triple>.doctests.<pkg>
#   repo.workspaces.<ws>.target.<triple>.spec          the resolved target spec
#
# A product (`packages.<pkg>`) is the package's build-plan roots (bins,
# cdylibs, dylibs and staticlibs) passed through the target's post-link
# stages and installed (bins in bin/, libraries in lib/): see
# lib/products.nix. `.stages.<name>` gives every stage, `.debug` the split
# debug info, `.checks.<name>` the checks. Roots Cargo did not build
# (required features) are left out and listed in `.unbuilt`; when no root
# was built, the product is the first stub, which fails with the reason.
# Every root is also under `.roots."<kind>/<target>"`.
#
# repo.checks (default variant): `<ws>/<triple>/<pkg>/build` (the
# product), `…/<pkg>/<check>` (its checks), `…/<pkg>/test-<name>` (enabled
# test runs) and `…/<pkg>/doctest`.
#
# Test names (`tests.<pkg>.<name>`): an integration test by its name, the
# library's unit tests as `lib`, a bin's unit tests as `bin-<name>`, an
# example as `example-<name>`. When two of these collide, both use the
# full root name `<kind>/<name>`.
{
  lib,
  util,
  lockfile,
  manifest,
  envCapture,
  mkFetch,
  mkTools,
  mkWorkspace,
  dynamic,
  products,
  variantsLib,
  presets,
}:
let
  versionReq = import ./modules/version-req.nix { inherit lib; };
  bt = import ./modules/types.nix { inherit lib; };
  bbModules = import ./modules;
  sysDefaults = ./sys-defaults.nix;
  mkDevShell = import ./devshell.nix { inherit lib; };
in
{
  pkgs,
  root,
  modules ? [ ],
  specialArgs ? { },
  tools ? mkTools pkgs,
}@args:
let
  userModules = args.modules or [ ];

  eval = lib.evalModules {
    modules = bbModules ++ [ sysDefaults ] ++ userModules;
    specialArgs = {
      inherit pkgs;
      breakbulkPresets = presets;
    }
    // specialArgs;
  };
  cfg = eval.config;

  nativeTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  fetchArgs = {
    inherit (cfg)
      registries
      gitHashes
      gitTrees
      gitSubdirs
      gitSubmodules
      ;
  };
  fetch = mkFetch pkgs fetchArgs;

  # --- lockfiles -------------------------------------------------------------

  wsDirOf = ws: util.normalizeRel ws.path;
  lockOf =
    wsName: ws:
    let
      p = root + "/${util.joinRel (wsDirOf ws) "Cargo.lock"}";
    in
    if builtins.pathExists p then
      lockfile.read p
    else
      throw "breakbulk: workspaces.${wsName}: ${util.joinRel (wsDirOf ws) "Cargo.lock"} does not exist; run `cargo generate-lockfile` and commit it";
  locks = lib.mapAttrs lockOf cfg.workspaces;
  allEntries = lib.concatLists (lib.attrValues locks);

  # --- per-package overrides -------------------------------------------------

  # "name" or "name@<requirement>".
  parseKey =
    k:
    let
      m = builtins.match "([^@]+)@(.+)" k;
    in
    if m == null then
      {
        name = k;
        req = null;
      }
    else
      {
        name = builtins.elemAt m 0;
        req = builtins.elemAt m 1;
      };

  overrideMatches =
    k: e:
    let
      p = parseKey k;
      o = cfg.packages.${k};
    in
    p.name == e.name
    && (p.req == null || versionReq.matches p.req e.version)
    && (o.version == null || versionReq.matches o.version e.version);

  # Keys some module other than the curated defaults defined.
  userKeys = lib.unique (
    lib.concatMap (d: lib.attrNames d.value) (
      lib.filter (d: d.file != "breakbulk/lib/sys-defaults.nix") eval.options.packages.definitionsWithLocations
    )
  );
  unmatchedWarnings = map (
    k:
    "breakbulk: `packages.${lib.strings.escapeNixIdentifier k}` matches no package in any workspace's Cargo.lock${
      lib.optionalString (cfg.packages.${k}.version != null) " (version requirement `${cfg.packages.${k}.version}`)"
    }; it has no effect."
  ) (lib.filter (k: !(lib.any (overrideMatches k) allEntries)) userKeys);

  # Unversioned keys first, so a versioned override wins over a plain one.
  orderedKeys = lib.sort (
    a: b:
    let
      pa = parseKey a;
      pb = parseKey b;
      va = pa.req != null || cfg.packages.${a}.version != null;
      vb = pb.req != null || cfg.packages.${b}.version != null;
    in
    if va != vb then vb else a < b
  ) (lib.attrNames cfg.packages);

  emptyOverride = {
    env = { };
    nativeInputs = _: [ ];
    inputs = _: [ ];
    extraSources = [ ];
    host = {
      env = { };
      nativeInputs = _: [ ];
      inputs = _: [ ];
    };
    target = { };
    strictSources = null;
  };
  catFn = f: g: p: f p ++ g p;
  mergeSide = a: b: {
    env = a.env // b.env;
    nativeInputs = catFn a.nativeInputs b.nativeInputs;
    inputs = catFn a.inputs b.inputs;
  };
  mergeOverride = a: b: {
    env = a.env // b.env;
    nativeInputs = catFn a.nativeInputs b.nativeInputs;
    inputs = catFn a.inputs b.inputs;
    extraSources = a.extraSources ++ b.extraSources;
    host = mergeSide a.host b.host;
    target = lib.zipAttrsWith (_: lib.foldl' mergeSide (mergeSide emptyOverride.host emptyOverride.host)) [
      a.target
      b.target
    ];
    strictSources = if b.strictSources != null then b.strictSources else a.strictSources;
  };

  # The merged override for one lockfile entry, or null.
  overrideFor =
    e:
    let
      ks = lib.filter (k: overrideMatches k e) orderedKeys;
    in
    if ks == [ ] then null else lib.foldl' (acc: k: mergeOverride acc cfg.packages.${k}) emptyOverride ks;

  envStrings = lib.mapAttrs (_: bt.envString);

  # The `packages.<name>` keys matching a workspace's path package `pkg`
  # (unversioned keys first).
  memberKeys =
    wsName: pkg:
    let
      es = lib.filter (e: e.name == pkg && e.source or null == null) locks.${wsName};
    in
    lib.filter (k: lib.any (overrideMatches k) es) orderedKeys;

  # Product settings for mkProducts: each key's stages and checks, then its
  # target.<triple> stages and checks.
  productConfig =
    wsName: triple: pkg:
    lib.concatMap (
      k:
      let
        o = cfg.packages.${k};
        t = o.target.${triple} or { };
      in
      [
        { inherit (o) stages checks; }
        {
          stages = t.stages or { };
          checks = t.checks or { };
        }
      ]
    ) (memberKeys wsName pkg);

  # packages.<name>.test merged over matching keys, for mkTestRuns:
  # `{ <pkg> = { test = …; }; }` for the workspace's path packages.
  testConfigs =
    wsName:
    let
      members = lib.unique (map (e: e.name) (lib.filter (e: e.source or null == null) locks.${wsName}));
      mergeTest = a: b: {
        env = a.env // envStrings b.env;
        path = a.path ++ b.path;
        args = a.args ++ b.args;
        includeIgnored = a.includeIgnored || b.includeIgnored;
        sourceScope = lib.unique (a.sourceScope ++ b.sourceScope);
        runner = if b.runner != null then b.runner else a.runner;
        nextest = lib.mapAttrs (k: v: if b.nextest.${k} != null then b.nextest.${k} else v) a.nextest;
        binaries = lib.zipAttrsWith (
          _:
          lib.foldl'
            (x: y: {
              args = x.args ++ y.args;
              enable = x.enable && y.enable;
            })
            {
              args = [ ];
              enable = true;
            }
        ) [
          a.binaries
          b.binaries
        ];
      };
      empty = {
        env = { };
        path = [ ];
        args = [ ];
        includeIgnored = false;
        sourceScope = [ ];
        binaries = { };
        # The workspace's defaults (decision 93); package settings win.
        inherit (cfg.workspaces.${wsName}.test) runner nextest;
      };
      # nextest reads `.config/nextest.toml` under the Cargo workspace root.
      nextestConfig = root + "/${util.joinRel (wsDirOf cfg.workspaces.${wsName}) ".config/nextest.toml"}";
      withDefaults =
        t:
        t
        // {
          nextest = t.nextest // {
            configFile =
              if t.nextest.configFile == null && builtins.pathExists nextestConfig then
                nextestConfig
              else
                t.nextest.configFile;
          };
        };
    in
    lib.genAttrs members (pkg: {
      test = withDefaults (
        lib.foldl' (acc: k: mergeTest acc cfg.packages.${k}.test) empty (memberKeys wsName pkg)
      );
    });

  # --- target specs, per workspace (decision 70) ------------------------------
  #
  # The spec of one workspace on one triple: the repository-wide
  # `targets.<triple>` and the workspace's own `workspaces.<ws>.targets.<triple>`
  # (both modules, lib/modules/target-spec.nix), evaluated together with the
  # workspace's toolchain, so a preset picks tools for that workspace's
  # rustc. `present` is false when neither defines anything but `packages`:
  # such a target has no spec (the toolchain as Cargo finds it), as before.
  specArgs = {
    inherit pkgs;
    breakbulkPresets = presets;
  }
  // specialArgs;
  evalTargetSpec =
    ws: triple:
    let
      repoDef = cfg.targets.${triple} or null;
      wsDef = ws.targets.${triple} or null;
      e = lib.evalModules {
        modules = [ ./modules/target-spec.nix ] ++ lib.optional (repoDef != null) repoDef ++ lib.optional (wsDef != null) wsDef;
        specialArgs = specArgs // {
          name = triple;
          breakbulkToolchain = ws.toolchain;
        };
      };
      specOptions = lib.collect lib.isOption (
        removeAttrs e.options [
          "_module"
          "packages"
        ]
      );
    in
    {
      inherit (e) config;
      packages = e.config.packages or null;
      present = repoDef != null || (wsDef != null && lib.any (o: o.highestPrio < 1500) specOptions);
    };
  targetSpecs = lib.mapAttrs (
    _: ws: lib.genAttrs (lib.unique (lib.attrNames ws.targets ++ [ nativeTriple ])) (evalTargetSpec ws)
  ) cfg.workspaces;
  # The spec's values, or null when the workspace has none for the triple.
  targetCfgOf =
    wsName: triple:
    let
      s = targetSpecs.${wsName}.${triple};
    in
    if s.present then s.config else null;
  # One field of it, or `default` without a spec.
  targetField =
    wsName: triple: field: default:
    let
      t = targetCfgOf wsName triple;
    in
    if t == null then default else t.${field};
  selectionOf = wsName: triple: targetSpecs.${wsName}.${triple}.packages;

  # The package set of a target's units: the target spec's `packageSet`
  # (set by the presets), else pkgs for the native triple.
  targetPkgs =
    wsName: triple:
    let
      p = targetField wsName triple "packageSet" null;
    in
    if p != null then
      p
    else if triple == nativeTriple then
      pkgs
    else
      throw "breakbulk: package inputs on target ${triple} need that target's nixpkgs package set (`targets.${triple}.packageSet`, which the Linux presets set); this target has none";

  # --- toolchain specs (M3) -------------------------------------------------
  #
  # A target's spec as mkWorkspace takes it: the planner's part (rustflags
  # and linkers, through `--config`), the env of each platform's units, the
  # store paths the plan will name, the target capture's package set, and
  # the runner.
  envName = triple: lib.replaceStrings [ "-" ] [ "_" ] triple;
  storePathsIn =
    s:
    lib.concatMap (
      p: if builtins.isList p then [ (lib.addContextFrom s (lib.head p)) ] else [ ]
    ) (builtins.split "(${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-[^/ =:;\"]+)" s);
  specFor =
    wsName: triple:
    let
      t = targetCfgOf wsName triple;
      e = envName triple;
      flags = l: lib.concatStringsSep " " l;
      cEnv =
        lib.filterAttrs (_: v: v != null) {
          "CC_${e}" = t.cc;
          "CXX_${e}" = t.cxx;
          "AR_${e}" = t.ar;
        }
        // lib.optionalAttrs (t.cflags != [ ]) {
          "CFLAGS_${e}" = flags t.cflags;
          "CXXFLAGS_${e}" = flags t.cflags;
        }
        // lib.optionalAttrs (t.bindgen.extraClangArgs != [ ]) {
          "BINDGEN_EXTRA_CLANG_ARGS_${e}" = flags t.bindgen.extraClangArgs;
        };
      str = v: if v == null then null else "${v}";
      linker = str t.linker;
      hostLinker = str t.host.linker;
      named = prefix: l: lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair "${prefix}-${toString i}" p) l);
      runner =
        if t.runner == null then
          null
        else if builtins.isFunction t.runner then
          t.runner {
            lockfile = root + "/${util.joinRel (wsDirOf cfg.workspaces.${wsName}) "Cargo.lock"}";
            workspace = wsName;
          }
        else
          t.runner;
    in
    if t == null then
      {
        mkWorkspace = { };
        runner = null;
        testSystem = null;
      }
    else
      {
        mkWorkspace = {
          spec = {
            inherit (t) rustflags;
            inherit linker hostLinker;
          };
          specTools =
            named "spec-linker" (lib.filter (x: x != null) [
              linker
              hostLinker
            ])
            // named "spec-rustflags" (lib.concatMap storePathsIn t.rustflags);
          hostEnv = envStrings t.host.env;
          targetPackageSet = if t.packageSet != null then t.packageSet else pkgs;
          targetEnv = envStrings (cEnv // t.env);
        };
        # A program, or a list: program and arguments (as Cargo's
        # `target.<triple>.runner` takes a string or an array).
        runner = if runner == null then null else map (x: "${x}") (lib.toList runner);
        inherit (t) testSystem;
      };

  # instantiate's overrides for one workspace on one target, keyed
  # "<name>@<version>".
  instOverrides =
    wsName: entries: triple:
    lib.listToAttrs (
      lib.concatMap (
        e:
        let
          o = overrideFor e;
          t = o.target.${triple} or (mergeSide emptyOverride.host emptyOverride.host);
          capture =
            platform: nativeInputs: inputs:
            let
              # A target without a package set (msvc, wasm32-unknown-unknown)
              # still has the build machine's for its host units.
              hasSet = targetField wsName triple "packageSet" null != null || triple == nativeTriple;
              p = if hasSet || platform == "host" then (if hasSet then targetPkgs wsName triple else pkgs) else null;
              sets =
                if platform == "target" then
                  {
                    host = p;
                    build = p.buildPackages;
                  }
                else
                  {
                    host = p.buildPackages;
                    build = p.buildPackages.buildPackages;
                  };
              # Target units of such a target cannot have library inputs.
              # The error belongs to the units that would use them, so a
              # package that never builds for this target (a curated
              # -sys default, a native-only crate) costs nothing: its
              # capture is a derivation that fails with the reason.
              noSet =
                let
                  probe = builtins.tryEval (
                    inputs (throw "no package set") == [ ] && nativeInputs pkgs.buildPackages == [ ]
                  );
                in
                if probe.success && probe.value then
                  null
                else
                  pkgs.runCommand "breakbulk-env-${e.name}-no-package-set" { } ''
                    echo ${lib.escapeShellArg "breakbulk: package inputs of ${e.name} on target ${triple} need that target's nixpkgs package set (`targets.${triple}.packageSet`, which the Linux presets set); this target has none"} >&2
                    exit 1
                  '';
            in
            if p == null then
              noSet
            else if nativeInputs sets.build == [ ] && inputs sets.host == [ ] then
              null
            else
              envCapture.forPackage {
                pkgs = p;
                inherit platform nativeInputs inputs;
                name = e.name;
              };
        in
        lib.optional (o != null) (
          lib.nameValuePair "${e.name}@${e.version}" {
            host = {
              env = envStrings (o.env // o.host.env);
              envCapture = capture "host" (catFn o.nativeInputs o.host.nativeInputs) (catFn o.inputs o.host.inputs);
            };
            target = {
              env = envStrings (o.env // t.env);
              envCapture = capture "target" (catFn o.nativeInputs t.nativeInputs) (catFn o.inputs t.inputs);
            };
            inherit (o) strictSources;
          }
        )
      ) entries
    );

  # extraSources by package name, from every matching override.
  extraSourcesOf =
    entries:
    lib.foldl' (
      acc: e:
      let
        o = overrideFor e;
      in
      if o == null || o.extraSources == [ ] then
        acc
      else
        acc // { ${e.name} = lib.unique ((acc.${e.name} or [ ]) ++ o.extraSources); }
    ) { } entries;

  # --- workspaces --------------------------------------------------------------

  checkMode =
    wsName: vName: v:
    if v.benches && (v.mode == "check" || v.mode == "clippy") then
      throw "breakbulk: workspaces.${wsName}.variants.${vName}: `benches` needs a build variant, not `${v.mode}`"
    else if !v.allTargets && !(v.mode == "check" || v.mode == "clippy") then
      throw "breakbulk: workspaces.${wsName}.variants.${vName}: `allTargets = false` needs a check or clippy variant, not `${v.mode}`"
    else
      v;

  shippedRemapScopeOf =
    wsName: triple: v:
    products.shippedRemapScope {
      inherit triple;
      stagePreset = targetField wsName triple "stagePreset" null;
      targetStages = targetField wsName triple "stages" { };
      coverage = v.mode == "coverage";
    };

  instance =
    wsName: ws: triple: vName:
    let
      v = checkMode wsName vName ws.variants.${vName};
      entries = locks.${wsName};
      sel = selectionOf wsName triple;
      s = specFor wsName triple;
      # splitDebug needs a GNU build ID; nixpkgs' linker wrapper adds a
      # content-derived one (`--build-id=sha1`) when NIX_SET_BUILD_ID is
      # set, as stdenv's separateDebugInfo does. Target units only.
      buildId = lib.optionalAttrs (shippedRemapScopeOf wsName triple v != null) { NIX_SET_BUILD_ID = "1"; };
    in
    mkWorkspace pkgs (
      {
      inherit root tools fetchArgs;
      path = ws.path;
      toolchain = {
        inherit (ws.toolchain) rustc cargo;
      };
      target = triple;
      inherit (v)
        profile
        features
        noDefaultFeatures
        allFeatures
        ;
      variant = vName;
      select = if sel == null then [ ] else sel;
      extraSources = extraSourcesOf entries;
      packageOverrides = instOverrides wsName entries triple;
      inherit (cfg) strictSources;
      name = "${wsName}-${triple}-${vName}";
      inherit delivery;
      shippedRemapScope = shippedRemapScopeOf wsName triple v;
      packages = testConfigs wsName;
      inherit (cfg) ca;
      inherit (v) mode clippyArgs;
      clippyDriver = if v.mode == "clippy" then "${ws.toolchain.clippy}/bin/clippy-driver" else null;
      bench = v.benches;
      inherit (s) runner testSystem;
    }
    // s.mkWorkspace
    // {
      targetEnv = buildId // (s.mkWorkspace.targetEnv or { });
    }
    # Coverage: `-C instrument-coverage` on target units, through the
    # spec's rustflags (so under the key the project uses, decision 33).
    // lib.optionalAttrs (v.mode == "coverage") {
      spec =
        let
          base =
            if s.mkWorkspace.spec or null != null then
              s.mkWorkspace.spec
            else
              {
                rustflags = [ ];
                linker = null;
                hostLinker = null;
              };
        in
        base
        // {
          rustflags = base.rustflags ++ [
            "-C"
            "instrument-coverage"
          ];
        };
    }
    );

  rootName = r: "${r.breakbulkRoot.kind}/${r.breakbulkRoot.target}";

  # One product per package: its build-plan roots through the target's
  # stages (lib/products.nix).
  productsOf =
    wsName: ws: triple: inst: sel:
    products.mkProducts {
      inherit pkgs inst triple;
      select = sel;
      stagePreset = targetField wsName triple "stagePreset" null;
      targetStages = targetField wsName triple "stages" { };
      targetChecks = targetField wsName triple "checks" { };
      packageConfig = productConfig wsName triple;
      inherit (cfg) ca;
      lockfile = root + "/${util.joinRel (wsDirOf ws) "Cargo.lock"}";
    };

  testName =
    r:
    let
      b = r.breakbulkRoot;
    in
    if b.kind == "test" then
      b.target
    else if b.kind == "lib" then
      "lib"
    else
      "${b.kind}-${b.target}";

  selectPkgs = sel: attrs: if sel == null then attrs else lib.filterAttrs (n: _: lib.elem n sel) attrs;

  # benches.<pkg>.<name>: bench-plan roots installed as $out/bin/<target>
  # (stubs as they are): a bench by its name, the lib harness in bench
  # mode as `lib`, a bin's as `bin-<name>`.
  benchesOf =
    inst: sel:
    let
      byPkg = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues inst.benches);
      nameOf =
        r:
        let
          b = r.breakbulkRoot;
        in
        if b.kind == "bench" then
          b.target
        else if b.kind == "lib" then
          "lib"
        else
          "${b.kind}-${b.target}";
      install =
        r:
        if r.breakbulkRoot.unit == null then
          r
        else
          pkgs.runCommand r.breakbulkRoot.target { } ''
            files=(${r}/*)
            install -D -m755 "''${files[0]}" $out/bin/${r.breakbulkRoot.target}
          '';
    in
    lib.mapAttrs (_: rs: lib.listToAttrs (map (r: lib.nameValuePair (nameOf r) (install r)) rs)) (
      selectPkgs sel byPkg
    );

  # testRuns.<pkg>.<name>: test runs, named as `tests` names test
  # binaries; `.enabled` holds those whose run is enabled
  # (`test.binaries.<binary>.enable`).
  namedRuns = inst: namedRuns' false inst.testRuns (pkg: k: inst.checks ? "test/${pkg}/${k}");
  # `benchPlan`: the runs are a bench plan's (benchRuns), where a bench is
  # named as in `benches` (by its name); in a test plan a bench built as a
  # test (`test = true`) is `bench-<name>`, as in `tests`.
  namedRuns' =
    benchPlan: allRuns: isEnabled: sel:
    let
      split = key: builtins.match "([a-z]+)/(.*)" key;
      short =
        key:
        let
          m = split key;
        in
        if m == null then
          key
        else if lib.head m == "lib" then
          "lib"
        else if benchPlan && lib.head m == "bench" then
          lib.last m
        else
          "${lib.head m}-${lib.last m}";
      long = key: if split key == null then "test/${key}" else key;
    in
    lib.mapAttrs (
      pkg: runs:
      let
        keys = lib.attrNames runs;
        counts = lib.groupBy short keys;
        nameOf = k: if lib.length counts.${short k} > 1 then long k else short k;
        pick = ks: lib.listToAttrs (map (k: lib.nameValuePair (nameOf k) runs.${k}) ks);
      in
      pick keys
      // {
        enabled = pick (lib.filter (isEnabled pkg) keys);
      }
    ) (selectPkgs sel allRuns);

  # tests.<pkg>.<name>: test-plan roots installed as $out/bin/<target>
  # (stubs as they are).
  testsOf =
    inst: sel:
    let
      byPkg = lib.groupBy (r: inst.tests.${r}.breakbulkRoot.package) (lib.attrNames inst.tests);
      selected = if sel == null then byPkg else lib.filterAttrs (n: _: lib.elem n sel) byPkg;
    in
    lib.mapAttrs (
      _: names:
      let
        named = map (n: {
          root = n;
          short = testName inst.tests.${n};
          long = rootName inst.tests.${n};
        }) names;
        counts = lib.groupBy (x: x.short) named;
      in
      lib.listToAttrs (
        map (
          x: lib.nameValuePair (if lib.length counts.${x.short} > 1 then x.long else x.short) inst.testBins.${x.root}
        ) named
      )
    ) selected;

  workspaceOut =
    wsName: ws:
    let
      instances = lib.mapAttrs (triple: _: lib.mapAttrs (vName: _: instance wsName ws triple vName) ws.variants) ws.targets;
      perTarget = lib.mapAttrs (
        triple: vs:
        let
          sel = selectionOf wsName triple;
          variants = lib.mapAttrs (
            vName: inst:
            let
              v = ws.variants.${vName};
            in
            {
              packages = productsOf wsName ws triple inst sel;
              tests = testsOf inst sel;
              testRuns = selectPkgs sel inst.testRuns;
              # testRuns named as `tests` names test binaries, for repo.checks.
              namedTestRuns = namedRuns inst sel;
              testApps = selectPkgs sel inst.testApps;
              doctests = selectPkgs sel inst.doctests;
              benches = benchesOf inst sel;
              benchRuns = selectPkgs sel inst.benchRuns;
              namedBenchRuns = namedRuns' true inst.benchRuns (_: _: true) sel;
            }
            // lib.optionalAttrs (v.mode == "check" || v.mode == "clippy") {
              # Every unit of both plans (`cargo check` and `cargo check
              # --all-targets`): for clippy, its lints on every workspace
              # member. With `allTargets = false`, the build plan's only
              # (decision 108); the test plan is then never planned.
              check = variantsLib.unitsCheck {
                inherit pkgs;
                name = "${wsName}-${triple}-${vName}-${v.mode}";
                units =
                  let
                    kinds = [ "build" ] ++ lib.optional (checkMode wsName vName v).allTargets "test";
                  in
                  if inst.delivery == "dynamic" then
                    map (k: inst.allUnits.${k}) kinds
                  else
                    lib.concatMap (k: lib.attrValues inst.units.${k}) kinds;
              };
            }
          ) vs;
          dflt =
            variants.${ws.defaultVariant}
              or (throw "breakbulk: workspaces.${wsName}.defaultVariant `${ws.defaultVariant}` is not one of its variants (${lib.concatStringsSep ", " (lib.attrNames ws.variants)})");
          benchVariants = lib.attrNames (lib.filterAttrs (_: v: v.benches) ws.variants);
          benchVariant =
            if ws.variants.${ws.defaultVariant}.benches or false then
              ws.defaultVariant
            else if lib.length benchVariants == 1 then
              lib.head benchVariants
            else
              null;
          s = specFor wsName triple;
        in
        {
          inherit variants;
          benches =
            if benchVariant != null then
              variants.${benchVariant}.benches
            else if benchVariants == [ ] then
              { }
            else
              throw "breakbulk: workspaces.${wsName}: several variants have benches (${lib.concatStringsSep ", " benchVariants}) and the default variant does not; use target.<triple>.variants.<v>.benches";
          benchRuns = if benchVariant != null then variants.${benchVariant}.benchRuns else { };
          namedBenchRuns = if benchVariant != null then variants.${benchVariant}.namedBenchRuns else { };
          inherit (dflt)
            packages
            tests
            testRuns
            namedTestRuns
            testApps
            doctests
            ;
          # The target spec's runner (a list: program and arguments, or
          # null) and test system, as test runs use them.
          inherit (s) runner testSystem;
          # The resolved target spec of this workspace (the evaluated
          # `targets.<triple>` options), or null when it has none.
          spec = targetCfgOf wsName triple;
        }
      ) instances;
    in
    {
      inherit instances;
      target = perTarget;
      packages = perTarget.${nativeTriple}.packages or { };
      tests = perTarget.${nativeTriple}.tests or { };
      testRuns = perTarget.${nativeTriple}.testRuns or { };
      plans = lib.mapAttrs (_: lib.mapAttrs (_: inst: inst.plans)) instances;
      devShell = mkDevShell {
        inherit pkgs nativeTriple;
        name = wsName;
        inherit (ws) toolchain;
        inherit (ws.devShell) setTarget;
        overrides = lib.filter (o: o != null) (map overrideFor locks.${wsName});
        targetEnv = envStrings (targetField wsName nativeTriple "env" { });
        # How the planner passes the native spec to Cargo (IFD: a small
        # derivation that reads the project's Cargo config and asks rustc,
        # apart from planning, so a broken manifest does not break the
        # shell; decision 81). The file names tool paths without their
        # context; the spec's own values carry it.
        cargoEnv =
          let
            inst = instances.${nativeTriple}.${ws.defaultVariant} or null;
            spec = (specFor wsName nativeTriple).mkWorkspace.spec or null;
            values = lib.filter builtins.isString (
              if spec == null then
                [ ]
              else
                [
                  spec.linker
                  spec.hostLinker
                ]
                ++ spec.rustflags
            );
            withContext = builtins.replaceStrings (map builtins.unsafeDiscardStringContext values) values;
            j = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${inst.cargoEnv}/cargo-env.json"));
          in
          if inst == null then
            { }
          else
            j // { env = lib.mapAttrs (_: withContext) j.env; };
      };
    };

  workspaces = lib.mapAttrs workspaceOut cfg.workspaces;

  # repo.checks, for the default variant of every workspace and target:
  # every product that built something (`build`) and its checks; every
  # enabled test run (`test-<name>`, named as in `tests`) and doctest.
  checks = lib.concatMapAttrs (
    wsName: w:
    lib.concatMapAttrs (
      triple: t:
      lib.concatMapAttrs (
        pkg: p:
        # Dynamic-derivation mode cannot tell at evaluation time whether a
        # product whose roots all have required features was built
        # (lib/products.nix `uncertain`): its check builds the roots Cargo
        # built and logs the others.
        if p.uncertain or false then
          { "${wsName}/${triple}/${pkg}/build" = p.buildCheck; }
        else
          lib.optionalAttrs (p.unbuilt == [ ] || lib.length p.unbuilt < lib.length (lib.attrNames p.roots)) (
            {
              "${wsName}/${triple}/${pkg}/build" = p;
            }
            // lib.mapAttrs' (n: c: lib.nameValuePair "${wsName}/${triple}/${pkg}/${n}" c) (p.checks or { })
          )
      ) t.packages
      // lib.concatMapAttrs (
        pkg: rs: lib.mapAttrs' (n: d: lib.nameValuePair "${wsName}/${triple}/${pkg}/test-${n}" d) rs.enabled
      ) t.namedTestRuns
      // lib.mapAttrs' (pkg: d: lib.nameValuePair "${wsName}/${triple}/${pkg}/doctest" d) t.doctests
      // lib.optionalAttrs cfg.workspaces.${wsName}.benchSmoke (
        lib.concatMapAttrs (
          pkg: rs: lib.mapAttrs' (n: d: lib.nameValuePair "${wsName}/${triple}/${pkg}/bench-${n}" d) rs.enabled
        ) t.namedBenchRuns
      )
      // lib.concatMapAttrs (
        vName: v: lib.optionalAttrs (v ? check) { "${wsName}/${triple}/variant-${vName}/check" = v.check; }
      ) t.variants
    ) w.target
  ) workspaces;

  # --- warnings and mode -----------------------------------------------------

  warnings = cfg.warnings ++ unmatchedWarnings;
  warned = x: lib.foldr (w: acc: lib.warn w acc) x warnings;
  # `mode = "auto"`: dynamic-derivation mode when the evaluator has
  # `builtins.outputOf` and is Nix 2.36 or later (lib/dynamic.nix).
  delivery = dynamic.resolveMode cfg.mode;
  guard = warned;

  # --- explainSharing --------------------------------------------------------
  #
  #   repo.explainSharing {
  #     a = repo.workspaces.one.plans.x86_64-unknown-linux-gnu.default.build;
  #     b = "two/x86_64-unknown-linux-gnu/default/build";   # or { workspace; target; variant; kind; }
  #     package = "shared";      # or null (the default): every unit
  #   }
  #
  # pairs the package's units in the two plans (by kind, crate name, crate
  # types, platform and test mode) and, for each pair, says whether the
  # unit derivations are the same and, when not, which fields of the
  # rendered units differ: argv (as added and removed arguments), env, cwd,
  # the env capture, and which dependency units differ. Store paths are
  # compared with their hashes removed, so a field that differs only by a
  # dependency's store path shows up under `deps` and not as its own
  # reason. Unit keys (`-C metadata`) are never compared: they leave out
  # rustflags (spike A, S13). `.text` is a readable report.
  #
  # In dynamic-derivation mode it reads the unit derivations through IFD
  # mode (importing units.json, which builds breakbulk-instantiate and the
  # plans): they are the same derivations the outer derivation writes,
  # except units downstream of an embedded product, which IFD mode
  # describes as IFD mode would build them.

  discard = builtins.unsafeDiscardStringContext;
  planIndex = lib.concatMapAttrs (
    wsName: w:
    lib.concatMapAttrs (
      triple: vs:
      lib.concatMapAttrs (
        vName: inst:
        lib.mapAttrs' (
          kind: plan:
          lib.nameValuePair (discard plan.outPath) {
            inherit inst kind;
            label = "${wsName}/${triple}/${vName}/${kind}";
          }
        ) inst.plans
      ) vs
    ) w.instances
  ) workspaces;

  resolvePlan =
    h:
    let
      fromParts =
        {
          workspace,
          target ? nativeTriple,
          variant ? cfg.workspaces.${workspace}.defaultVariant,
          kind ? "build",
        }:
        {
          inst =
            workspaces.${workspace}.instances.${target}.${variant}
              or (throw "breakbulk: explainSharing: no plan ${workspace}/${target}/${variant}");
          inherit kind;
          label = "${workspace}/${target}/${variant}/${kind}";
        };
    in
    if builtins.isString h then
      let
        ps = lib.splitString "/" h;
        n = lib.length ps;
      in
      fromParts (
        {
          workspace = lib.elemAt ps 0;
        }
        // lib.optionalAttrs (n > 1) { target = lib.elemAt ps 1; }
        // lib.optionalAttrs (n > 2) { variant = lib.elemAt ps 2; }
        // lib.optionalAttrs (n > 3) { kind = lib.elemAt ps 3; }
      )
    else if h ? outPath then
      planIndex.${discard h.outPath} or (throw "breakbulk: explainSharing: ${discard h.outPath} is not a plan of this repository")
    else
      fromParts h;

  readPlanOf =
    r: builtins.fromJSON (discard (builtins.readFile "${r.inst.plans.${r.kind}}/plan.json"));

  pkgNameOf =
    id:
    let
      frag = lib.last (lib.splitString "#" id);
      at = builtins.match "([^@]+)@(.*)" frag;
      url = lib.head (lib.splitString "?" (lib.head (lib.splitString "#" id)));
    in
    if at != null then lib.head at else lib.last (lib.splitString "/" (lib.removeSuffix "/" url));

  isTestUnit = u: lib.elem "--test" (lib.filter builtins.isString (u.args or [ ]));
  unitLabel =
    u:
    if u.kind == "run" then
      "${pkgNameOf u.package} build-script run (${u.platform})"
    else
      "${pkgNameOf u.package} ${u.crate.name} [${lib.concatStringsSep "," u.crate.types}]${lib.optionalString (isTestUnit u) " test"} (${u.platform})";

  # Units of one plan, by label, for one package (or all, when null).
  labelled =
    plan: pkg:
    let
      ids = lib.filter (id: pkg == null || pkgNameOf plan.units.${id}.package == pkg) (lib.attrNames plan.units);
      groups = lib.groupBy (id: unitLabel plan.units.${id}) ids;
    in
    lib.concatMapAttrs (
      l: is:
      if lib.length is == 1 then
        { ${l} = lib.head is; }
      else
        lib.listToAttrs (lib.imap0 (i: id: lib.nameValuePair "${l} #${toString i}" id) (lib.sort (a: b: a < b) is))
    ) groups;

  # Unit ids a plan unit refers to (its dependencies, its script, its runs).
  refsOf =
    v:
    if builtins.isAttrs v then
      (if v ? out then [ v.out ] else [ ]) ++ (if v ? splice then [ v.splice ] else [ ]) ++ lib.concatMap refsOf (lib.attrValues v)
    else if builtins.isList v then
      lib.concatMap refsOf v
    else
      [ ];

  noHash =
    s:
    lib.concatStrings (
      map (p: if builtins.isString p then p else "${builtins.storeDir}/…-") (
        builtins.split "${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-" s
      )
    );
  normalize =
    v:
    if builtins.isString v then
      noHash v
    else if builtins.isList v then
      map normalize v
    else if builtins.isAttrs v then
      lib.mapAttrs (_: normalize) v
    else
      v;

  renderedOf =
    drv:
    let
      u = drv.drvAttrs.BREAKBULK_UNIT or null;
    in
    if u == null then { } else builtins.fromJSON (discard u);

  listDiff = a: b: {
    onlyA = lib.filter (x: !(lib.elem x b)) a;
    onlyB = lib.filter (x: !(lib.elem x a)) b;
    sameElementsOtherOrder = a != b && lib.sort lib.lessThan (map builtins.toJSON a) == lib.sort lib.lessThan (map builtins.toJSON b);
  };
  attrDiff =
    a: b:
    lib.filterAttrs (_: x: x != null) (
      lib.genAttrs (lib.unique (lib.attrNames a ++ lib.attrNames b)) (
        k:
        if (a.${k} or null) == (b.${k} or null) then
          null
        else
          {
            a = a.${k} or null;
            b = b.${k} or null;
          }
      )
    );

  fieldDiffs =
    ra: rb:
    let
      a = normalize ra;
      b = normalize rb;
      fields = lib.unique (lib.attrNames a ++ lib.attrNames b);
      one =
        f:
        let
          x = a.${f} or null;
          y = b.${f} or null;
        in
        if x == y then
          null
        else if f == "args" && builtins.isList x && builtins.isList y then
          listDiff x y
        else if builtins.isAttrs x && builtins.isAttrs y then
          attrDiff x y
        else
          {
            a = x;
            b = y;
          };
    in
    lib.filterAttrs (_: d: d != null) (lib.genAttrs fields one);

  explainSharing =
    {
      a,
      b,
      package ? null,
    }:
    let
      what = if package == null then "all packages" else package;
      ra = resolvePlan a;
      rb = resolvePlan b;
      pa = readPlanOf ra;
      pb = readPlanOf rb;
      # In dynamic-derivation mode the unit derivations are not known at
      # evaluation time; IFD mode's are the same derivations (except
      # downstream of an embedded product), so they are read through it.
      unitsOf = r: if r.inst.delivery == "dynamic" then r.inst.ifdUnits.${r.kind} else r.inst.units.${r.kind};
      ua = unitsOf ra;
      ub = unitsOf rb;
      la = labelled pa package;
      lb = labelled pb package;
      allA = labelled pa null;
      allB = labelled pb null;
      revA = lib.mapAttrs' (l: id: lib.nameValuePair id l) allA;
      revB = lib.mapAttrs' (l: id: lib.nameValuePair id l) allB;
      labels = lib.sort (x: y: x < y) (lib.unique (lib.attrNames la ++ lib.attrNames lb));
      pair =
        l:
        let
          ia = la.${l} or null;
          ib = lb.${l} or null;
        in
        if ia == null || ib == null then
          {
            unit = l;
            same = false;
            onlyIn = if ia == null then rb.label else ra.label;
          }
        else
          let
            da = ua.${ia};
            db = ub.${ib};
            same = da.drvPath == db.drvPath;
            depsA = lib.unique (map (r: revA.${r} or r) (refsOf pa.units.${ia}));
            depsB = lib.unique (map (r: revB.${r} or r) (refsOf pb.units.${ib}));
            depDiff = lib.filter (
              dl:
              let
                x = allA.${dl} or null;
                y = allB.${dl} or null;
              in
              x == null || y == null || ua.${x}.drvPath != ub.${y}.drvPath
            ) (lib.unique (depsA ++ depsB));
          in
          {
            unit = l;
            inherit same;
            drvA = da.drvPath;
            drvB = db.drvPath;
          }
          // lib.optionalAttrs (!same) {
            fields = fieldDiffs (renderedOf da) (renderedOf db);
            deps = depDiff;
          };
      units = map pair labels;
      show = v: builtins.toJSON v;
      fieldText =
        f: d:
        if d ? onlyA then
          "    ${f}: only in a: ${show d.onlyA}\n    ${f}: only in b: ${show d.onlyB}\n"
          + lib.optionalString d.sameElementsOtherOrder "    ${f}: same elements, different order\n"
        else if d ? a then
          "    ${f}: a = ${show d.a}\n    ${f}: b = ${show d.b}\n"
        else
          lib.concatStrings (lib.mapAttrsToList (k: x: "    ${f}.${k}: a = ${show x.a}, b = ${show x.b}\n") d);
      unitText =
        u:
        if u ? onlyIn then
          "  ${u.unit}: only in ${u.onlyIn}\n"
        else if u.same then
          "  ${u.unit}: shared (${u.drvA})\n"
        else
          "  ${u.unit}: differs\n"
          + lib.concatStrings (lib.mapAttrsToList fieldText u.fields)
          + lib.optionalString (u.deps != [ ]) "    dependencies that differ: ${lib.concatStringsSep "; " u.deps}\n";
    in
    {
      inherit package units;
      a = ra.label;
      b = rb.label;
      shared = lib.all (u: u.same) units;
      text =
        "explainSharing ${what}: a = ${ra.label}, b = ${rb.label}\n"
        + (if units == [ ] then "  no units of ${what} in either plan\n" else lib.concatMapStrings unitText units);
    };
in
{
  workspaces = guard workspaces;
  checks = guard checks;
  sources = fetch.byName (fetch.sourcesFor (lockfile.merge (lib.attrValues locks)));
  inherit explainSharing warnings;
  inherit (eval) config options;
  optionsDoc = pkgs.nixosOptionsDoc {
    options = removeAttrs eval.options [
      "_module"
      "warnings"
    ];
    warningsAreErrors = false;
    # Declarations as paths in breakbulk's repository (docs/options.md links
    # them from docs/), not store paths.
    transformOptions =
      opt:
      opt
      // {
        declarations = map (
          d:
          let
            parts = lib.splitString "/lib/" (toString d);
            rel = "lib/${lib.last parts}";
          in
          if lib.length parts > 1 then
            {
              name = rel;
              url = "../${rel}";
            }
          else
            d
        ) opt.declarations;
      };
  };
}
