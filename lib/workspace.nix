# One workspace on one target in one variant: fetch -> skeleton -> vendor
# -> plan -> instantiate -> units -> root products. mkRepository calls it
# once per (workspace, target, variant); it is not exported, and keeps no
# arguments beyond what mkRepository and the planner fixtures need
# (tests/lib/workspace.nix gives it to tests).
#
#   ws = mkWorkspace pkgs {
#     root = ./.;                      # the repository root
#     path = ".";                      # the workspace, relative to root
#     toolchain = { inherit (pkgs) rustc cargo; };
#     # toolchain.capabilities = { remapPathScope = false; };  overrides
#     # (lib/toolchain-facts.nix); null values are ignored
#     target = "x86_64-unknown-linux-gnu";
#     # rustcTarget = ./my-board.json;  with target = "my-board": a `.json`
#     # target spec, passed to Cargo as `<name>.json` (target-traits.nix
#     # rustcTargetArg); `target` names everything else
#     profile = "dev";
#     testProfile = "test";            # the test plan's (default: profile)
#     features = [ ];
#   };
#
#   ws.packages.<bin>          the bin, installed as $out/bin/<bin><exe suffix>
#   ws.roots."<pkg>/<kind>/<target>"   build-plan roots (instantiate.nix rootShape),
#                              e.g. "c/cdylib/c" for a library's cdylib
#   ws.tests."<pkg>/<kind>/<target>"   test-plan roots
#   ws.testBins."<root>"       test-plan roots installed as $out/bin/<target><exe suffix>
#   ws.installExecutable root  a root installed as $out/bin/<target><exe suffix>
#   ws.plans.{build,test,doc}  the plan derivations ($out/plan.json)
#   ws.cargoEnv                the dev shell's cargo-env.json (no planning)
#   ws.units.{build,test,doc}  every unit derivation, by unit id
#   ws.buildScriptRuns.{build,test}   the `flags` outputs of every
#                              build-script run of the plan
#   ws.docs                    the doc plan's docs (`cargo doc`'s folder);
#                              `docsNoDeps = true` (the default) traces
#                              `cargo doc --no-deps`
#   ws.capabilities            the toolchain's capabilities, as the planner
#                              and breakbulk-instantiate get them
#
# Arguments added for mkRepository (lib/repository.nix), all optional:
#   select = [ "<pkg>" ];      plan with -p for each instead of --workspace
#   testSelect = [ "<pkg>" ];  the test plan's -p list (default: select)
#   benchSelect = [ "<pkg>" ]; the bench plan's -p list (default: select)
#   noDefaultFeatures, allFeatures   passed to the planner
#   variant = "<name>";        the variant's name in root stubs' messages
#   packageOverrides."<name>@<version>" = { host = { env; envCapture; };
#     target = { ... }; }      as breakbulk.instantiate takes them
#   targetEnv = { };           the target spec's env (target units only)
# Path packages outside the workspace root (in the skeleton's closure) get
# source views too, keyed by their directory like members.
#   ws.testRuns.<pkg>.<binary> test-run derivations (lib/test-runs.nix)
#   ws.testApps.<pkg>.<binary> test apps, for `nix run` (lib/test-apps.nix)
#   ws.doctests.<pkg>          doctest derivations
#   ws.checks."test/<pkg>/<binary>", ."doctest/<pkg>"
#                              enabled test runs and doctests, flat
#   ws.benchRuns.<pkg>.<binary>, ws.benchChecks   with `bench`: the bench
#                              plan's runs, and the enabled ones
#
# Test options (set by mkRepository's module options): `runner` (null or a
# list), `testSystem`, `packages.<name>` (settings with `runs`, each run's
# settings: lib/package-settings.nix), `ca` (default:
# breakbulk.nixFeatures.defaultCa), `nixFeatures` (the record every use of
# a Nix feature is checked against, lib/nix-features.nix),
# `checkout` (the user's checkout of the repository root, for test apps).
{
  lib,
  util,
  lockfile,
  roots,
  sourceViews,
  envCapture,
  skeleton,
  instantiate,
  planRoots,
  mkFetch,
  mkVendor,
  defaultTools,
  mkPlan,
  mkCargoEnv,
  testRuns,
  testApps,
  dynamic,
  toolchainFacts,
  featureGates,
  targetTraitsLib,
  packageSettings,
}:
pkgs:
{
  root,
  path ? ".",
  toolchain ? { inherit (pkgs) rustc cargo; },
  target ? targetTraitsLib.nativeTriple pkgs,
  rustcTarget ? target,
  profile ? "dev",
  # The test plan's profile; check and clippy variants trace their test
  # plan (`cargo check --all-targets`) with `profile`.
  testProfile ? profile,
  features ? [ ],
  fetchArgs ? { },
  configs ? [ ],
  # The variant's Cargo configuration, as the content of a config file
  # (`variants.<v>.cargoConfig`): both plans' Cargo gets it as one
  # `--config` file. Store paths in it reach the units that name them.
  cargoConfig ? { },
  # extraSources.<package name> = [ "<path from the repository root>" ]
  extraSources ? { },
  # productInputs.<package name> = [ "<package name>" ]: the packages whose
  # products of this plan the package's settings use (mkRepository's
  # `packages.<name>.productInputs`).
  productInputs ? { },
  # packages.<name>: a member's settings, as mkRepository evaluates them
  # (lib/package-settings.nix), every option set, and `runs`, its runs'
  # settings (`runsOf` there); `sources` is the package's list of
  # source-view functions (lib/source-views.nix). A path package without
  # an entry has the options' defaults. Its env captures and env come in
  # `packageOverrides`.
  packages ? { },
  tools ? defaultTools pkgs,
  name ? "breakbulk",
  select ? [ ],
  # The test and bench plans' selections, when they differ
  # (`variants.<v>.tests`, `variants.<v>.benches`).
  testSelect ? select,
  benchSelect ? select,
  noDefaultFeatures ? false,
  allFeatures ? false,
  variant ? profile,
  # The `roots` option: `{ build; test; bench; doctests; }`, each a list
  # that replaces the prediction from the manifests, or null (or absent)
  # to keep it. build, test, bench: root names (`<pkg>/<kind>/<target>`);
  # doctests: the packages whose libraries `cargo test` doc-tests.
  rootNames ? { },
  packageOverrides ? { },
  targetEnv ? { },
  runner ? null,
  testSystem ? null,
  ca ? featureGates.defaultCa,
  checkout ? null,
  # How unit derivations reach Nix: "ifd" (units.json, imported) or
  # "dynamic" (an outer derivation writes them through builder-rpc-v0;
  # lib/dynamic.nix).
  delivery ? "ifd",
  nixFeatures ? featureGates.standalone {
    inherit ca;
    dynamic = delivery == "dynamic";
  },
  # `--remap-path-scope` for non-test target compile units (lib/instantiate.nix
  # `shippedRemapScope`); null remaps every scope.
  shippedRemapScope ? null,
  # How source paths are hidden (`workspaces.<ws>.sourcePaths`): "auto",
  # "cargo", "remap" or "keep".
  sourcePaths ? "auto",
  # The target's traits (lib/target-traits.nix `resolve`); mkRepository
  # passes them with the user's `targets.<triple>.traits` merged in.
  traits ? targetTraitsLib.resolve { triple = target; },
  # How test processes find shared libraries ({ var; sep; } or null;
  # lib/test-runs.nix dylibPathOf): mkRepository passes the runner's.
  testDylibPath ? testRuns.dylibPathOf { inherit traits runner; },
  # The target's package set for the stages of test-run binaries (or
  # null; lib/test-runs.nix testPlatforms): mkRepository passes
  # `targets.<triple>.packageSet`.
  testPackageSet ? if target == targetTraitsLib.nativeTriple pkgs then pkgs else null,
  # The test settings of the build machine's triple, { triple; runner;
  # testSystem; dylibPath; }, which host units' tests (a proc macro's) run
  # with (lib/test-runs.nix testPlatforms): mkRepository passes the native
  # target's.
  hostTest ? testRuns.defaultHost {
    inherit
      pkgs
      target
      runner
      testSystem
      ;
    dylibPath = testDylibPath;
  },
  # Variants (lib/variants.nix): `mode` is build, check, clippy or
  # coverage. `rustcWrapper` and `rustcWorkspaceWrapper` are Cargo's
  # `build.rustc-wrapper` and `build.rustc-workspace-wrapper` (executable
  # paths, or null); clippy needs the latter to be clippy-driver, matching
  # rustc (`clippyOption`, the option that set it, is named when it does
  # not). `sideFiles`: the extensions of the files a wrapper writes beside
  # a crate file that its unit keeps there. `bench` adds a bench plan
  # (`cargo bench --no-run`): ws.benches, ws.plans.bench, ws.units.bench.
  mode ? "build",
  rustcWrapper ? null,
  rustcWorkspaceWrapper ? null,
  clippyOption ? null,
  clippyArgs ? [ ],
  sideFiles ? [ ],
  bench ? false,
  # The doc plan's `cargo doc --no-deps` (`variants.<v>.docs.noDeps`).
  docsNoDeps ? true,
  # The target's toolchain spec (from lib/repository.nix):
  #   spec = { rustflags; linker; hostLinker; }  for the planner (mkPlan)
  #   specTools.<name> = <store path>  tool paths the spec puts in the plan
  #   hostEnv = { };                    the host spec's env (host units only)
  #   targetPackageSet                  the target units' env capture's pkgs
  #   targetStdenv, hostStdenv          the captures' stdenvs (null: the sets')
  spec ? null,
  specTools ? { },
  hostEnv ? { },
  targetPackageSet ? pkgs,
  targetStdenv ? null,
  hostStdenv ? null,
  # The workspace's vendor directory (mkVendor); mkRepository passes one per
  # workspace, so its targets and variants do not each evaluate it again.
  vendor ? null,
}:
let
  wsDir = util.normalizeRel path;
  # The settings of a package that `packages` does not list, with its
  # runs' (lib/package-settings.nix).
  defaultSettings =
    let
      e = packageSettings.evaluate {
        layers = [ ];
        defaults = packageSettings.contextDefaults {
          inherit ca;
          nextestConfig = testRuns.nextestDefaultConfig { inherit root wsDir; };
        };
      };
    in
    e.config // { inherit (e) runs; };
  system = pkgs.stdenv.buildPlatform.system;

  fetch = mkFetch pkgs fetchArgs;
  entries = lockfile.read (root + "/${util.joinRel wsDir "Cargo.lock"}");
  vendored = if vendor != null then vendor else mkVendor pkgs { inherit fetch entries; };
  skel = skeleton.mkSkeleton pkgs { inherit root wsDir; };

  # Cargo's package id for a lockfile entry: the source (for git, with its
  # `git+` protocol and reference query, without the locked revision), then
  # `#name@version`, or `#version` alone when the name equals the URL's last
  # path segment (cargo-util-schemas 0.11.0, `core/package_id_spec.rs`,
  # `impl Display for PackageIdSpec`), as for a git dependency on
  # github.com/<owner>/<crate>.
  crateId =
    e:
    let
      url = lib.head (lib.splitString "?" (lib.removePrefix "sparse+" e.parsed.url));
      parts = lib.splitString "/" url;
      # scheme:, "", host, path segments…; a URL without a path has the
      # single empty segment.
      last = if lib.length parts > 3 then lib.last parts else "";
      base = if e.parsed.kind == "git" then "git+${e.parsed.id}" else e.source;
    in
    if last == e.name then "${base}#${e.version}" else "${base}#${e.name}@${e.version}";
  crates = lib.listToAttrs (
    map (e: lib.nameValuePair (crateId e) (fetch.crateSource e).path) (lockfile.remoteEntries entries)
  );
  # Each package's settings for its views: `extraSources` and those of
  # `packages.<name>` (`test`, `sources`).
  viewSettings = name: (packages.${name} or { }) // { extraSources = extraSources.${name} or [ ]; };
  views = sourceViews.workspaceViews {
    inherit root wsDir;
    packages = lib.genAttrs (lib.attrNames packages ++ lib.attrNames extraSources) viewSettings;
    targetsOf = dir: memberTargets.${dir} or [ ];
    extraKeep = clippyKeep wsDir;
    # A package outside the workspace root needs none: its own `Cargo.toml`
    # is the one in its working directory.
    extraFiles = clippyKeep wsDir;
    runCommand = pkgs.runCommandLocal;
  };
  # A clippy variant's views, predicted or not, hold the `Cargo.toml` of
  # the compiles' working directory (`cwd`: the workspace root for a
  # member, the package directory for a package outside it): clippy's
  # `lint_groups_priority` reads it there, and skips the lint without a
  # word when it is missing.
  clippyKeep = cwd: lib.optional (mode == "clippy") (util.joinRel cwd "Cargo.toml");
  memberTargets = lib.listToAttrs (
    map (p: lib.nameValuePair p.dir p.targets) (lib.attrValues wsRoots)
  );
  # Path packages Cargo loads from outside the workspace root.
  closureDirs = skel.passthru.description.packages;
  memberDirs = lib.catAttrs "dir" (lib.attrValues views);
  outsideViews = lib.genAttrs (lib.filter (d: !(lib.elem d memberDirs)) closureDirs) (
    dir:
    let
      pkgName =
        (builtins.fromTOML (builtins.readFile (root + "/${util.joinRel dir "Cargo.toml"}"))).package.name;
    in
    # Not tested, so no test view; test-only paths still stay out.
    sourceViews.packageViews {
      inherit root;
      name = pkgName;
      pkgDir = dir;
      memberDirs = closureDirs;
      settings = viewSettings pkgName;
      # No per-target views for a package whose targets cannot be
      # predicted (outsideRoots' note): the package's view stands in.
      targets =
        let
          r = builtins.tryEval (lib.deepSeq outsideRoots.${pkgName}.targets outsideRoots.${pkgName}.targets);
        in
        if outsideRoots ? ${pkgName} && r.success then r.value else [ ];
      tested = false;
      runCommand = pkgs.runCommandLocal;
      extraKeep = clippyKeep dir;
    }
    // {
      name = pkgName;
    }
  );
  allViews = lib.mapAttrs' (n: v: lib.nameValuePair v.dir (v // { name = n; })) views // outsideViews;
  # The views a plan's units can read, by directory (instantiate's
  # `sources.workspace`), and the members' views of their test units
  # (`sources.workspaceTest`): those of the packages the plan can contain
  # (`canContain`), for the reason `overridesFor` gives: a view can name a
  # product (`sourceOverlay`).
  viewsFor =
    kind:
    let
      keep = lib.filterAttrs (_: v: canContain kind v.name) allViews;
    in
    {
      workspace = lib.mapAttrs (_: v: v.src) keep;
      workspaceTest = lib.mapAttrs (_: v: v.testSrc) (lib.filterAttrs (_: v: v ? testSrc) keep);
      # A predicted view's key is listed with the view it narrows as its
      # value; instantiate's `sources.predicted` gives the predicted one.
      workspaceTargets = lib.filterAttrs (_: ts: ts != { }) (
        lib.mapAttrs (_: v: v.targetSrc // lib.mapAttrs (_: s: s.view) (v.predicted.build or { })) keep
      );
      workspaceTestTargets = lib.filterAttrs (_: ts: ts != { }) (
        lib.mapAttrs (
          _: v: v.targetTestSrc or { } // lib.mapAttrs (_: s: s.view) (v.predicted.test or { })
        ) keep
      );
    };
  # Predicted views (`predictSources`), by instantiation key: `spec`, what
  # breakbulk-predict narrows, and `value`, the view, from one
  # derivation over every predicted view of the workspace (import from
  # derivation; dynamic-derivation mode's outer derivation makes the views
  # from the specs instead and never reads `value`). A view whose
  # prediction falls back is the view it would have narrowed.
  predictedAll = lib.concatMapAttrs (
    dir: v:
    let
      at = prefix: specs: lib.mapAttrs' (t: spec: lib.nameValuePair "${prefix}:${dir}#${t}" spec) specs;
    in
    at "src" (v.predicted.build or { }) // at "test-src" (v.predicted.test or { })
  ) allViews;
  predictOut = derivation {
    name = "${name}-predicted-views";
    inherit system;
    builder = "${tools.breakbulk-predict}/bin/breakbulk-predict";
    args = [
      "--spec"
      (builtins.toFile "predict.json" (
        builtins.toJSON (lib.mapAttrsToList (key: spec: spec // { inherit key; }) predictedAll)
      ))
      "--out"
      (placeholder "out")
    ];
  };
  predictResult = builtins.fromJSON (
    featureGates.readOutput nixFeatures "the predicted views of `${name}`" "${predictOut}/result.json"
  );
  predictedFor =
    kind:
    let
      dirs = lib.attrNames (lib.filterAttrs (_: v: canContain kind v.name) allViews);
    in
    lib.mapAttrs
      (key: spec: {
        inherit spec;
        value =
          let
            r = predictResult.${key};
          in
          if r ? view then
            builtins.path {
              path = "${predictOut}/${r.view}";
              name = "source";
            }
          else
            spec.view;
      })
      (
        lib.filterAttrs (
          key: _:
          let
            m = builtins.match "([a-z-]+):([^#]*)#.*" key;
          in
          lib.elem (lib.elemAt m 1) dirs && (lib.head m == "src" || kind == "test" || kind == "bench")
        ) predictedAll
      );
  # Test-only paths by directory (instantiate's `sources.testOnly`), for
  # the hint when a non-test unit misses one.
  testOnly = lib.mapAttrs (_: v: v.testOnly) (lib.filterAttrs (_: v: v.testOnly != [ ]) allViews);
  # The paths per-target views leave out, by directory (instantiate's
  # `sources.targetRoots`), for the hint when a unit misses one.
  targetRoots = lib.mapAttrs (_: v: v.targetRoots) (
    lib.filterAttrs (_: v: v.targetRoots != [ ]) allViews
  );
  # The junk paths views leave out (sourceViews.junkPaths), by directory
  # (instantiate's `sources.junk`), for the hint when a unit misses one.
  junk = lib.mapAttrs (_: v: v.junk) (lib.filterAttrs (_: v: v.junk != [ ]) allViews);
  # Directories of the packages whose `sources` functions choose files
  # (instantiate's `sources.custom`), for the same hints.
  custom = lib.attrNames (lib.filterAttrs (_: v: v.custom) allViews);

  # Clippy variants: each member's clippy config tree, by directory
  # (instantiate's `sources.clippyConf`).
  clippyConf = lib.optionalAttrs (mode == "clippy") (
    lib.genAttrs memberDirs (
      dir:
      sourceViews.clippyConfTree {
        inherit root;
        pkgDir = dir;
      }
    )
  );

  # The package directory of each member's "run" view, by package name, or
  # null when its test runs read their test binary's own view. Test runs
  # use it as their working directory and runtime CARGO_MANIFEST_DIR.
  runDirs = lib.mapAttrs (_: v: v.runDir) views;

  # `packages` with the function values of their test env applied
  # (testRuns.resolveTestEnv) for one kind of run. `filesOf` gives the
  # files such a run of a package reads, from the package's views, and
  # `workspaceRoot` is the package's Cargo workspace root in them: this
  # workspace's for a member; for a path package outside it, the
  # workspace it belongs to, else its own directory. Test runs read the
  # "run" view, doctests and test apps the test view, a test app with
  # `checkout` the checkout. A package outside the workspace has only its
  # "build" view, which its test units read.
  closureWsRoots = (skeleton.packageClosure { inherit root wsDir; }).wsRootOf;
  testEnvIn =
    filesOf:
    testRuns.resolveTestEnv (lib.mapAttrs' (
      dir: v:
      let
        d = if views ? ${v.name} then wsDir else closureWsRoots.${dir} or null;
        rel = if d == null then dir else d;
      in
      lib.nameValuePair v.name {
        workspaceRoot = if rel == "" then filesOf v else "${filesOf v}/${rel}";
      }
    ) allViews) settingsByName;
  # Every path package's settings, by name.
  settingsByName = lib.mapAttrs' (
    _: v: lib.nameValuePair v.name (packages.${v.name} or defaultSettings)
  ) allViews;
  runPackages = testEnvIn (v: "${v.runSrc or v.src}");
  viewPackages = testEnvIn (v: "${v.testSrc or v.src}");
  appPackages =
    if checkout == null then viewPackages else testEnvIn (_: lib.removeSuffix "/" (toString checkout));

  # What the toolchain can do (lib/toolchain-facts.nix), with the
  # toolchain's own overrides: the one place the planner's and
  # breakbulk-instantiate's capabilities come from.
  capabilities =
    (toolchainFacts.of {
      inherit pkgs nixFeatures;
      inherit (toolchain) rustc cargo;
      capabilities = toolchain.capabilities or { };
    }).capabilities;

  # Check and clippy variants link nothing: no roots, no test runs.
  checking = mode == "check" || mode == "clippy";

  # breakbulk-plan's `--trim-paths`.
  trimPaths =
    {
      auto = "auto";
      cargo = "on";
      remap = "off";
      keep = "off";
    }
    .${sourcePaths};

  # Written here rather than by `pkgs.formats.toml`, a derivation that
  # planning would wait for. Without context, as the spec's file:
  # planning never runs what it names, and the units that name a store
  # path get it as a tool (`cargoConfigTools`).
  cargoConfigText = util.toTOML cargoConfig;
  cargoConfigFile =
    if cargoConfig == { } then
      null
    else
      builtins.toFile "breakbulk-cargo-config.toml" (util.devirtualizeAndDiscard cargoConfigText);
  cargoConfigTools = lib.listToAttrs (
    lib.imap0 (i: p: lib.nameValuePair "cargo-config-${toString i}" p) (
      util.storePathsIn cargoConfigText
    )
  );

  plans =
    lib.genAttrs
      (
        [
          "build"
          "test"
          "doc"
        ]
        ++ lib.optional bench "bench"
      )
      (
        kind:
        mkPlan pkgs {
          vendor = vendored;
          inherit
            mode
            clippyOption
            tools
            kind
            features
            configs
            wsDir
            noDefaultFeatures
            allFeatures
            spec
            trimPaths
            ;
          target = rustcTargetArg.arg;
          packages = selectOf kind;
          profile = if kind == "test" && !checking then testProfile else profile;
          cargoConfig = cargoConfigFile;
          # A doc plan runs no wrapper (breakbulk-plan's `runs_wrappers`).
          rustcWrapper = if kind == "doc" then null else rustcWrapper;
          rustcWorkspaceWrapper = if kind == "doc" then null else rustcWorkspaceWrapper;
          clippyArgs = if kind == "doc" then [ ] else clippyArgs;
          noDeps = docsNoDeps;
          inherit (toolchain) cargo rustc;
          inherit capabilities;
          skeleton = skel;
          name = "${name}-plan";
        }
      );

  captures = {
    host = envCapture.base {
      inherit pkgs;
      platform = "host";
      stdenv = hostStdenv;
    };
    target = envCapture.base {
      pkgs = targetPackageSet;
      platform = "target";
      stdenv = targetStdenv;
    };
  };

  wsRoots = roots.workspaceRoots { inherit root wsDir; };
  # The predicted roots of a plan kind: every member's, and those of the
  # selected path packages outside the workspace. A member's roots are
  # predicted whatever the selection (the unselected ones are stubs); an
  # outside package's only when selected, since a plan without it has none.
  outsideRoots = skeleton.outsideRoots { inherit root wsDir; };
  # A plan's `-p` list (`[ ]`: `--workspace`).
  selectOf =
    kind:
    if kind == "test" then
      testSelect
    else if kind == "bench" then
      benchSelect
    else
      select;
  rootsOf =
    kind:
    let
      sel = selectOf kind;
    in
    wsRoots // lib.filterAttrs (n: _: lib.elem n sel && !(wsRoots ? ${n})) outsideRoots;

  rustcTargetArg = targetTraitsLib.rustcTargetArg {
    inherit pkgs rustcTarget;
    name = target;
  };

  unitTools = {
    rustc = toolchain.rustc;
    # The sysroot, which Cargo puts on build scripts' library path.
    rustc-sysroot = toolchain.rustc.unwrapped or toolchain.rustc;
    cargo = toolchain.cargo;
    breakbulk-unit = "${tools.breakbulk-unit}/bin/breakbulk-unit";
    shell = "${pkgs.bash}/bin/bash";
  }
  # rust-overlay toolchains are symlinkJoins of components; Cargo records
  # its own resolved path (`CARGO`), which lies in a component.
  // lib.listToAttrs (
    lib.imap0 (i: p: lib.nameValuePair "toolchain-component-${toString i}" p) (
      lib.unique ((toolchain.rustc.paths or [ ]) ++ (toolchain.cargo.paths or [ ]))
    )
  )
  // specTools
  // lib.optionalAttrs (rustcTargetArg.storePath != null) {
    rustc-target-spec = rustcTargetArg.storePath;
  }
  // cargoConfigTools
  // lib.optionalAttrs (rustcWrapper != null) { rustc-wrapper = "${rustcWrapper}"; }
  // lib.optionalAttrs (rustcWorkspaceWrapper != null) {
    rustc-workspace-wrapper = "${rustcWorkspaceWrapper}";
  };

  # Test runs also get breakbulk-hints, for their hints after a failure.
  # Not in `unitTools`, which instantiation reads: a breakbulk-hints change
  # would then re-instantiate every plan.
  testRunTools =
    unitTools
    // lib.optionalAttrs (tools ? breakbulk-hints) {
      breakbulk-hints = "${tools.breakbulk-hints}/bin/breakbulk-hints";
    };

  # The Rust toolchain's own store paths (rustc, its sysroot, cargo, and a
  # rust-overlay toolchain's components, rust-src among them), which no
  # product should reference: products' noSourceReferences looks for them.
  toolchainPaths = lib.unique (
    [
      toolchain.rustc
      (toolchain.rustc.unwrapped or toolchain.rustc)
      toolchain.cargo
    ]
    ++ (toolchain.rustc.paths or [ ])
    ++ (toolchain.cargo.paths or [ ])
  );

  isDynamic = delivery == "dynamic";
  breakbulkDrv = tools.breakbulk-drv or (dynamic.mkBreakbulkDrv pkgs);
  # The libraries `cargo test` doc-tests (roots.nix `doc`, or
  # `rootNames.doctests`) among the selected packages: the test plan's
  # instantiation gives each a doctest wrapper, with its test
  # configuration (testRuns.doctestConfig), so it must know them up front.
  predictedDoctests = lib.filterAttrs (n: _: testSelect == [ ] || lib.elem n testSelect) (
    if rootNames.doctests or null != null then
      lib.genAttrs rootNames.doctests (_: { })
    else
      lib.filterAttrs (_: p: p.roots.doc != [ ]) (rootsOf "test")
  );
  # The package settings a plan's units can read: those of the packages the
  # plan can contain, which are its selection and everything Cargo.lock
  # says they depend on (any kind, any feature: a superset of the plan).
  # Not every package's: in dynamic-derivation mode the outer derivation
  # takes every value it is given as an input, so another package's
  # `env.X = <a product of this target>` would make the plan depend on
  # itself. A name Cargo.lock does not have (the standard library's
  # crates under -Zbuild-std) is kept.
  lockDeps = lib.foldl' (
    acc: e:
    acc
    // {
      ${e.name} = (acc.${e.name} or [ ]) ++ map (d: lib.head (lib.splitString " " d)) e.dependencies;
    }
  ) { } entries;
  reachableFrom = lib.genAttrs [ "build" "test" "doc" "bench" ] (
    kind:
    let
      sel = selectOf kind;
    in
    if sel == [ ] then
      null
    else
      lib.listToAttrs (
        map (x: lib.nameValuePair x.key true) (
          builtins.genericClosure {
            startSet = map (n: { key = n; }) sel;
            operator = x: map (n: { key = n; }) (lockDeps.${x.key} or [ ]);
          }
        )
      )
  );
  canContain =
    kind: n:
    let
      r = reachableFrom.${kind};
    in
    r == null || r ? ${n} || !(lockDeps ? ${n});
  overridesFor =
    kind: lib.filterAttrs (k: _: canContain kind (lib.head (lib.splitString "@" k))) (packageOverrides);

  # The package whose settings an instantiation input holds (its key, as
  # lib/instantiate.nix names it), or null for the toolchain's, the
  # tools' and fetched crates' inputs.
  valueOwner =
    key:
    let
      setting = builtins.match "(override|doctest):([^:@]+)[^:]*:.*" key;
      view = builtins.match "(src|test-src|clippy-conf):([^#]*)(#.*)?" key;
    in
    if setting != null then
      lib.elemAt setting 1
    else if view != null then
      allViews.${lib.elemAt view 1}.name or null
    else
      null;

  # Products as inputs (`productInputs`): the packages that declare
  # products of their own plan, and every package that depends on one of
  # them in Cargo.lock. In dynamic-derivation mode the build plan's second
  # outer derivation writes these, with their settings; the first writes
  # the rest, the products those settings use among them, and never takes
  # these settings. A declaration of a package Cargo.lock lacks plans
  # nothing here.
  declaring = lib.filterAttrs (n: l: l != [ ] && lockDeps ? ${n}) productInputs;
  lockDependents = lib.mapAttrs (_: map (x: x.from)) (
    lib.groupBy (x: x.to) (
      lib.concatLists (
        lib.mapAttrsToList (
          n: ds:
          map (d: {
            from = n;
            to = d;
          }) (lib.unique ds)
        ) lockDeps
      )
    )
  );
  dependentsOf =
    names:
    lib.listToAttrs (
      map (x: lib.nameValuePair x.key true) (
        builtins.genericClosure {
          startSet = map (n: { key = n; }) names;
          operator = x: map (n: { key = n; }) (lockDependents.${x.key} or [ ]);
        }
      )
    );
  productUsers = dependentsOf (lib.attrNames declaring);
  # The shortest chain of Cargo.lock dependencies from `a` to `b`
  # (genericClosure works breadth-first), as `a -> … -> b`.
  lockChain =
    a: b:
    lib.concatStringsSep " -> " (
      (lib.findFirst (x: x.key == b)
        {
          path = [
            a
            b
          ];
        }
        (
          builtins.genericClosure {
            startSet = [
              {
                key = a;
                path = [ a ];
              }
            ];
            operator =
              x:
              map (n: {
                key = n;
                path = x.path ++ [ n ];
              }) (lockDeps.${x.key} or [ ]);
          }
        )
      ).path
    );
  # Declarations that cannot work, found from the names alone: a product
  # whose package depends on the declaring one (the product would need
  # itself), or that the second outer derivation writes for another
  # declaration (dynamic-derivation mode has two, not one per level).
  productInputConflicts = lib.concatLists (
    lib.mapAttrsToList (
      d: qs:
      lib.concatMap (
        q:
        let
          via = lib.findFirst (v: (dependentsOf [ v ]) ? ${q}) d ([ d ] ++ lib.attrNames declaring);
          opt = "`packages.${d}.productInputs`";
        in
        if !(productUsers ? ${q}) then
          [ ]
        else if q == d then
          [
            "breakbulk: ${opt} names `${d}` itself: the settings of `${d}` cannot use its own product, which is built with them."
          ]
        else if via == d then
          [
            "breakbulk: `${q}` depends on `${d}` in Cargo.lock (${lockChain q d}), and ${opt} says the settings of `${d}` use the product of `${q}`: that product would need itself."
          ]
        else
          [
            "breakbulk: ${opt} names `${q}`, but `${q}` ${
              if q == via then
                "declares products of its plan itself"
              else
                "depends on `${via}` in Cargo.lock (${lockChain q via}), which declares products of its plan"
            } (`packages.${via}.productInputs`). Dynamic-derivation mode builds a plan's units in two steps, the products that settings use and then the packages whose settings use them (with everything that depends on those), so `${q}` is in the second step and its product cannot be an input of `${d}`."
          ]
      ) qs
    ) declaring
  );
  # The second outer derivation of a plan: the build plan's, which makes
  # the products, when it can contain a package that uses them.
  splitOf =
    kind:
    let
      ps = lib.filter (canContain kind) (lib.attrNames productUsers);
    in
    if kind != "build" || ps == [ ] then
      null
    else
      {
        packages = ps;
        owner = valueOwner;
      };

  # The root wrappers are named after `<ws>-<triple>-<variant>` for the
  # build plan, with `-<kind>` for the others (in dynamic-derivation mode
  # the name of each plan's outer derivation).
  instantiateWith =
    kind: args:
    let
      all = args // {
        inherit (pkgs) coreutils;
        outerName = if kind == "build" then name else "${name}-${kind}";
        doctests = lib.optionalAttrs (kind == "test" && !checking) (
          lib.mapAttrs (
            pkg: _:
            testRuns.doctestConfig {
              inherit pkgs runner;
              packages = viewPackages;
              hostRunner = hostTest.runner;
            } pkg
          ) predictedDoctests
        );
        docs = kind == "doc";
        inherit nixFeatures;
      };
    in
    if productInputConflicts != [ ] then
      throw (lib.concatStringsSep "\n" productInputConflicts)
    else if isDynamic then
      dynamic.instantiate (
        all
        // {
          inherit breakbulkDrv;
          split = splitOf kind;
        }
      )
    else
      instantiate all;

  inst =
    kind:
    instantiateWith kind {
      breakbulkInstantiate = tools.breakbulk-instantiate;
      inherit system;
      plan = "${plans.${kind}}/plan.json";
      sources = {
        inherit (viewsFor kind) workspace workspaceTargets;
        inherit
          crates
          clippyConf
          testOnly
          targetRoots
          custom
          junk
          ;
        predicted = predictedFor kind;
      }
      # The build and doc plans have no test units; the bench plan's
      # benches and harnesses in bench mode are.
      // lib.optionalAttrs (kind == "test" || kind == "bench") {
        inherit (viewsFor kind) workspaceTest workspaceTestTargets;
      };
      tools = unitTools;
      host = {
        envCapture = captures.host;
        env = hostEnv;
      };
      target = {
        envCapture = captures.target;
        env = targetEnv;
      };
      overrides = overridesFor kind;
      inherit shippedRemapScope sideFiles;
      keepSourcePaths = sourcePaths == "keep";
      inherit capabilities;
      roots =
        if checking || kind == "doc" then
          null
        else
          planRoots {
            workspaceRoots = rootsOf kind;
            planKind = kind;
            inherit variant;
            names = rootNames.${kind} or null;
          };
      name = "${name}-${kind}-units";
    };
  built = inst "build";
  tested = inst "test";
  benched = inst "bench";
  documented = inst "doc";

  # Put a root unit's single linked file at $out/bin/<target name><suffix>,
  # as Cargo uplifts an executable. Products and their stages are in
  # lib/repository.nix; this is only enough to run things. The suffix
  # (`.exe`, `.wasm`) is the file's own: everything from its first `.`,
  # since rustc's names (`<crate name>-<hash><suffix>`, a bin's
  # `<target name><suffix>`) have none before it (rustc takes only
  # alphanumerics and `_` in a crate name, and Cargo's crate name is the
  # target name with `-` as `_`).
  installExecutable =
    r:
    pkgs.runCommand r.breakbulkRoot.target { } ''
      # A test binary Cargo did not build is its stub's output (a file with
      # the reason).
      if [ ! -d ${r} ]; then
        ln -s ${r} $out
        exit 0
      fi
      files=(${r}/*)
      if [ ''${#files[@]} -ne 1 ]; then
        echo "expected one file in ${r}, found: ''${files[*]}" >&2
        exit 1
      fi
      b=''${files[0]##*/}
      suffix=
      case "$b" in *.*) suffix=".''${b#*.}" ;; esac
      install -D -m755 "''${files[0]}" "$out/bin/"${lib.escapeShellArg r.breakbulkRoot.target}"$suffix"
    '';

  tr = testRuns.mkTestRuns {
    inherit
      pkgs
      target
      runner
      testSystem
      runDirs
      ca
      nixFeatures
      name
      traits
      ;
    dylibPath = testDylibPath;
    packageSet = testPackageSet;
    host = hostTest;
    packages = runPackages;
    inst = tested;
    coverage = mode == "coverage";
    tools = testRunTools;
  };

  benchTr = lib.optionalAttrs bench (
    testRuns.mkTestRuns {
      inherit
        pkgs
        target
        runner
        testSystem
        runDirs
        ca
        nixFeatures
        traits
        ;
      dylibPath = testDylibPath;
      packageSet = testPackageSet;
      host = hostTest;
      name = "${name}-bench";
      kind = "bench";
      packages = runPackages;
      inst = benched;
      coverage = mode == "coverage";
      tools = testRunTools;
    }
  );

  bins = lib.filterAttrs (_: r: r.breakbulkRoot.kind == "bin" && !r.breakbulkRoot.test) built.roots;
in
{
  vendor = vendored;
  inherit
    plans
    tools
    captures
    toolchainPaths
    ;
  skeleton = skel;
  # What Cargo is given as `--target`.
  rustcTarget = rustcTargetArg.arg;
  # The toolchain spec as Cargo env config, for the dev shell; independent
  # of the plans, so the shell opens even when planning fails.
  cargoEnv = mkCargoEnv pkgs {
    configSkeleton = skeleton.mkConfigSkeleton pkgs { inherit root wsDir; };
    inherit
      wsDir
      tools
      spec
      trimPaths
      capabilities
      ;
    target = rustcTargetArg.arg;
    profiles = lib.unique ([ profile ] ++ lib.optional (!checking) testProfile);
    inherit (toolchain) rustc;
    name = "${name}-cargo-env";
  };
  sources = {
    workspace = lib.mapAttrs (_: v: v.src) allViews;
    # The tested members' test views, by directory.
    workspaceTest = lib.mapAttrs (_: v: v.testSrc) (lib.filterAttrs (_: v: v ? testSrc) allViews);
    # Per-target views (packageViews' `targetSrc`, `targetTestSrc`), by
    # directory.
    workspaceTargets = lib.mapAttrs (_: v: v.targetSrc) allViews;
    workspaceTestTargets = lib.mapAttrs (_: v: v.targetTestSrc) (
      lib.filterAttrs (_: v: v ? targetTestSrc) allViews
    );
    # Predicted views, by key. IFD mode only: in dynamic-derivation mode
    # the outer derivation makes them, and they are not known here.
    predicted = lib.optionalAttrs (delivery != "dynamic") (
      lib.mapAttrs (_: p: p.value) (predictedFor "test")
    );
    # What each predicted view narrows (breakbulk-predict's ViewSpec), by
    # key, in both modes.
    predictedSpecs = lib.mapAttrs (_: p: p.spec) (predictedFor "test");
    inherit crates;
  };
  roots = built.roots;
  tests = tested.roots;
  # IFD mode: the test plan's doctest derivations (instantiate.nix
  # `doctestDrvs`).
  doctestDrvs = tested.doctestDrvs or { };
  docsDrv = documented.docsDrv or null;
  # IFD mode: each root's unit output, by root name (instantiate.nix
  # `rootUnits`).
  rootUnits = {
    build = built.rootUnits or { };
    test = tested.rootUnits or { };
  };
  units = {
    build = built.units;
    test = tested.units;
    doc = documented.units;
  }
  // lib.optionalAttrs bench { bench = benched.units; };
  unitsJson = {
    build = built.unitsJson;
    test = tested.unitsJson;
    doc = documented.unitsJson;
  }
  // lib.optionalAttrs bench { bench = benched.unitsJson; };
  # The `flags` outputs of every build-script run of the build and test
  # plans, on both platforms: `{ runsFile; }`, a file listing them at
  # build time (instantiate.nix `rootShape`).
  buildScriptRuns = {
    build = built.buildScriptRuns;
    test = tested.buildScriptRuns;
  };
  inherit delivery capabilities;
  # Products as inputs: the declarations and whether a plan kind can
  # contain a package, for mkRepository's check of the declarations in IFD
  # mode; the declarations that cannot work (messages; instantiating any
  # plan fails with them).
  inherit productInputs canContain productInputConflicts;
  # Dynamic-derivation mode: the outer derivations, by plan kind; each the
  # one that writes every unit of its plan (with `productInputs`, the
  # build plan's second).
  outer = lib.optionalAttrs isDynamic (
    {
      build = built.outer;
      test = tested.outer;
      doc = documented.outer;
    }
    // lib.optionalAttrs bench { bench = benched.outer; }
  );
  # The unit derivations through IFD mode, for explainSharing (in
  # dynamic-derivation mode they import units.json: lib/dynamic.nix
  # `ifdUnits`).
  ifdUnits = (
    {
      build = built.ifdUnits;
      test = tested.ifdUnits;
      doc = documented.ifdUnits;
    }
    // lib.optionalAttrs bench { bench = benched.ifdUnits; }
  );
  # A derivation per plan kind that builds every unit (in
  # dynamic-derivation mode ws.units is not known at evaluation time).
  allUnits = (
    {
      build = built.allUnits;
      test = tested.allUnits;
      doc = documented.allUnits;
    }
    // lib.optionalAttrs bench { bench = benched.allUnits; }
  );
  # The doc plan's documentation, `cargo doc`'s folder: `<crate>/index.html`
  # per documented crate, `crates.js`, `search.index/`, `static.files/`, ….
  docs = documented.docs;
  # Bench-plan roots (benches and harnesses in bench mode), by root name.
  benches = if bench then benched.roots else { };
  # Runs of the bench plan's binaries, with their `bench` run settings
  # (each once with `--test` by default), by package, then binary key as
  # in testRuns; `benchChecks`: the enabled ones, as testRuns' `checks`.
  benchRuns = benchTr.runs or { };
  benchChecks = benchTr.checks or { };
  packages = lib.mapAttrs' (
    _: r: lib.nameValuePair r.breakbulkRoot.target (installExecutable r)
  ) bins;
  testRuns = tr.runs;
  testApps = testApps.mkTestApps {
    inherit
      pkgs
      checkout
      name
      ;
    packages = appPackages;
    testRuns = tr;
  };
  inherit (tr) doctests checks;
  # Test binaries by root name, installed as $out/bin/<target><suffix>.
  testBins = lib.mapAttrs (_: installExecutable) tested.roots;
  inherit installExecutable;
}
