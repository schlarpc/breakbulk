# M3 fixtures: toolchain presets end to end through mkRepository (IFD).
# Imported by ./default.nix; every attribute is a flake check.
#
#   same-triple-*     a marker linker, env and rustflags on the native
#                     triple reach target units only (spec.rs's linker
#                     rewrite; decision 33's key choice with a project
#                     [build] rustflags)
#   static-*          HEAVY-ish (cross toolchains): musl x86_64 and aarch64
#                     and static glibc products have no INTERP or NEEDED;
#                     build scripts stay dynamic; tests run (aarch64 under
#                     qemu-user)
#   presets-eval      evaluation-time assertions on preset values
{
  pkgs,
  breakbulk,
  xwinPkgs ? null,
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  presets = breakbulk.presets;

  rustWith =
    targets:
    pkgs.rust-bin.stable."1.99.0".minimal.override {
      inherit targets;
    };

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      inherit modules;
    };

  evalCheck =
    name: report:
    pkgs.runCommand name { inherit report; } ''
      mkdir -p $out
      printf '%s\n' "$report" > $out/report
    '';

  discard = builtins.unsafeDiscardStringContext;
  planOf = inst: kind: builtins.fromJSON (discard (builtins.readFile "${inst.plans.${kind}}/plan.json"));
  unitText = drv: discard (drv.drvAttrs.BREAKBULK_UNIT or "");

  # Units of both plans of an instance with their plan entry and rendered
  # text: [ { id; kind; platform; name; text; } ].
  unitsOf =
    inst:
    lib.concatMap (
      kind:
      let
        plan = planOf inst kind;
      in
      lib.mapAttrsToList (id: u: {
        inherit id kind;
        inherit (u) platform;
        unitKind = u.kind;
        name = inst.units.${kind}.${id}.name;
        text = unitText inst.units.${kind}.${id};
      }) plan.units
    ) [
      "build"
      "test"
    ];

  # ELF checks on one file: `expect` is "static" (no PT_INTERP, no
  # DT_NEEDED) or "dynamic" (a PT_INTERP). Every ELF the Linux presets link,
  # host or target, is linked by mold (never rustup's rust-lld): mold
  # records itself in `.comment`.
  elfCheck =
    name: expect: file:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.buildPackages.binutils ]; } ''
      f=${file}
      readelf -lW "$f" > ph.txt
      readelf -dW "$f" > dyn.txt || true
      file_info=$(readelf -hW "$f" | grep -E 'Machine|Type')
      echo "$f: $file_info"
      ${
        if expect == "static" then
          ''
            if grep -q INTERP ph.txt; then echo "$f has a PT_INTERP:"; grep INTERP ph.txt; exit 1; fi
            if grep -q NEEDED dyn.txt; then echo "$f has DT_NEEDED entries:"; grep NEEDED dyn.txt; exit 1; fi
          ''
        else
          ''
            grep -q INTERP ph.txt || { echo "$f has no PT_INTERP: expected a dynamic executable"; exit 1; }
          ''
      }
      readelf -p .comment "$f" > comment.txt
      grep -q mold comment.txt || { echo "$f was not linked by mold:"; cat comment.txt; exit 1; }
      if grep -q LLD comment.txt; then echo "$f mentions LLD:"; cat comment.txt; exit 1; fi
      mkdir -p $out
      cp ph.txt dyn.txt comment.txt $out/
    '';

  # The single file of a unit output or product directory.
  oneFile = dir: "$(echo ${dir}/*)";

  # --- same-triple ------------------------------------------------------------

  markerLinker = pkgs.writeShellScript "bb-marker-linker" ''
    exec ${pkgs.stdenv.cc}/bin/cc "$@"
  '';
  sameTriple = mkRepo (fixtures + "/same-triple") [
    {
      workspaces.main.variants.default.profile = "dev";
      targets.${native} = {
        preset = presets.linuxGnu;
        linker = "${markerLinker}";
        env.BB_MARKER = "target-only";
        rustflags = [
          "--cfg"
          "bb_marker_flag"
        ];
      };
    }
  ];
  stInst = sameTriple.workspaces.main.instances.${native}.default;
  stUnits = unitsOf stInst;
  stHostLinker = discard sameTriple.config.targets.${native}.host.linker;
  sameTripleEval =
    let
      host = lib.filter (u: u.platform == "host") stUnits;
      target = lib.filter (u: u.platform == "target") stUnits;
      markers = [
        "bb-marker-linker"
        "BB_MARKER"
        "bb_marker_flag"
        "project_flag"
      ];
      leaks = lib.concatMap (u: map (m: "${u.name}: ${m}") (lib.filter (m: lib.hasInfix m u.text) markers)) host;
      targetCompiles = lib.filter (u: u.unitKind == "compile") target;
      missing = lib.concatMap (
        u: map (m: "${u.name}: ${m}") (lib.filter (m: !(lib.hasInfix m u.text)) markers)
      ) targetCompiles;
      hostCompiles = lib.filter (u: u.unitKind == "compile") host;
      noHostLinker = map (u: u.name) (lib.filter (u: !(lib.hasInfix "linker=${stHostLinker}" u.text)) hostCompiles);
      hostRuns = lib.filter (u: u.unitKind == "run") host;
      runsWithoutHostLinker = map (u: u.name) (
        lib.filter (u: !(lib.hasInfix "\"RUSTC_LINKER\":\"${stHostLinker}\"" u.text)) hostRuns
      );
    in
    assert lib.assertMsg (host != [ ] && hostRuns != [ ]) "same-triple: expected host compiles and runs";
    assert lib.assertMsg (leaks == [ ]) "same-triple: target markers in host units: ${toString leaks}";
    assert lib.assertMsg (missing == [ ]) "same-triple: markers missing from target compiles: ${toString missing}";
    assert lib.assertMsg (noHostLinker == [ ]) "same-triple: host compiles without the host linker: ${toString noHostLinker}";
    assert lib.assertMsg (
      runsWithoutHostLinker == [ ]
    ) "same-triple: host runs without RUSTC_LINKER=<host linker>: ${toString runsWithoutHostLinker}";
    evalCheck "same-triple-eval" "host units: ${toString (map (u: u.name) host)}";

  # --- static -----------------------------------------------------------------

  muslTriples = [
    "x86_64-unknown-linux-musl"
    "aarch64-unknown-linux-musl"
  ];
  staticRust = rustWith muslTriples;
  staticWs = {
    path = ".";
    toolchain = {
      rustc = staticRust;
      cargo = staticRust;
    };
    variants.default.profile = "release";
  };
  musl = mkRepo (fixtures + "/static") [
    {
      workspaces.main = staticWs // {
        targets = lib.genAttrs muslTriples (_: { });
      };
      targets = lib.genAttrs muslTriples (_: {
        preset = presets.linuxMusl;
      });
    }
  ];
  glibcStatic = mkRepo (fixtures + "/static") [
    {
      workspaces.main = staticWs;
      targets.${native}.preset = presets.staticGlibc;
    }
  ];

  # The build-script compile unit of `app` in an instance's build plan.
  buildScriptOf =
    inst:
    let
      plan = planOf inst "build";
      ids = lib.attrNames (
        lib.filterAttrs (_: u: u.kind == "compile" && u.crate.name == "build_script_build" && lib.hasInfix "app" u.package) plan.units
      );
    in
    assert lib.length ids == 1;
    inst.units.build.${lib.head ids}.out;

  staticChecks =
    prefix: repo: triple:
    let
      t = repo.workspaces.main.target.${triple};
      inst = repo.workspaces.main.instances.${triple}.default;
    in
    {
      "${prefix}-product" = elfCheck "${prefix}-product" "static" "${t.packages.app}/bin/app";
      "${prefix}-build-script" = elfCheck "${prefix}-build-script" "dynamic" (oneFile (buildScriptOf inst));
      "${prefix}-test" = t.testRuns.app."bin/app";
    }
    // lib.optionalAttrs (t.runner == null) {
      "${prefix}-run" = pkgs.runCommand "${prefix}-run" { } ''
        ${t.packages.app}/bin/app | tee $out
        grep -q "static ok: mix(6,7)=45" $out
      '';
    };

  # --- evaluation-time checks on preset values ---------------------------------

  presetsEval =
    let
      gnu = presets.linuxGnu {
        inherit pkgs;
        triple = native;
      };
      cross = presets.linuxGnu {
        inherit pkgs;
        triple = "aarch64-unknown-linux-gnu";
      };
      bound = presets.msvc { arch = "x86_64"; };
      llvm = breakbulk.llvmVersions;
      checks = {
        partial = builtins.isFunction bound;
        nativeRunner = gnu.runner.content == null;
        crossRunnerQemu = lib.hasInfix "qemu-aarch64" (discard cross.runner.content);
        crossNativeBuilder =
          (presets.linuxGnu {
            inherit pkgs;
            triple = "aarch64-unknown-linux-gnu";
            nativeBuilder = true;
          }).testSystem.content == "aarch64-linux";
        llvmTable =
          llvm.majorFor "1.95.0" == 22
          && llvm.majorFor "1.98.1" == 22
          && llvm.majorFor "1.99.0" == 23
          && llvm.majorFor "1.101.0-nightly" == 23
          && llvm.majorFor "1.90.0" == 20;
        nixpkgsRustcLlvm = (llvm.packagesFor { inherit pkgs; rustc = pkgs.rustc; }) == pkgs.rustc.llvmPackages;
        overlayRustcLlvm =
          (llvm.packagesFor {
            inherit pkgs;
            rustc = staticRust;
          }).llvm.version == pkgs.llvmPackages_23.llvm.version;
        sameHostLinker = discard gnu.host.linker.content == discard cross.host.linker.content;
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    if failed == [ ] then
      evalCheck "presets-eval" (builtins.toJSON (lib.attrNames checks))
    else
      throw "presets-eval: failed: ${toString failed}";
in
{
  repos = {
    inherit sameTriple musl glibcStatic;
  };
  checks = {
  presets-eval = presetsEval;

  same-triple-eval = sameTripleEval;
  same-triple-build = pkgs.runCommand "same-triple-run" { } ''
    ${sameTriple.workspaces.main.packages.app}/bin/app | tee $out
    grep -qx "marker=target-only shared=target shared-in-build-script=host" $out
  '';
  same-triple-test = sameTriple.workspaces.main.target.${native}.testRuns.app."bin/app";
  # The marker linker execs plain cc, so only the host side is mold.
  same-triple-build-script = elfCheck "same-triple-build-script" "dynamic" (
    oneFile (buildScriptOf stInst)
  );
  }
  // staticChecks "static-glibc" glibcStatic native
// staticChecks "static-musl-x86_64" musl "x86_64-unknown-linux-musl"
// staticChecks "static-musl-aarch64" musl "aarch64-unknown-linux-musl"
  ;
}
