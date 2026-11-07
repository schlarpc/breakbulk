# A minimal end-to-end entry for one workspace, in IFD mode: fetch ->
# skeleton -> vendor -> plan -> instantiate -> units -> root products. The
# module system (mkRepository) replaces this in M2; it keeps no options
# beyond what the walking skeleton and the M1 fixtures need.
#
#   ws = breakbulk.mkWorkspace pkgs {
#     root = ./.;                      # the repository root
#     path = ".";                      # the workspace, relative to root
#     toolchain = { inherit (pkgs) rustc cargo; };
#     target = "x86_64-unknown-linux-gnu";
#     profile = "dev";
#     features = [ ];
#     # Per-package overrides (a minimal stand-in for M2's `packages.<name>`):
#     # they reach only that package's units, on both platforms.
#     packages.openssl-sys = {
#       nativeInputs = p: [ p.pkg-config ];   # or a plain list
#       inputs = p: [ p.openssl ];
#       env.OPENSSL_NO_VENDOR = "1";
#     };
#   };
#
#   ws.packages.<bin>          the bin, installed as $out/bin/<bin>
#   ws.roots."<pkg>/<kind>/<target>"   build-plan roots (unit outputs or stubs),
#                              e.g. "c/cdylib/c" for a library's cdylib
#   ws.tests."<pkg>/<kind>/<target>"   test-plan roots
#   ws.testBins."<root>"       test-plan roots installed as $out/bin/<target>
#   ws.plans.{build,test}      the plan derivations ($out/plan.json)
#   ws.units.{build,test}      every unit derivation, by unit id
#
# Arguments added for mkRepository (lib/repository.nix), all optional:
#   select = [ "<pkg>" ];      plan with -p for each instead of --workspace
#   noDefaultFeatures, allFeatures   passed to the planner
#   variant = "<name>";        the variant's name in root stubs' messages
#   packageOverrides."<name>@<version>" = { host = { env; envCapture; };
#     target = { ... }; strictSources; }   as breakbulk.instantiate takes them
#   strictSources = false;     the repository-wide default
#   targetEnv = { };           the target spec's env (target units only)
# Path packages outside the workspace root (in the skeleton's closure) get
# source views too, keyed by their directory like members.
#   ws.testRuns.<pkg>.<binary> test-run derivations (lib/test-runs.nix)
#   ws.testApps.<pkg>.<binary> runnable apps (lib/test-apps.nix)
#   ws.doctests.<pkg>          doctest derivations
#   ws.checks."test/<pkg>/<binary>", ."doctest/<pkg>"
#                              enabled test runs and doctests, flat
#
# Test options (M2's module options take these over): `runner` (null or a
# list), `testSystem`, `packages.<name>.test` (env, path, args,
# includeIgnored, binaries.<binary>.{args,enable}), `ca` (null: automatic),
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
  predictedRoots,
  mkFetch,
  mkVendor,
  mkTools,
  mkPlan,
  testRuns,
  testApps,
}:
pkgs:
{
  root,
  path ? ".",
  toolchain ? { inherit (pkgs) rustc cargo; },
  target ? pkgs.stdenv.hostPlatform.rust.rustcTarget,
  profile ? "dev",
  features ? [ ],
  fetchArgs ? { },
  configs ? [ ],
  # extraSources.<package name> = [ "<path from the repository root>" ]
  extraSources ? { },
  # packages.<name> = { nativeInputs; inputs; env; test; }: see above.
  packages ? { },
  tools ? mkTools pkgs,
  name ? "breakbulk",
  select ? [ ],
  noDefaultFeatures ? false,
  allFeatures ? false,
  variant ? profile,
  packageOverrides ? { },
  strictSources ? false,
  targetEnv ? { },
  runner ? null,
  testSystem ? null,
  ca ? null,
  checkout ? null,
  # `--remap-path-scope` for non-test compile units (lib/instantiate.nix
  # `shippedRemapScope`); null remaps every scope.
  shippedRemapScope ? null,
  # Variants (lib/variants.nix): `mode` is build, check, clippy or
  # coverage; clippy needs `clippyDriver` (the clippy-driver executable,
  # matching rustc). `bench` adds a bench plan (`cargo bench --no-run`):
  # ws.benches, ws.plans.bench, ws.units.bench.
  mode ? "build",
  clippyDriver ? null,
  clippyArgs ? [ ],
  bench ? false,
  # The target's toolchain spec (M3, from lib/repository.nix):
  #   spec = { rustflags; linker; hostLinker; }  for the planner (mkPlan)
  #   specTools.<name> = <store path>  tool paths the spec puts in the plan
  #   hostEnv = { };                    the host spec's env (host units only)
  #   targetPackageSet                  the target units' env capture's pkgs
  spec ? null,
  specTools ? { },
  hostEnv ? { },
  targetPackageSet ? pkgs,
}:
let
  wsDir = util.normalizeRel path;
  system = pkgs.stdenv.buildPlatform.system;

  fetch = mkFetch pkgs fetchArgs;
  entries = lockfile.read (root + "/${util.joinRel wsDir "Cargo.lock"}");
  vendor = mkVendor pkgs { inherit fetch entries; };
  skel = skeleton.mkSkeleton pkgs { inherit root wsDir; };

  # Cargo's package id for a lockfile entry: the source without the
  # locked revision, then `#name@version`.
  crateId = e: "${if e.parsed.kind == "git" then e.parsed.id else e.source}#${e.name}@${e.version}";
  crates = lib.listToAttrs (
    map (e: lib.nameValuePair (crateId e) (fetch.crateSource e).path) (lockfile.remoteEntries entries)
  );
  views = sourceViews.workspaceViews { inherit root wsDir extraSources; };
  # Path packages Cargo loads from outside the workspace root.
  closureDirs = skel.passthru.description.packages;
  memberDirs = lib.catAttrs "dir" (lib.attrValues views);
  outsideViews = lib.genAttrs (lib.filter (d: !(lib.elem d memberDirs)) closureDirs) (
    dir:
    let
      pkgName = (builtins.fromTOML (builtins.readFile (root + "/${util.joinRel dir "Cargo.toml"}"))).package.name;
    in
    sourceViews.sourceView {
      inherit root;
      pkgDir = dir;
      memberDirs = closureDirs;
      extraSources = extraSources.${pkgName} or [ ];
    }
  );
  workspace = lib.mapAttrs' (_: v: lib.nameValuePair v.dir v.src) views // outsideViews;

  # Check and clippy variants link nothing: no roots, no test runs.
  checking = mode == "check" || mode == "clippy";

  plans = lib.genAttrs ([ "build" "test" ] ++ lib.optional bench "bench") (
    kind:
    mkPlan pkgs {
      inherit
        mode
        clippyDriver
        clippyArgs
        vendor
        tools
        kind
        target
        profile
        features
        configs
        wsDir
        noDefaultFeatures
        allFeatures
        spec
        ;
      packages = select;
      inherit (toolchain) cargo rustc;
      skeleton = skel;
      name = "${name}-plan";
    }
  );

  captures = {
    host = envCapture.base {
      inherit pkgs;
      platform = "host";
    };
    target = envCapture.base {
      pkgs = targetPackageSet;
      platform = "target";
    };
  };

  wsRoots = roots.workspaceRoots { inherit root wsDir; };

  # Each package's own env capture per platform (envCapture.forPackage
  # gives the base capture when it declares no inputs), and its env.
  overrides = lib.mapAttrs (
    n: o:
    lib.genAttrs [ "host" "target" ] (platform: {
      env = o.env or { };
      envCapture = envCapture.forPackage {
        inherit pkgs platform;
        name = n;
        nativeInputs = o.nativeInputs or [ ];
        inputs = o.inputs or [ ];
      };
    })
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
  // lib.optionalAttrs (clippyDriver != null) { clippy-driver = "${clippyDriver}"; };

  inst =
    kind:
    instantiate {
      breakbulkInstantiate = tools.breakbulk-instantiate;
      inherit system;
      plan = "${plans.${kind}}/plan.json";
      sources = { inherit workspace crates; };
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
      overrides = overrides // packageOverrides;
      inherit strictSources shippedRemapScope;
      roots =
        if checking then
          null
        else
          predictedRoots {
            workspaceRoots = wsRoots;
            planKind = kind;
            inherit variant;
          };
      name = "${name}-${kind}-units";
    };
  built = inst "build";
  tested = inst "test";
  benched = inst "bench";

  # Put a root unit's single linked file at $out/<dir>/<name>. Products and
  # their stages come in M4; this is only enough to run things.
  install =
    dir: fileName: r:
    pkgs.runCommand fileName { } ''
      files=(${r}/*)
      if [ ''${#files[@]} -ne 1 ]; then
        echo "expected one file in ${r}, found: ''${files[*]}" >&2
        exit 1
      fi
      install -D -m755 "''${files[0]}" $out/${dir}/${fileName}
    '';

  tr = testRuns.mkTestRuns {
    inherit
      pkgs
      target
      runner
      testSystem
      packages
      ca
      name
      ;
    plan = plans.test;
    inst = tested;
    coverage = mode == "coverage";
    sources = { inherit workspace crates; };
    tools = unitTools;
  };

  bins = lib.filterAttrs (_: r: r.breakbulkRoot.kind == "bin" && !r.breakbulkRoot.test) built.roots;
in
{
  inherit
    plans
    vendor
    tools
    captures
    overrides
    ;
  skeleton = skel;
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
  # Bench-plan roots (benches and harnesses in bench mode), by root name.
  benches = if bench then benched.roots else { };
  # Smoke runs of the bench plan's binaries: each once with `--test`, in
  # its test-run environment (`test.env`, `test.path`; no test arguments).
  # By package, then binary key as in testRuns.
  benchRuns =
    if !bench then
      { }
    else
      (testRuns.mkTestRuns {
        inherit
          pkgs
          target
          runner
          testSystem
          ca
          ;
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
        plan = plans.bench;
        inst = benched;
        sources = { inherit workspace crates; };
        tools = unitTools;
      }).runs;
  packages = lib.mapAttrs' (
    _: r: lib.nameValuePair r.breakbulkRoot.target (install "bin" r.breakbulkRoot.target r)
  ) bins;
  testRuns = tr.runs;
  testApps = testApps.mkTestApps {
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
    _: r: if r.breakbulkRoot.unit == null then r else install "bin" r.breakbulkRoot.target r
  ) tested.roots;
}
