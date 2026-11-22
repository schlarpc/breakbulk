# mkRepository: the module-system entry point
# (docs/src/explanation/internals/nix-library.md).
#
#   repo = breakbulk.mkRepository {
#     inherit pkgs;
#     root = ./.;
#     modules = [ ./nix/rust.nix ];
#   };
#
# It evaluates breakbulk's options (lib/modules, the curated -sys
# defaults included) with the user's modules, then makes one
# mkWorkspace call per (workspace, target, variant). Outputs:
#
#   repo.workspaces.<ws>.packages.<pkg>                  default target (defaultTarget), default variant
#   repo.workspaces.<ws>.tests.<pkg>.<test>              the same, test binaries
#   repo.workspaces.<ws>.target.<triple>.packages.<pkg>
#   repo.workspaces.<ws>.target.<triple>.tests.<pkg>.<test>
#   repo.workspaces.<ws>.target.<triple>.variants.<v>.{packages,tests}
#   repo.workspaces.<ws>.plans.<triple>.<v>.{build,test,doc}  the plan derivations
#   repo.workspaces.<ws>.devShell
#   repo.workspaces.<ws>.toolchain.{rustc,cargo,clippy,rustfmt}   resolved
#   repo.workspaces.<ws>.instances.<triple>.<v>           the mkWorkspace results
#   repo.workspaces.<ws>.vendor.{dir,configFile,cargoHome}  the locked
#                                                         dependencies, vendored
#   repo.checks."<ws>/<triple>/<pkg>/<name>"              flattened
#   repo.apps."<ws>/<triple>/<pkg>/test-<name>"           every test app, flake app shape
#   repo.sources.<crate> / ."<crate>@<version>"           fetched crate sources
#   repo.explainSharing { a; b; package; }                why units differ (lib/explain-sharing.nix)
#   repo.config, repo.options                             the evaluated modules
#   repo.optionsDoc                                       nixosOptionsDoc of them
#   repo.nixFeatures                                      the Nix features this evaluation may use
#
#   repo.workspaces.<ws>.target.<triple>.testRuns.<pkg>.<test>   test runs
#   repo.workspaces.<ws>.target.<triple>.testApps.<pkg>.<binary>  test apps (`nix run`)
#   repo.workspaces.<ws>.target.<triple>.doctests.<pkg>
#   repo.workspaces.<ws>.docs                          the default target's, or null
#   repo.workspaces.<ws>.target.<triple>.docs          `cargo doc`'s folder
#                                                      (also per variant)
#   repo.workspaces.<ws>.target.<triple>.buildScriptPaths.{build,test}
#                                                      the plans' checks of
#                                                      missing build-script
#                                                      paths (also per variant)
#   repo.workspaces.<ws>.target.<triple>.spec          the resolved target spec
#   repo.workspaces.<ws>.target.<triple>.traits        the target's traits
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
# repo.checks: for each build or coverage variant with `checks = true`,
# `<pkg>/build` (the product), `<pkg>/<check>` (its checks),
# `<pkg>/test-<name>` and `<pkg>/doctest` (enabled test runs and
# doctests), `buildScriptPaths/{build,test}` (the plans' checks), under
# `<ws>/<triple>/` for the default variant and `<ws>/<triple>/variant-<v>/`
# for the others; check and clippy variants as
# `<ws>/<triple>/variant-<v>/check` and `…/buildScriptPaths/<plan>`.
# A variant with `docs.check` (any mode) adds its docs as `docs` under its
# prefix.
# Every proper prefix of those names,
# `all` and each of `checkGroups` is also a check: an aggregate of the
# checks it selects (lib/check-groups.nix).
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
  mkVendor,
  defaultTools,
  mkWorkspace,
  dynamic,
  products,
  buildScriptPaths,
  variantsLib,
  presets,
  targetTraits,
  toolchainFacts,
  featureGates,
  # The whole library (lib/default.nix), for modules' `breakbulk` argument.
  breakbulkLib,
}:
let
  versionReq = import ./modules/version-req.nix { inherit lib; };
  bt = import ./modules/types.nix { inherit lib; };
  bbModules = import ./modules;
  mkDevShell = import ./devshell.nix { inherit lib util; };
  mkExplainSharing = import ./explain-sharing.nix { inherit lib featureGates; };
in
{
  pkgs,
  root,
  modules ? [ ],
  specialArgs ? { },
  tools ? defaultTools pkgs,
}@args:
let
  userModules = args.modules or [ ];

  # `root` as a path value: `./.`, or a flake's `self` (or any string-like
  # value naming a store path, such as `self.outPath` or a filtered
  # `lib.fileset.toSource` result, which keeps repository files out of a
  # root-level crate's source view). lib.fileset takes
  # only paths, so a store path string becomes the path of the same
  # location. That reads the tree in place: source views copy only their
  # filtered subsets, as from `./.`.
  root = util.rootPath args.root;

  eval = lib.evalModules {
    modules = bbModules ++ userModules ++ [ projectAssertions ];
    # Module arguments: `pkgs`; `root` (the repository root, a path), for
    # reading project files; `repo` (the result, below), for products used
    # as inputs; `breakbulk` (the library: presets, stage helpers, xwinSdk);
    # `projectBuildTarget` and `targetsDefaultTarget` (below). The
    # caller's specialArgs win.
    specialArgs = {
      inherit
        pkgs
        root
        projectBuildTarget
        targetsDefaultTarget
        ;
      repo = result;
      breakbulk = breakbulkLib;
      breakbulkPresets = presets;
    }
    // specialArgs;
  };
  cfg = eval.config;

  # Checks of the options against the project's files (lockfiles,
  # manifests), which the modules do not read. A module rather than a
  # list `guard` adds, so that `repo.config.assertions` holds them with
  # the modules' own.
  projectAssertions = {
    _file = ./repository.nix;
    config.assertions = binaryKeyAssertions;
  };

  # The project's `build.target` for a workspace path, by the planner's
  # config-file rule (breakbulk-plan --build-target-only; IFD), as a list
  # of the values as written, or null. Without any config file, null with
  # no derivation.
  projectBuildTarget =
    path:
    let
      wsDir = util.normalizeRel path;
      drv = breakbulkLib.mkBuildTarget pkgs {
        configSkeleton = breakbulkLib.skeleton.mkConfigSkeleton pkgs { inherit root wsDir; };
        inherit wsDir tools;
        name = "breakbulk-build-target";
      };
    in
    if breakbulkLib.skeleton.configFiles { inherit root wsDir; } == [ ] then
      null
    else
      (builtins.fromJSON (
        featureGates.readOutput nixFeatures
          "the default of `defaultTarget` for the workspace at `${wsDir}` (its Cargo config's `build.target`)"
          "${drv}/build-target.json"
      )).buildTarget;

  # `defaultTarget`'s default from the workspace's `targets` alone: the
  # native triple when it is one of them, else the only one, else null
  # (then the project's `build.target` decides, `projectBuildTarget`).
  targetsDefaultTarget =
    ts:
    if lib.elem nativeTriple ts then
      nativeTriple
    else if lib.length ts == 1 then
      lib.head ts
    else
      null;

  nativeTriple = targetTraits.nativeTriple pkgs;

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
  vendors = lib.mapAttrs (
    wsName: _:
    mkVendor pkgs {
      inherit fetch;
      entries = locks.${wsName};
    }
  ) cfg.workspaces;
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

  unmatchedWarnings = map (
    k:
    "breakbulk: `packages.${lib.strings.escapeNixIdentifier k}` matches no package in any workspace's Cargo.lock${
      lib.optionalString (
        cfg.packages.${k}.version != null
      ) " (version requirement `${cfg.packages.${k}.version}`)"
    }; it has no effect."
  ) (lib.filter (k: !(lib.any (overrideMatches k) allEntries)) (lib.attrNames cfg.packages));

  # `sourceOverlay` in any layer of a key that matches a registry or git
  # crate: such crates have no source view to place it in.
  overlayWarnings = lib.concatMap (
    k:
    let
      o = cfg.packages.${k};
      layers = [
        o
      ]
      ++ lib.attrValues o.target
      ++ lib.concatMap (v: [ v ] ++ lib.attrValues v.target) (lib.attrValues o.variant);
      fetched = lib.unique (
        map (e: "${e.name} ${e.version}") (
          lib.filter (e: e.source or null != null && overrideMatches k e) allEntries
        )
      );
    in
    lib.optional (lib.any (l: l.sourceOverlay != { }) layers && fetched != [ ])
      "breakbulk: `packages.${lib.strings.escapeNixIdentifier k}.sourceOverlay` has no effect on ${lib.concatStringsSep ", " fetched}: registry and git crates have no source view; it applies to workspace packages only."
  ) (lib.attrNames cfg.packages);

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

  emptySide = {
    env = { };
    nativeInputs = _: [ ];
    inputs = _: [ ];
  };
  emptyOverride = emptySide // {
    extraSources = [ ];
    buildScriptPaths.allow = [ ];
    forHost = emptySide;
    forTarget = emptySide;
  };
  catFn =
    f: g: p:
    f p ++ g p;
  mergeSide = a: b: {
    env = a.env // b.env;
    nativeInputs = catFn a.nativeInputs b.nativeInputs;
    inputs = catFn a.inputs b.inputs;
  };
  mergeOverride =
    a: b:
    mergeSide a b
    // {
      extraSources = a.extraSources ++ b.extraSources;
      buildScriptPaths.allow = a.buildScriptPaths.allow ++ b.buildScriptPaths.allow;
      forHost = mergeSide a.forHost b.forHost;
      forTarget = mergeSide a.forTarget b.forTarget;
    };

  # A single-valued setting at `path` across settings blocks, lowest layer
  # first: the definition of the highest priority (`priorityOf`), and of
  # those the last, most specific layer's; `default` without blocks. As if
  # the blocks were one module with each layer's priorities moved up a
  # little, as variant layers are (`layer` in lib/modules/types.nix).
  pickSingle =
    default: path: blocks:
    (lib.foldl'
      (
        acc: b:
        let
          p = b.priorityOf path;
        in
        if p <= acc.prio then
          {
            prio = p;
            value = lib.getAttrFromPath path b;
          }
        else
          acc
      )
      {
        prio = 9999;
        value = default;
      }
      blocks
    ).value;

  # The attribute set at `path` (`[ "env" ]`) across settings blocks, each
  # attribute picked by `pickSingle` from the blocks that set it. Its
  # names are known without any priority or value: an env value can be a
  # product of the plan whose instantiation lists the names.
  pickAttrs =
    path: blocks:
    lib.mapAttrs (
      n: _: pickSingle null (path ++ [ n ]) (lib.filter (b: lib.getAttrFromPath path b ? ${n}) blocks)
    ) (lib.foldl' (acc: b: acc // lib.getAttrFromPath path b) { } blocks);

  # The attribute set at `path` (`[ "stages" ]`) of each settings block,
  # keeping only the attributes no other block sets at a higher priority.
  # Those left merge in layer order as before, so a stage's fields still
  # combine across layers of equal priority.
  keepHighestPrio =
    path: blocks:
    let
      setsOf = b: lib.getAttrFromPath path b;
      best = lib.zipAttrsWith (_: lib.foldl' lib.min 9999) (
        map (b: lib.mapAttrs (n: _: b.priorityOf (path ++ [ n ])) (setsOf b)) blocks
      );
    in
    map (b: lib.filterAttrs (n: _: b.priorityOf (path ++ [ n ]) <= best.${n}) (setsOf b)) blocks;

  # The package settings of one lockfile entry of workspace `wsName` in
  # the plans of variant `vName` on `triple`, as a list of
  # `packages.<name>`-shaped layers, lowest first: the curated defaults
  # (`sysDefaults.packages`), for a path package those of the crates it
  # depends on for their dependents (`sysDefaults.dependents`), the
  # workspace's `memberDefaults` for its path packages, then each matching
  # `packages` key; each followed by its own
  # `target.<triple>`, `variant.<v>` and `variant.<v>.target.<triple>`.
  layersFor =
    wsName: triple: vName: e:
    let
      sys = cfg.sysDefaults.packages.${e.name} or null;
      onTriple = l: [ l ] ++ lib.optional (l.target ? ${triple}) l.target.${triple};
      withTriple = l: onTriple l ++ lib.optionals (l.variant ? ${vName}) (onTriple l.variant.${vName});
      # The curated defaults name nixpkgs libraries: on a target without
      # a package set, only its host units (the build machine's set) get
      # them.
      hostOnly =
        l:
        l
        // emptySide
        // {
          forHost = mergeSide l l.forHost;
          forTarget = emptySide;
          # A `forHost.env` variable that came from `env` has its priority.
          priorityOf =
            path:
            if
              lib.take 2 path == [
                "forHost"
                "env"
              ]
              && lib.length path == 3
              && !(l.forHost.env ? ${lib.last path})
            then
              l.priorityOf [
                "env"
                (lib.last path)
              ]
            else
              l.priorityOf path;
        };
    in
    let
      curatedLayers =
        l:
        let
          ls = withTriple l;
        in
        if packageSetOf wsName triple != null then ls else map hostOnly ls;
    in
    lib.optionals (sys != null) (curatedLayers (sys e))
    ++ lib.optionals (e.source or null == null) (
      lib.concatMap (d: curatedLayers (cfg.sysDefaults.dependents.${d.name} d)) (
        curatedDeps wsName e.name
      )
    )
    ++ lib.optionals (e.source or null == null) (withTriple cfg.workspaces.${wsName}.memberDefaults)
    ++ lib.concatMap (k: withTriple cfg.packages.${k}) (
      lib.filter (k: overrideMatches k e) orderedKeys
    );

  # The lockfile entries of workspace `wsName` that `pkg` depends on, by
  # any kind of dependency and transitively, and that have curated
  # settings for their dependents (`sysDefaults.dependents`), sorted by
  # name. Cargo.lock names a dependency `<name>` or `<name> <version>
  # [(<source>)]`; every entry of the name counts.
  curatedDeps =
    wsName: pkg:
    let
      entries = locks.${wsName};
      byName = lib.groupBy (e: e.name) entries;
      reached = builtins.genericClosure {
        startSet = [ { key = pkg; } ];
        operator =
          x:
          map (d: { key = lib.head (lib.splitString " " d); }) (
            lib.concatMap (e: e.dependencies or [ ]) (byName.${x.key} or [ ])
          );
      };
      names = lib.filter (n: n != pkg && cfg.sysDefaults.dependents.${n} or null != null) (
        lib.sort lib.lessThan (map (x: x.key) reached)
      );
    in
    lib.concatMap (n: byName.${n}) names;

  # The merged override for one lockfile entry, or null. Each env
  # variable is `pickAttrs`'s.
  overrideFor =
    wsName: triple: vName: e:
    let
      ls = layersFor wsName triple vName e;
      m = lib.foldl' mergeOverride emptyOverride ls;
      envAt = side: m.${side} // { env = pickAttrs [ side "env" ] ls; };
    in
    if ls == [ ] then
      null
    else
      m
      // {
        env = pickAttrs [ "env" ] ls;
        forHost = envAt "forHost";
        forTarget = envAt "forTarget";
      };

  envStrings = lib.mapAttrs (_: bt.envString);
  # Test-run env: a function of the run stays one (lib/test-runs.nix
  # resolveTestEnv applies it).
  testEnvStrings = lib.mapAttrs (_: bt.testEnvString);

  # The layers of a workspace's path package `pkg`.
  memberLayers =
    wsName: triple: vName: pkg:
    let
      e = lib.findFirst (e: e.name == pkg && e.source or null == null) null locks.${wsName};
    in
    if e == null then [ ] else layersFor wsName triple vName e;

  # Product settings for mkProducts: each layer's stages and checks, but
  # those another layer sets at a higher priority.
  productConfig =
    wsName: triple: vName: pkg:
    let
      ls = memberLayers wsName triple vName pkg;
    in
    lib.zipListsWith (stages: checks: { inherit stages checks; }) (keepHighestPrio [ "stages" ] ls) (
      keepHighestPrio [ "checks" ] ls
    );

  # The layers' `test`, `scopeTargetRoots`, `predictSources`, `sources` and `sourceOverlay` settings merged, for
  # mkWorkspace's `packages`: `{ <pkg> = { test = …; sources = …; }; }` for the
  # workspace's path packages. Lists and snippets combine, in layer order;
  # single values are `pickSingle`'s, env variables `pickAttrs`'.
  memberConfigs =
    wsName: triple: vName:
    let
      members = lib.unique (map (e: e.name) (lib.filter (e: e.source or null == null) locks.${wsName}));
      joinLines =
        a: b:
        if a == "" then
          b
        else if b == "" then
          a
        else
          a + "\n" + b;
      mergeTest = a: b: {
        path = a.path ++ b.path;
        args = a.args ++ b.args;
        sourceScope = lib.unique (a.sourceScope ++ b.sourceScope);
        postRun = joinLines a.postRun b.postRun;
        # Several matching keys: the union of their lists.
        runFiles =
          if b.runFiles == null then
            a.runFiles
          else if a.runFiles == null then
            b.runFiles
          else
            lib.unique (a.runFiles ++ b.runFiles);
        binaries =
          lib.zipAttrsWith
            (
              _:
              lib.foldl'
                (x: y: {
                  args = x.args ++ y.args;
                  postRun = joinLines x.postRun y.postRun;
                })
                {
                  args = [ ];
                  postRun = "";
                }
            )
            [
              a.binaries
              b.binaries
            ];
        doctest = {
          args = a.doctest.args ++ b.doctest.args;
          postRun = joinLines a.doctest.postRun b.doctest.postRun;
        };
      };
      empty = {
        path = [ ];
        args = [ ];
        sourceScope = [ ];
        binaries = { };
        doctest = {
          args = [ ];
          postRun = "";
        };
        runFiles = null;
        postRun = "";
      };
      merged =
        ls:
        let
          t = lib.foldl' (acc: l: mergeTest acc l.test) empty ls;
          single = default: path: pickSingle default ([ "test" ] ++ path) ls;
        in
        t
        // {
          scopeTestsDir = single null [ "scopeTestsDir" ];
          workspaceManifest = single null [ "workspaceManifest" ];
          runner = single null [ "runner" ];
          stripForRun = single null [ "stripForRun" ];
          wrapper = single null [ "wrapper" ];
          keepLog = single null [ "keepLog" ];
          nextest = lib.genAttrs [ "profile" "configFile" "package" ] (
            n:
            single null [
              "nextest"
              n
            ]
          );
          env = testEnvStrings (pickAttrs [ "test" "env" ] ls);
          doctest =
            let
              ds = map (l: l.test.doctest) ls;
            in
            t.doctest
            // {
              env = testEnvStrings (pickAttrs [ "env" ] ds);
              enable = pickSingle true [ "enable" ] ds;
            };
          binaries = lib.mapAttrs (
            k: b:
            let
              bs = map (l: l.test.binaries.${k}) (lib.filter (l: l.test.binaries ? ${k}) ls);
            in
            b
            // {
              env = testEnvStrings (pickAttrs [ "env" ] bs);
              enable = pickSingle true [ "enable" ] bs;
              wrapper = pickSingle null [ "wrapper" ] bs;
            }
          ) t.binaries;
        };
      withDefaults =
        t:
        t
        // {
          nextest = t.nextest // {
            configFile =
              if t.nextest.configFile == null then
                breakbulkLib.testRuns.nextestDefaultConfig {
                  inherit root;
                  wsDir = wsDirOf cfg.workspaces.${wsName};
                }
              else
                t.nextest.configFile;
          };
        };
    in
    lib.genAttrs members (
      pkg:
      let
        ls = memberLayers wsName triple vName pkg;
      in
      {
        test = withDefaults (merged ls);
        scopeTargetRoots = pickSingle null [ "scopeTargetRoots" ] ls;
        predictSources = {
          enable = pickSingle null [ "predictSources" "enable" ] ls;
          buildScriptRuns = pickSingle null [ "predictSources" "buildScriptRuns" ] ls;
          keep = lib.concatMap (l: l.predictSources.keep) ls;
        };
        sources = lib.concatMap (l: l.sources) ls;
        # Later layers win per path, as for env.
        sourceOverlay = lib.foldl' (acc: l: acc // l.sourceOverlay) { } ls;
      }
    );

  # --- test binary keys --------------------------------------------------------
  #
  # The keys of `test.binaries` (lib/test-runs.nix `binaryKey`), by
  # workspace and package, from the test roots predicted from the
  # manifests (or listed in `roots.test`). Every plan of a workspace has
  # its members' roots, whatever its target, variant or package selection
  # (Cargo's skipped ones, such as an unmet `required-features`, as stubs;
  # a root the plan has and the prediction does not is an instantiation
  # error), and an outside package's when it selects one, so one check
  # covers them all, at evaluation, without planning, in both delivery
  # modes.
  testBinaryKeys = lib.mapAttrs (
    _: ws:
    let
      predicted = breakbulkLib.planRoots {
        # Path packages outside the workspace too: a selection can name
        # one, and its test binaries are then the plan's.
        workspaceRoots =
          let
            wsDir = wsDirOf ws;
            members = breakbulkLib.roots.workspaceRoots { inherit root wsDir; };
          in
          breakbulkLib.skeleton.outsideRoots { inherit root wsDir; } // members;
        planKind = "test";
        variant = "";
        names = ws.roots.test;
      };
    in
    lib.mapAttrs (_: rs: lib.sort lib.lessThan (map breakbulkLib.testRuns.binaryKey rs)) (
      lib.groupBy (r: r.package) (lib.filter (r: r.test) predicted.roots)
    )
  ) cfg.workspaces;

  # A `test.binaries` key that names no test binary is an error: the
  # settings are looked up by key, so a misspelt one would leave enabled
  # what the user turned off. `option` is the module option holding the
  # setting (for the files that set a key), `path` the setting's path
  # within it, `name` its name in messages, `owner` what `known` are the
  # test binaries of.
  unknownBinaryKeys =
    {
      option,
      path,
      name,
      keys,
      known,
      owner,
    }:
    let
      unknown = lib.filter (k: !(lib.elem k known)) keys;
      files = lib.unique (
        lib.concatMap (
          k:
          map (d: d.file) (
            lib.filter (
              d:
              lib.hasAttrByPath (
                path
                ++ [
                  "test"
                  "binaries"
                  k
                ]
              ) d.value
            ) option.definitionsWithLocations
          )
        ) unknown
      );
      quoted = ks: lib.concatMapStringsSep ", " (k: "`${k}`") ks;
    in
    lib.optional (unknown != [ ]) {
      assertion = false;
      message = "breakbulk: ${name}.test.binaries${bt.setIn { inherit files; }}: ${quoted unknown} ${
        if lib.length unknown == 1 then "names" else "name"
      } no test binary of ${owner}; ${
        if known == [ ] then "it has none" else "the test binaries are ${quoted known}"
      }";
    };

  # A setting and its `target.<triple>`, `variant.<v>` and
  # `variant.<v>.target.<triple>` layers, each with its path.
  withLayers =
    path: v:
    let
      sub =
        name: l:
        lib.mapAttrsToList (n: v: {
          path = l.path ++ [
            name
            n
          ];
          inherit v;
        }) l.v.${name};
      withTriples = l: [ l ] ++ sub "target" l;
    in
    withTriples { inherit path v; } ++ lib.concatMap withTriples (sub "variant" { inherit path v; });
  layerName = lib.concatMapStringsSep "." lib.strings.escapeNixIdentifier;

  binaryKeyAssertions = lib.concatLists (
    lib.mapAttrsToList (
      wsName: ws:
      let
        known = testBinaryKeys.${wsName};
        pathPackages = lib.filter (e: e.source or null == null) locks.${wsName};
      in
      # `packages.<name>`: the keys of each package it applies to.
      lib.concatMap (
        k:
        lib.concatMap (
          l:
          let
            keys = lib.attrNames l.v.test.binaries;
          in
          lib.optionals (keys != [ ]) (
            lib.concatMap (
              e:
              unknownBinaryKeys {
                option = eval.options.packages;
                inherit (l) path;
                name = "packages.${layerName l.path}";
                inherit keys;
                known = known.${e.name} or [ ];
                owner = "`${e.name}` in workspaces.${wsName}";
              }
            ) (lib.filter (overrideMatches k) pathPackages)
          )
        ) (withLayers [ k ] cfg.packages.${k})
      ) (lib.attrNames cfg.packages)
      # `memberDefaults`: the keys of any of the path packages.
      ++ lib.concatMap (
        l:
        let
          keys = lib.attrNames l.v.test.binaries;
        in
        lib.optionals (keys != [ ]) (unknownBinaryKeys {
          option = eval.options.workspaces;
          inherit (l) path;
          name = "workspaces.${layerName l.path}";
          inherit keys;
          known = lib.sort lib.lessThan (lib.unique (lib.concatMap (e: known.${e.name} or [ ]) pathPackages));
          owner = "any member of workspaces.${wsName}";
        })
      ) (withLayers [ wsName "memberDefaults" ] ws.memberDefaults)
    ) cfg.workspaces
  );
  # --- target specs, per workspace -------------------------------------------
  #
  # The spec of one workspace on one triple: the repository-wide
  # `targets.<triple>` and the workspace's own `workspaces.<ws>.targets.<triple>`
  # (both modules, lib/modules/target-spec.nix), evaluated together with the
  # workspace's toolchain, so a preset picks tools for that workspace's
  # rustc. `present` is false when neither defines anything but `packages`
  # and the triple has no default preset (`targetTraits.defaultPreset`):
  # such a target has no spec (the toolchain as Cargo finds it).
  specArgs = {
    inherit pkgs;
    breakbulkPresets = presets;
  }
  // specialArgs;
  evalTargetSpec =
    wsName: ws: triple:
    let
      repoDef = cfg.targets.${triple} or null;
      wsDef = ws.targets.${triple} or null;
      e = lib.evalModules {
        modules = [
          ./modules/target-spec.nix
        ]
        ++ lib.optional (repoDef != null) repoDef
        ++ lib.optional (wsDef != null) wsDef;
        specialArgs = specArgs // {
          name = triple;
          breakbulkToolchain = ws.toolchain;
        };
      };
      # Read-only options (`cEnv`) are computed from the others and always
      # defined, so they say nothing about whether the workspace set a spec.
      specOptions = lib.filter (o: !(o.readOnly or false)) (
        lib.collect lib.isOption (
          removeAttrs e.options [
            "_module"
            "packages"
            "tests"
            "products"
            "variantDefaults"
          ]
        )
      );
      selections = {
        packages = e.config.packages or null;
        tests = e.config.tests or true;
        products = e.config.products or true;
      };
    in
    {
      inherit (e) config;
      present =
        repoDef != null
        || (wsDef != null && lib.any (o: o.highestPrio < 1500) specOptions)
        || e.config.preset != null;
      selectionErrors = lib.concatLists (
        lib.mapAttrsToList (
          o: s:
          lib.optionals (builtins.isAttrs s) (
            map (
              m: "breakbulk: workspaces.${wsName}.targets.${triple}.${o}.exclude${bt.setIn e.options.${o}}: ${m}"
            ) (excludeOf ws s).errors
          )
        ) selections
      );
    }
    // lib.mapAttrs (_: resolveSelection ws) selections;
  targetSpecs = lib.mapAttrs (
    wsName: ws:
    lib.genAttrs (lib.unique (lib.attrNames ws.targets ++ [ nativeTriple ])) (evalTargetSpec wsName ws)
  ) cfg.workspaces;
  # The exclude form of a package selection (`{ exclude = [ … ]; }`) against
  # the workspace's members, and any selection with it resolved to the
  # members it leaves.
  excludeOf = ws: s: manifest.excludeMembers (lib.attrNames ws.members) s.exclude;
  resolveSelection = ws: s: if builtins.isAttrs s then (excludeOf ws s).selected else s;
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
  # The target's traits (lib/target-traits.nix): the triple's built-in ones
  # with `targets.<triple>.traits` (repository-wide and the workspace's)
  # merged over them. Every platform-dependent decision below reads these.
  traitsOf =
    wsName: triple:
    targetTraits.resolve {
      inherit triple;
      inherit (targetSpecs.${wsName}.${triple}.config) traits;
    };

  # The nixpkgs package set of a target's units, one rule for every use:
  # the target spec's `packageSet` (set by the presets,
  # `presetHelpers.targetPkgsFor`), else pkgs for the native triple, else null:
  # the target has none (msvc, wasm32-unknown-unknown), so its packages
  # cannot have library inputs.
  packageSetOf =
    wsName: triple:
    let
      p = targetField wsName triple "packageSet" null;
    in
    if p != null then
      p
    else if triple == nativeTriple then
      pkgs
    else
      null;
  # The package set a platform's env captures come from (envCapture.sets
  # derives the host and build sets from it): the target's; a target
  # without one has the build machine's, for its host units and its base
  # capture (the build machine's tools, no libraries).
  captureSetOf =
    wsName: triple:
    let
      p = packageSetOf wsName triple;
    in
    if p == null then pkgs else p;

  # --- toolchain specs ------------------------------------------------------
  #
  # A target's spec as mkWorkspace takes it: the planner's part (rustflags
  # and linkers, through `--config`), the env of each platform's units, the
  # store paths the plan will name, the target capture's package set, and
  # the runner.
  inherit (util) storePathsIn;
  specFor =
    wsName: triple:
    let
      t = targetCfgOf wsName triple;
      inherit (t) cEnv;
      str = v: if v == null then null else "${v}";
      linker = str t.linker;
      hostLinker = str t.host.linker;
      named =
        prefix: l: lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair "${prefix}-${toString i}" p) l);
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
      # What strips its test binaries for runs: the binutils of its
      # package set's C toolchain, for an ELF target.
      testObjcopy = breakbulkLib.testRuns.objcopyOf {
        inherit pkgs triple;
        traits = traitsOf wsName triple;
        packageSet = packageSetOf wsName triple;
      };
    in
    if t == null then
      {
        inherit testObjcopy;
        mkWorkspace = { };
        canRunTests = true;
        runner = null;
        testDylibPath = breakbulkLib.testRuns.dylibPathOf { traits = traitsOf wsName triple; };
        testSystem = null;
      }
    else
      {
        inherit testObjcopy;
        mkWorkspace = {
          spec = {
            inherit (t) rustflags;
            inherit linker hostLinker;
          };
          specTools =
            named "spec-linker" (
              lib.filter (x: x != null) [
                linker
                hostLinker
              ]
            )
            // named "spec-rustflags" (lib.concatMap storePathsIn t.rustflags);
          hostEnv = envStrings t.host.env;
          targetPackageSet = captureSetOf wsName triple;
          targetStdenv = t.stdenv;
          hostStdenv = t.host.stdenv;
          targetEnv = envStrings (cEnv // t.env);
        };
        # A program, or a list: program and arguments (as Cargo's
        # `target.<triple>.runner` takes a string or an array).
        runner = if runner == null then null else map (x: "${x}") (lib.toList runner);
        canRunTests = !(lib.any (x: x.breakbulkNoRunner or false) (lib.toList runner));
        # How its test processes find shared libraries: the runner's way
        # (wine: WINEPATH), else the target's traits.
        testDylibPath = breakbulkLib.testRuns.dylibPathOf {
          traits = traitsOf wsName triple;
          inherit runner;
        };
        inherit (t) testSystem;
      };

  # instantiate's overrides for one workspace on one target, keyed
  # "<name>@<version>".
  instOverrides =
    wsName: entries: triple: vName:
    lib.listToAttrs (
      lib.concatMap (
        e:
        let
          o = overrideFor wsName triple vName e;
          capture =
            platform: nativeInputs: inputs:
            let
              # A target without a package set (msvc, wasm32-unknown-unknown)
              # still has the build machine's for its host units.
              p = if platform == "host" then captureSetOf wsName triple else packageSetOf wsName triple;
              sets = envCapture.sets p platform;
              # Target units of such a target cannot have library inputs.
              # The error belongs to the units that would use them, so a
              # package that never builds for this target (a native-only
              # crate) costs nothing: its capture is a derivation that fails
              # with the reason.
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
                # targets.<t>.stdenv / host.stdenv (null: the set's).
                stdenv =
                  let
                    t = targetCfgOf wsName triple;
                  in
                  if t == null then
                    null
                  else if platform == "target" then
                    t.stdenv
                  else
                    t.host.stdenv;
              };
          ov = {
            host = {
              env = envStrings (o.env // o.forHost.env);
              envCapture = capture "host" (catFn o.nativeInputs o.forHost.nativeInputs) (
                catFn o.inputs o.forHost.inputs
              );
            };
            target = {
              env = envStrings (o.env // o.forTarget.env);
              envCapture = capture "target" (catFn o.nativeInputs o.forTarget.nativeInputs) (
                catFn o.inputs o.forTarget.inputs
              );
            };
          };
          # Members always have a layer (`memberDefaults`); one that sets
          # nothing is left out, so instantiation's inputs do not change.
          empty = s: s.env == { } && s.envCapture == null;
        in
        lib.optional (o != null && !(empty ov.host && empty ov.target)) (
          lib.nameValuePair "${e.name}@${e.version}" ov
        )
      ) entries
    );

  # extraSources by package name, from every matching override.
  extraSourcesOf =
    wsName: triple: vName: entries:
    lib.foldl' (
      acc: e:
      let
        o = overrideFor wsName triple vName e;
      in
      if o == null || o.extraSources == [ ] then
        acc
      else
        acc // { ${e.name} = lib.unique ((acc.${e.name} or [ ]) ++ o.extraSources); }
    ) { } entries;

  # The `buildScriptPaths` check of one plan (lib/build-script-paths.nix),
  # with each lockfile entry's `buildScriptPaths.allow`.
  planPathsCheck =
    wsName: triple: vName: inst: kind:
    buildScriptPaths.mkCheck {
      inherit pkgs;
      name = "${wsName}-${triple}-${vName}-${kind}-build-script-paths";
      plan = "the ${kind} plan of workspace ${wsName}, target ${triple}, variant ${vName}";
      targetName = triple;
      runs = inst.buildScriptRuns.${kind};
      allow = lib.concatMap (
        e:
        let
          o = overrideFor wsName triple vName e;
        in
        lib.optionals (o != null) (
          map (path: {
            package = e.name;
            inherit (e) version;
            inherit path;
          }) (lib.unique o.buildScriptPaths.allow)
        )
      ) locks.${wsName};
    };

  # productInputs by package name, from every layer of every matching
  # entry (the curated defaults' layers may lack the option).
  productInputsOf =
    wsName: triple: vName: entries:
    lib.foldl' (
      acc: e:
      let
        names = lib.concatMap (l: l.productInputs or [ ]) (layersFor wsName triple vName e);
      in
      if names == [ ] then acc else acc // { ${e.name} = lib.unique ((acc.${e.name} or [ ]) ++ names); }
    ) { } entries;

  # IFD mode's check of `productInputs`: for the settings of each package
  # the build plan can contain, the products of that plan (a product, its
  # stages and its roots) in the string context of a value that the
  # package does not declare. The settings as written, every layer: the
  # instantiation's inputs would hide `inputs`, `nativeInputs` and
  # `sourceOverlay` inside env captures and views. One message per
  # package, naming the settings and the line to add. Dynamic-derivation
  # mode cannot evaluate this: a missing declaration is an infinite
  # recursion there (null).
  #
  # Evaluated by repo.checks only, never by a product: the check reads
  # every product of the plan, and a product the settings use would then
  # depend on it.
  undeclaredProductInputs =
    wsName: triple: vName: inst: products:
    let
      label = "workspace ${wsName}, target ${triple}, variant ${vName}";
      discard = builtins.unsafeDiscardStringContext;
      byDrv = lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            pkg: p:
            map (d: lib.nameValuePair (discard d.drvPath) pkg) (
              [ p ] ++ lib.attrValues (p.stages or { }) ++ lib.attrValues (p.roots or { })
            )
          ) products
        )
      );
      # A value's string context, as instantiation would take it.
      context =
        v:
        if builtins.isString v then
          builtins.getContext v
        else if builtins.isList v then
          lib.foldl' (a: x: a // context x) { } v
        else if lib.isDerivation v || (builtins.isAttrs v && v ? outPath) then
          builtins.getContext "${v}"
        else
          { };
      called = f: if lib.isFunction f then f pkgs else f;
      # Every value-carrying setting of one layer the build plan takes:
      # { what; value; }.
      layerValues =
        l:
        let
          side =
            prefix: s:
            lib.mapAttrsToList (k: v: {
              what = "`${prefix}env.${k}`";
              value = v;
            }) (s.env or { })
            ++ map (v: {
              what = "`${prefix}nativeInputs`";
              value = v;
            }) (called (s.nativeInputs or [ ]))
            ++ map (v: {
              what = "`${prefix}inputs`";
              value = v;
            }) (called (s.inputs or [ ]));
        in
        side "" l
        ++ side "forHost." (l.forHost or { })
        ++ side "forTarget." (l.forTarget or { })
        ++ lib.mapAttrsToList (k: v: {
          what = "`sourceOverlay.\"${k}\"`";
          value = v;
        }) (l.sourceOverlay or { });
      found = lib.concatMap (
        e:
        let
          owner = e.name;
          declared = inst.productInputs.${owner} or [ ];
        in
        lib.optionals (inst.canContain "build" owner) (
          lib.concatMap (
            s:
            lib.concatMap (
              d:
              let
                q = byDrv.${d} or null;
              in
              lib.optional (q != null && q != owner && !(lib.elem q declared)) {
                inherit owner q;
                inherit (s) what;
              }
            ) (lib.attrNames (context s.value))
          ) (lib.concatMap layerValues (layersFor wsName triple vName e))
        )
      ) locks.${wsName};
      message =
        owner: xs:
        let
          uses = lib.mapAttrsToList (
            what: ys:
            "${what} uses ${
              lib.concatMapStringsSep ", " (q: "`${q}`") (lib.sort (a: b: a < b) (lib.unique (map (y: y.q) ys)))
            }"
          ) (lib.groupBy (y: y.what) xs);
          all = lib.sort (a: b: a < b) (lib.unique ((inst.productInputs.${owner} or [ ]) ++ map (x: x.q) xs));
        in
        "breakbulk: the settings of `${owner}` use products of the plan that builds it (${label}) that `packages.${owner}.productInputs` does not name: ${lib.concatStringsSep "; " uses}. Dynamic-derivation mode needs them named (it cannot find them: there, this is an infinite recursion). Add: packages.${owner}.productInputs = [ ${
          lib.concatMapStringsSep " " (q: "\"${q}\"") all
        } ];";
    in
    if inst.delivery != "ifd" then
      null
    else
      lib.mapAttrsToList message (lib.groupBy (x: x.owner) found);

  # --- workspaces --------------------------------------------------------------

  # The packages a variant plans on a target (null: the whole workspace):
  # the variant's own selection, else the target's.
  selOf =
    wsName: triple: v:
    if v.packages != null then
      resolveSelection cfg.workspaces.${wsName} v.packages
    else
      selectionOf wsName triple;
  # The test plan's selection: false (no test outputs on this target), a
  # list (`workspaces.<ws>.targets.<t>.tests`), or the variant's selection.
  testSelOf =
    wsName: triple: v:
    let
      t = targetSpecs.${wsName}.${triple}.tests;
    in
    if t == false then
      false
    else if builtins.isList t then
      t
    else
      selOf wsName triple v;

  # The packages with products: false (none; the build plan is then never
  # read), the target's list, or the variant's selection.
  productSelOf =
    wsName: triple: v:
    let
      p = targetSpecs.${wsName}.${triple}.products;
    in
    if p == false then
      false
    else if builtins.isList p then
      p
    else
      selOf wsName triple v;

  # The variants planned for a target (`variants.<v>.targets`).
  variantsFor =
    ws: triple: lib.filterAttrs (_: v: v.targets == null || lib.elem triple v.targets) ws.variants;

  # Each planned variant's settings on each target: its own, then the
  # target's `variantDefaults`, then its `target.<triple>` layer. Every
  # per-variant decision below reads these.
  variantCells = lib.mapAttrs (
    wsName: ws:
    lib.mapAttrs (
      triple: _:
      lib.mapAttrs (
        _: v: v.onTarget (targetSpecs.${wsName}.${triple}.config.variantDefaults or { }) triple
      ) (variantsFor ws triple)
    ) ws.targets
  ) cfg.workspaces;

  # The target's stage set's inputs (lib/products.nix targetStageSet): one
  # decision, per target, of what happens to debug info (`debugInfo`),
  # read by the products, the remap scope and the build ID
  # alike.
  stageSetArgs = wsName: triple: {
    inherit triple;
    traits = traitsOf wsName triple;
    stagePreset = targetField wsName triple "stagePreset" null;
    debugInfo = targetField wsName triple "debugInfo" null;
    targetStages = targetField wsName triple "stages" { };
  };
  shippedRemapScopeOf =
    wsName: triple: v:
    products.shippedRemapScope (stageSetArgs wsName triple // { coverage = v.mode == "coverage"; });

  instance =
    wsName: ws: triple: vName:
    let
      v = variantCells.${wsName}.${triple}.${vName};
      entries = locks.${wsName};
      sel = selOf wsName triple v;
      tsel = testSelOf wsName triple v;
      s = specFor wsName triple;
      # Target units only: host units' products are not shipped.
      debugEnv = products.targetUnitEnv (stageSetArgs wsName triple);
    in
    mkWorkspace pkgs (
      {
        inherit root tools fetchArgs;
        vendor = vendors.${wsName};
        path = ws.path;
        toolchain = {
          inherit (ws.toolchain) rustc cargo capabilities;
        };
        target = triple;
        inherit (targetSpecs.${wsName}.${triple}.config) rustcTarget;
        inherit (v)
          profile
          testProfile
          cargoConfig
          features
          noDefaultFeatures
          allFeatures
          ;
        variant = vName;
        rootNames = ws.roots;
        select = if sel == null then [ ] else sel;
        testSelect =
          if builtins.isList tsel then
            tsel
          else if sel == null then
            [ ]
          else
            sel;
        extraSources = extraSourcesOf wsName triple vName entries;
        productInputs = productInputsOf wsName triple vName entries;
        packageOverrides = instOverrides wsName entries triple vName;
        name = "${wsName}-${triple}-${vName}";
        inherit delivery;
        shippedRemapScope = shippedRemapScopeOf wsName triple v;
        inherit (v) cargoTrimPaths sourcePaths;
        traits = traitsOf wsName triple;
        packages = memberConfigs wsName triple vName;
        inherit (cfg) ca;
        inherit nixFeatures;
        inherit (v)
          mode
          clippyArgs
          rustcWrapper
          sideFiles
          ;
        rustcWorkspaceWrapper =
          if v.mode == "clippy" then "${ws.toolchain.clippy}/bin/clippy-driver" else v.rustcWorkspaceWrapper;
        clippyOption = "workspaces.${wsName}.toolchain.clippy";
        bench = v.benches;
        docsNoDeps = ws.docs.noDeps;
        inherit (s)
          runner
          testSystem
          testDylibPath
          testObjcopy
          ;
        # Host units' tests run with the native target's settings, as Cargo
        # gives them `target.<host>.runner`.
        hostTest =
          let
            h = specFor wsName nativeTriple;
          in
          {
            triple = nativeTriple;
            inherit (h) runner testSystem;
            dylibPath = h.testDylibPath;
            objcopy = h.testObjcopy;
          };
      }
      // s.mkWorkspace
      // {
        targetEnv = debugEnv // (s.mkWorkspace.targetEnv or { });
      }
      # Coverage: `-C instrument-coverage` on target units, through the
      # spec's rustflags (so under the key the project uses).
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
    wsName: ws: triple: vName: v: inst: sel:
    products.mkProducts (
      stageSetArgs wsName triple
      // {
        inherit pkgs inst;
        # `sourcePaths = "keep"`: no default noSourceReferences check.
        defaultChecks = v.sourcePaths == "hide";
        select = sel;
        targetChecks = targetField wsName triple "checks" { };
        packageConfig = productConfig wsName triple vName;
        inherit (cfg) ca;
        inherit nixFeatures;
        lockfile = root + "/${util.joinRel (wsDirOf ws) "Cargo.lock"}";
        cargoPackages =
          let
            wsManifest = manifest.readManifest root (wsDirOf ws);
          in
          lib.mapAttrs (
            _: m:
            (manifest.packageInfo {
              inherit root wsManifest;
              dir = util.normalizeRel m.path;
            }).package
          ) ws.members;
      }
    );

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

  selectPkgs =
    sel: attrs: if sel == null then attrs else lib.filterAttrs (n: _: lib.elem n sel) attrs;

  # benches.<pkg>.<name>: bench-plan roots installed as
  # $out/bin/<target><exe suffix> (stubs as they are): a bench by its name,
  # the lib harness in bench mode as `lib`, a bin's as `bin-<name>`.
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
      install = r: if r.breakbulkRoot.unit == null then r else inst.installExecutable r;
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

  # tests.<pkg>.<name>: test-plan roots installed as
  # $out/bin/<target><exe suffix> (stubs as they are).
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
          x:
          lib.nameValuePair (
            if lib.length counts.${x.short} > 1 then x.long else x.short
          ) inst.testBins.${x.root}
        ) named
      )
    ) selected;

  workspaceOut =
    wsName: ws:
    let
      instances = lib.mapAttrs (
        triple: _: lib.mapAttrs (vName: _: instance wsName ws triple vName) (variantsFor ws triple)
      ) ws.targets;
      perTarget = lib.mapAttrs (
        triple: vs:
        let
          variants = lib.mapAttrs (
            vName: inst:
            let
              v = variantCells.${wsName}.${triple}.${vName};
              sel = selOf wsName triple v;
              # Test outputs: none when the target has `tests = false`.
              tsel = testSelOf wsName triple v;
              testsOn = tsel != false;
              tSel = if testsOn then tsel else null;
              ifTests = attrs: if testsOn then attrs else { };
              psel = productSelOf wsName triple v;
              packages = if psel == false then { } else productsOf wsName ws triple vName v inst psel;
            in
            {
              inherit packages;
              # IFD mode: the undeclared products as inputs, a message per
              # package (undeclaredProductInputs); repo.checks fails with
              # them. null in dynamic-derivation mode.
              productInputErrors = undeclaredProductInputs wsName triple vName inst packages;
              # The `buildScriptPaths` check of each plan the variant
              # builds: the build plan (unless products are off), and the
              # test plan when there are test outputs; a check or clippy
              # variant's plans are those its `check` builds.
              buildScriptPaths =
                let
                  checking = v.mode == "check" || v.mode == "clippy";
                  kinds =
                    lib.optional (checking || productSelOf wsName triple v != false) "build"
                    ++ lib.optional (if checking then v.allTargets else testsOn) "test";
                in
                lib.genAttrs kinds (kind: planPathsCheck wsName triple vName inst kind);
              tests = ifTests (testsOf inst tSel);
              testRuns = ifTests (selectPkgs tSel inst.testRuns);
              # testRuns named as `tests` names test binaries, for repo.checks.
              namedTestRuns = ifTests (namedRuns inst tSel);
              testApps = ifTests (selectPkgs tSel inst.testApps);
              doctests = ifTests (selectPkgs tSel inst.doctests);
              # Those in repo.checks (`test.doctest.enable`).
              enabledDoctests = ifTests (
                lib.filterAttrs (pkg: _: inst.checks ? "doctest/${pkg}") (selectPkgs tSel inst.doctests)
              );
              benches = benchesOf inst sel;
              benchRuns = selectPkgs sel inst.benchRuns;
              namedBenchRuns = namedRuns' true inst.benchRuns (_: _: true) sel;
              # `cargo doc` of the variant's packages (lib/workspace.nix).
              inherit (inst) docs;
            }
            // lib.optionalAttrs (v.mode == "check" || v.mode == "clippy") {
              # Every unit of both plans (`cargo check` and `cargo check
              # --all-targets`): for clippy, its lints on every workspace
              # member. With `allTargets = false`, the build plan's only;
              # the test plan is then never planned.
              check = variantsLib.unitsCheck {
                inherit pkgs;
                name = "${wsName}-${triple}-${vName}-${v.mode}";
                units =
                  let
                    kinds = [ "build" ] ++ lib.optional v.allTargets "test";
                  in
                  if inst.delivery == "dynamic" then
                    map (k: inst.allUnits.${k}) kinds
                  else
                    lib.concatMap (k: lib.attrValues inst.units.${k}) kinds;
              };
            }
          ) vs;
          # The default variant's outputs; empty when it is not planned for
          # this target (`variants.<v>.targets`).
          dflt =
            variants.${ws.defaultVariant} or {
              packages = { };
              tests = { };
              testRuns = { };
              namedTestRuns = { };
              testApps = { };
              doctests = { };
              docs = null;
              buildScriptPaths = { };
            };
          cells = variantCells.${wsName}.${triple};
          benchVariants = lib.attrNames (lib.filterAttrs (_: v: v.benches) cells);
          benchVariant =
            if cells.${ws.defaultVariant}.benches or false then
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
            docs
            buildScriptPaths
            ;
          # The target spec's runner (a list: program and arguments, or
          # null) and test system, as test runs use them.
          inherit (s) runner testSystem;
          # false when the target's runner is `runners.none` (a preset
          # found nothing that runs its programs): its test runs and
          # doctests fail naming the options, and are not in repo.checks.
          inherit (s) canRunTests;
          # The resolved target spec of this workspace (the evaluated
          # `targets.<triple>` options), or null when it has none.
          spec = targetCfgOf wsName triple;
          # The target's traits (lib/target-traits.nix), as every decision
          # for it reads them.
          traits = traitsOf wsName triple;
        }
      ) instances;
    in
    {
      inherit instances;
      vendor = vendors.${wsName};
      # The resolved toolchain (rustc, cargo, clippy, rustfmt), for wiring
      # the same programs elsewhere (treefmt's rustfmt).
      inherit (ws) toolchain;
      target = perTarget;
      packages = if ws.defaultTarget == null then { } else perTarget.${ws.defaultTarget}.packages;
      tests = if ws.defaultTarget == null then { } else perTarget.${ws.defaultTarget}.tests;
      testRuns = if ws.defaultTarget == null then { } else perTarget.${ws.defaultTarget}.testRuns;
      docs = if ws.defaultTarget == null then null else perTarget.${ws.defaultTarget}.docs;
      plans = lib.mapAttrs (_: lib.mapAttrs (_: inst: inst.plans)) instances;
      devShell = mkDevShell {
        inherit pkgs nativeTriple;
        name = wsName;
        inherit (ws) toolchain;
        target = ws.devShell.target;
        rustcTarget =
          if ws.devShell.target == null then
            null
          else
            (targetTraits.rustcTargetArg {
              inherit pkgs;
              name = ws.devShell.target;
              inherit (targetSpecs.${wsName}.${ws.devShell.target}.config) rustcTarget;
            }).arg;
        packages = lib.filter (p: p.override != null) (
          map (e: {
            id = "${e.name}@${e.version}";
            override = overrideFor wsName (
              if ws.devShell.target == null then nativeTriple else ws.devShell.target
            ) ws.defaultVariant e;
          }) locks.${wsName}
        );
        shellEnv = ws.devShell.env;
        targetEnv = lib.optionalAttrs (ws.devShell.target != null) (
          envStrings (targetField wsName ws.devShell.target "env" { })
        );
        # How the planner passes the shell target's spec to Cargo, and the
        # trim-paths variable when the planner turns it on for the default
        # variant's profile (IFD: a small derivation that reads the
        # project's Cargo config and root manifest as files and asks rustc,
        # apart from planning, so a broken manifest does not break the
        # shell). The file names tool paths without
        # their context; the spec's own values carry it.
        cargoEnv =
          let
            inst =
              if ws.devShell.target == null then
                null
              else
                instances.${ws.devShell.target}.${ws.defaultVariant} or null;
            spec =
              if ws.devShell.target == null then
                null
              else
                (specFor wsName ws.devShell.target).mkWorkspace.spec or null;
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
            withContext = builtins.replaceStrings (map util.devirtualizeAndDiscard values) (
              map util.devirtualize values
            );
            j = builtins.fromJSON (
              builtins.unsafeDiscardStringContext (
                featureGates.readOutput nixFeatures "the dev shell of workspace `${wsName}` (cargo-env.json)"
                  "${inst.cargoEnv}/cargo-env.json"
              )
            );
          in
          if inst == null then { } else j // { env = lib.mapAttrs (_: withContext) j.env; };
      };
    };

  workspaces = lib.mapAttrs workspaceOut cfg.workspaces;

  # repo.checks, for every workspace and target, from each build or
  # coverage variant with `checks = true` (the default variant's under the
  # target, the others' under `variant-<v>/`): its products that built
  # something (`<pkg>/build`) and their checks, every enabled test run
  # (`<pkg>/test-<name>`, named as in `tests`) and doctest, and the
  # plans' `buildScriptPaths/<plan>`; check and clippy variants' `check`
  # and `buildScriptPaths/<plan>`; and the docs of every variant with
  # `docs.check`.
  checks =
    lib.concatMapAttrs (
      wsName: w:
      lib.concatMapAttrs (
        triple: t:
        lib.concatMapAttrs (
          vName: v:
          let
            vc = variantCells.${wsName}.${triple}.${vName};
            prefix = variantPrefix wsName triple vName;
            # IFD mode checks the variant's `productInputs` here.
            verified =
              d:
              if v.productInputErrors == null || v.productInputErrors == [ ] then
                d
              else
                throw (lib.concatStringsSep "\n" v.productInputErrors);
          in
          lib.mapAttrs (_: verified) (
            lib.optionalAttrs (vc.checks && (vc.mode == "build" || vc.mode == "coverage")) (
              lib.concatMapAttrs (
                pkg: p:
                # IFD mode leaves out a product whose roots Cargo all skipped
                # (it is a stub). Dynamic-derivation mode cannot tell at
                # evaluation time: such a product holds only the no-binaries
                # marker and its stages and checks pass it on, so it is in
                # like any other.
                lib.optionalAttrs (p.unbuilt == [ ] || lib.length p.unbuilt < lib.length (lib.attrNames p.roots)) (
                  {
                    "${prefix}/${pkg}/build" = p;
                  }
                  // lib.mapAttrs' (n: c: lib.nameValuePair "${prefix}/${pkg}/${n}" c) (p.checks or { })
                )
              ) v.packages
              // lib.mapAttrs' (
                kind: c: lib.nameValuePair "${prefix}/buildScriptPaths/${kind}" c
              ) v.buildScriptPaths
              // lib.optionalAttrs t.canRunTests (
                lib.concatMapAttrs (
                  pkg: rs: lib.mapAttrs' (n: d: lib.nameValuePair "${prefix}/${pkg}/test-${n}" d) rs.enabled
                ) v.namedTestRuns
                // lib.mapAttrs' (pkg: d: lib.nameValuePair "${prefix}/${pkg}/doctest" d) v.enabledDoctests
              )
            )
          )
        ) t.variants
        // lib.concatMapAttrs (
          vName: v:
          lib.optionalAttrs (variantCells.${wsName}.${triple}.${vName}.docs.check) {
            "${variantPrefix wsName triple vName}/docs" = v.docs;
          }
        ) t.variants
        // lib.optionalAttrs (cfg.workspaces.${wsName}.benchSmoke && t.canRunTests) (
          lib.concatMapAttrs (
            pkg: rs:
            lib.mapAttrs' (n: d: lib.nameValuePair "${wsName}/${triple}/${pkg}/bench-${n}" d) rs.enabled
          ) t.namedBenchRuns
        )
        // lib.concatMapAttrs (
          vName: v:
          lib.optionalAttrs (v ? check) (
            {
              "${wsName}/${triple}/variant-${vName}/check" = v.check;
            }
            // lib.mapAttrs' (
              kind: c: lib.nameValuePair "${wsName}/${triple}/variant-${vName}/buildScriptPaths/${kind}" c
            ) v.buildScriptPaths
          )
        ) t.variants
      ) w.target
    ) workspaces
    // lib.concatMapAttrs (
      wsName: ws: lib.optionalAttrs ws.fmt.enable { "${wsName}/fmt" = fmtCheck wsName ws; }
    ) cfg.workspaces;

  # Where a variant's checks are named: `<ws>/<triple>` for the default
  # variant, `<ws>/<triple>/variant-<v>` for the others.
  variantPrefix =
    wsName: triple: vName:
    if vName == cfg.workspaces.${wsName}.defaultVariant then
      "${wsName}/${triple}"
    else
      "${wsName}/${triple}/variant-${vName}";

  # repo.apps: every test app of every build or coverage variant, in a
  # flake's `apps` shape, named as its test run's check
  # (`<prefix>/<pkg>/test-<name>`). Unlike repo.checks, it does not ask
  # for `checks = true` or an enabled run: the sandbox's skip lists and
  # disabled runs are what a test app is for. A target that cannot run
  # tests here (`canRunTests`) has none, as its apps would only fail.
  apps = lib.concatMapAttrs (
    wsName: w:
    lib.concatMapAttrs (
      triple: t:
      lib.optionalAttrs t.canRunTests (
        lib.concatMapAttrs (
          vName: v:
          let
            vc = variantCells.${wsName}.${triple}.${vName};
            prefix = variantPrefix wsName triple vName;
            # Named over the test runs' binaries, not the apps': IFD mode
            # has no app for a binary Cargo did not build, and a name
            # depends on the names it collides with.
            named = namedRuns' false (lib.mapAttrs (
              pkg: lib.mapAttrs (k: _: v.testApps.${pkg}.${k} or null)
            ) v.testRuns) (_: _: false) null;
          in
          lib.optionalAttrs (vc.mode == "build" || vc.mode == "coverage") (
            lib.concatMapAttrs (
              pkg: as:
              lib.mapAttrs' (
                n: drv:
                lib.nameValuePair "${prefix}/${pkg}/test-${n}" {
                  type = "app";
                  program = "${drv}/bin/${drv.meta.mainProgram}";
                  meta.description = "Test binary ${n} of ${pkg} on ${triple}, variant ${vName}, outside the sandbox";
                }
              ) (lib.filterAttrs (_: drv: drv != null) (removeAttrs as [ "enabled" ]))
            ) named
          )
        ) t.variants
      )
    ) w.target
  ) workspaces;

  # `workspaces.<ws>.fmt`: `cargo fmt --check -p <member>…` over the
  # workspace directory (minus its top level's `sourceViews.junkPaths`)
  # and the rustfmt config files above it, with toolchain.rustfmt. Cargo
  # reads only the members' manifests (`cargo metadata --no-deps`), so no
  # plan, lockfile or vendored source is needed.
  fmtCheck =
    wsName: ws:
    let
      wsDir = wsDirOf ws;
      at = manifest.at root;
      names = lib.attrNames ws.members;
      above =
        rel:
        if rel == "" then
          [ ]
        else
          let
            up = util.normalizeRel "${rel}/..";
          in
          [ up ] ++ above up;
      configs = lib.filter (f: builtins.pathExists (at f)) (
        lib.concatMap (d: [
          (util.joinRel d "rustfmt.toml")
          (util.joinRel d ".rustfmt.toml")
        ]) (above wsDir)
      );
      junk = breakbulkLib.sourceViews.junkPaths {
        inherit root;
        dir = wsDir;
      };
      src = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions (
          [
            (lib.fileset.difference (at wsDir) (lib.fileset.unions (map at junk)))
          ]
          ++ map at configs
        );
      };
      tc = ws.toolchain;
    in
    pkgs.runCommand "${wsName}-fmt"
      {
        nativeBuildInputs = [
          tc.cargo
          tc.rustfmt
        ];
      }
      ''
        if ! command -v cargo-fmt >/dev/null || ! command -v rustfmt >/dev/null; then
          echo "breakbulk: the fmt check needs bin/cargo-fmt and bin/rustfmt in ${tc.rustfmt}; set workspaces.${wsName}.toolchain.rustfmt to the rustfmt of this toolchain" >&2
          exit 1
        fi
        cp -r --no-preserve=mode ${src} "$NIX_BUILD_TOP/src"
        cd "$NIX_BUILD_TOP/src"/${lib.escapeShellArg wsDir}
        export HOME=$NIX_BUILD_TOP/home CARGO_HOME=$NIX_BUILD_TOP/cargo-home CARGO_NET_OFFLINE=true
        cargo fmt --check ${lib.concatMapStringsSep " " (n: "-p ${lib.escapeShellArg n}") names}
        touch $out
      '';

  # --- warnings and mode -----------------------------------------------------

  warnings = cfg.warnings ++ unmatchedWarnings ++ overlayWarnings;
  warned = x: lib.foldr (w: acc: lib.warn w acc) x warnings;
  # The modules' `assertions` (lib/modules/types.nix): any false one fails
  # whatever the repository is read for, with every such message.
  # Each variant's settings on each target have their own, as a target
  # layer can break what the variant's own settings satisfy.
  cellAssertions = lib.concatMap (lib.concatMap (lib.concatMap (v: v.assertions))) (
    map (lib.mapAttrsToList (_: lib.attrValues)) (lib.attrValues variantCells)
  );
  # A target's exclude forms are checked here: its selections are not
  # options of the workspace module, which cannot read them.
  selectionErrors = lib.concatMap (lib.concatMap (s: s.selectionErrors)) (
    map lib.attrValues (lib.attrValues targetSpecs)
  );
  failedAssertions = lib.unique (
    map (a: a.message) (lib.filter (a: !a.assertion) (cfg.assertions ++ cellAssertions))
    ++ selectionErrors
  );
  delivery = dynamic.checkMode cfg.mode;

  # repo.nixFeatures: every Nix feature some part of this evaluation may
  # use, lazy parts included, so that a gate (lib/nix-features.nix) that
  # throws means the record is wrong. Dynamic-derivation mode imports from
  # derivations only where a workspace's toolchain needs probing, a
  # workspace's `defaultTarget` default may read the project's
  # `build.target`, or a dev shell reads its Cargo env. A preset given a
  # rustc other than its workspace's is not counted: it checks its probes
  # against no record. The order matters: `devShell.target` defaults to
  # `defaultTarget`, which reads `build.target` through the record, and is
  # reached only when the `defaultTarget` site is not.
  importsInDynamicMode =
    ws:
    toolchainFacts.mayProbe { inherit (ws.toolchain) rustc cargo; }
    || (
      targetsDefaultTarget (lib.attrNames ws.targets) == null
      &&
        breakbulkLib.skeleton.configFiles {
          inherit root;
          wsDir = wsDirOf ws;
        } != [ ]
    )
    || ws.devShell.target != null;
  nixFeatures = {
    dynamicDerivations = cfg.mode == "dynamic";
    caDerivations = cfg.ca || cfg.mode == "dynamic";
    importFromDerivation =
      cfg.mode == "ifd" || lib.any importsInDynamicMode (lib.attrValues cfg.workspaces);
  };
  guard =
    x: if failedAssertions == [ ] then warned x else throw (lib.concatStringsSep "\n" failedAssertions);

  explainSharing = mkExplainSharing {
    inherit workspaces nativeTriple nixFeatures;
    defaultVariantOf = ws: cfg.workspaces.${ws}.defaultVariant;
  };

  # The repository object. Modules receive it as `repo`, for products used
  # as inputs (an embedded product of another workspace); laziness makes
  # that fine as long as no option's structure depends on it.
  result = {
    workspaces = guard workspaces;
    checks = guard (
      if cfg.workspaces ? all then
        throw "breakbulk: a workspace is named `all`, which is the name of the group of every check; rename the workspace"
      else
        checks
        // breakbulkLib.checkGroups.groups {
          inherit pkgs checks;
          user = cfg.checkGroups;
        }
    );
    apps = guard apps;
    sources = fetch.byName (fetch.sourcesFor (lockfile.merge (lib.attrValues locks)));
    inherit explainSharing warnings;
    inherit (eval) config options;
    inherit nixFeatures;
    optionsDoc = pkgs.nixosOptionsDoc {
      options = removeAttrs eval.options [
        "_module"
        "warnings"
      ];
      warningsAreErrors = false;
      # Declarations as links to breakbulk's repository, not store paths.
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
                url = "https://github.com/schlarpc/breakbulk/blob/main/${rel}";
              }
            else
              d
          ) opt.declarations;
        };
    };
  };
in
result
