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
#   };
#
#   ws.packages.<bin>          the bin, installed as $out/bin/<bin>
#   ws.libs.<pkg>.<kind>       a library's cdylib/staticlib/dylib output
#   ws.roots."<pkg>/<kind>/<target>"   build-plan roots (unit outputs or stubs)
#   ws.tests."<pkg>/<kind>/<target>"   test-plan roots
#   ws.plans.{build,test}      the plan derivations ($out/plan.json)
#   ws.units.{build,test}      every unit derivation, by unit id
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
  tools ? mkTools pkgs,
  name ? "breakbulk",
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
  views = sourceViews.workspaceViews { inherit root wsDir; };
  workspace = lib.mapAttrs' (_: v: lib.nameValuePair v.dir v.src) views;

  plans = lib.genAttrs [ "build" "test" ] (
    kind:
    mkPlan pkgs {
      inherit
        vendor
        tools
        kind
        target
        profile
        features
        configs
        wsDir
        ;
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
      inherit pkgs;
      platform = "target";
    };
  };

  wsRoots = roots.workspaceRoots { inherit root wsDir; };

  inst =
    kind:
    instantiate {
      breakbulkInstantiate = tools.breakbulk-instantiate;
      inherit system;
      plan = "${plans.${kind}}/plan.json";
      sources = { inherit workspace crates; };
      tools = {
        rustc = toolchain.rustc;
        # The sysroot, which Cargo puts on build scripts' library path.
        rustc-sysroot = toolchain.rustc.unwrapped or toolchain.rustc;
        cargo = toolchain.cargo;
        breakbulk-unit = "${tools.breakbulk-unit}/bin/breakbulk-unit";
        shell = "${pkgs.bash}/bin/bash";
      };
      host.envCapture = captures.host;
      target.envCapture = captures.target;
      roots = predictedRoots {
        workspaceRoots = wsRoots;
        planKind = kind;
        variant = profile;
      };
      name = "${name}-${kind}-units";
    };
  built = inst "build";
  tested = inst "test";

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

  bins = lib.filterAttrs (_: r: r.breakbulkRoot.kind == "bin" && !r.breakbulkRoot.test) built.roots;
in
{
  inherit
    plans
    vendor
    tools
    captures
    ;
  skeleton = skel;
  sources = { inherit workspace crates; };
  roots = built.roots;
  tests = tested.roots;
  units = {
    build = built.units;
    test = tested.units;
  };
  unitsJson = {
    build = built.unitsJson;
    test = tested.unitsJson;
  };
  packages = lib.mapAttrs' (
    _: r: lib.nameValuePair r.breakbulkRoot.target (install "bin" r.breakbulkRoot.target r)
  ) bins;
  # Test binaries by root name, installed as $out/bin/<target>.
  testBins = lib.mapAttrs (
    _: r: if r.breakbulkRoot.unit == null then r else install "bin" r.breakbulkRoot.target r
  ) tested.roots;
}
