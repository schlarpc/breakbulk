# Reproducibility: what tests/rebuild/run.sh (`nix run .#test-rebuild`)
# builds and then rebuilds with `nix build --rebuild`. This file only
# describes the derivations; run.sh builds and compares.
#
#   nix-instantiate tests/rebuild -A products.<fixture>   .drv paths
#   nix-instantiate tests/rebuild -A units.<fixture>
#   nix-instantiate --eval --json tests/rebuild -A names
#
# Every directory under tests/fixtures is in `catalog` (as the
# repositories the other tests configure for it) or in `skipped` with the
# reason; the `rebuild-catalog` check holds that.
#
#   products.<fixture>   every product the fixture's repositories build
#                        (packages of every workspace, target and
#                        non-check variant, Cargo-built roots only) and
#                        each product's stages
#   units.<fixture>      a deterministic sample of the unit derivations of
#                        every instance (build and test plans): per
#                        instance and plan, the ceil(n / every) units with
#                        the lowest sha256 of "<seed>:<plan>:<unit id>"
#   names                the catalog's fixture names
#
# Arguments:
#   targets   a regex over target triples (default: every target)
#   every     the unit sampling rate, 1 in `every` (default 4; 1: all)
#   seed      changes the sample
{
  pkgs ?
    let
      lock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes;
      fetch =
        n:
        fetchTarball {
          url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
          sha256 = n.narHash;
        };
    in
    import (fetch lock.nixpkgs.locked) {
      overlays = [ (import (fetch lock.rust-overlay.locked)) ];
    },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
  # The msvc fixture's SDK is unfree; only this set admits it (as the
  # flake's checks do).
  xwinPkgs ? import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = p: pkgs.lib.getName p == "xwin-sdk";
  },
  targets ? ".*",
  every ? 4,
  seed ? "",
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  args = { inherit pkgs breakbulk; };

  dynamic = import ../dynamic (args // { mode = "ifd"; });
  products = import ../products args;
  repository = import ../repository args;
  presetFixtures = import ../presets/fixtures.nix (args // { inherit xwinPkgs; });
  extraTargets = import ../presets/extra-targets.nix args;
  buildStd = import ../presets/build-std.nix args;

  # A fixture with one workspace at `path`, dev profile.
  plainAt =
    path: fixture: modules:
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = fixtures + "/${fixture}";
      modules = [
        {
          workspaces.main = {
            inherit path;
            variants.default.profile = "dev";
          };
        }
      ]
      ++ modules;
    };
  plain = plainAt ".";
  withToolchain = tc: {
    workspaces.main.toolchain = {
      rustc = tc;
      cargo = tc;
    };
  };

  # Fixture name -> the repositories (mkRepository) or workspaces
  # (mkWorkspace) built from it, each optionally as
  # `{ source; except = { variants; plans; }; }` to leave out variants or
  # plans ("build", "test") that fail. Where another test configures the
  # fixture (presets, inputs, stages), that configuration is reused.
  catalog = {
    all-required = [ dynamic.repos.all-required ];
    benches = [ products.repos.benchesRepo ];
    bin-exe-not-built = [ (plain "bin-exe-not-built" [ ]) ];
    build-dep-leak = [ (plain "build-dep-leak" [ ]) ];
    build-script-outputs = [ products.repos.buildScriptOutputs ];
    build-std = [ buildStd.repos.bare ];
    build-std-deps = [ buildStd.repos.hosted ];
    cargo-config = [ dynamic.repos.cargo-config ];
    cdylib-debug = [ products.repos.cdylibDebug ];
    # Its clippy units fail by design (disallowed methods): the default
    # variant only.
    clippy-conf = [ (plainAt "ws" "clippy-conf" [ ]) ];
    # With the setting that lets the host copy's clippy unit pass.
    clippy-host = [ products.repos.clippyHostFixed ];
    crate-types = [ (plain "crate-types" [ ]) ];
    cross-doctests = [ dynamic.repos.cross-doctests-aarch64 ];
    cross-lto = [ presetFixtures.repos.crossLto ];
    declared-paths = [ dynamic.repos.declared-paths ];
    dev-dep-features = [ (plain "dev-dep-features" [ ]) ];
    directives = [ dynamic.repos.directives ];
    doctest-false = [ (plain "doctest-false" [ ]) ];
    doctests = [ dynamic.repos.doctests ];
    docs = [
      products.repos.docsNoDeps
      products.repos.docsDeps
    ];
    doctest-off = [ (plain "doctest-off" [ ]) ];
    embed = [ products.repos.embed ];
    exclusive-features = [ repository.repos.exclusive ];
    feature-unification = [ (plain "feature-unification" [ (withToolchain pkgs.rust-bin.nightly.latest.minimal) ]) ];
    git-multi-workspace = [ (import ../git-multi-workspace args).ws ];
    git-revisions = [ (import ../git-revisions args).repos.repository ];
    linux-portable = [ extraTargets.repos.zigRepo ];
    linux-portable-native = [ extraTargets.repos.zigNativeRepo ];
    manifest-dir = [ dynamic.repos.manifest-dir ];
    missing-input = [ repository.repos.provided ];
    msvc = [ presetFixtures.repos.msvc ];
    multi-ws = [ repository.repos.multiWs ];
    nested-cargo = [ dynamic.repos.nested-cargo ];
    nextest = [ dynamic.repos.nextest ];
    optional-dependency = [ repository.repos.optionalDep ];
    out-dir-walk = [ dynamic.repos.out-dir-walk ];
    outside-reads = [ repository.repos.outside ];
    own-view = [ repository.repos.ownView ];
    pkgid-short = [
      (plainAt "app" "pkgid-short" [
        {
          gitTrees."https://example.invalid/me/gitdep" = fixtures + "/pkgid-short/repo";
          gitTrees."https://example.invalid/me/tools" = fixtures + "/pkgid-short/tools";
        }
      ])
    ];
    port-from-crane = [ products.repos.portFromCrane ];
    post-link = [ products.repos.postLink ];
    required-features = [ repository.repos.rf ];
    riscv64 = [ extraTargets.repos.riscv64Repo ];
    rlib-example = [ dynamic.repos.rlib-example ];
    roots-override = [ repository.repos.rootsOverride ];
    same-triple = [ presetFixtures.repos.sameTriple ];
    same-workspace-products = [ products.repos.sameWsRepo ];
    snapshots = [ repository.repos.snapshots ];
    source-overlay = [ products.repos.sourceOverlayRepo ];
    source-paths = [ products.repos.sourcePaths ];
    sources = [ repository.repos.sources ];
    stamps = [ repository.repos.stampsA ];
    static = [
      presetFixtures.repos.musl
      presetFixtures.repos.glibcStatic
    ];
    static-pkgconfig = [ presetFixtures.repos.staticPkgconfig ];
    stdpaths = [
      (plain "stdpaths" [
        (withToolchain (pkgs.rust-bin.stable."1.99.0".minimal.override { extensions = [ "rust-src" ]; }))
        { targets.${native}.preset = breakbulk.presets.linux; }
      ])
    ];
    sys-native = [ presetFixtures.repos.sysNativeCross ];
    test-closure = [ dynamic.repos.test-closure ];
    test-control = [ dynamic.repos.test-control ];
    test-cutoff = [ (plain "test-cutoff" [ ]) ];
    test-home = [ dynamic.repos.test-home ];
    test-threads = [ dynamic.repos.test-threads ];
    test-only = [ repository.repos.testOnly ];
    trim-paths = [ products.repos.trimPathsRepo ];
    trim-paths-cc = [ products.repos.trimCc ];
    # The `strict` clippy variant fails on lib-a by design.
    ui-dist = [ products.repos.uiDistRepo ];
    variants = [
      {
        source = products.repos.variantsRepo;
        except.variants = [ "strict" ];
      }
    ];
    # With the options its hints name; the fixture fails by design without.
    view-hints = [ repository.repos.viewHintsFixed ];
    walking-skeleton = [ dynamic.repos.walking-skeleton ];
    workspace-members = [ (plain "workspace-members" [ ]) ];
    wasip2 = [ extraTargets.repos.wasip2Repo ];
    wasm-browser = [ presetFixtures.repos.wasmBrowser ];
    wasm-component = [ presetFixtures.repos.wasmComponent ];
    windows-dll = [ extraTargets.repos.windowsDllRepo ];
    windows-gnu = [ extraTargets.repos.windowsGnuRepo ];

    # Fixtures outside tests/fixtures.
    config-env = [ dynamic.repos.config-env ];
    test-options = [ dynamic.repos.test-options ];
    native-link = [ (import ../native-link args).repo ];
    # breakbulk itself.
    self-host = [ (import ../self-host args).repo ];
  };

  skipped = {
    build-script-signal = "a build script dies of a signal by design";
    diagnostics = "a unit fails to compile by design";
    directive-errors = "build scripts print outputs Cargo rejects, by design";
    uefi = "not bit-identical: rustc's temporary symbols.o path lands in the PDB";
    forced-target = "planning fails by design";
    roots-layouts = "root prediction only; nothing is built";
    vendor-collision = "a Cargo build over the vendor directory; fetches GitHub repositories at evaluation";
    vendor-git-inherit = "a Cargo build over the vendor directory";
  };

  # --- what to rebuild ----------------------------------------------------

  wanted = triple: builtins.match targets triple != null;

  # Products Cargo built at least one root of, and their stages.
  productDrvs =
    packages:
    lib.concatMap (p: [ p ] ++ lib.filter lib.isDerivation (lib.attrValues (p.stages or { }))) (
      lib.attrValues (
        lib.filterAttrs (_: d: !(d ? unbuilt) || lib.length d.unbuilt < lib.length (lib.attrNames d.roots)) packages
      )
    );

  sample =
    plan: units:
    let
      ids = lib.attrNames units;
      key = id: builtins.hashString "sha256" "${seed}:${plan}:${id}";
      sorted = lib.sort (a: b: key a < key b) ids;
      n = (lib.length ids + every - 1) / every;
    in
    map (id: units.${id}) (lib.take n sorted);

  unitDrvs =
    except: inst:
    lib.concatMap (plan: sample plan inst.units.${plan}) (
      lib.subtractLists (except.plans or [ ]) [
        "build"
        "test"
      ]
    );

  # One mkWorkspace result: its own target is the native one.
  fromWorkspace = except: ws: {
    products = lib.optionals (wanted native) (productDrvs ws.packages);
    units = lib.optionals (wanted native) (unitDrvs except ws);
  };

  fromRepository =
    except: repo:
    let
      parts = lib.concatLists (
        lib.mapAttrsToList (
          _: w:
          lib.concatLists (
            lib.mapAttrsToList (
              triple: variants:
              lib.optionals (wanted triple) (
                lib.mapAttrsToList (
                  v: inst:
                  let
                    vv = w.target.${triple}.variants.${v};
                  in
                  {
                    # A check or clippy variant's packages are not products.
                    products = lib.optionals (!(vv ? check)) (productDrvs vv.packages);
                    units = unitDrvs except inst;
                  }
                ) (removeAttrs variants (except.variants or [ ]))
              )
            ) w.instances
          )
        ) repo.workspaces
      );
    in
    {
      products = lib.concatMap (p: p.products) parts;
      units = lib.concatMap (p: p.units) parts;
    };

  of =
    x:
    let
      except = x.except or { };
      source = x.source or x;
    in
    if source ? workspaces then fromRepository except source else fromWorkspace except source;

  missing = lib.filter (n: !(catalog ? ${n} || skipped ? ${n})) (
    lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir fixtures))
  );
in
assert lib.assertMsg (missing == [ ])
  "tests/rebuild: fixtures neither in the catalog nor skipped: ${toString missing}";
{
  names = lib.attrNames catalog;
  inherit skipped;
  products = lib.mapAttrs (_: xs: lib.concatMap (x: (of x).products) xs) catalog;
  units = lib.mapAttrs (_: xs: lib.concatMap (x: (of x).units) xs) catalog;
}
