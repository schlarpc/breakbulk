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
# repo.checks: for each variant, the outputs its `checks` record names,
# `<pkg>/build` (the product), `<pkg>/<check>` (its checks),
# `<pkg>/test-<name>` and `<pkg>/doctest` (enabled test runs and
# doctests), `<pkg>/bench-<name>` (bench runs),
# `buildScriptPaths/{build,test}` (the plans' checks), `docs`, under
# `<ws>/<triple>/` for the default variant and `<ws>/<triple>/variant-<v>/`
# for the others; check variants as
# `<ws>/<triple>/variant-<v>/check` and `…/buildScriptPaths/<plan>`;
# then the user's own `checks.<name>`. Every proper prefix of those names,
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
    specialArgs = moduleArgs;
  };
  # Module arguments, of these modules and of package settings: `pkgs`;
  # `root` (the repository root, a path), for reading project files;
  # `repo` (the result, below), for products used as inputs; `breakbulk`
  # (the library: presets, stage helpers, xwinSdk); `projectBuildTarget`
  # and `targetsDefaultTarget` (below). The caller's specialArgs win.
  moduleArgs = {
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
  cfg = eval.config;

  # Checks of the options against the project's files (lockfiles,
  # manifests), which the modules do not read. A module rather than a
  # list `guard` adds, so that `repo.config.assertions` holds them with
  # the modules' own.
  projectAssertions = {
    _file = ./repository.nix;
    config.assertions = binaryKeyAssertions ++ doctestAssertions;
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
      git
      crateSources
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

  # --- package settings ------------------------------------------------------

  esc = lib.strings.escapeNixIdentifier;

  isPathEntry = e: e.source or null == null;
  # A lockfile entry's key in the tables below: a Cargo.lock can hold one
  # name and version from two sources.
  entryKey = e: "${e.name} ${e.version}${lib.optionalString (!isPathEntry e) " ${e.source}"}";

  # The settings layers of one lockfile entry of workspace `wsName`,
  # lowest first: the curated defaults (`sysDefaults.packages`), those of
  # the crates it depends on for their dependents (`sysDefaults.dependents`),
  # for a path package the workspace's `memberDefaults`, then
  # `packages.<name>`. lib/package-settings.nix adds each one's `target`
  # and `variant` layers. `hostOnly`: the plan's target has no package
  # set, so the curated layers reach host units only. For warnings:
  # `label` names the layer, `known` the variants its `variant.<v>` may
  # name, `where` says where they are.
  layersFor =
    wsName: hostOnly: e:
    let
      sys = cfg.sysDefaults.packages.${e.name} or null;
      md = cfg.workspaces.${wsName}.memberDefaults;
      curated = label: module: {
        inherit label module hostOnly;
        known = allVariants;
        where = "any workspace";
      };
    in
    lib.optional (sys != null) (curated "sysDefaults.packages.${esc e.name}" sys)
    ++ map (
      d:
      curated "sysDefaults.dependents.${esc d.name}" (
        cfg.sysDefaults.dependents.${d.name} (
          d
          // {
            direct = lib.any (n: lib.head (lib.splitString " " n) == d.name) (e.dependencies or [ ]);
            buildDependency =
              isPathEntry e && lib.elem d.name (buildDependencyNames.${wsName}.${e.name} or [ ]);
          }
        )
      )
    ) (curatedDeps wsName e.name)
    ++ lib.optional (isPathEntry e && md.imports != [ ]) {
      label = "workspaces.${wsName}.memberDefaults";
      module = md;
      known = lib.attrNames cfg.workspaces.${wsName}.variants;
      where = "workspaces.${wsName} (${
        lib.concatStringsSep ", " (lib.attrNames cfg.workspaces.${wsName}.variants)
      })";
    }
    ++ lib.optional (cfg.packages ? ${e.name}) {
      label = "packages.${esc e.name}";
      module = cfg.packages.${e.name};
      known = allVariants;
      where = "any workspace";
    };

  allVariants = lib.unique (
    lib.concatMap (ws: lib.attrNames ws.variants) (lib.attrValues cfg.workspaces)
  );

  # Each lockfile entry's settings before any `target` or `variant`
  # layer (lib/package-settings.nix `evaluate`), by workspace, by whether
  # the curated layers are host-only (`host`) or not (`both`), and by
  # entryKey; null for an entry without layers. `defaults`: the settings
  # of a member without layers.
  settingsBases = lib.mapAttrs (
    wsName: ws:
    let
      defaults = breakbulkLib.packageSettings.contextDefaults { inherit (cfg) ca; };
      bases =
        hostOnly:
        lib.listToAttrs (
          map (
            e:
            let
              layers = layersFor wsName hostOnly e;
            in
            lib.nameValuePair (entryKey e) (
              if layers == [ ] then
                null
              else
                breakbulkLib.packageSettings.evaluate {
                  inherit layers defaults;
                  specialArgs = moduleArgs // {
                    package = e;
                  };
                }
            )
          ) locks.${wsName}
        );
    in
    {
      host = bases true;
      both = bases false;
      defaults = breakbulkLib.packageSettings.evaluate {
        layers = [ ];
        inherit defaults;
      };
    }
  ) cfg.workspaces;

  # The evaluated settings of lockfile entry `e` of workspace `wsName`
  # in the plans of variant `vName` on `triple` (`.config`, `.options`),
  # or null when it has no layers.
  settingsFor =
    wsName: triple: vName: e:
    let
      b =
        settingsBases.${wsName}.${
          if packageSetOf wsName triple == null then "host" else "both"
        }.${entryKey e};
    in
    if b == null then
      null
    else
      b.on {
        inherit triple;
        variant = vName;
      };
  # Each one evaluated once, for the workspace's targets and variants.
  settingsTable = lib.mapAttrs (
    wsName: ws:
    lib.genAttrs (lib.attrNames ws.targets) (
      triple:
      lib.genAttrs (lib.attrNames ws.variants) (
        vName:
        lib.listToAttrs (
          map (e: lib.nameValuePair (entryKey e) (settingsFor wsName triple vName e)) locks.${wsName}
        )
      )
    )
  ) cfg.workspaces;
  # The settings themselves, or null.
  settingsOf =
    wsName: triple: vName: e:
    let
      ev =
        settingsTable.${wsName}.${triple}.${vName}.${entryKey e} or (settingsFor wsName triple vName e);
    in
    if ev == null then null else ev.config;

  # The path packages of each workspace's Cargo.lock, by name.
  memberEntries = lib.mapAttrs (
    _: entries: lib.listToAttrs (map (e: lib.nameValuePair e.name e) (lib.filter isPathEntry entries))
  ) locks;

  # A member's evaluated settings (`config`, `runs`): its own, or the
  # defaults.
  memberEval =
    wsName: triple: vName: pkg:
    let
      e = memberEntries.${wsName}.${pkg} or null;
      ev =
        if e == null then
          null
        else
          settingsTable.${wsName}.${triple}.${vName}.${entryKey e} or (settingsFor wsName triple vName e);
    in
    if ev == null then settingsBases.${wsName}.defaults else ev;
  memberSettings =
    wsName: triple: vName: pkg:
    (memberEval wsName triple vName pkg).config;

  entryNames = lib.genAttrs (map (e: e.name) allEntries) (_: null);
  unmatchedWarnings = map (
    k:
    "breakbulk: `packages.${esc k}` matches no package in any workspace's Cargo.lock; it has no effect."
  ) (lib.filter (k: !(entryNames ? ${k})) (lib.attrNames cfg.packages));

  # `sourceOverlay` in the settings of a registry or git crate that a
  # `packages` key names: such crates have no source view to place it in.
  overlayWarnings = lib.concatMap (
    k:
    let
      fetched = lib.concatLists (
        lib.mapAttrsToList (
          wsName: ws:
          map (e: { inherit wsName ws e; }) (lib.filter (e: e.name == k && !(isPathEntry e)) locks.${wsName})
        ) cfg.workspaces
      );
      overlaid =
        x:
        lib.any (
          triple:
          lib.any (vName: (settingsOf x.wsName triple vName x.e).sourceOverlay != { }) (
            lib.attrNames x.ws.variants
          )
        ) (lib.attrNames x.ws.targets);
      hits = lib.unique (map (x: "${x.e.name} ${x.e.version}") (lib.filter overlaid fetched));
    in
    lib.optional (hits != [ ])
      "breakbulk: `packages.${esc k}.sourceOverlay` has no effect on ${lib.concatStringsSep ", " hits}: registry and git crates have no source view; it applies to workspace packages only."
  ) (lib.attrNames cfg.packages);

  # A layer's `variant.<v>` that names a variant it cannot reach.
  variantWarnings =
    let
      given = lib.concatLists (
        lib.mapAttrsToList (
          wsName: _:
          lib.concatMap (
            e:
            let
              b = settingsBases.${wsName}.both.${entryKey e};
            in
            lib.optionals (b != null) (
              lib.zipListsWith (l: names: l // { inherit names; }) (layersFor wsName false e) b.layerVariants
            )
          ) locks.${wsName}
        ) cfg.workspaces
      );
    in
    lib.concatLists (
      lib.mapAttrsToList (
        label: ls:
        let
          l = lib.head ls;
        in
        map (
          v: "breakbulk: `${label}.variant.${esc v}` names no variant of ${l.where}; it has no effect."
        ) (lib.filter (v: !(lib.elem v l.known)) (lib.unique (lib.concatMap (x: x.names) ls)))
      ) (lib.groupBy (l: l.label) given)
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

  # The crate names in the `[build-dependencies]` of each workspace's path
  # packages, by workspace and package name, for the `buildDependency`
  # argument of `sysDefaults.dependents` functions. A manifest is read
  # only when a function uses the argument.
  buildDependencyNames = lib.mapAttrs (
    _:
    lib.mapAttrs (
      _: dir:
      breakbulkLib.sourceViews.buildDependencies {
        inherit root;
        pkgDir = dir;
      }
    )
  ) pathPackageDirs;
  # The directories of each workspace's path packages, by name: every
  # package Cargo may load for it (lib/skeleton.nix `packageClosure`).
  pathPackageDirs = lib.mapAttrs (
    _: ws:
    lib.listToAttrs (
      lib.concatMap
        (
          dir:
          let
            m = manifest.readManifest root dir;
            p = m.package or m.project or null;
          in
          lib.optional (p != null) (lib.nameValuePair p.name dir)
        )
        (breakbulkLib.skeleton.packageClosure {
          inherit root;
          wsDir = wsDirOf ws;
        }).packages
    )
  ) cfg.workspaces;

  envStrings = lib.mapAttrs (_: bt.envString);
  # Two `inputs` (functions of a package set), concatenated.
  catFn =
    f: g: p:
    f p ++ g p;

  # Product settings for mkProducts.
  productConfig =
    wsName: triple: vName: pkg:
    let
      o = (memberEval wsName triple vName pkg).options;
    in
    {
      stages = products.definitionsOf o.stages;
      checks = products.definitionsOf o.checks;
    };

  # mkWorkspace's `packages`: each member's settings, with its runs'
  # (lib/package-settings.nix `runsOf`: test env values as strings).
  memberConfigs =
    wsName: triple: vName:
    lib.mapAttrs (
      pkg: _:
      let
        ev = memberEval wsName triple vName pkg;
      in
      ev.config // { inherit (ev) runs; }
    ) memberEntries.${wsName};

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
      # Path packages outside the workspace too: a selection can name
      # one, and its test binaries are then the plan's.
      workspaceRoots =
        let
          wsDir = wsDirOf ws;
          members = breakbulkLib.roots.workspaceRoots { inherit root wsDir; };
        in
        breakbulkLib.skeleton.outsideRoots { inherit root wsDir; } // members;
      # The test plan's and the bench plan's: `test.binaries` also
      # refines bench runs.
      predicted =
        planKind:
        (breakbulkLib.planRoots {
          inherit workspaceRoots planKind;
          variant = "";
          names = ws.roots.${planKind};
        }).roots;
    in
    lib.mapAttrs (_: rs: lib.sort lib.lessThan (lib.unique (map breakbulkLib.testRuns.binaryKey rs))) (
      lib.groupBy (r: r.package) (lib.filter (r: r.test) (predicted "test" ++ predicted "bench"))
    )
  ) cfg.workspaces;

  # A `test.doctest` setting a doctest run cannot honour (`wrapper`,
  # `runner`, `preRun`, `stages`) is an error: rustdoc runs each example
  # itself, so it would do nothing. Found in each member's doctest run
  # settings by where the definition comes from (`…, via option
  # test.doctest`), so a function module is found too.
  doctestAssertions = lib.concatLists (
    lib.mapAttrsToList (
      wsName: ws:
      let
        found = lib.concatMap (
          e:
          lib.concatMap (
            triple:
            lib.concatMap (
              vName:
              let
                ev = settingsTable.${wsName}.${triple}.${vName}.${entryKey e};
                opts = ev.runEvals.doctest.options.test;
              in
              lib.optionals (ev != null && ev.config.test.doctest != [ ]) (
                lib.concatMap (
                  n:
                  map
                    (d: {
                      name = n;
                      file = lib.head (lib.splitString ", via option " d.file);
                      owner = e.name;
                    })
                    (lib.filter (d: lib.hasInfix ", via option test.doctest" d.file) opts.${n}.definitionsWithLocations)
                ) breakbulkLib.packageSettings.doctestRefused
              )
            ) (lib.attrNames ws.variants)
          ) (lib.attrNames ws.targets)
        ) (lib.attrValues memberEntries.${wsName});
      in
      map (x: {
        assertion = false;
        message = "breakbulk: `test.doctest.${x.name}` of `${x.owner}` in workspaces.${wsName}${
          bt.setIn { files = [ x.file ]; }
        }: a doctest run has no ${x.name}; rustdoc compiles and runs each example itself (the package's `test.${x.name}` does not apply to doctests either)";
      }) (lib.unique found)
    ) cfg.workspaces
  );

  # A `test.binaries` key that names no test binary is an error: the
  # settings are looked up by key, so a misspelt one would leave enabled
  # what the user turned off. A key of `memberDefaults` must name a test
  # binary of some member, any other a test binary of the package. Each
  # definition says where it comes from (`<file>, via option
  # packages.app, via option target.<triple>`, as the module system
  # locates a module given in an option); a definition from a module file
  # given as a path says only its file, and is held to the
  # `memberDefaults` rule.
  binaryKeyAssertions =
    let
      keysOf =
        v:
        let
          t = v._type or null;
        in
        if t == "if" || t == "override" || t == "order" then
          keysOf v.content
        else if t == "merge" then
          lib.concatMap keysOf v.contents
        else
          lib.attrNames v;
      quoted = ks: lib.concatMapStringsSep ", " (k: "`${k}`") ks;
    in
    lib.concatLists (
      lib.mapAttrsToList (
        wsName: ws:
        let
          known = testBinaryKeys.${wsName};
          anyMember = lib.sort lib.lessThan (
            lib.unique (lib.concatMap (n: known.${n} or [ ]) (lib.attrNames memberEntries.${wsName}))
          );
          memberDefaults = lib.showOption [
            "workspaces"
            wsName
            "memberDefaults"
          ];
          # The keys no test binary has, of each definition of
          # `test.binaries` in a member's settings on each of the
          # workspace's targets and variants: { name; owner; known; file;
          # keys; }.
          problems =
            e:
            lib.concatMap (
              triple:
              lib.concatMap (
                vName:
                let
                  ev = settingsTable.${wsName}.${triple}.${vName}.${entryKey e};
                in
                lib.optionals (ev != null) (
                  map (
                    d:
                    let
                      parts = lib.splitString ", via option " d.file;
                      layer = lib.tail parts;
                      own = layer != [ ] && lib.head layer != memberDefaults;
                      k =
                        if own then
                          {
                            known = known.${e.name} or [ ];
                            owner = "`${e.name}` in workspaces.${wsName}";
                          }
                        else
                          {
                            known = anyMember;
                            owner = "any member of workspaces.${wsName}";
                          };
                    in
                    k
                    // {
                      name = if layer == [ ] then "test.binaries" else "${lib.concatStringsSep "." layer}.test.binaries";
                      file = lib.head parts;
                      keys = lib.filter (key: !(lib.elem key (known.${e.name} or [ ])) && !(lib.elem key k.known)) (
                        keysOf d.value
                      );
                    }
                  ) ev.options.test.binaries.definitionsWithLocations
                )
              ) (lib.attrNames ws.variants)
            ) (lib.attrNames ws.targets);
          found = lib.filter (p: p.keys != [ ]) (
            lib.concatMap problems (lib.attrValues memberEntries.${wsName})
          );
        in
        lib.mapAttrsToList (
          _: ps:
          let
            p = lib.head ps;
            keys = lib.sort lib.lessThan (lib.unique (lib.concatMap (p: p.keys) ps));
          in
          {
            assertion = false;
            message = "breakbulk: ${p.name}${
              bt.setIn { files = lib.unique (map (p: p.file) ps); }
            }: ${quoted keys} ${
              if lib.length keys == 1 then "names" else "name"
            } no test or bench binary of ${p.owner}; ${
              if p.known == [ ] then "it has none" else "the test and bench binaries are ${quoted p.known}"
            }";
          }
        ) (lib.groupBy (p: "${p.name} ${p.owner}") found)
      ) cfg.workspaces
    );

  # --- target specs, per workspace -------------------------------------------
  #
  # The spec of one workspace on one triple: the repository-wide
  # `targets.<triple>` and the workspace's own `workspaces.<ws>.targets.<triple>`
  # (both modules, lib/modules/target-spec.nix), evaluated together with the
  # workspace's toolchain, so a preset picks tools for that workspace's
  # rustc. `present` is false when neither defines anything but
  # `variantDefaults` and the triple has no default preset (`targetTraits.presetRule`):
  # such a target has no spec (the toolchain as Cargo finds it). A triple
  # whose preset needs arguments or a choice fails here when the target
  # sets no preset, no linker and not `preset = null`: the empty spec
  # would fail only at its first link, with the build machine's linker.
  evalTargetSpec =
    wsName: ws: triple:
    let
      repoDef = cfg.targets.${triple} or null;
      wsDef = ws.targets.${triple} or null;
      e = breakbulkLib.evalTargetSpec {
        inherit pkgs triple specialArgs;
        inherit (ws) toolchain;
        modules = lib.optional (repoDef != null) repoDef ++ lib.optional (wsDef != null) wsDef;
      };
      # The definitions before the preset's.
      inherit (e) first;
      # Read-only options (`cEnv`) are computed from the others and always
      # defined, so they say nothing about whether the workspace set a spec.
      specOptions = lib.filter (o: !(o.readOnly or false)) (
        lib.collect lib.isOption (
          removeAttrs first.options [
            "_module"
            "variantDefaults"
          ]
        )
      );
      rule = targetTraits.presetRule {
        inherit pkgs triple;
        inherit (first.config) traits;
      };
      # `preset` at its option default (null here), so not `preset = null`.
      unchosen = rule ? choose && first.options.preset.highestPrio >= 1500 && first.config.linker == null;
    in
    {
      inherit (e) config options;
      present =
        if unchosen then
          throw "breakbulk: targets.\"${triple}\" (workspace ${wsName}) has no preset and no linker, and ${triple} has no default preset: set `targets.\"${triple}\".preset` to ${rule.choose}; or `preset = null` to build with the toolchain as Cargo finds it"
        else
          repoDef != null
          || (wsDef != null && lib.any (o: o.highestPrio < 1500) specOptions)
          || first.config.preset != null;
    };
  targetSpecs = lib.mapAttrs (
    wsName: ws:
    lib.genAttrs (lib.unique (lib.attrNames ws.targets ++ [ nativeTriple ])) (evalTargetSpec wsName ws)
  ) cfg.workspaces;
  # A selection (lib/modules/types.nix `selection`) as the plans take it:
  # false (none), null (the whole workspace) or a list of members, the
  # exclude form resolved against the workspace's members.
  resolveSelection =
    ws: s:
    if s == true then
      null
    else if builtins.isAttrs s then
      (manifest.excludeMembers (lib.attrNames ws.members) s.exclude).selected
    else
      s;
  # The spec's values, or null when the workspace has none for the triple.
  targetCfgOf =
    wsName: triple:
    let
      s = targetSpecs.${wsName}.${triple};
    in
    if s.present then s.config else null;
  # The definitions of one of its options (`products.definitionsOf`),
  # or none without a spec.
  targetDefinitions =
    wsName: triple: field:
    let
      s = targetSpecs.${wsName}.${triple};
    in
    if s.present then products.definitionsOf s.options.${field} else { };
  # One field of it, or `default` without a spec.
  targetField =
    wsName: triple: field: default:
    let
      t = targetCfgOf wsName triple;
    in
    if t == null then default else t.${field};
  # The target's traits (lib/target-traits.nix): the triple's built-in ones
  # with `targets.<triple>.traits` (repository-wide and the workspace's)
  # merged over them. Every platform-dependent decision below reads these.
  traitsOf = wsName: triple: targetSpecs.${wsName}.${triple}.config.traits;

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
  # the runner. The host units' part is the workspace's host spec, the
  # same in every plan, whether the target has a spec or not.
  inherit (util) storePathsIn;
  # A runner option's value (`targets.<t>.runner`, `workspaces.<ws>.host.runner`),
  # a function called with the workspace's lockfile.
  runnerValue =
    wsName: r:
    if builtins.isFunction r then
      r {
        lockfile = root + "/${util.joinRel (wsDirOf cfg.workspaces.${wsName}) "Cargo.lock"}";
        workspace = wsName;
      }
    else
      r;
  # It as test runs take it: a list, program and arguments (as Cargo's
  # `target.<triple>.runner` takes a string or an array), or null.
  runnerOf =
    wsName: r:
    let
      v = runnerValue wsName r;
    in
    if v == null then null else map (x: "${x}") (lib.toList v);
  # The workspace's host spec (`workspaces.<ws>.host`).
  hostOf =
    wsName:
    let
      h = cfg.workspaces.${wsName}.host;
    in
    {
      linker = "${h.linker}";
      env = envStrings h.env;
      inherit (h) stdenv testSystem;
      runner = runnerOf wsName h.runner;
    };
  specFor =
    wsName: triple:
    let
      t = targetCfgOf wsName triple;
      h = hostOf wsName;
      str = v: if v == null then null else "${v}";
      linker = if t == null then null else str t.linker;
      rustflags = if t == null then [ ] else t.rustflags;
      named =
        prefix: l: lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair "${prefix}-${toString i}" p) l);
      runner = if t == null then null else runnerOf wsName t.runner;
      # The package set the stages of its test binaries get (`strip`
      # takes its C toolchain's binutils from it).
      testPackageSet = packageSetOf wsName triple;
    in
    {
      inherit testPackageSet runner;
      mkWorkspace = {
        spec = {
          inherit rustflags linker;
          hostLinker = h.linker;
        };
        specTools =
          named "spec-linker" (
            lib.filter (x: x != null) [
              linker
              h.linker
            ]
          )
          // named "spec-rustflags" (lib.concatMap storePathsIn rustflags);
        hostEnv = h.env;
        hostStdenv = h.stdenv;
      }
      // lib.optionalAttrs (t != null) {
        targetPackageSet = captureSetOf wsName triple;
        targetStdenv = t.stdenv;
        targetEnv = envStrings (t.cEnv // t.env);
      };
      # `runners.none` (a preset found nothing that runs the target's
      # programs) says so as an attribute, which the list above drops.
      canRunTests =
        t == null
        || !(lib.any (x: x.breakbulkNoRunner or false) (lib.toList (runnerValue wsName t.runner)));
      # How its test processes find shared libraries: the runner's way
      # (wine: WINEPATH), else the target's traits.
      testDylibPath = breakbulkLib.testRuns.dylibPathOf {
        traits = traitsOf wsName triple;
        # The runner as given: a list of strings loses its attributes.
        runner = if t == null then null else runnerValue wsName t.runner;
      };
      testSystem = if t == null then null else t.testSystem;
    };

  # instantiate's overrides for one workspace on one target, keyed
  # "<name>@<version>".
  instOverrides =
    wsName: entries: triple: vName:
    lib.listToAttrs (
      lib.concatMap (
        e:
        let
          o = settingsOf wsName triple vName e;
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
                # targets.<t>.stdenv / workspaces.<ws>.host.stdenv (null:
                # the set's).
                stdenv =
                  let
                    t = targetCfgOf wsName triple;
                  in
                  if platform == "host" then
                    cfg.workspaces.${wsName}.host.stdenv
                  else if t == null then
                    null
                  else
                    t.stdenv;
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
          outDirRemove = map (r: { inherit (r) beside path; }) o.buildScript.outDirRemove;
          # Settings that give units nothing (test settings only) are left
          # out, so instantiation's inputs do not change.
          empty = s: s.env == { } && s.envCapture == null;
        in
        lib.optional (o != null && !(empty ov.host && empty ov.target && outDirRemove == [ ])) (
          lib.nameValuePair "${e.name}@${e.version}" (
            ov // lib.optionalAttrs (outDirRemove != [ ]) { inherit outDirRemove; }
          )
        )
      ) entries
    );

  # extraSources by package name, from the settings of every entry of
  # the name.
  extraSourcesOf =
    wsName: triple: vName: entries:
    lib.foldl' (
      acc: e:
      let
        o = settingsOf wsName triple vName e;
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
          o = settingsOf wsName triple vName e;
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

  # productInputs by package name, from the settings of every entry of
  # the name.
  productInputsOf =
    wsName: triple: vName: entries:
    lib.foldl' (
      acc: e:
      let
        o = settingsOf wsName triple vName e;
        names = if o == null then [ ] else o.productInputs;
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
          lib.concatMap
            (
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
            )
            (
              let
                o = settingsOf wsName triple vName e;
              in
              lib.optionals (o != null) (layerValues o)
            )
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

  # The packages a variant plans on a target (its settings there, `v`):
  # false (none: no plan is traced), null (the whole workspace) or a list.
  selOf = wsName: v: resolveSelection cfg.workspaces.${wsName} v.packages;
  # A plan's selection, `option` of `v` (`tests`, `products`, `benches`):
  # false (the plan is not traced), its own list, or with `true` the
  # variant's `packages`.
  planSelOf =
    option: wsName: v:
    let
      sel = selOf wsName v;
    in
    if sel == false || v.${option} == false then
      false
    else if v.${option} == true then
      sel
    else
      resolveSelection cfg.workspaces.${wsName} v.${option};
  testSelOf = planSelOf "tests";
  # The packages with products; the build plan is traced for `selOf`.
  productSelOf = planSelOf "products";
  benchSelOf = planSelOf "benches";

  # The variants planned for a target (`variants.<v>.targets`).
  variantsFor =
    ws: triple: lib.filterAttrs (_: v: v.targets == null || lib.elem triple v.targets) ws.variants;

  # Each planned variant's settings on each target: the workspace's and
  # the target's `variantDefaults`, its own, then its `target.<triple>`
  # layer. Every per-variant decision below reads these.
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
    debugInfo = targetField wsName triple "debugInfo" null;
    targetStages = targetDefinitions wsName triple "stages";
  };

  instance =
    wsName: ws: triple: vName:
    let
      v = variantCells.${wsName}.${triple}.${vName};
      entries = locks.${wsName};
      # A plan whose selection is false is never read.
      listOr = s: if builtins.isList s then s else [ ];
      sel = selOf wsName v;
      tsel = testSelOf wsName v;
      bsel = benchSelOf wsName v;
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
          inherit (ws.toolchain) rustc cargo;
          inherit (ws.toolchain.facts) capabilities;
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
        select = listOr sel;
        testSelect = listOr tsel;
        benchSelect = listOr bsel;
        extraSources = extraSourcesOf wsName triple vName entries;
        productInputs = productInputsOf wsName triple vName entries;
        packageOverrides = instOverrides wsName entries triple vName;
        name = "${wsName}-${triple}-${vName}";
        inherit delivery;
        shippedRemapScope = products.shippedRemapScope (stageSetArgs wsName triple);
        inherit (v) sourcePaths;
        traits = traitsOf wsName triple;
        packages = memberConfigs wsName triple vName;
        inherit (cfg) ca;
        inherit nixFeatures;
        inherit (v)
          mode
          rustcWrapper
          rustcWorkspaceWrapper
          wrapperEnv
          wrapperConfig
          sideFiles
          ;
        variantOption = "workspaces.${wsName}.variants.${vName}";
        bench = bsel != false;
        docsNoDeps = v.docs.noDeps;
        inherit (s)
          runner
          testSystem
          testDylibPath
          testPackageSet
          ;
        # Host units' tests run with the workspace's host spec, never a
        # target's (the native one's included).
        hostTest =
          let
            h = hostOf wsName;
          in
          {
            triple = nativeTriple;
            inherit (h) runner testSystem;
            dylibPath = breakbulkLib.testRuns.dylibPathOf {
              traits = targetTraits.resolve { triple = nativeTriple; };
              runner = runnerValue wsName cfg.workspaces.${wsName}.host.runner;
            };
            packageSet = pkgs;
          };
      }
      // s.mkWorkspace
      // {
        targetEnv = debugEnv // (s.mkWorkspace.targetEnv or { });
      }
      # The variant's rustflags: target units, through the spec's
      # rustflags (so under the key the project uses).
      // lib.optionalAttrs (v.rustflags != [ ]) {
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
            rustflags = base.rustflags ++ v.rustflags;
          };
      }
    );

  # One product per package: its build-plan roots through the target's
  # stages (lib/products.nix).
  productsOf =
    wsName: ws: triple: vName: v: inst: sel:
    products.mkProducts (
      stageSetArgs wsName triple
      // {
        inherit pkgs inst;
        # `sourcePaths = "keep"`: no default noSourceReferences check.
        keepSourcePaths = v.sourcePaths == "keep";
        select = sel;
        targetChecks = targetDefinitions wsName triple "checks";
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

  selectPkgs =
    sel: attrs: if sel == null then attrs else lib.filterAttrs (n: _: lib.elem n sel) attrs;

  # A plan's roots (`roots`, by root name) as `<pkg>.<binary key>`
  # (lib/test-runs.nix `binaryKey`: `lib/<crate>`, `bin/<name>`, `<test>`,
  # …), each installed as $out/bin/<target><exe suffix>: the names test
  # runs, test apps and checks use, which never collide.
  byBinaryKey =
    inst: roots: sel:
    lib.mapAttrs (
      _: rs:
      lib.listToAttrs (
        map (
          r: lib.nameValuePair (breakbulkLib.testRuns.binaryKey r.breakbulkRoot) (inst.installExecutable r)
        ) rs
      )
    ) (selectPkgs sel (lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues roots)));

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
              checking = v.mode == "check";
              # Test outputs: none with `tests = false`.
              tsel = testSelOf wsName v;
              testsOn = tsel != false;
              tSel = if testsOn then tsel else null;
              ifTests = attrs: if testsOn then attrs else { };
              psel = productSelOf wsName v;
              bsel = benchSelOf wsName v;
              ifBenches = attrs: if bsel != false then attrs else { };
              bSel = if bsel != false then bsel else null;
              packages = if psel == false then { } else productsOf wsName ws triple vName v inst psel;
              # The plans the variant traces, of the build and test plans:
              # a check variant's `check` builds their units.
              traced = lib.optional (psel != false) "build" ++ lib.optional testsOn "test";
            in
            {
              inherit packages;
              # The plan derivations ($out/plan.json), for debugging and
              # explainSharing.
              inherit (inst) plans;
              # The `buildScriptPaths` check of each plan the variant
              # traces.
              buildScriptPaths = lib.genAttrs traced (kind: planPathsCheck wsName triple vName inst kind);
              # Test binaries, their runs and apps, by binary key; each run
              # and doctest says whether it is in repo.checks (`enabled`,
              # its run settings' `enable`).
              tests = ifTests (byBinaryKey inst inst.tests tSel);
              testRuns = ifTests (selectPkgs tSel inst.testRuns);
              testApps = ifTests (selectPkgs tSel inst.testApps);
              doctests = ifTests (selectPkgs tSel inst.doctests);
              benches = ifBenches (byBinaryKey inst inst.benches bSel);
              benchRuns = ifBenches (selectPkgs bSel inst.benchRuns);
              # `cargo doc` of the variant's packages (lib/workspace.nix).
              inherit (inst) docs;
            }
            // lib.optionalAttrs (checking && traced != [ ]) {
              # Every unit of the plans it traces (`cargo check` and the test
              # plan's check form): with a lint driver, its lints on every
              # workspace member. With `tests = false`, the build plan's
              # only; with `products = false`, the test plan's.
              check = variantsLib.unitsCheck {
                inherit pkgs;
                name = "${wsName}-${triple}-${vName}-${v.mode}";
                units = map (k: inst.allUnits.${k}) traced;
              };
            }
          ) vs;
          s = specFor wsName triple;
        in
        {
          inherit variants;
          # The default variant's products; empty when it is not planned
          # for this target (`variants.<v>.targets`).
          packages = variants.${ws.defaultVariant}.packages or { };
          # The target spec's target runner (a list: program and
          # arguments, or null) and test system, as test runs use them.
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
      # What the outputs are made of: the mkWorkspace result of each
      # target and variant (lib/workspace.nix), and IFD mode's undeclared
      # products as inputs (undeclaredProductInputs: a message per
      # package, which repo.checks fails with; null in
      # dynamic-derivation mode), by target and variant.
      internal = {
        inherit instances;
        productInputErrors = lib.mapAttrs (
          triple:
          lib.mapAttrs (
            vName: inst:
            undeclaredProductInputs wsName triple vName inst perTarget.${triple}.variants.${vName}.packages
          )
        ) instances;
      };
      vendor = vendors.${wsName};
      # The resolved toolchain (rustc, cargo, clippy, rustfmt), for wiring
      # the same programs elsewhere (treefmt's rustfmt).
      inherit (ws) toolchain;
      target = perTarget;
      # The default target's (`defaultTarget`) default variant's
      # products and docs.
      packages = if ws.defaultTarget == null then { } else perTarget.${ws.defaultTarget}.packages;
      docs =
        if ws.defaultTarget == null then
          null
        else
          perTarget.${ws.defaultTarget}.variants.${ws.defaultVariant}.docs or null;
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
            override = settingsOf wsName (
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

  # repo.checks, for every workspace and target, from each variant, as
  # its `checks` record says (the default variant's under the target, the
  # others' under `variant-<v>/`): a build variant's products
  # (`<pkg>/build`) and their checks (`products`), every enabled test run
  # (`<pkg>/test/<binary key>`) and doctest (`tests`), and bench run
  # (`<pkg>/bench/<binary key>`, `benches`); a check
  # variant's `check` (`check`); the `buildScriptPaths/<plan>` of the
  # plans whose outputs are in (`buildScriptPaths`); and the docs
  # (`docs`). Then the user's own (`checks.<name>`).
  generatedChecks =
    lib.concatMapAttrs (
      wsName: w:
      lib.concatMapAttrs (
        triple: t:
        lib.concatMapAttrs (
          vName: v:
          let
            vc = variantCells.${wsName}.${triple}.${vName};
            c = vc.checks;
            building = vc.mode == "build";
            prefix = variantPrefix wsName triple vName;
            # The plans whose outputs are in repo.checks.
            plansIn =
              if building then
                lib.optional c.products "build" ++ lib.optional c.tests "test"
              else
                lib.optionals c.check [
                  "build"
                  "test"
                ];
            planChecks = lib.optionalAttrs c.buildScriptPaths (
              lib.filterAttrs (kind: _: lib.elem kind plansIn) v.buildScriptPaths
            );
            # IFD mode checks the variant's `productInputs` here.
            errors = w.internal.productInputErrors.${triple}.${vName};
            verified =
              d: if errors == null || errors == [ ] then d else throw (lib.concatStringsSep "\n" errors);
            enabled = lib.filterAttrs (_: d: d.enabled);
          in
          lib.mapAttrs (_: verified) (
            lib.optionalAttrs (building && c.products) (
              lib.concatMapAttrs (
                pkg: p:
                # Whether Cargo built any of a product's roots is known at
                # build time only: a product whose roots it all skipped
                # holds only the no-binaries marker, and its stages and
                # checks pass it on.
                {
                  "${prefix}/${pkg}/build" = p;
                }
                // lib.mapAttrs' (n: c: lib.nameValuePair "${prefix}/${pkg}/${n}" c) (p.checks or { })
              ) v.packages
            )
            // lib.optionalAttrs (building && c.tests && t.canRunTests) (
              lib.concatMapAttrs (
                pkg: rs: lib.mapAttrs' (k: d: lib.nameValuePair "${prefix}/${pkg}/test/${k}" d) (enabled rs)
              ) v.testRuns
              // lib.mapAttrs' (pkg: d: lib.nameValuePair "${prefix}/${pkg}/doctest" d) (enabled v.doctests)
            )
            // lib.optionalAttrs (building && c.benches && t.canRunTests) (
              lib.concatMapAttrs (
                pkg: rs: lib.mapAttrs' (k: d: lib.nameValuePair "${prefix}/${pkg}/bench/${k}" d) (enabled rs)
              ) v.benchRuns
            )
            // lib.optionalAttrs building (
              lib.mapAttrs' (kind: d: lib.nameValuePair "${prefix}/buildScriptPaths/${kind}" d) planChecks
            )
          )
          // lib.optionalAttrs (v ? check && c.check) (
            {
              "${wsName}/${triple}/variant-${vName}/check" = v.check;
            }
            // lib.mapAttrs' (
              kind: d: lib.nameValuePair "${wsName}/${triple}/variant-${vName}/buildScriptPaths/${kind}" d
            ) planChecks
          )
          // lib.optionalAttrs c.docs { "${prefix}/docs" = v.docs; }
        ) t.variants
      ) w.target
    ) workspaces
    // lib.concatMapAttrs (
      wsName: ws: lib.optionalAttrs ws.fmt.enable { "${wsName}/fmt" = fmtCheck wsName ws; }
    ) cfg.workspaces;
  checks =
    let
      taken = lib.attrNames (builtins.intersectAttrs cfg.checks generatedChecks);
    in
    if taken != [ ] then
      throw "breakbulk: checks.\"${lib.head taken}\"${bt.setIn eval.options.checks}: the name is one of breakbulk's own checks; choose another"
    else
      generatedChecks // cfg.checks;

  # Where a variant's checks are named: `<ws>/<triple>` for the default
  # variant, `<ws>/<triple>/variant-<v>` for the others.
  variantPrefix =
    wsName: triple: vName:
    if vName == cfg.workspaces.${wsName}.defaultVariant then
      "${wsName}/${triple}"
    else
      "${wsName}/${triple}/variant-${vName}";

  # repo.apps: every test app of every build variant, in a
  # flake's `apps` shape, named as its test run's check
  # (`<prefix>/<pkg>/test/<binary key>`). Unlike repo.checks, it does not ask
  # for `checks.tests` or an enabled run: the sandbox's skip lists and
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
          in
          lib.optionalAttrs (vc.mode == "build") (
            lib.concatMapAttrs (
              pkg: as:
              lib.mapAttrs' (
                k: drv:
                lib.nameValuePair "${prefix}/${pkg}/test/${k}" {
                  type = "app";
                  program = "${drv}/bin/${drv.meta.mainProgram}";
                  meta.description = "Test binary ${k} of ${pkg} on ${triple}, variant ${vName}, outside the sandbox";
                }
              ) as
            ) v.testApps
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

  warnings = cfg.warnings ++ unmatchedWarnings ++ overlayWarnings ++ variantWarnings;
  warned = x: lib.foldr (w: acc: lib.warn w acc) x warnings;
  # The modules' `assertions` (lib/modules/types.nix): any false one fails
  # whatever the repository is read for, with every such message.
  # Each variant's settings on each target have their own, as a target
  # layer can break what the variant's own settings satisfy.
  cellAssertions = lib.concatMap (lib.concatMap (lib.concatMap (v: v.assertions))) (
    map (lib.mapAttrsToList (_: lib.attrValues)) (lib.attrValues variantCells)
  );
  failedAssertions = lib.unique (
    map (a: a.message) (lib.filter (a: !a.assertion) (cfg.assertions ++ cellAssertions))
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

  # repo.flake: the repository as a flake's outputs, by kind, for
  # `checks.<system>`, `packages.<system>`, `apps.<system>` and
  # `devShells.<system>` (the flake-parts module sets them from it):
  #  - checks: repo.checks, groups included;
  #  - packages: each workspace's products of its default variant on its
  #    default target, by package name (`<ws>-<pkg>` when two workspaces
  #    have a package of that name), and `<ws>-docs`, those docs;
  #  - apps: repo.apps;
  #  - devShells: each workspace's dev shell by name, and `default` when
  #    there is one workspace.
  flake =
    let
      wsNames = lib.attrNames workspaces;
      allPkgs = lib.concatMap (
        ws: map (p: { inherit ws p; }) (lib.attrNames workspaces.${ws}.packages)
      ) wsNames;
      counts = lib.groupBy (x: x.p) allPkgs;
      pkgName = x: if lib.length counts.${x.p} > 1 then "${x.ws}-${x.p}" else x.p;
      products = lib.listToAttrs (
        map (x: lib.nameValuePair (pkgName x) workspaces.${x.ws}.packages.${x.p}) allPkgs
      );
      docs = lib.listToAttrs (
        lib.concatMap (
          ws:
          let
            c = cfg.workspaces.${ws};
          in
          # Not `docs != null`: that evaluates the docs derivation, which
          # in IFD mode plans `cargo doc` to list `packages`.
          lib.optional (
            c.defaultTarget != null && workspaces.${ws}.target.${c.defaultTarget}.variants ? ${c.defaultVariant}
          ) (lib.nameValuePair "${ws}-docs" workspaces.${ws}.docs)
        ) wsNames
      );
      clash = lib.attrNames (builtins.intersectAttrs products docs);
    in
    {
      checks = result.checks;
      packages =
        if clash != [ ] then
          throw "breakbulk: repo.flake.packages names both a product and a workspace's docs ${lib.concatStringsSep ", " clash}; rename the package"
        else
          products // docs;
      apps = result.apps;
      devShells =
        lib.genAttrs wsNames (ws: workspaces.${ws}.devShell)
        // lib.optionalAttrs (lib.length wsNames == 1) {
          default = workspaces.${lib.head wsNames}.devShell;
        };
    };

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
    flake = guard flake;
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
