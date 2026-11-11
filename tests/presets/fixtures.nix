# Toolchain presets end to end through mkRepository (IFD).
# Imported by ./default.nix; every attribute is a flake check.
#
#   same-triple-*     a marker linker, env and rustflags on the native
#                     triple reach target units only (spec.rs's linker
#                     rewrite; the spec's rustflags go under the
#                     project's own [build] rustflags key)
#   static-*          HEAVY-ish (cross toolchains): musl x86_64 and aarch64
#                     and static glibc products have no INTERP or NEEDED;
#                     build scripts stay dynamic; tests run (aarch64 under
#                     qemu-user)
#   static-pkgconfig-musl-*   a musl product links a library found with
#                     pkg-config (both .a and .so present) statically
#   presets-eval      evaluation-time assertions on preset values (and the
#                     linker choice, lib/presets/linker.nix)
#   presets-per-workspace  two workspaces on different Rust releases get
#                     their own LLVM tools and wasi-sdk from one preset
#   debug-outputs     a plain Linux release plan: no unit and no `linked`
#                     stage has a `debug` output
#   msvc-debug-outputs  msvc release: every linked target unit has one
#   cross-lto         linux { crossLanguageLto = true; }: the build
#                     script's C is bitcode, and lld inlines it into its
#                     Rust caller (the plain linux preset does not); the
#                     archive and the linked binary rebuild byte for byte
{
  pkgs,
  breakbulk,
  xwinPkgs ? null,
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
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
      modules = modules ++ extraModules;
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
        preset = presets.linux;
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
  stHostLinker = discard sameTriple.workspaces.main.target.${native}.spec.host.linker;
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
        preset = presets.linuxStatic;
      });
    }
  ];
  # A C library with both static and shared builds and a pkg-config file,
  # built for the target package set `p`. libbbfoo uses libbbbar, a private
  # dependency: the shared libbbfoo.so names it itself, the static
  # libbbfoo.a needs `-lbbbar` too, which pkg-config gives only with
  # `--static` (`Libs.private`).
  bbfoo =
    p:
    p.stdenv.mkDerivation {
      name = "bbfoo";
      dontUnpack = true;
      buildPhase = ''
        echo 'int bbbar_base(void) { return 40; }' > bbbar.c
        echo 'int bbbar_base(void); int bbfoo_answer(void) { return bbbar_base() + 2; }' > bbfoo.c
        for l in bbbar bbfoo; do
          $CC -c -fPIC $l.c -o $l.o
          $AR rcs lib$l.a $l.o
        done
        $CC -shared -o libbbbar.so bbbar.o
        $CC -shared -o libbbfoo.so bbfoo.o -L. -lbbbar
      '';
      installPhase = ''
        mkdir -p $out/lib/pkgconfig
        cp lib*.a lib*.so $out/lib/
        cat > $out/lib/pkgconfig/bbfoo.pc <<EOF
        libdir=$out/lib
        Name: bbfoo
        Description: breakbulk test library
        Version: 1.0
        Libs: -L\''${libdir} -lbbfoo
        Libs.private: -lbbbar
        EOF
      '';
    };
  # The -sys crate finds it with pkg-config (static-pkgconfig fixture).
  staticPkgconfig = mkRepo (fixtures + "/static-pkgconfig") [
    {
      workspaces.main = staticWs // {
        targets."x86_64-unknown-linux-musl" = { };
      };
      targets."x86_64-unknown-linux-musl".preset = presets.linuxStatic;
      packages.foo-sys = {
        nativeInputs = p: [ p.pkg-config ];
        inputs = p: [ (bbfoo p) ];
      };
    }
  ];
  glibcStatic = mkRepo (fixtures + "/static") [
    {
      workspaces.main = staticWs;
      targets.${native}.preset = presets.linuxStatic;
    }
  ];

  # A unit has a `debug` output only when rustc writes
  # debuginfo side files (breakbulk-format
  # `writes_debuginfo_side_files`). A plain Linux release build (linux,
  # no split-debuginfo) has none, in either plan; msvc links always write a
  # PDB, so its release bins and tests have one.
  linuxRelease = mkRepo (fixtures + "/static") [
    {
      workspaces.main = staticWs;
      targets.${native}.preset = presets.linux;
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
  # The sys-native fixture for aarch64-unknown-linux-gnu: pkg-config +
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
      targets.${a64}.preset = presets.linux;
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
  # is in the product's `debug` output. msvc-x86_64-relink: the link is
  # reproducible (#35).

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
      # LLVM tools for the workspace's rustc.
      targets = lib.genAttrs msvcTriples (_: {
        preset = presets.windows { inherit sdk; };
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
      # With debug info on, lld-link writes a PDB. It lands in
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
      # #35 (assumption X4): the lld-link wrapper keeps msvc links
      # reproducible by copying inputs out of rustc's random
      # `rustcXXXXXX` link directory. The bin unit (debug info on, so a
      # PDB) is linked by hand twice with the same output paths: the .exe
      # and .pdb are byte-identical, and the wrapper copied at least one
      # input (a rename of rustc's directory would leave none). Negative
      # control: with plain lld-link in the wrapper's place, the two links
      # differ, so the comparison can see the random directory.
      msvc-x86_64-relink =
        let
          unit =
            (lib.findFirst (u: u.name == "msvc-smoke-0.1.0-bin") (throw "msvc-x86_64-relink: no bin unit") (
              lib.attrValues msvc.workspaces.main.instances.x86_64-pc-windows-msvc.debuginfo.units.build
            )).drvAttrs.BREAKBULK_UNIT;
        in
        pkgs.runCommand "msvc-x86_64-relink"
          {
            inherit unit;
            passAsFile = [ "unit" ];
          }
          ''
            set -euo pipefail
            result=$out
            wrapper=$(grep -o '/nix/store/[^" ]*/bin/lld-link-stable' "$unitPath" | head -n1)
            [ -n "$wrapper" ] || { echo "the unit does not link with lld-link-stable" >&2; exit 1; }
            link() {
              rm -rf "$TMPDIR/unit-out" "$TMPDIR/unit-debug" "$TMPDIR/breakbulk-lld-link" /tmp/breakbulk-lld-link
              BREAKBULK_UNIT="$(cat "$2")" out=$TMPDIR/unit-out debug=$TMPDIR/unit-debug \
                ${tools.breakbulk-unit}/bin/breakbulk-unit unit 2> "$1.log" || { cat "$1.log"; exit 1; }
              mkdir "$1"
              cp -r "$TMPDIR/unit-out" "$1/out"
              cp -r "$TMPDIR/unit-debug" "$1/debug"
              find "$TMPDIR/breakbulk-lld-link" /tmp/breakbulk-lld-link -type f 2> /dev/null > "$1.copied" || true
            }
            link run1 "$unitPath"
            link run2 "$unitPath"
            ls -lR run1
            ls run1/debug | grep -q '\.pdb$' || { echo "no PDB" >&2; exit 1; }
            cat run1.copied
            [ -s run1.copied ] || { echo "the wrapper copied no rustcXXXXXX input" >&2; exit 1; }
            diff -r run1 run2

            # Negative control: plain lld-link, two links differ.
            mkdir -p raw/bin
            printf '#!%s\nexec %s "$@"\n' ${pkgs.runtimeShell} \
              "$(sed -n 's/^LLD_LINK=//p' "$wrapper")" > raw/bin/lld-link-stable
            chmod +x raw/bin/lld-link-stable
            sed "s|$wrapper|$PWD/raw/bin/lld-link-stable|g" "$unitPath" > raw.json
            link raw1 raw.json
            link raw2 raw.json
            if diff -rq raw1 raw2; then
              echo "plain lld-link links reproducibly too; the check cannot see the random directory" >&2
              exit 1
            fi
            mkdir -p $result
            cp run1.copied $result/
          '';
      msvc-aarch64-build = pkgs.runCommand "msvc-aarch64-build" { nativeBuildInputs = [ pkgs.file ]; } ''
        file ${a.packages.msvc-smoke}/bin/msvc-smoke.exe | tee $out
        grep -qi 'PE32+ executable.*\(aarch64\|arm64\)' $out
      '';
      msvc-post-link = msvcPostLinkCheck;
    };

  # --- post-link on msvc ---------------------------------------------------------
  #
  # The post-link fixture for x86_64-pc-windows-msvc with a Windows
  # pipeline: `stageDlls` copies the VC++ runtime DLLs the .exe imports
  # next to it, `sign` appends an overlay to the .exe (where an Authenticode
  # signature goes), `deterministicZip` packs the result. A check on
  # `linked` sees the .exe as the linker wrote it. The DLLs come from wine
  # (no redistributable DLLs in the xwin download); wine runs the unpacked
  # zip.

  msvcX86 = "x86_64-pc-windows-msvc";
  msvcPostLinkRust = rustWith [ msvcX86 ];
  wine = pkgs.wineWow64Packages.minimal;

  # Copies each imported DLL named like the VC++ redistributable's from
  # `dllDir`; OS DLLs (kernel32, api-ms-win-*) are never staged.
  stageRuntimeDlls =
    dllDir:
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-stage-dlls" { nativeBuildInputs = [ pkgs.llvmPackages.llvm ]; } ''
      set -euo pipefail
      mkdir -p $out
      cp -RL --no-preserve=mode,ownership ${input}/. $out/
      for exe in $out/*.exe; do
        llvm-readobj --coff-imports "$exe" | sed -n 's/^ *Name: \(.*\.dll\)$/\1/Ip'
      done | tr 'A-Z' 'a-z' | LC_ALL=C sort -u > imports.txt
      cat imports.txt
      grep -E '^(vcruntime|msvcp)[0-9_a-z]*\.dll$' imports.txt > runtime.txt || true
      [ -s runtime.txt ] || { echo "no VC++ runtime import" >&2; exit 1; }
      while read -r dll; do
        cp ${dllDir}/"$dll" $out/
      done < runtime.txt
    '';

  # Appends a fixed marker to every .exe: a PE ignores bytes past its
  # last section, so the program still runs.
  signExe =
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-sign" { } ''
      mkdir -p $out
      cp -RL --no-preserve=mode,ownership ${input}/. $out/
      for exe in $out/*.exe; do printf 'BREAKBULK-SIGNED' >> "$exe"; done
    '';

  # Fails unless the .exe has no overlay marker and no DLL beside it.
  unsignedExe =
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-unsigned" { nativeBuildInputs = [ pkgs.file ]; } ''
      set -euo pipefail
      ls -la ${input}/
      exe=$(echo ${input}/*.exe)
      file -L "$exe" | grep -q 'PE32+ executable'
      if grep -qaF BREAKBULK-SIGNED "$exe"; then echo "$exe is signed" >&2; exit 1; fi
      if find -L ${input}/ -iname '*.dll' | grep .; then echo "DLLs in linked" >&2; exit 1; fi
      sha256sum "$exe" > $out
    '';

  msvcPostLink = mkRepo (fixtures + "/post-link") [
    {
      workspaces.main = {
        toolchain = {
          rustc = msvcPostLinkRust;
          cargo = msvcPostLinkRust;
        };
        targets.${msvcX86} = { };
        variants.default.profile = "dev";
      };
      targets.${msvcX86} = {
        preset = presets.windows { inherit sdk; };
        checks.unsigned = {
          on = "linked";
          run = unsignedExe;
        };
      };
      packages.server.target.${msvcX86}.stages = {
        stageDlls = {
          after = "linked";
          run = stageRuntimeDlls "${wine}/lib/wine/x86_64-windows";
        };
        sign = {
          after = "stageDlls";
          run = signExe;
        };
        zip = {
          after = "sign";
          run = breakbulk.stageHelpers.deterministicZip;
        };
      };
    }
  ];
  msvcPostLinkCheck =
    let
      t = msvcPostLink.workspaces.main.target.${msvcX86};
      server = t.packages.server;
      tool = t.packages.tool;
    in
    assert lib.assertMsg (
      server.stageOrder == [
        "stageDlls"
        "sign"
        "zip"
        "install"
      ]
    ) "msvc-post-link: server stages ${builtins.toJSON server.stageOrder}";
    assert lib.assertMsg (
      tool.stageOrder == [ "install" ]
    ) "msvc-post-link: tool stages ${builtins.toJSON tool.stageOrder}";
    pkgs.runCommand "msvc-post-link"
      {
        nativeBuildInputs = [ pkgs.unzip ];
        linked = server.stages.linked;
        unsigned = server.checks.unsigned;
        toolUnsigned = tool.checks.unsigned;
        zip = server.stages.zip;
      }
      ''
        set -euo pipefail
        ls -la $linked ${server} $zip
        # The check's .exe is linked's, unchanged.
        [ "$(cut -d' ' -f1 $unsigned)" = "$(sha256sum $linked/server.exe | cut -d' ' -f1)" ]
        unzip -Z1 $zip/server.zip | tee entries.txt
        grep -qx server.exe entries.txt
        grep -qx vcruntime140.dll entries.txt
        ! grep -q '\.pdb$' entries.txt
        # The product carries the zip; the .exe in it is signed.
        cmp ${server}/server.zip $zip/server.zip
        mkdir x && (cd x && unzip -q $zip/server.zip)
        grep -qaF BREAKBULK-SIGNED x/server.exe
        ${lib.escapeShellArgs t.runner} x/server.exe a b | tr -d '\r' > out.txt
        grep -qx 'server 3' out.txt
        mkdir -p $out
        cp entries.txt $out/
      '';

  # --- cross-language LTO --------------------------------------------------------
  #
  # linux { crossLanguageLto = true; } on the native triple: the build
  # script's C (cc-rs, the preset's clang, `-flto=thin`) is an archive of
  # LLVM bitcode, and lld, given rustc's bitcode too, inlines the C function
  # into its Rust caller: the product has no `cross_lto_mix`, and the
  # caller computes the C constant itself. Negative control: the plain
  # linux preset keeps the symbol and the call.

  crossLtoRust = rustWith [ ];
  crossLtoWith =
    preset:
    mkRepo (fixtures + "/cross-lto") [
      {
        workspaces.main = {
          toolchain = {
            rustc = crossLtoRust;
            cargo = crossLtoRust;
          };
          targets.${native} = { };
          variants.default.profile = "release";
        };
        targets.${native}.preset = preset;
      }
    ];
  crossLto = crossLtoWith (presets.linux { crossLanguageLto = true; });
  crossLtoOff = crossLtoWith presets.linux;
  crossLtoCheck =
    let
      ws = crossLto.workspaces.main;
      unit =
        name:
        lib.findFirst (u: u.name == name) (throw "cross-lto: no unit ${name}") (
          lib.attrValues ws.instances.${native}.default.units.build
        );
      run = unit "cross-lto-0.1.0-build-run";
      bin = unit "cross-lto-0.1.0-bin";
      # A second build of a unit, as `nix build --rebuild` would do: one
      # extra attribute gives another derivation with the same build.
      salted = d: derivation (d.drvAttrs // { breakbulkSalt = "cross-lto"; });
    in
    pkgs.runCommand "cross-lto"
      {
        nativeBuildInputs = [
          pkgs.llvmPackages.llvm
          pkgs.file
        ];
        product = ws.target.${native}.packages.cross-lto;
        control = crossLtoOff.workspaces.main.target.${native}.packages.cross-lto;
        run = run.out;
        run2 = (salted run).out;
        binUnit = bin.out;
        binUnit2 = (salted bin).out;
      }
      ''
        set -euo pipefail
        # The archive the build script made holds bitcode, not machine code.
        lib=$(find -L $run -name libmix.a)
        mkdir members && (cd members && llvm-ar x "$lib")
        file members/*.o | tee members.txt
        grep -q 'LLVM IR bitcode' members.txt
        caller() {
          llvm-objdump -d --no-show-raw-insn --disassemble-symbols=cross_lto_caller "$1" > "$2"
          cat "$2"
          grep -q 'cross_lto_caller' "$2"
        }
        # LTO: no C symbol, the caller multiplies by the C constant
        # (2654435761 = 0x9e3779b1) and calls nothing.
        bin=$product/bin/cross-lto
        llvm-nm "$bin" > lto-syms.txt
        if grep cross_lto_mix lto-syms.txt; then echo "cross_lto_mix survived LTO" >&2; exit 1; fi
        caller "$bin" lto.txt
        grep -qi '0x9e3779b1' lto.txt
        if grep -qE '^ +[0-9a-f]+:\s+(call|jmp)' lto.txt; then echo "the caller still calls" >&2; exit 1; fi
        [ "$($bin)" = "cross-lto: $(printf '%08x' $(( ((1 * 2654435761) ^ 0x5bd1e995) + 1 & 0xffffffff )))" ]
        # Control, without LTO: the symbol and the call are there.
        llvm-nm $control/bin/cross-lto > plain-syms.txt
        grep -q ' T cross_lto_mix$' plain-syms.txt
        caller $control/bin/cross-lto plain.txt
        grep -qE '^ +[0-9a-f]+:\s+(call|jmp).*<cross_lto_mix' plain.txt
        [ "$($control/bin/cross-lto)" = "$($bin)" ]
        # Reproducible: the bitcode archive and the LTO-linked binary
        # rebuild byte for byte.
        [ "$run" != "$run2" ] && [ "$binUnit" != "$binUnit2" ]
        cmp "$lib" "$(find -L $run2 -name libmix.a)"
        cmp $binUnit/cross_lto-* $binUnit2/cross_lto-*
        mkdir -p $out
        cp members.txt lto.txt plain.txt $out/
      '';

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
      targets.${wasm}.preset = presets.wasmWeb { rustc = wasmRust; };
    }
  ];
  # Package inputs on a target without a package set (field trials: the
  # curated libsqlite3-sys default failed evaluation of a workspace with a
  # wasm32 target whose wasm plan never builds it). Host units get the
  # build machine's capture; target units would fail when built.
  wasmHostInputs = mkRepo (fixtures + "/wasm-browser") [
    {
      workspaces.main = wasmWs;
      targets.${wasm}.preset = presets.wasmWeb { rustc = wasmRust; };
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
  # The same tests in a headless browser, inside the sandbox.
  wasmBrowserOn =
    browser:
    wasmBrowserWith {
      targets.${wasm}.preset = presets.wasmWeb {
        rustc = wasmRust;
        inherit browser;
      };
    };
  wasmBrowserIn = browser: (wasmBrowserOn browser).workspaces.main.target.${wasm}.testRuns.ui.web;
  # Compile and build-script units by drvPath, for configurations of the
  # wasm-browser fixture that differ only in the test runner.
  wasmBrowserWith =
    module:
    mkRepo (fixtures + "/wasm-browser") [
      { workspaces.main = wasmWs; }
      module
    ];
  wasmBrowserUnits =
    repo:
    let
      i = repo.workspaces.main.instances.${wasm}.default;
    in
    map (u: discard u.drvPath) (lib.attrValues i.units.build ++ lib.attrValues i.units.test);
  wasmRunnerSharing =
    let
      configs = {
        node = wasmBrowser;
        chromium = wasmBrowserOn "chromium";
        firefox = wasmBrowserOn "firefox";
        override = wasmBrowserWith {
          targets.${wasm} = {
            preset = presets.wasmWeb { rustc = wasmRust; };
            runner = lib.mkForce "${pkgs.coreutils}/bin/true";
          };
        };
      };
      units = lib.mapAttrs (_: wasmBrowserUnits) configs;
      differing = lib.filterAttrs (_: u: u != units.node) units;
      runs = lib.mapAttrs (_: r: discard r.workspaces.main.target.${wasm}.testRuns.ui.web.drvPath) configs;
    in
    # Guards against a runner setting that never takes effect.
    assert lib.assertMsg (lib.length (lib.unique (lib.attrValues runs)) == lib.length (lib.attrValues runs))
      "wasm-web-runner-sharing: two configurations have the same test run: ${builtins.toJSON runs}";
    assert lib.assertMsg (units.node != [ ]) "wasm-web-runner-sharing: no units";
    assert lib.assertMsg (differing == { })
      "wasm-web-runner-sharing: units differ from the node runner's in ${toString (lib.attrNames differing)}";
    evalCheck "wasm-web-runner-sharing" "${toString (lib.length units.node)} units identical across ${toString (lib.attrNames configs)}";
  wasmBrowserChecks =
    let
      t = wasmBrowser.workspaces.main.target.${wasm};
      product = breakbulk.mkProduct {
        name = "ui";
        linked = t.packages.ui.roots."cdylib/ui";
        stages = breakbulk.stages.defaultStages.wasmWeb;
        target.triple = wasm;
        info.lockfile = fixtures + "/wasm-browser/Cargo.lock";
        inherit pkgs;
      };
    in
    {
      wasm-web-test = t.testRuns.ui.web;
      wasm-web-test-chromium = wasmBrowserIn "chromium";
      wasm-web-test-firefox = wasmBrowserIn "firefox";
      wasm-web-runner-sharing = wasmRunnerSharing;
      # The bindgen stage with the lockfile-matched CLI (0.2.130), then
      # wasm-opt; the JS glue loads in Node and computes the digest.
      wasm-web-bindgen =
        pkgs.runCommand "wasm-web-bindgen"
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
  # The preset gets the workspace's rustc; see
  # presets-per-workspace for the same with `rustc` passed.
  wasmComponent = mkRepo (fixtures + "/wasm-component") [
    {
      workspaces.main = wasmWs;
      targets.${wasm}.preset = presets.wasmComponent { withC = true; };
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

  # Target specs are resolved per (workspace, target), and a
  # preset gets the workspace's rustc. Two workspaces on Rust 1.96 (LLVM
  # 22, wasi-sdk 30) and 1.99 (LLVM 23, wasi-sdk 33) build wasm32 and
  # wasip2 from the same repository-wide presets, with no `rustc` passed,
  # and each gets its own clang, wasm-ld and wasi-sdk headers. A
  # workspace's own `targets.<triple>` merges over the repository's for it
  # alone; an explicit `rustc` still wins; an entry with only `packages`
  # and no repository-wide spec has no spec, as before; and the wasm
  # component fixture's products are the same derivations whether the
  # preset is given `rustc` or takes the workspace's.
  perWorkspace =
    let
      wasip2 = "wasm32-wasip2";
      tc =
        v:
        let
          r = pkgs.rust-bin.stable.${v}.minimal.override {
            targets = [
              wasm
              wasip2
            ];
          };
        in
        {
          rustc = r;
          cargo = r;
        };
      repo =
        extra:
        mkRepo (fixtures + "/multi-ws") (
          [
            {
              workspaces.b = {
                path = "b";
                toolchain = tc "1.96.0";
                targets = {
                  ${wasm} = { };
                  ${wasip2} = { };
                  "aarch64-unknown-linux-gnu".packages = [ "app-b" ];
                };
              };
              workspaces.c = {
                path = "c";
                toolchain = tc "1.99.0";
                targets = {
                  ${wasm} = { };
                  ${wasip2}.rustflags = [
                    "--cfg"
                    "only_c"
                  ];
                };
              };
              targets.${wasm}.preset = presets.wasmComponent;
              targets.${wasip2}.preset = presets.wasmComponent { withC = true; };
            }
          ]
          ++ extra
        );
      r = repo [ ];
      spec = repo': ws: t: repo'.workspaces.${ws}.target.${t}.spec;
      # The LLVM major in a tool's store path name (clang-22.1.8, lld-23.1.3).
      majorIn =
        s:
        let
          m = builtins.match ".*-(clang|lld)-([0-9]+)\\.[^/]*/bin/.*" (discard s);
        in
        if m == null then null else lib.toInt (lib.elemAt m 1);
      sysrootIn =
        s:
        let
          m = builtins.match ".*-wasi-sysroot-([0-9]+)/.*" (discard (lib.concatStringsSep " " s));
        in
        if m == null then null else lib.head m;
      explicit = repo [
        {
          targets.${wasm}.preset = lib.mkForce (presets.wasmComponent { inherit (tc "1.99.0") rustc; });
        }
      ];
      componentExplicit = mkRepo (fixtures + "/wasm-component") [
        {
          workspaces.main = wasmWs;
          targets.${wasm}.preset = presets.wasmComponent {
            rustc = wasmRust;
            withC = true;
          };
        }
      ];
      drvsOf = repo': map (d: d.drvPath) (lib.attrValues repo'.workspaces.main.target.${wasm}.packages);
      checks = {
        wasmLlvm =
          majorIn (spec r "b" wasm).linker == 22
          && majorIn (spec r "b" wasm).cc == 22
          && majorIn (spec r "c" wasm).linker == 23
          && majorIn (spec r "c" wasm).cc == 23;
        wasip2WasiSdk =
          sysrootIn (spec r "b" wasip2).cflags == "30"
          && sysrootIn (spec r "c" wasip2).cflags == "33"
          && majorIn (spec r "b" wasip2).cc == 22
          && majorIn (spec r "c" wasip2).cc == 23;
        workspaceOverride = (spec r "c" wasip2).rustflags == [
          "--cfg"
          "only_c"
        ]
        && (spec r "b" wasip2).rustflags == [ ];
        explicitRustcWins = majorIn (spec explicit "b" wasm).linker == 23;
        packagesOnlyHasNoSpec = spec r "b" "aarch64-unknown-linux-gnu" == null;
        sameDrvs = drvsOf wasmComponent == drvsOf componentExplicit;
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    if failed == [ ] then
      evalCheck "presets-per-workspace" (builtins.toJSON (lib.attrNames checks))
    else
      throw "presets-per-workspace: failed: ${toString failed}";

  presetsEval =
    let
      gnu = presets.linux {
        inherit pkgs;
        triple = native;
      };
      cross = presets.linux {
        inherit pkgs;
        triple = "aarch64-unknown-linux-gnu";
      };
      bound = presets.windows { crtStatic = true; };
      llvm = breakbulk.llvmVersions;
      checks = {
        partial = lib.isFunction bound && lib.functionArgs bound ? toolchain;
        nativeRunner = gnu.runner.content == null;
        crossRunnerQemu = lib.hasInfix "qemu-aarch64" (discard cross.runner.content);
        crossNativeBuilder =
          (presets.linux {
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
        # Outside the table: null from the table, and the
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
        # The Rust to wasi-sdk table (lib/wasi-sdk.nix): an
        # unknown Rust release fails evaluation, naming the file.
        wasiSdkTable =
          let
            w = breakbulk.wasiSdk;
            unknown = builtins.tryEval (w.versionFor "1.94.0");
          in
          w.versionFor "1.95.0" == "30"
          && w.versionFor "1.96.1" == "30"
          && w.versionFor "1.99.0" == "33"
          && w.versionFor "1.100.0-beta.10-2026-11-05" == "34"
          && w.versionFor "1.101.0-nightly-2026-11-06" == "34"
          && !unknown.success
          && fails (w.versionFor "1.200.0")
          && lib.all (v: w.releases ? ${v}) (lib.attrValues w.table);
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
            p = presets.windows {
              inherit pkgs;
              triple = "x86_64-pc-windows-msvc";
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
      msvcPostLink
      crossLto
      crossLtoOff
      wasmBrowser
      wasmComponent
      staticPkgconfig
      ;
  };
  checks = {
    presets-eval = presetsEval;
    presets-per-workspace = perWorkspace;
    debug-outputs = debugOutputsEval;
    wasm-host-inputs = wasmHostInputsCheck;
    cross-lto = crossLtoCheck;

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
  # musl links a pkg-config library statically: the preset's
  # PKG_CONFIG_ALL_STATIC (lib/presets staticLinking) makes pkg-config-rs
  # pick libbbfoo.a over libbbfoo.so.
  // (
    let
      t = staticPkgconfig.workspaces.main.target."x86_64-unknown-linux-musl";
    in
    {
      static-pkgconfig-musl-product = elfCheck "static-pkgconfig-musl-product" "static" "${t.packages.app}/bin/app";
      static-pkgconfig-musl-run = pkgs.runCommand "static-pkgconfig-musl-run" { } ''
        ${t.packages.app}/bin/app | tee $out
        grep -qx "bbfoo says 42" $out
      '';
    }
  )
  // sysNativeCrossChecks
  // msvcChecks
  // lib.optionalAttrs (xwinPkgs != null) { msvc-debug-outputs = msvcDebugOutputsEval; }
  // wasmBrowserChecks
  // wasmComponentChecks;
}
