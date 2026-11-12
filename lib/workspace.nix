# A minimal end-to-end entry for one workspace, in IFD mode: fetch ->
# skeleton -> vendor -> plan -> instantiate -> units -> root products. The
# module system (mkRepository) is built on it; it keeps no options
# beyond what mkRepository and the planner fixtures need.
#
#   ws = breakbulk.mkWorkspace pkgs {
#     root = ./.;                      # the repository root
#     path = ".";                      # the workspace, relative to root
#     toolchain = { inherit (pkgs) rustc cargo; };
#     # toolchain.capabilities = { remapPathScope = false; };  overrides
#     # (lib/toolchain-facts.nix); null values are ignored
#     target = "x86_64-unknown-linux-gnu";
#     profile = "dev";
#     testProfile = "test";            # the test plan's (default: profile)
#     features = [ ];
#     # Per-package overrides (what mkRepository's `packages.<name>` becomes):
#     # they reach only that package's units, on both platforms.
#     packages.openssl-sys = {
#       nativeInputs = p: [ p.pkg-config ];   # or a plain list
#       inputs = p: [ p.openssl ];
#       env.OPENSSL_NO_VENDOR = "1";
#     };
#   };
#
#   ws.packages.<bin>          the bin, installed as $out/bin/<bin><exe suffix>
#   ws.roots."<pkg>/<kind>/<target>"   build-plan roots (unit outputs or stubs),
#                              e.g. "c/cdylib/c" for a library's cdylib
#   ws.tests."<pkg>/<kind>/<target>"   test-plan roots
#   ws.testBins."<root>"       test-plan roots installed as $out/bin/<target><exe suffix>
#   ws.plans.{build,test}      the plan derivations ($out/plan.json)
#   ws.cargoEnv                the dev shell's cargo-env.json (no planning)
#   ws.units.{build,test}      every unit derivation, by unit id
#   ws.capabilities            the toolchain's capabilities, as the planner
#                              and breakbulk-instantiate get them
#
# Arguments added for mkRepository (lib/repository.nix), all optional:
#   select = [ "<pkg>" ];      plan with -p for each instead of --workspace
#   testSelect = [ "<pkg>" ];  the test plan's -p list (default: select)
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
#
# Test options (set by mkRepository's module options): `runner` (null or a
# list), `testSystem`, `packages.<name>.test` (env, path, args,
# includeIgnored, binaries.<binary>.{args,env,enable},
# doctest.{args,env,postRun,enable}), `ca` (null: automatic),
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
  targetTraitsLib,
}:
pkgs:
{
  root,
  path ? ".",
  toolchain ? { inherit (pkgs) rustc cargo; },
  target ? targetTraitsLib.nativeTriple pkgs,
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
  # packages.<name> = { nativeInputs; inputs; env; test; sources; }: see
  # above; `sources` is the package's list of source-view functions
  # (lib/source-views.nix).
  packages ? { },
  tools ? defaultTools pkgs,
  name ? "breakbulk",
  select ? [ ],
  # The test plan's selection, when it differs (`targets.<t>.tests`).
  testSelect ? select,
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
  ca ? null,
  checkout ? null,
  # How unit derivations reach Nix: "ifd" (units.json, imported) or
  # "dynamic" (an outer derivation writes them through builder-rpc-v0;
  # lib/dynamic.nix). mkRepository resolves `mode = "auto"`.
  delivery ? "ifd",
  # `--remap-path-scope` for non-test target compile units (lib/instantiate.nix
  # `shippedRemapScope`); null remaps every scope.
  shippedRemapScope ? null,
  # Whether the planner turns Cargo's trim-paths on (null:
  # unless the project declares it; true; false), and whether source paths
  # are hidden at all ("hide") or left as they are ("keep": no trim-paths
  # from breakbulk and no remaps of its own).
  cargoTrimPaths ? null,
  sourcePaths ? "hide",
  # The target's traits (lib/target-traits.nix `resolve`); mkRepository
  # passes them with the user's `targets.<triple>.traits` merged in.
  traits ? targetTraitsLib.resolve { triple = target; },
  # How test processes find shared libraries ({ var; sep; } or null;
  # lib/test-runs.nix dylibPathOf): mkRepository passes the runner's.
  testDylibPath ? testRuns.dylibPathOf { inherit traits runner; },
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
  # coverage; clippy needs `clippyDriver` (the clippy-driver executable,
  # matching rustc; `clippyOption`, the option that set it, is named when
  # it does not). `bench` adds a bench plan (`cargo bench --no-run`):
  # ws.benches, ws.plans.bench, ws.units.bench.
  mode ? "build",
  clippyDriver ? null,
  clippyOption ? null,
  clippyArgs ? [ ],
  bench ? false,
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
  };
  # Path packages Cargo loads from outside the workspace root.
  closureDirs = skel.passthru.description.packages;
  memberDirs = lib.catAttrs "dir" (lib.attrValues views);
  outsideViews = lib.genAttrs (lib.filter (d: !(lib.elem d memberDirs)) closureDirs) (
    dir:
    let
      pkgName = (builtins.fromTOML (builtins.readFile (root + "/${util.joinRel dir "Cargo.toml"}"))).package.name;
    in
    # Not tested, so no test view; test-only paths still stay out.
    sourceViews.packageViews {
      inherit root;
      name = pkgName;
      pkgDir = dir;
      memberDirs = closureDirs;
      settings = viewSettings pkgName;
      tested = false;
    }
  );
  allViews = lib.mapAttrs' (_: v: lib.nameValuePair v.dir v) views // outsideViews;
  workspace = lib.mapAttrs (_: v: v.src) allViews;
  # The members' views of their test units, by directory (instantiate's
  # `sources.workspaceTest`).
  workspaceTest = lib.mapAttrs' (_: v: lib.nameValuePair v.dir v.testSrc) views;
  # Test-only paths by directory (instantiate's `sources.testOnly`), for
  # the hint when a non-test unit misses one.
  testOnly = lib.mapAttrs (_: v: v.testOnly) (lib.filterAttrs (_: v: v.testOnly != [ ]) allViews);
  # Directories of the packages whose `sources` functions choose files
  # (instantiate's `sources.custom`), for the same hints.
  custom = lib.attrNames (lib.filterAttrs (_: v: v.custom) allViews);

  # Clippy variants: each member's clippy config tree, by directory
  # (instantiate's `sources.clippyConf`).
  clippyConf = lib.optionalAttrs (mode == "clippy") (
    lib.genAttrs memberDirs (dir: sourceViews.clippyConfTree { inherit root; pkgDir = dir; })
  );

  # The package directory of each member's "run" view, by package name, or
  # null when its test runs read their test binary's own view. Test runs
  # use it as their working directory and runtime CARGO_MANIFEST_DIR.
  runDirs = lib.mapAttrs (_: v: v.runDir) views;

  # What the toolchain can do (lib/toolchain-facts.nix), with the
  # toolchain's own overrides: the one place the planner's and
  # breakbulk-instantiate's capabilities come from.
  capabilities =
    (toolchainFacts.of {
      inherit pkgs;
      inherit (toolchain) rustc cargo;
      capabilities = toolchain.capabilities or { };
    }).capabilities;

  # Check and clippy variants link nothing: no roots, no test runs.
  checking = mode == "check" || mode == "clippy";

  # breakbulk-plan's `--trim-paths`.
  trimPaths =
    if sourcePaths == "keep" then
      "off"
    else if cargoTrimPaths == null then
      "auto"
    else if cargoTrimPaths then
      "on"
    else
      "off";

  # Written here rather than by `pkgs.formats.toml`, a derivation that
  # planning would wait for. Without context, as the spec's file:
  # planning never runs what it names, and the units that name a store
  # path get it as a tool (`cargoConfigTools`).
  cargoConfigText = util.toTOML cargoConfig;
  cargoConfigFile =
    if cargoConfig == { } then
      null
    else
      builtins.toFile "breakbulk-cargo-config.toml" (builtins.unsafeDiscardStringContext cargoConfigText);
  cargoConfigTools = lib.listToAttrs (
    lib.imap0 (i: p: lib.nameValuePair "cargo-config-${toString i}" p) (util.storePathsIn cargoConfigText)
  );

  plans = lib.genAttrs ([ "build" "test" ] ++ lib.optional bench "bench") (
    kind:
    mkPlan pkgs {
      vendor = vendored;
      inherit
        mode
        clippyDriver
        clippyOption
        clippyArgs
        tools
        kind
        target
        features
        configs
        wsDir
        noDefaultFeatures
        allFeatures
        spec
        trimPaths
        traits
        ;
      packages = if kind == "test" then testSelect else select;
      profile = if kind == "test" && !checking then testProfile else profile;
      cargoConfig = cargoConfigFile;
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

  # Each package's own env capture per platform (envCapture.forPackage
  # gives the base capture when it declares no inputs), and its env.
  # A package without inputs has no capture of its own (null), as in
  # mkRepository: its units get the platform's base capture, and linking
  # units of its dependents add nothing for it.
  overrides = lib.mapAttrs (
    n: o:
    lib.genAttrs [ "host" "target" ] (
      platform:
      let
        stdenv = if platform == "host" then hostStdenv else targetStdenv;
        c = envCapture.forPackage {
          inherit pkgs platform stdenv;
          name = n;
          nativeInputs = o.nativeInputs or [ ];
          inputs = o.inputs or [ ];
        };
      in
      {
        env = o.env or { };
        envCapture =
          if c.drvPath == (envCapture.base { inherit pkgs platform stdenv; }).drvPath then null else c;
      }
    )
  ) (lib.filterAttrs (_: o: o ? nativeInputs || o ? inputs || o ? env) packages);

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
  // cargoConfigTools
  // lib.optionalAttrs (clippyDriver != null) { clippy-driver = "${clippyDriver}"; };

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
  # Dynamic-derivation mode: the outer derivation is named
  # `<ws>-<triple>-<variant>` for the build plan, with `-test`
  # for the test plan, since each plan has its own.
  # The libraries `cargo test` doc-tests (roots.nix `doc`, or
  # `rootNames.doctests`) among the selected packages: in
  # dynamic-derivation mode the test plan's outer derivation writes their
  # doctests, with the test configuration IFD mode
  # gives them (testRuns.doctestConfig), so it must know them up front.
  predictedDoctests = lib.filterAttrs (n: _: testSelect == [ ] || lib.elem n testSelect) (
    if rootNames.doctests or null != null then
      lib.genAttrs rootNames.doctests (_: { })
    else
      lib.filterAttrs (_: p: p.roots.doc != [ ]) wsRoots
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
    acc // { ${e.name} = (acc.${e.name} or [ ]) ++ map (d: lib.head (lib.splitString " " d)) e.dependencies; }
  ) { } entries;
  overridesFor =
    kind:
    let
      all = overrides // packageOverrides;
      sel = if kind == "test" then testSelect else select;
      reachable = lib.listToAttrs (
        map (x: lib.nameValuePair x.key true) (
          builtins.genericClosure {
            startSet = map (n: { key = n; }) sel;
            operator = x: map (n: { key = n; }) (lockDeps.${x.key} or [ ]);
          }
        )
      );
      keep = k: let n = lib.head (lib.splitString "@" k); in reachable ? ${n} || !(lockDeps ? ${n});
    in
    if sel == [ ] then all else lib.filterAttrs (k: _: keep k) all;

  instantiateWith =
    kind: args:
    if isDynamic then
      dynamic.instantiate (
        args
        // {
          inherit breakbulkDrv;
          inherit (pkgs) coreutils;
          outerName = if kind == "build" then name else "${name}-${kind}";
          doctests = lib.optionalAttrs (kind == "test" && !checking) (
            lib.mapAttrs (
              pkg: _:
              testRuns.doctestConfig {
                inherit pkgs packages runner;
                hostRunner = hostTest.runner;
              } pkg
            ) predictedDoctests
          );
        }
      )
    else
      instantiate args;

  inst =
    kind:
    instantiateWith kind {
      breakbulkInstantiate = tools.breakbulk-instantiate;
      inherit system;
      plan = "${plans.${kind}}/plan.json";
      sources = {
        inherit
          workspace
          crates
          clippyConf
          testOnly
          custom
          ;
      }
      # The build plan has no test units; the bench plan's benches and
      # harnesses in bench mode are.
      // lib.optionalAttrs (kind != "build") { inherit workspaceTest; };
      tools = unitTools;
      host = {
        envCapture = captures.host;
        env = hostEnv;
      };
      target = {
        envCapture = captures.target;
        env = targetEnv;
      };
      # `packages` (by name) and mkRepository's `packageOverrides` (by name
      # or name@version, already in instantiate's shape); the latter win.
      overrides = overridesFor kind;
      inherit shippedRemapScope;
      keepSourcePaths = sourcePaths == "keep";
      targetTraits = targetTraitsLib.forRust traits;
      inherit capabilities;
      roots =
        if checking then
          null
        else
          planRoots {
            workspaceRoots = wsRoots;
            planKind = kind;
            inherit variant;
            names = rootNames.${kind} or null;
          };
      name = "${name}-${kind}-units";
    };
  built = inst "build";
  tested = inst "test";
  benched = inst "bench";

  # Put a root unit's single linked file at $out/<dir>/<name>. Products and
  # their stages are in lib/repository.nix; this is only enough to run things.
  # A root's executable name: its target name with the target's executable
  # suffix (traits.executableSuffix: `.exe` on Windows, `.wasm` for wasm), as
  # Cargo uplifts it.
  exeName = r: "${r.breakbulkRoot.target}${traits.executableSuffix}";

  install =
    dir: fileName: r:
    pkgs.runCommand fileName { } ''
      ${
        # Dynamic-derivation mode: a test binary Cargo did not build is its
        # stub's output (a file with the reason), as in IFD mode.
        lib.optionalString (r.breakbulkRoot.dynamic or false) ''
          if [ ! -d ${r} ]; then
            ln -s ${r} $out
            exit 0
          fi
        ''
      }files=(${r}/*)
      if [ ''${#files[@]} -ne 1 ]; then
        echo "expected one file in ${r}, found: ''${files[*]}" >&2
        exit 1
      fi
      install -D -m755 "''${files[0]}" $out/${dir}/${fileName}
    '';

  tr = (if isDynamic then dynamic.mkTestRuns else testRuns.mkTestRuns) {
    inherit
      pkgs
      target
      runner
      testSystem
      packages
      runDirs
      ca
      name
      traits
      ;
    dylibPath = testDylibPath;
    host = hostTest;
    inst = tested;
    coverage = mode == "coverage";
    tools = unitTools;
  };

  bins = lib.filterAttrs (_: r: r.breakbulkRoot.kind == "bin" && !r.breakbulkRoot.test) built.roots;
in
{
  vendor = vendored;
  inherit
    plans
    tools
    captures
    overrides
    toolchainPaths
    ;
  skeleton = skel;
  # The toolchain spec as Cargo env config, for the dev shell; independent
  # of the plans, so the shell opens even when planning fails.
  cargoEnv = mkCargoEnv pkgs {
    configSkeleton = skeleton.mkConfigSkeleton pkgs { inherit root wsDir; };
    inherit
      wsDir
      tools
      target
      spec
      trimPaths
      capabilities
      ;
    profiles = lib.unique ([ profile ] ++ lib.optional (!checking) testProfile);
    inherit (toolchain) rustc;
    name = "${name}-cargo-env";
  };
  sources = { inherit workspace crates; };
  roots = built.roots;
  tests = tested.roots;
  units = {
    build = built.units;
    test = tested.units;
  }
  // lib.optionalAttrs bench { bench = benched.units; };
  unitsJson = {
    build = built.unitsJson;
    test = tested.unitsJson;
  }
  // lib.optionalAttrs bench { bench = benched.unitsJson; };
  inherit delivery capabilities;
  # Dynamic-derivation mode: the outer derivations, by plan kind.
  outer = lib.optionalAttrs isDynamic (
    {
      build = built.outer;
      test = tested.outer;
    }
    // lib.optionalAttrs bench { bench = benched.outer; }
  );
  # Dynamic-derivation mode: the unit derivations through IFD mode, for
  # explainSharing (lib/dynamic.nix `ifdUnits`).
  ifdUnits = lib.optionalAttrs isDynamic (
    {
      build = built.ifdUnits;
      test = tested.ifdUnits;
    }
    // lib.optionalAttrs bench { bench = benched.ifdUnits; }
  );
  # Dynamic-derivation mode: a derivation per plan kind that builds every
  # unit (ws.units is not known at evaluation time).
  allUnits = lib.optionalAttrs isDynamic (
    {
      build = built.allUnits;
      test = tested.allUnits;
    }
    // lib.optionalAttrs bench { bench = benched.allUnits; }
  );
  # Bench-plan roots (benches and harnesses in bench mode), by root name.
  benches = if bench then benched.roots else { };
  # Smoke runs of the bench plan's binaries: each once with `--test`, in
  # its test-run environment (`test.env`, `test.path`; no test arguments).
  # By package, then binary key as in testRuns.
  benchRuns =
    if !bench then
      { }
    else
      ((if isDynamic then dynamic.mkTestRuns else testRuns.mkTestRuns) {
        inherit
          pkgs
          target
          runner
          testSystem
          runDirs
          ca
          traits
          ;
        dylibPath = testDylibPath;
        host = hostTest;
        name = "${name}-bench";
        packages = lib.genAttrs (lib.unique (map (r: r.breakbulkRoot.package) (lib.attrValues benched.roots))) (
          pkg: {
            test = (packages.${pkg}.test or { }) // {
              args = [ "--test" ];
              includeIgnored = false;
              binaries = { };
            };
          }
        );
        inst = benched;
        tools = unitTools;
      }).runs;
  packages = lib.mapAttrs' (
    _: r: lib.nameValuePair r.breakbulkRoot.target (install "bin" (exeName r) r)
  ) bins;
  testRuns = tr.runs;
  testApps = (if isDynamic then dynamic.mkTestApps else testApps.mkTestApps) {
    inherit
      pkgs
      checkout
      packages
      name
      ;
    testRuns = tr;
  };
  inherit (tr) doctests checks;
  # Test binaries by root name, installed as $out/bin/<target>.
  testBins = lib.mapAttrs (
    _: r: if r.breakbulkRoot.unit == null then r else install "bin" (exeName r) r
  ) tested.roots;
}
