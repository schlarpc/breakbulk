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
#   presets-eval      evaluation-time assertions on preset values (and the
#                     linker choice, lib/presets/linker.nix)
#   debug-outputs     a plain Linux release plan: no unit and no `linked`
#                     stage has a `debug` output (decision 97)
#   msvc-debug-outputs  msvc release: every linked target unit has one
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
  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  planOf =
    inst: kind: builtins.fromJSON (discard (builtins.readFile "${inst.plans.${kind}}/plan.json"));
  unitText = drv: discard (drv.drvAttrs.BREAKBULK_UNIT or "");

  # Units of both plans of an instance with their plan entry and rendered
  # text: [ { id; kind; platform; name; text; } ].
  unitsOf =
    inst:
    lib.concatMap
      (
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
      )
      [
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
      leaks = lib.concatMap (
        u: map (m: "${u.name}: ${m}") (lib.filter (m: lib.hasInfix m u.text) markers)
      ) host;
      targetCompiles = lib.filter (u: u.unitKind == "compile") target;
      missing = lib.concatMap (
        u: map (m: "${u.name}: ${m}") (lib.filter (m: !(lib.hasInfix m u.text)) markers)
      ) targetCompiles;
      hostCompiles = lib.filter (u: u.unitKind == "compile") host;
      noHostLinker = map (u: u.name) (
        lib.filter (u: !(lib.hasInfix "linker=${stHostLinker}" u.text)) hostCompiles
      );
      hostRuns = lib.filter (u: u.unitKind == "run") host;
      runsWithoutHostLinker = map (u: u.name) (
        lib.filter (u: !(lib.hasInfix "\"RUSTC_LINKER\":\"${stHostLinker}\"" u.text)) hostRuns
      );
    in
    assert lib.assertMsg (
      host != [ ] && hostRuns != [ ]
    ) "same-triple: expected host compiles and runs";
    assert lib.assertMsg (leaks == [ ]) "same-triple: target markers in host units: ${toString leaks}";
    assert lib.assertMsg (
      missing == [ ]
    ) "same-triple: markers missing from target compiles: ${toString missing}";
    assert lib.assertMsg (
      noHostLinker == [ ]
    ) "same-triple: host compiles without the host linker: ${toString noHostLinker}";
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

  # Decision 97: a unit has a `debug` output only when rustc writes
  # debuginfo side files (breakbulk-format
  # `writes_debuginfo_side_files`). A plain Linux release build (linuxGnu,
  # no split-debuginfo) has none, in either plan; msvc links always write a
  # PDB, so its release bins and tests have one.
  linuxRelease = mkRepo (fixtures + "/static") [
    {
      workspaces.main = staticWs;
      targets.${native}.preset = presets.linuxGnu;
    }
  ];
  debugOutputs =
    inst:
    lib.concatMap (
      kind:
      lib.mapAttrsToList (id: u: {
        inherit id kind;
        inherit (u) platform;
        links = (u.outputs or { }) ? bin;
        staticlib = (u.crate.types or [ ]) == [ "staticlib" ];
        debug = lib.elem "debug" inst.units.${kind}.${id}.outputs;
      }) (planOf inst kind).units
    ) [ "build" "test" ];
  debugOutputsEval =
    let
      linux = debugOutputs linuxRelease.workspaces.main.instances.${native}.default;
      linuxLinked = lib.filter (u: u.links && u.platform == "target") linux;
      linuxWithDebug = map (u: "${u.kind}/${u.id}") (lib.filter (u: u.debug) linux);
      product = linuxRelease.workspaces.main.target.${native}.packages.app;
    in
    assert lib.assertMsg (linuxLinked != [ ]) "debug-outputs: no linked target units in the Linux plan";
    assert lib.assertMsg (
      linuxWithDebug == [ ]
    ) "debug-outputs: Linux release units with a debug output: ${toString linuxWithDebug}";
    assert lib.assertMsg (!(product.roots."bin/app" ? debug)) "debug-outputs: the Linux root has a debug output";
    assert lib.assertMsg (
      !(product.stages.linked ? debug)
    ) "debug-outputs: the Linux product's linked stage has a debug output";
    evalCheck "debug-outputs" "linked Linux release units without debug: ${toString (lib.length linuxLinked)}";
  msvcDebugOutputsEval =
    let
      units = debugOutputs msvc.workspaces.main.instances.x86_64-pc-windows-msvc.default;
      linked = lib.filter (u: u.links && u.platform == "target") units;
      # Release (no debuginfo, `-C strip=debuginfo`): still a PDB.
      bad = map (u: "${u.kind}/${u.id}") (
        lib.filter (u: u.debug != (u.platform == "target" && u.links && !u.staticlib)) units
      );
    in
    assert lib.assertMsg (linked != [ ]) "msvc-debug-outputs: no linked target units";
    assert lib.assertMsg (bad == [ ]) "msvc-debug-outputs: wrong debug outputs: ${toString bad}";
    evalCheck "msvc-debug-outputs" "linked msvc release units with debug: ${toString (lib.length linked)}";

  # The build-script compile unit of `app` in an instance's build plan.
  buildScriptOf =
    inst:
    let
      plan = planOf inst "build";
      ids = lib.attrNames (
        lib.filterAttrs (
          _: u: u.kind == "compile" && u.crate.name == "build_script_build" && lib.hasInfix "app" u.package
        ) plan.units
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
      "${prefix}-build-script" = elfCheck "${prefix}-build-script" "dynamic" (
        oneFile (buildScriptOf inst)
      );
      "${prefix}-test" = t.testRuns.app."bin/app";
    }
    // lib.optionalAttrs (t.runner == null) {
      "${prefix}-run" = pkgs.runCommand "${prefix}-run" { } ''
        ${t.packages.app}/bin/app | tee $out
        grep -q "static ok: mix(6,7)=45" $out
      '';
    };

  # --- cross sys-native (aarch64) ----------------------------------------------
  #
  # M1's sys-native fixture for aarch64-unknown-linux-gnu: pkg-config +
  # openssl, cmake and bindgen + cc, each declared on its own package and
  # captured with the aarch64 cross stdenv for target units. The product
  # runs under qemu-user.

  a64 = "aarch64-unknown-linux-gnu";
  crossRust = rustWith [ a64 ];
  sysNativeCross = mkRepo (fixtures + "/sys-native") [
    {
      workspaces.main = {
        toolchain = {
          rustc = crossRust;
          cargo = crossRust;
        };
        targets.${a64} = { };
        variants.default.profile = "dev";
      };
      targets.${a64}.preset = presets.linuxGnu;
      packages = {
        openssl-sys = {
          nativeInputs = p: [ p.pkg-config ];
          inputs = p: [ p.openssl ];
        };
        cm-sys.nativeInputs = p: [ p.cmake ];
        bg-sys.nativeInputs = p: [ p.rustPlatform.bindgenHook ];
      };
    }
  ];
  sysNativeCrossChecks =
    let
      t = sysNativeCross.workspaces.main.target.${a64};
    in
    {
      sys-native-aarch64 =
        pkgs.runCommand "sys-native-aarch64" { nativeBuildInputs = [ pkgs.buildPackages.binutils ]; }
          ''
            readelf -hW ${t.packages.app}/bin/app | grep -q 'Machine:.*AArch64'
            ${lib.escapeShellArgs t.runner} ${t.packages.app}/bin/app | tee $out
            grep -qx "openssl=3+ cm=42 bg=7 plain-saw=none" $out
          '';
    };

  # --- msvc ---------------------------------------------------------------------
  #
  # C (clang-cl), bindgen, and a resource linked with rustc-link-arg-bins,
  # through the msvc preset. x86_64 runs (product and tests) under wine;
  # aarch64 compiles and links. msvc-x86_64-pdb: with debug info, the PDB
  # is in the product's `debug` output.

  msvcTriples = [
    "x86_64-pc-windows-msvc"
    "aarch64-pc-windows-msvc"
  ];
  msvcRust = rustWith msvcTriples;
  sdk = breakbulk.xwinSdk {
    pkgs = xwinPkgs;
    manifestVersion = 17;
    crt = "14.44.17.14";
    sdk = "10.0.26100";
    arches = [
      "x86_64"
      "aarch64"
    ];
    hash = "sha256-22dqk0tKSbC4bnfsnhhsG0aEJfUHb3JJNL3TnZGFVa0=";
  };
  msvc = mkRepo (fixtures + "/msvc") [
    {
      workspaces.main = {
        toolchain = {
          rustc = msvcRust;
          cargo = msvcRust;
        };
        targets = lib.genAttrs msvcTriples (_: { });
        variants.default.profile = "release";
        # Debug info on (the fixture's `release-debug` profile): a PDB.
        variants.debuginfo.profile = "release-debug";
      };
      targets = lib.genAttrs msvcTriples (_: {
        preset = presets.msvc {
          inherit sdk;
          rustc = msvcRust;
        };
      });
    }
  ];
  msvcChecks =
    let
      t = triple: msvc.workspaces.main.target.${triple};
      x = t "x86_64-pc-windows-msvc";
      a = t "aarch64-pc-windows-msvc";
      expect = "smoke: c_add=42 pid_match=true resource=resource-ok";
    in
    lib.optionalAttrs (xwinPkgs != null) {
      msvc-x86_64-run = pkgs.runCommand "msvc-x86_64-run" { } ''
        ${lib.escapeShellArgs x.runner} ${x.packages.msvc-smoke}/bin/msvc-smoke.exe > out.txt
        tr -d '\r' < out.txt | tee $out
        grep -qxF ${lib.escapeShellArg expect} $out
      '';
      msvc-x86_64-test = x.testRuns.msvc-smoke."bin/msvc-smoke";
      # Decision 89: with debug info on, lld-link writes a PDB. It lands in
      # the product's `debug` output next to where the .exe sits in the
      # main one (bin/), not in the main output; the main output's closure
      # has no unit outputs (rlibs) and no sources, and the program runs.
      # The PDB works: with the .exe and the debug output's PDB side by
      # side (as a debugger sees them), llvm-symbolizer resolves the
      # address of `msvc_smoke::main` (from the PDB's public symbols) to
      # the function, with inlined frames, and to src/main.rs and a line
      # in the source view, which the debug output references.
      msvc-x86_64-pdb =
        let
          p = x.variants.debuginfo.packages.msvc-smoke;
        in
        assert lib.assertMsg (p ? debug) "msvc-x86_64-pdb: the product has no debug output";
        pkgs.runCommand "msvc-x86_64-pdb"
          {
            nativeBuildInputs = [ pkgs.llvmPackages.llvm ];
            closure = pkgs.closureInfo { rootPaths = [ p ]; };
            debug = p.debug;
            noSources = p.checks.noSourceReferences;
          }
          ''
            set -euo pipefail
            ls -la ${p}/bin $debug/bin
            pdbs=($debug/bin/*.pdb)
            [ -f "''${pdbs[0]}" ] || { echo "no PDB in the debug output" >&2; exit 1; }
            # An MSF 7.0 file (the PDB format).
            head -c 29 "''${pdbs[0]}" | grep -q 'Microsoft C/C++ MSF 7.00' || { echo "not a PDB: ''${pdbs[0]}" >&2; exit 1; }
            if find ${p}/ -name '*.pdb' | grep .; then
              echo "a PDB in the main output" >&2; exit 1
            fi
            # The .exe names its PDB by file name only (rustc passes
            # /PDBALTPATH:%_PDB%), the name the debug output uses.
            grep -qaF "$(basename "''${pdbs[0]}")" ${p}/bin/msvc-smoke.exe
            if grep -E -- '-(rlib|rmeta|lib-rlib|bin|debug)$' $closure/store-paths; then
              echo "the main output references unit outputs" >&2; exit 1
            fi
            ${lib.escapeShellArgs x.runner} ${p}/bin/msvc-smoke.exe | tr -d '\r' > out.txt
            grep -qxF ${lib.escapeShellArg expect} out.txt
            # Symbolize: main's section:offset from the PDB's publics, the
            # section's RVA and the image base from the .exe.
            mkdir dbg
            cp ${p}/bin/msvc-smoke.exe "''${pdbs[0]}" dbg/
            llvm-pdbutil dump --publics "''${pdbs[0]}" > publics.txt
            read -r sec off < <(grep -A1 'msvc_smoke4main`' publics.txt \
              | sed -n 's/.*addr = \([0-9]*\):\([0-9]*\).*/\1 \2/p' | head -n1)
            llvm-readobj --file-headers --sections dbg/msvc-smoke.exe > headers.txt
            base=$(sed -n 's/^ *ImageBase: \(0x[0-9A-Fa-f]*\)$/\1/p' headers.txt)
            rva=$(sed -n 's/^ *VirtualAddress: \(0x[0-9A-Fa-f]*\)$/\1/p' headers.txt | sed -n "$((10#$sec))p")
            addr=$(printf '0x%x' $((base + rva + 0x$off)))
            llvm-symbolizer --obj=dbg/msvc-smoke.exe "$addr" | tee sym.txt
            grep -qx 'msvc_smoke::main' sym.txt
            grep -E '^/nix/store/[^/]*-source/src/main.rs:[0-9]+:[0-9]+$' sym.txt > lines.txt
            # The source file the PDB names is there (the debug output
            # references it) and its line is main's.
            src=$(head -n1 lines.txt | cut -d: -f1)
            line=$(head -n1 lines.txt | cut -d: -f2)
            sed -n "''${line}p" "$src" | tee line.txt
            grep -q 'fn main\|c_add\|pids' line.txt
            mkdir -p $out
            basename "''${pdbs[0]}" > $out/pdb
            cp sym.txt $out/
          '';
      msvc-aarch64-build = pkgs.runCommand "msvc-aarch64-build" { nativeBuildInputs = [ pkgs.file ]; } ''
        file ${a.packages.msvc-smoke}/bin/msvc-smoke.exe | tee $out
        grep -qi 'PE32+ executable.*\(aarch64\|arm64\)' $out
      '';
    };

  # --- wasm ----------------------------------------------------------------------

  wasm = "wasm32-unknown-unknown";
  wasmRust = rustWith [ wasm ];
  wasmWs = {
    toolchain = {
      rustc = wasmRust;
      cargo = wasmRust;
    };
    targets.${wasm} = { };
    variants.default.profile = "release";
  };

  # wasm-bindgen + ring (C via unwrapped clang) + getrandom's wasm_js cfg
  # from the project's config; tests under wasm-bindgen-test-runner (Node),
  # the runner matching the locked wasm-bindgen.
  wasmBrowser = mkRepo (fixtures + "/wasm-browser") [
    {
      workspaces.main = wasmWs;
      targets.${wasm}.preset = presets.wasmBrowser { rustc = wasmRust; };
    }
  ];
  # Package inputs on a target without a package set (field trials: the
  # curated libsqlite3-sys default failed evaluation of a workspace with a
  # wasm32 target whose wasm plan never builds it). Host units get the
  # build machine's capture; target units would fail when built.
  wasmHostInputs = mkRepo (fixtures + "/wasm-browser") [
    {
      workspaces.main = wasmWs;
      targets.${wasm}.preset = presets.wasmBrowser { rustc = wasmRust; };
      packages.wasm-bindgen-macro.inputs = p: [ p.zlib ];
    }
  ];
  wasmHostInputsCheck =
    let
      i = wasmHostInputs.workspaces.main.instances.${wasm}.default;
      macro = lib.filter (u: u.name == "wasm-bindgen-macro-0.2.130-lib") (lib.attrValues i.units.build);
      capture = builtins.fromJSON (unitText (lib.head macro));
    in
    assert lib.assertMsg (lib.length macro == 1) "wasm-host-inputs: no wasm-bindgen-macro unit";
    assert lib.assertMsg (lib.hasInfix "breakbulk-env-wasm-bindgen-macro" (capture.envCapture or ""))
      "wasm-host-inputs: the macro's unit has capture ${capture.envCapture or "none"}";
    pkgs.runCommand "wasm-host-inputs" {
      ui = wasmHostInputs.workspaces.main.target.${wasm}.packages.ui;
    } "ls $ui/pkg/*.wasm > $out";
  wasmBrowserChecks =
    let
      t = wasmBrowser.workspaces.main.target.${wasm};
      product = breakbulk.mkProduct {
        name = "ui";
        linked = t.packages.ui.roots."cdylib/ui";
        stages = breakbulk.stages.defaultStages.wasmBrowser;
        target.triple = wasm;
        info.lockfile = fixtures + "/wasm-browser/Cargo.lock";
        inherit pkgs;
      };
    in
    {
      wasm-browser-test = t.testRuns.ui.web;
      # The bindgen stage with the lockfile-matched CLI (0.2.130), then
      # wasm-opt; the JS glue loads in Node and computes the digest.
      wasm-browser-bindgen =
        pkgs.runCommand "wasm-browser-bindgen"
          {
            nativeBuildInputs = [ pkgs.nodejs ];
            bindgen = product.stages.bindgen;
          }
          ''
            ls $bindgen ${product}
            cp -r ${product.stages.bindgen} pkg
            chmod -R u+w pkg
            # --target web glue: instantiate from bytes in Node.
            cat > run.mjs <<'EOF'
            import fs from 'node:fs';
            import init, { digest_hex } from './pkg/ui.js';
            await init({ module_or_path: fs.readFileSync('./pkg/ui_bg.wasm') });
            console.log(digest_hex('abc'));
            EOF
            node run.mjs | tee $out
            grep -qx ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad $out
          '';
    };

  # C via wasilibc, componentized, no imports.
  wasmComponent = mkRepo (fixtures + "/wasm-component") [
    {
      workspaces.main = wasmWs;
      targets.${wasm}.preset = presets.wasmComponent {
        rustc = wasmRust;
        withC = true;
      };
    }
  ];
  wasmComponentChecks =
    let
      t = wasmComponent.workspaces.main.target.${wasm};
      product = breakbulk.mkProduct {
        name = "comp";
        linked = t.packages.comp.roots."cdylib/comp";
        stages = breakbulk.stages.merge [
          breakbulk.stages.defaultStages.wasmComponent
          {
            componentize.run = breakbulk.stageHelpers.componentize {
              metadata = {
                name = "comp";
                processedBy.breakbulk = "0.1.0";
              };
            };
          }
        ];
        target.triple = wasm;
        inherit pkgs;
      };
    in
    {
      wasm-component = pkgs.runCommand "wasm-component" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
        core=$(echo ${t.packages.comp.roots."cdylib/comp"}/*.wasm)
        comp=$(echo ${product.stages.componentize}/*.wasm)
        wasm-tools print "$core" > core.wat
        if grep -q '(import' core.wat; then echo "the core module has imports:"; grep '(import' core.wat; exit 1; fi
        grep -q '(export "checksum"' core.wat
        wasm-tools validate --features component-model "$comp"
        wasm-tools component wit "$comp" > comp.wit
        cat comp.wit
        if grep -q '^ *import' comp.wit; then echo "the component has imports"; exit 1; fi
        wasm-tools metadata show "$comp" | tee meta.txt
        grep -q breakbulk meta.txt
        mkdir -p $out
        cp core.wat comp.wit meta.txt $out/
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
        # Outside the table (decision 41): null from the table, and the
        # LLVM major read from `rustc -vV` (import-from-derivation). The
        # toolchains are 1.97 (LLVM 22) and 1.99 (LLVM 23), given a version
        # the table does not know, or none.
        llvmOutsideTable =
          llvm.lookup "1.102.0" == null
          && llvm.lookup "1.89.0" == null
          && llvm.lookup "unknown" == null
          && llvm.lookup "1.101.0-nightly-2026-11-01" == 23;
        llvmProbe =
          let
            r97 = pkgs.rust-bin.stable."1.97.0".minimal;
          in
          lib.versions.major
            (llvm.packagesFor {
              inherit pkgs;
              rustc = r97 // {
                version = "1.300.0";
              };
            }).llvm.version == "22"
          && llvm.probe {
            inherit pkgs;
            rustc = removeAttrs staticRust [ "version" ];
          } == 23;
        nixpkgsRustcLlvm =
          (llvm.packagesFor {
            inherit pkgs;
            rustc = pkgs.rustc;
          }) == pkgs.rustc.llvmPackages;
        overlayRustcLlvm =
          (llvm.packagesFor {
            inherit pkgs;
            rustc = staticRust;
          }).llvm.version == pkgs.llvmPackages_23.llvm.version;
        sameHostLinker = discard gnu.host.linker.content == discard cross.host.linker.content;
        # The linker choice (lib/presets/linker.nix), one rule per kind.
        linkerKinds =
          let
            k = triple: args: presets.linkerKind ({ inherit triple; } // args);
          in
          k native { } == "mold"
          && k "aarch64-unknown-linux-musl" { } == "mold"
          && k "riscv64gc-unknown-linux-gnu" { } == "mold"
          && k native { lto = true; } == "clang-lld"
          && k native { flavor = "zig"; } == "zig"
          && k "x86_64-pc-windows-msvc" { } == "lld-link"
          && k "aarch64-pc-windows-msvc" { lto = true; } == "lld-link"
          && k "x86_64-pc-windows-gnu" { } == "mingw-lld"
          && k "x86_64-pc-windows-gnullvm" { } == "mingw-lld"
          && k "wasm32-unknown-unknown" { } == "wasm-ld"
          && k "wasm32-wasip1" { } == "wasm-ld"
          && k "wasm32-wasip2" { } == "wasm-component-ld"
          && fails (k "aarch64-apple-darwin" { })
          && fails (k native { flavor = "gold"; });
        # `crtStatic = true` adds the flag (the option once shadowed the
        # flag list, and the preset failed with "expected a list but found
        # a Boolean"; found in the field trials).
        msvcCrtStatic =
          let
            p = presets.msvc {
              inherit pkgs;
              arch = "x86_64";
              llvmMajor = 22;
              crtStatic = true;
              sdk = {
                includeDirs = [ "/inc" ];
                libDirs.x86_64 = [ "/lib" ];
              };
            };
          in
          lib.elem "target-feature=+crt-static" p.rustflags;
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
    inherit
      sameTriple
      musl
      glibcStatic
      sysNativeCross
      msvc
      wasmBrowser
      wasmComponent
      ;
  };
  checks = {
    presets-eval = presetsEval;
    debug-outputs = debugOutputsEval;
    wasm-host-inputs = wasmHostInputsCheck;

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
  // sysNativeCrossChecks
  // msvcChecks
  // lib.optionalAttrs (xwinPkgs != null) { msvc-debug-outputs = msvcDebugOutputsEval; }
  // wasmBrowserChecks
  // wasmComponentChecks;
}
