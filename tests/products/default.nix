# Products, stages, source paths, products as inputs and variants,
# through mkRepository (IFD mode, native target). Wired into the flake's
# checks as `products-*`.
#
#   nix build -f tests/products post-link
#
#   debug-info       `targets.<t>.debugInfo` (split, keep, strip) inserts
#                    the stage and sets the units' remap scope; removing
#                    that stage or adding `splitDebug` against it, at
#                    target or package level, fails evaluation
#   post-link        stage order from target and package stages; a stage
#                    removed with mkForce null; a check on `linked` sees
#                    unstripped bytes; checks in repo.checks
#   source-paths     no source reference in the product's main output
#                    (noSourceReferences passes); panics and file!() in a
#                    dependency print remapped paths; the debug output
#                    references the dependency's source view and the
#                    registry crate's source; gdb, given only the debug
#                    output's lib/debug as its debug-file-directory, runs
#                    the product to a breakpoint in the dependency `dep`
#                    and prints a backtrace with dep's and app's source
#                    files and lines, and the source line itself; non-test
#                    units remap macro,diagnostics, test harnesses every
#                    scope; dep's tests pass
#   source-paths-dwp the same with split-debuginfo = "packed" (a `packed`
#                    profile): the DWARF is in app.dwp, which splitDebug
#                    puts next to the separate debug file, where gdb finds
#                    it; gdb's backtrace and source lines as above
#   source-paths-dwo the same with split-debuginfo = "unpacked": the
#                    libraries' `.dwo` files reach the `linked` stage's
#                    debug output with the bin's, and splitDebug packs the
#                    ones the binary names into app.dwp;
#                    gdb's backtrace and source lines as above
#   source-paths-dwo5 the same with DWARF 5 (`-C dwarf-version=5`), which
#                    binutils' dwp packs into an empty .dwp
#   source-paths-readme   editing dep's README changes its test binary's
#                    derivation but not its bytes
#   staticlib-sources   crate-types' staticlib passes noSourceReferences:
#                    sources named only by the archive (its objects' debug
#                    info) are allowed; a stage adding a file that names
#                    the same sources fails it
#   prefer-dynamic   -C prefer-dynamic: noSourceReferences allows the
#                    sysroot that holds the libstd-*.so the binary loads
#                    (nixpkgs' rustc), and fails on rust-overlay's rustc and
#                    cargo components the joined sysroot brings along
#   variants         build, check, clippy (with and without clippy
#                    arguments), coverage, a custom profile inheriting
#                    release and a feature powerset: host units shared
#                    between build and clippy at the same profile; every
#                    dependency unit shared between check and clippy,
#                    members not; no target unit shared between build and
#                    coverage, every host unit shared; every unit shared
#                    between release and the custom profile;
#                    the powerset's products have their features, and its
#                    variants' test runs are not in repo.checks (the
#                    coverage variant's are); the check
#                    and clippy variants' unit checks build
#   variants-narrowing   `variants.<v>.targets`, `variants.<v>.packages`
#                    and `targets.<t>.tests` narrow plans and outputs per
#                    target; other variants' test runs are in repo.checks
#                    under `variant-<v>/` unless `checks = false`
#   tests-only       `targets.<t>.tests = false` on wasm32 and
#                    `products = false` on the native target: native test
#                    runs and doctests only; `products = [ "app" ]`
#   variants-per-target   `targets.<t>.variantDefaults` and
#                    `variants.<v>.target.<t>` (wasm32 with rust-overlay's
#                    1.99): a feature on one target only, a variant's
#                    layer replacing the defaults, a package run keeping
#                    its own features, `allTargets = false` on one
#                    target; invalid layers fail evaluation
#   variants-clippy-strict   `clippyArgs = [ "-D" "clippy::len_zero" ]`
#                    fails the member's clippy unit naming the lint
#   variants-clippy-conf   clippy units find `clippy.toml` above the
#                    workspace (a root `disallowed-methods` fails
#                    `rooted`) and a member's own file instead of the
#                    root's (`own`); an edit to the root file changes
#                    only clippy units, and a `CLIPPY_CONF_DIR` in `env`
#                    replaces breakbulk's
#   variants-clippy-toolchain   with rust-overlay's 1.99 as rustc and
#                    cargo, `toolchain.clippy` defaults to that toolchain
#                    and the clippy plan builds; nixpkgs' clippy (another
#                    sysroot) and a toolchain without clippy-driver fail
#                    planning naming `workspaces.main.toolchain.clippy`
#   variants-coverage   with rust-overlay's 1.99 (nixpkgs' rustc 1.99
#                    builds instrumented multi-crate binaries that crash
#                    in the profiler runtime at exit, with plain Cargo
#                    too): the coverage product writes a profile, and the
#                    coverage test run keeps its profiles in $out/profraw
#   embed            products as inputs: `packages.embedder.env` names
#                    another workspace's product, which `embedder` embeds
#                    with include_bytes!; the host workspace's instantiation
#                    (units.json) does not depend on the product, only the
#                    embedding unit's env names it, and `other`'s units do
#                    not reference it; the host binary carries it and the
#                    extracted payload runs
#   embed-invalidation   editing the payload changes only the embedding
#                    chain's units (embedder and host), not `other`'s
#   trim-paths       Cargo's trim-paths, with rust-overlay's nightly (Cargo
#                    1.101): workspace `set` sets it in its dev profile, so
#                    its plan keeps Cargo's remaps and scope (the planner
#                    reads the manifest and leaves it to the project);
#                    workspace `default` does not, so the planner turns it on
#                    and drops Cargo's scope. Both:
#                    breakbulk adds no remaps of its own; the shared path
#                    crate outside both roots gets one `-C metadata` in both,
#                    and the same when planned at two other skeleton
#                    locations (Cargo hashes it without its absolute path;
#                    stable 1.99 refuses to plan there); OUT_DIR paths read
#                    `/cargo/build-dir/…`; products have no source
#                    references; `default`'s debug info keeps store paths
#                    (gdb lists the shared crate's source), `set`'s does
#                    not (scope `all`); `default`'s tests pass
#   trim-paths-cc    nightly Cargo 1.101: a build script
#                    compiling C with cc-rs 1.11.1 under the trim-paths the
#                    planner turned on: the C object's `__FILE__` and debug
#                    info name only Cargo's form (`./cfile/c/where.c`), never
#                    the source view; breakbulk's C prefix maps for the run
#                    use Cargo's names (the run's OUT_DIR as
#                    `/cargo/build-dir/…`). `cargoTrimPaths = false`: no
#                    trim-paths, breakbulk's own names; `sourcePaths =
#                    "keep"`: no remaps at all and no noSourceReferences
#                    check; trim-paths set for one package only (a profile
#                    override) fails planning naming the packages on and off
#   benches          a libtest-harness bench and a Criterion bench come
#                    from the bench variant only (`cargo bench --no-run`,
#                    bench profile, opt-level 3); the test plan has none;
#                    benchSmoke runs each once with `--test` as a check
#
# `repos` exposes each repository for debugging, `modules` the modules of
# some (tests/dynamic adds its own to them).
{
  # nixpkgs and rust-overlay as the flake pins them (the flake's checks
  # pass its own pkgs, which has the overlay).
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
  # Modules added to every repository (tests/dynamic sets `mode`).
  extraModules ? [ ],
}:
let
  inherit (pkgs) lib;
  fixtures = ../fixtures;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  tools = breakbulk.mkTools pkgs;
  helpers = breakbulk.stageHelpers;

  mkRepo =
    root: modules:
    breakbulk.mkRepository {
      inherit pkgs root tools;
      modules = modules ++ extraModules;
    };

  oneWs = path: profile: {
    workspaces.main = {
      inherit path;
      variants.default = { inherit profile; };
    };
  };

  evalCheck =
    name: report:
    pkgs.runCommand name { inherit report; } ''
      mkdir -p $out
      printf '%s\n' "$report" > $out/report
    '';

  # A copy of a fixture with an edit applied, usable as a repository root.
  edited =
    fixture: script:
    let
      drv = pkgs.runCommand "${fixture}-edited" { } ''
        cp -r --no-preserve=mode ${fixtures + "/${fixture}"} $out
        cd $out
        ${script}
      '';
    in
    builtins.seq (builtins.readDir drv) (/. + builtins.unsafeDiscardStringContext drv.outPath);

  inst = repo: repo.workspaces.main.instances.${native}.default;

  # Rendered BREAKBULK_UNIT of each unit of a plan kind, by derivation name.
  renderedUnits =
    repo: kind:
    lib.listToAttrs (
      map (
        u:
        lib.nameValuePair u.name (
          builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)
        )
      ) (lib.attrValues (inst repo).units.${kind})
    );

  expectFailure =
    name: unit: patterns:
    let
      a = unit.drvAttrs;
    in
    derivation (
      a
      // {
        name = "${name}-expect-failure";
        builder = "${pkgs.bash}/bin/bash";
        args = [
          "-c"
          ''
            set -u
            result=$out
            for o in $unitOutputs; do
              d=$NIX_BUILD_TOP/unit-out-$o
              export "$o=$d"
            done
            unitArgs=()
            for ((i = 0; i < unitArgc; i++)); do
              v=unitArg$i
              unitArgs+=("''${!v}")
            done
            rc=0
            "$unitBuilder" "''${unitArgs[@]}" > $NIX_BUILD_TOP/log 2>&1 || rc=$?
            ${pkgs.coreutils}/bin/cat $NIX_BUILD_TOP/log
            if [ $rc -eq 0 ]; then
              echo "expected the unit to fail, but it succeeded" >&2
              exit 1
            fi
            ${lib.concatMapStrings (p: ''
              ${pkgs.gnugrep}/bin/grep -qF -- ${lib.escapeShellArg p} $NIX_BUILD_TOP/log || {
                echo "the failure does not mention: "${lib.escapeShellArg p} >&2
                exit 1
              }
            '') patterns}
            ${pkgs.coreutils}/bin/mkdir -p $result
            ${pkgs.coreutils}/bin/cp $NIX_BUILD_TOP/log $result/log
          ''
        ];
        outputs = [ "out" ];
        unitOutputs = a.outputs or [ "out" ];
        unitBuilder = a.builder;
        unitArgc = toString (lib.length (a.args or [ ]));
      }
      // lib.listToAttrs (lib.imap0 (i: v: lib.nameValuePair "unitArg${toString i}" v) (a.args or [ ]))
    );

  # Unit derivations of one plan kind of a variant, by derivation name.
  unitsOf =
    repo: vName: kind:
    lib.listToAttrs (
      map (u: lib.nameValuePair u.name u) (
        lib.attrValues repo.workspaces.main.instances.${native}.${vName}.units.${kind}
      )
    );
  drvsOf =
    repo: vName: kind:
    lib.mapAttrs (_: u: u.drvPath) (unitsOf repo vName kind);

  # --- post-link ---------------------------------------------------------------

  # A custom stage: copies its input and writes a marker file listing the
  # stages seen so far (each stage appends its name).
  marker =
    stage:
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-${stage}" { } ''
      cp -RL --no-preserve=mode,ownership ${input} $out
      chmod -R u+w $out
      find $out -type f ! -name '*.txt' -exec chmod +x {} +
      echo ${stage} >> $out/stages.txt
    '';

  # A check that fails unless every ELF file in its input still has debug
  # info: on `linked` it sees the bytes before splitDebug and strip.
  hasDebugInfo =
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-has-debug-info"
      { nativeBuildInputs = [ pkgs.binutils-unwrapped ]; }
      ''
        for f in ${input}/*; do
          readelf -S -W "$f" > sections
          grep -q ' \.debug_info ' sections || { echo "$f: no debug info" >&2; exit 1; }
        done
        touch $out
      '';

  postLink = mkRepo (fixtures + "/post-link") [
    (oneWs "." "dev")
    {
      # Target level: strip after splitDebug (removes the debuglink's
      # remaining symbol tables too) for every product.
      targets.${native} = {
        stages.strip = {
          after = "splitDebug";
          run = helpers.strip { all = true; };
        };
        checks.unstripped = {
          on = "linked";
          run = hasDebugInfo;
        };
      };
      packages.server = {
        stages = {
          # Signing breaks if stripped: remove the target's strip stage.
          strip = lib.mkForce null;
          stamp = {
            after = "splitDebug";
            run = marker "stamp";
          };
          sign = {
            after = "stamp";
            run = marker "sign";
          };
        };
      };
    }
    # A second module sets strip again at normal priority; mkForce wins.
    {
      packages.server.stages.strip = {
        after = "sign";
        run = helpers.strip;
      };
    }
  ];
  plServer = postLink.workspaces.main.packages.server;
  plTool = postLink.workspaces.main.packages.tool;

  # --- source-paths ------------------------------------------------------------

  spModules = [
    (oneWs "." "dev")
    { workspaces.main.variants.packed.profile = "packed"; }
    { workspaces.main.variants.unpacked.profile = "unpacked"; }
  ];
  sourcePaths = mkRepo (fixtures + "/source-paths") spModules;
  sourcePathsDwarf5 = mkRepo (fixtures + "/source-paths") (
    spModules
    ++ [
      {
        targets.${native}.rustflags = [
          "-C"
          "dwarf-version=5"
        ];
      }
    ]
  );
  sourcePathsReadme =mkRepo (edited "source-paths" "echo 'More words.' >> dep/README.md") spModules;
  spApp = sourcePaths.workspaces.main.packages.app;

  # --- trim-paths ----------------------------------------------------------------

  trimRust = pkgs.rust-bin.nightly.latest.minimal;
  trimPathsRepo = mkRepo (fixtures + "/trim-paths") [
    {
      workspaces = lib.genAttrs [ "set" "default" ] (w: {
        path = w;
        toolchain = {
          rustc = trimRust;
          cargo = trimRust;
        };
        variants.default.profile = "dev";
      });
    }
  ];

  # gdb on $app/bin/app with only $debug/lib/debug as its debug-file-directory
  # (what installing the debug output gives): a breakpoint in the
  # dependency `dep`, a backtrace through it into `app`, with the source
  # files and lines from the debug info (store paths of the source views,
  # which the debug output references), and the source line itself. Inside
  # the sandbox; ASLR stays on (no personality change). Needs $app, $debug
  # and $depView.
  gdbCheck = ''
    gdb -batch -nx -iex "set debug-file-directory $debug/lib/debug" \
      -ex 'break dep::boom' -ex run -ex bt -ex 'frame 0' -ex 'info source' -ex list \
      $app/bin/app > gdb.txt 2>&1 || true
    cat gdb.txt
    # Frame 0 in dep with its file and line; app's frames below it. The
    # debug info names files relative to the compilation directory, the
    # source view (rustc's working directory).
    grep -E '^#0 +dep::boom .* at dep/src/lib.rs:1[0-9]$' gdb.txt
    # The argument's value: from the DWARF itself, not the line table
    # (which split DWARF keeps in the binary).
    grep -qF 'dep::boom (n=7)' gdb.txt
    grep -E '^#[1-9] .*app::main.* at app/src/main.rs:[0-9]+$' gdb.txt
    # gdb read the file from the dependency's source view, which the debug
    # output references.
    grep -qxF "Located in $depView/dep/src/lib.rs" gdb.txt
    grep -qF 'panic!("boom {n}");' gdb.txt
  '';

  # The `unpacked` variant's app through splitDebug, with every split unit
  # at DWARF `version`: the `.dwo` files reach the linked stage, splitDebug
  # packs them into app.dwp, and gdb reads the dependency's arguments from
  # it, and not without it.
  dwoCheck =
    name: repo: version:
    let
      p = repo.workspaces.main.target.${native}.variants.unpacked.packages.app;
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.gdb
          pkgs.binutils-unwrapped
        ];
        app = p;
        debug = p.debug;
        linkedDebug = p.stages.linked.debug;
        noSrc = p.checks.noSourceReferences;
        depView = builtins.unsafeDiscardStringContext "${(inst repo).sources.workspace.dep}";
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        grep -qxF 'formatted 42' run.txt
        # The link unit's own `.dwo` files and its libraries' (`dep`, the
        # registry crate `itoa`), and no .dwp.
        ls $linkedDebug
        ls $linkedDebug | grep -qE '^app[-.].*\.dwo$'
        ls $linkedDebug | grep -qE '^dep[-.].*\.dwo$'
        ls $linkedDebug | grep -qE '^itoa[-.].*\.dwo$'
        test ! -e $linkedDebug/app.dwp
        readelf --debug-dump=info --dwarf-depth=1 $linkedDebug/*.dwo 2>/dev/null \
          | sed -n 's/^ *Version: *//p' | sort -u > versions.txt
        cat versions.txt
        test "$(cat versions.txt)" = ${toString version}
        # splitDebug packed them into app.dwp next to the separate debug
        # file, as rustc's own .dwp is with `packed`, and dropped the loose
        # ones.
        id=$(readelf -n $app/bin/app | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
        test -f $debug/lib/debug/.build-id/''${id:0:2}/app.dwp
        readelf -S -W $debug/lib/debug/.build-id/''${id:0:2}/app.dwp | grep -q '\.debug_info\.dwo'
        test -L $debug/bin/app.dwp
        test -z "$(find $debug -name '*.dwo')"
        ${gdbCheck}
        mkdir -p $out
        cp gdb.txt $out/
        # Negative control: without app.dwp, gdb has the line table but
        # not the arguments, so the check above is not passing vacuously.
        cp -r $debug nodwp
        chmod -R u+w nodwp
        rm nodwp/lib/debug/.build-id/''${id:0:2}/app.dwp
        gdb -batch -nx -iex "set debug-file-directory $PWD/nodwp/lib/debug" \
          -ex 'break dep::boom' -ex run -ex bt $app/bin/app > nodwp.txt 2>&1 || true
        cat nodwp.txt
        ! grep -qF 'dep::boom (n=7)' nodwp.txt
      '';

  # cc-rs 1.11.1 compiling C under Cargo's trim-paths.
  trimCcRepo =
    extra:
    mkRepo (fixtures + "/trim-paths-cc") [
      (oneWs "." "dev")
      {
        workspaces.main = {
          toolchain = {
            rustc = trimRust;
            cargo = trimRust;
          };
        }
        // extra;
      }
    ];

  # --- variants ------------------------------------------------------------------

  variantsModules = [
    {
      workspaces.main = {
        path = "ws";
        variants = {
          default.profile = "release";
          custom.profile = "release-custom";
          check = {
            mode = "check";
            profile = "release";
          };
          clippy = {
            mode = "clippy";
            profile = "release";
          };
          coverage = {
            mode = "coverage";
            profile = "release";
          };
          # Plain `cargo check`.
          check-lib = {
            mode = "check";
            profile = "release";
            allTargets = false;
          };
          strict = {
            mode = "clippy";
            profile = "release";
            clippyArgs = [
              "-D"
              "clippy::len_zero"
            ];
          };
        }
        // breakbulk.variants.featurePowerset {
          features = [
            "lib-a/x"
            "lib-a/y"
          ];
          profile = "release";
          prefix = "fp";
        };
      };
    }
  ];
  variantsRepo = mkRepo (fixtures + "/variants") variantsModules;
  vt = variantsRepo.workspaces.main.target.${native};

  # Coverage with an upstream toolchain (see variants-coverage).
  overlayRust = pkgs.rust-bin.stable."1.99.0".minimal;
  coverageRepo = mkRepo (fixtures + "/variants") [
    {
      workspaces.main = {
        path = "ws";
        toolchain = {
          rustc = overlayRust;
          cargo = overlayRust;
        };
        variants.default = {
          mode = "coverage";
          profile = "release";
        };
      };
    }
  ];

  # --- embed ---------------------------------------------------------------------

  # A repository whose `host` workspace embeds the `payload` workspace's
  # product. The module refers to the repository itself through its `repo`
  # argument (mkRepository's specialArgs); Nix's laziness makes that fine,
  # since building `payload` never reads `embedder`'s env.
  embedRepo =
    root:
    mkRepo root [
      (
        { repo, ... }:
        {
          workspaces = {
            payload = {
              path = "payload";
              variants.default.profile = "dev";
            };
            host = {
              path = "host";
              variants.default.profile = "dev";
            };
          };
          packages.embedder.env.PAYLOAD_BIN = "${repo.workspaces.payload.packages.payload}/bin/payload";
        }
      )
    ];
  embed = embedRepo (fixtures + "/embed");
  embedEdited = embedRepo (edited "embed" "echo '// v2' >> payload/src/main.rs");
  hostInst = repo: repo.workspaces.host.instances.${native}.default;
  # A derivation's .drv file without its outputs: exportReferencesGraph of
  # it is the closure of build inputs, and building it builds nothing.
  drvOnly = d: builtins.unsafeDiscardOutputDependency d.drvPath;
  hostDrvs =
    repo:
    lib.listToAttrs (
      map (u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (
        lib.attrValues (hostInst repo).units.build ++ lib.attrValues (hostInst repo).units.test
      )
    );

  # The stdpaths fixture on a toolchain with rust-src (see rust-src).
  rustSrcRepo =
    let
      tc = pkgs.rust-bin.stable."1.99.0".minimal.override { extensions = [ "rust-src" ]; };
    in
    mkRepo (fixtures + "/stdpaths") [
      {
        workspaces.main.toolchain = {
          rustc = tc;
          cargo = tc;
        };
        targets.${native}.preset = breakbulk.presets.linux;
      }
    ];

  # --- benches -------------------------------------------------------------------

  benchesRepo = mkRepo (fixtures + "/benches") [
    {
      workspaces.main = {
        path = ".";
        benchSmoke = true;
        # `benches` reads the smoke runs' output.
        memberDefaults.test.keepLog = true;
        variants = {
          default.profile = "dev";
          bench = {
            profile = "bench";
            benches = true;
          };
        };
      };
    }
  ];
in
{
  modules.variants = variantsModules;
  repos = {
    inherit
      postLink
      sourcePaths
      sourcePathsReadme
      trimPathsRepo
      variantsRepo
      benchesRepo
      embed
      coverageRepo
      rustSrcRepo
      ;
    trimCc = trimCcRepo { };
  };

  embed =
    let
      i = hostInst embed;
      payload = embed.workspaces.payload.packages.payload;
      payloadOut = builtins.unsafeDiscardStringContext payload.outPath;
      units = lib.attrValues i.units.build ++ lib.attrValues i.units.test;
      naming = lib.filter (u: lib.hasInfix payloadOut (u.drvAttrs.BREAKBULK_UNIT or "")) units;
      namingNames = lib.sort lib.lessThan (lib.unique (map (u: u.name) naming));
      other = lib.filter (u: lib.hasPrefix "other-" u.name) units;
    in
    assert lib.assertMsg (
      namingNames == [
        "embedder-0.1.0-lib"
        "embedder-0.1.0-test"
      ]
    ) "embed: units naming the product: ${builtins.toJSON namingNames}";
    pkgs.runCommand "embed"
      {
        host = embed.workspaces.host.packages.host;
        hostChecks = lib.attrValues embed.workspaces.host.packages.host.checks;
        payloadDrv = builtins.unsafeDiscardStringContext payload.drvPath;
        # The closure of the host workspace's instantiation (both plans)
        # and of `other`'s unit derivations: none may contain the product.
        exportReferencesGraph = [
          "instBuild"
          (drvOnly i.unitsJson.build)
          "instTest"
          (drvOnly i.unitsJson.test)
        ]
        ++ lib.concatLists (
          lib.imap0 (n: u: [
            "other${toString n}"
            (drvOnly u)
          ]) other
        )
        # Positive control: the embedding chain does depend on it.
        ++ [
          "chainEmbedder"
          (drvOnly (lib.findFirst (u: u.name == "embedder-0.1.0-lib") null units))
          "chainHost"
          (drvOnly (lib.findFirst (u: u.name == "host-0.1.0-bin") null units))
        ];
      }
      ''
        set -euo pipefail
        for g in instBuild instTest other*; do
          if grep -qxF "$payloadDrv" "$g"; then
            echo "$g depends on the embedded product $payloadDrv" >&2
            exit 1
          fi
        done
        grep -qxF "$payloadDrv" chainEmbedder
        grep -qxF "$payloadDrv" chainHost
        $host/bin/host $TMPDIR/payload | tee run.txt
        grep -q '^host embeds [0-9]* bytes, magic 7f454c46$' run.txt
        chmod +x $TMPDIR/payload
        [ "$($TMPDIR/payload)" = "payload says hi" ]
        touch $out
      '';

  embed-invalidation =
    let
      b = hostDrvs embed;
      a = hostDrvs embedEdited;
      changed = lib.sort lib.lessThan (
        lib.unique (lib.attrValues (lib.filterAttrs (d: _: !(b ? ${d})) a))
      );
    in
    assert lib.assertMsg (
      changed == [
        "embedder-0.1.0-lib"
        "embedder-0.1.0-test"
        "host-0.1.0-bin"
        "host-0.1.0-test"
      ]
    ) "embed-invalidation: changed units ${builtins.toJSON changed}";
    evalCheck "embed-invalidation" (builtins.toJSON changed);

  benches =
    let
      w = benchesRepo.workspaces.main;
      t = w.target.${native};
      readPlan =
        drv: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${drv}/plan.json"));
      benchPlan = readPlan w.plans.${native}.bench.bench;
      testPlans = map (v: readPlan w.plans.${native}.${v}.test) [
        "default"
        "bench"
      ];
      kinds = plan: map (r: r.kind) plan.roots;
      critUnit = (unitsOf benchesRepo "bench" "bench")."bencher-0.1.0-bin-crit" or null;
      critArgs = lib.filter builtins.isString (
        (builtins.fromJSON (builtins.unsafeDiscardStringContext critUnit.drvAttrs.BREAKBULK_UNIT)).args
      );
      smoke = lib.filterAttrs (n: _: lib.hasInfix "/bench-" n) benchesRepo.checks;
    in
    assert lib.assertMsg (
      lib.attrNames t.benches.bencher == [
        "crit"
        "lib"
        "libtest"
      ]
    ) "benches: ${builtins.toJSON (lib.attrNames t.benches.bencher)}";
    assert lib.assertMsg (lib.all (
      p: !(lib.elem "bench" (kinds p))
    ) testPlans) "benches: a test plan has bench roots";
    assert lib.assertMsg (
      benchPlan.kind == "bench" && benchPlan.variant.profile == "bench"
    ) "benches: bench plan header ${builtins.toJSON benchPlan.variant}";
    assert lib.assertMsg (
      lib.sort lib.lessThan (kinds benchPlan) == [
        "bench"
        "bench"
        "lib"
      ]
    ) "benches: bench plan roots ${builtins.toJSON benchPlan.roots}";
    assert lib.assertMsg (
      critUnit != null && lib.elem "opt-level=3" critArgs
    ) "benches: crit unit args ${builtins.toJSON critArgs}";
    assert lib.assertMsg (
      lib.length (lib.attrNames smoke) == 3
    ) "benches: smoke checks ${builtins.toJSON (lib.attrNames smoke)}";
    pkgs.runCommand "benches"
      (
        {
          crit = t.benches.bencher.crit;
          libtest = t.benches.bencher.libtest;
        }
        // lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) smoke
      )
      ''
        set -euo pipefail
        [ -x $crit/bin/crit ]
        [ -x $libtest/bin/libtest ]
        cat ${lib.concatMapStringsSep " " (d: "${d}/log") (lib.attrValues smoke)}
        grep -q Success ${smoke."main/${native}/bencher/bench-crit"}/log
        touch $out
      '';

  variants =
    let
      d = drvsOf variantsRepo;
      same =
        a: b: names:
        lib.filter (n: (a.${n} or "missing-a") != (b.${n} or "missing-b")) names;
      hostUnits = [
        "pm-0.1.0-lib"
        "hostdep-0.1.0-build-script"
        "hostdep-0.1.0-build-run"
      ];
      depNames =
        plan: lib.filter (n: lib.hasPrefix "pm-" n || lib.hasPrefix "hostdep-" n) (lib.attrNames plan);
      memberNames =
        plan: lib.filter (n: lib.hasPrefix "app-" n || lib.hasPrefix "lib-a-" n) (lib.attrNames plan);
      buildVsClippy = same (d "default" "build") (d "clippy" "build") hostUnits;
      checkVsClippy = lib.concatMap (k: same (d "check" k) (d "clippy" k) (depNames (d "check" k))) [
        "build"
        "test"
      ];
      membersDiffer = lib.filter (n: (d "check" "build").${n} == (d "clippy" "build").${n}) (
        memberNames (d "check" "build")
      );
      customVsRelease =
        lib.concatMap
          (
            k:
            let
              a = d "default" k;
              b = d "custom" k;
            in
            lib.optional (
              lib.sort lib.lessThan (lib.attrValues a) != lib.sort lib.lessThan (lib.attrValues b)
            ) k
          )
          [
            "build"
            "test"
          ];
      # The lib target unit of the check variant is metadata only, so it
      # differs from the build variant's (sanity check for the comparison).
      libDiffers = (d "default" "build")."hostdep-0.1.0-lib" != (d "check" "build")."hostdep-0.1.0-lib";
      fpNames = lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "fp-" n) vt.variants);
      # Build vs coverage, both plans: units by platform, compared by
      # derivation path.
      platformOf =
        u: (builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)).platform;
      unitsBy =
        vName: platform:
        lib.concatMap
          (k: lib.filter (u: platformOf u == platform) (lib.attrValues (unitsOf variantsRepo vName k)))
          [
            "build"
            "test"
          ];
      drvSet = us: lib.genAttrs (map (u: builtins.unsafeDiscardStringContext u.drvPath) us) (_: true);
      sharedTarget = lib.filter (
        u: (drvSet (unitsBy "coverage" "target")) ? ${builtins.unsafeDiscardStringContext u.drvPath}
      ) (unitsBy "default" "target");
      hostCov = drvSet (unitsBy "coverage" "host");
      unsharedHost = lib.filter (u: !(hostCov ? ${builtins.unsafeDiscardStringContext u.drvPath})) (
        unitsBy "default" "host"
      );
    in
    assert lib.assertMsg (sharedTarget == [ ])
      "variants: target units shared between build and coverage: ${
        builtins.toJSON (map (u: u.name) sharedTarget)
      }";
    assert lib.assertMsg (unsharedHost == [ ] && unitsBy "default" "host" != [ ])
      "variants: host units not shared between build and coverage: ${
        builtins.toJSON (map (u: u.name) unsharedHost)
      }";
    assert lib.assertMsg (
      buildVsClippy == [ ]
    ) "variants: host units differ between build and clippy: ${builtins.toJSON buildVsClippy}";
    assert lib.assertMsg (
      checkVsClippy == [ ]
    ) "variants: dependency units differ between check and clippy: ${builtins.toJSON checkVsClippy}";
    assert lib.assertMsg (
      membersDiffer == [ ]
    ) "variants: member units shared between check and clippy: ${builtins.toJSON membersDiffer}";
    assert lib.assertMsg (
      customVsRelease == [ ]
    ) "variants: release and release-custom differ in plans ${builtins.toJSON customVsRelease}";
    assert lib.assertMsg libDiffers "variants: hostdep's lib is shared between build and check";
    assert lib.assertMsg (
      fpNames == [
        "fp-lib-a_x"
        "fp-lib-a_x+lib-a_y"
        "fp-lib-a_y"
        "fp-none"
      ]
    ) "variants: powerset ${builtins.toJSON fpNames}";
    assert lib.assertMsg (
      variantsRepo.checks ? "main/${native}/variant-clippy/check"
    ) "variants: no clippy check in repo.checks";
    # The powerset's variants keep their test runs out of
    # repo.checks; the hand-written coverage variant's are in.
    assert lib.assertMsg (
      lib.filter (lib.hasInfix "/variant-fp-") (lib.attrNames variantsRepo.checks) == [ ]
    ) "variants: powerset variants in repo.checks";
    assert lib.assertMsg (
      lib.any (lib.hasPrefix "main/${native}/variant-coverage/lib-a/test-") (lib.attrNames variantsRepo.checks)
    ) "variants: the coverage variant's test runs are not in repo.checks";
    # Its products and their checks too, and the custom build variant's.
    assert lib.assertMsg (lib.all (n: variantsRepo.checks ? ${n}) [
      "main/${native}/variant-coverage/app/build"
      "main/${native}/variant-coverage/app/noSourceReferences"
      "main/${native}/variant-custom/app/build"
      "main/${native}/variant-custom/app/noSourceReferences"
    ]) "variants: other variants' products are not in repo.checks";
    pkgs.runCommand "variants"
      {
        app = vt.packages.app;
        custom = vt.variants.custom.packages.app;
        none = vt.variants.fp-none.packages.app;
        both = vt.variants."fp-lib-a_x+lib-a_y".packages.app;
        check = vt.variants.check.check;
        clippy = vt.variants.clippy.check;
      }
      ''
        set -euo pipefail
        [ "$($app/bin/app)" = "app 42 x=true y=false host=7" ]
        [ "$($custom/bin/app)" = "app 42 x=true y=false host=7" ]
        [ "$($none/bin/app)" = "app 42 x=false y=false host=7" ]
        [ "$($both/bin/app)" = "app 42 x=true y=true host=7" ]

        cat $check/units $clippy/units > $out
      '';

  # `allTargets = false` checks the build plan's units only
  # (`cargo check`); the default also checks the test plan's (`cargo check
  # --all-targets`). A build variant rejects it.
  variants-all-targets =
    let
      outsOf = us: lib.sort lib.lessThan (map (o: builtins.unsafeDiscardStringContext o) (lib.concatMap (u: map (o: u.${o}) u.outputs) us));
      lib' = vt.variants.check-lib.check;
      all = vt.variants.check.check;
      buildOuts = outsOf (lib.attrValues variantsRepo.workspaces.main.instances.${native}.check.units.build);
      got = lib.sort lib.lessThan (map builtins.unsafeDiscardStringContext lib'.units);
      allGot = map builtins.unsafeDiscardStringContext all.units;
      rejected = mkRepo (fixtures + "/variants") [
        {
          workspaces.main = {
            path = "ws";
            variants.default.allTargets = false;
          };
        }
      ];
      rejectedEval = builtins.tryEval (builtins.seq rejected.workspaces.main.target.${native}.packages.app.drvPath true);
    in
    assert lib.assertMsg (got == buildOuts) "variants-all-targets: check-lib does not check exactly the build plan";
    assert lib.assertMsg (lib.length allGot > lib.length got) "variants-all-targets: the default does not check more than the build plan";
    assert lib.assertMsg (!rejectedEval.success) "variants-all-targets: a build variant accepted allTargets = false";
    pkgs.runCommand "variants-all-targets" { check = lib'; } ''
      cp $check/units $out
    '';

  variants-clippy-toolchain =
    let
      withClippy = overlayRust.override { extensions = [ "clippy" ]; };
      planOf =
        toolchain:
        (mkRepo (fixtures + "/variants") [
          {
            workspaces.main = {
              path = "ws";
              inherit toolchain;
              variants.clippy.mode = "clippy";
            };
          }
        ]).workspaces.main.instances.${native}.clippy.plans.build;
    in
    pkgs.runCommand "variants-clippy-toolchain"
      {
        follows = planOf {
          rustc = withClippy;
          cargo = withClippy;
        };
        mismatch = pkgs.testers.testBuildFailure (planOf {
          rustc = withClippy;
          cargo = withClippy;
          clippy = pkgs.clippy;
        });
        missing = pkgs.testers.testBuildFailure (planOf {
          rustc = overlayRust;
          cargo = overlayRust;
        });
      }
      ''
        cat $mismatch/testBuildFailure.log $missing/testBuildFailure.log
        grep -q 'is built for another rustc' $mismatch/testBuildFailure.log
        grep -q 'set workspaces.main.toolchain.clippy to the clippy of this rustc' $mismatch/testBuildFailure.log
        grep -q 'does not exist; set workspaces.main.toolchain.clippy' $missing/testBuildFailure.log
        touch $out
      '';

  variants-coverage =
    let
      t = coverageRepo.workspaces.main.target.${native};
    in
    pkgs.runCommand "variants-coverage"
      {
        app = t.packages.app;
        run = t.testRuns.lib-a."lib/lib_a";
      }
      ''
        set -euo pipefail
        LLVM_PROFILE_FILE=$TMPDIR/app.profraw $app/bin/app
        [ -s $TMPDIR/app.profraw ]
        ls -l $run/profraw/
        [ -s "$(echo $run/profraw/*.profraw)" ]
        touch $out
      '';

  variants-clippy-strict =
    let
      unit = (unitsOf variantsRepo "strict" "build")."lib-a-0.1.0-lib";
    in
    pkgs.runCommand "variants-clippy-strict"
      {
        failure = expectFailure "lib-a-clippy" unit [
          "#len_zero"
          "-D clippy::len-zero"
        ];
        # The default clippy variant lints the same code and succeeds.
        lenient = (unitsOf variantsRepo "clippy" "build")."lib-a-0.1.0-lib";
      }
      ''
        cat $failure/log
        touch $out
      '';

  variants-clippy-conf =
    let
      repoAt =
        root: extra:
        mkRepo root [
          {
            workspaces.main = {
              path = "ws";
              variants = {
                default.profile = "dev";
                check.mode = "check";
                clippy = {
                  mode = "clippy";
                  clippyArgs = [
                    "-D"
                    "clippy::disallowed_methods"
                  ];
                };
              };
            };
          }
          extra
        ];
      repo = repoAt (fixtures + "/clippy-conf") { };
      edited' = repoAt (edited "clippy-conf" "echo '# edited' >> clippy.toml") { };
      # A user's CLIPPY_CONF_DIR names `own`'s directory for `rooted` too,
      # whose config allows `len`: `rooted`'s clippy unit then passes.
      userDir = repoAt (fixtures + "/clippy-conf") {
        packages.rooted.env.CLIPPY_CONF_DIR = "${fixtures + "/clippy-conf/ws/own"}";
      };
      clippyUnits = r: unitsOf r "clippy" "build";
      changed =
        vName: kind:
        lib.attrNames (
          lib.filterAttrs (n: d: (drvsOf edited' vName kind).${n} or null != d) (drvsOf repo vName kind)
        );
    in
    assert lib.assertMsg (
      changed "default" "build" == [ ] && changed "check" "build" == [ ] && changed "check" "test" == [ ]
    ) "variants-clippy-conf: a clippy.toml edit changed build or check units";
    assert lib.assertMsg (
      changed "clippy" "build" == [
        "own-0.1.0-lib"
        "rooted-0.1.0-lib"
      ]
    ) "variants-clippy-conf: clippy units changed by a root clippy.toml edit: ${builtins.toJSON (changed "clippy" "build")}";
    pkgs.runCommand "variants-clippy-conf"
      {
        rooted = expectFailure "rooted-clippy" (clippyUnits repo)."rooted-0.1.0-lib" [
          "disallowed method `std::vec::Vec::len`"
          "root config"
        ];
        own = expectFailure "own-clippy" (clippyUnits repo)."own-0.1.0-lib" [
          "disallowed method `std::vec::Vec::is_empty`"
          "own config"
        ];
        user = (clippyUnits userDir)."rooted-0.1.0-lib";
      }
      ''
        cat $rooted/log $own/log
        if grep -q 'root config' $own/log; then
          echo "a member with its own clippy.toml saw the root's" >&2
          exit 1
        fi
        touch $out
      '';

  # Field-trial gaps 4 and 5: variants and test plans narrowed per target
  # (`variants.<v>.targets`, `variants.<v>.packages`,
  # `workspaces.<ws>.targets.<t>.tests`), and every variant's test runs in
  # repo.checks under `variant-<v>/`. The musl target is never planned:
  # only a check variant is planned for it, and nothing here builds it.
  variants-narrowing =
    let
      musl = "x86_64-unknown-linux-musl";
      repo = mkRepo (fixtures + "/variants") [
        {
          workspaces.main = {
            path = "ws";
            targets = {
              ${native}.tests = [ "lib-a" ];
              ${musl}.tests = false;
            };
            variants = {
              default = {
                profile = "release";
                targets = [ native ];
              };
              # lib-a alone, with only `y`: its own test runs in checks.
              y-only = {
                profile = "release";
                targets = [ native ];
                packages = [ "lib-a" ];
                noDefaultFeatures = true;
                features = [ "y" ];
              };
              # The same with app's product, kept out of repo.checks.
              quiet = {
                profile = "release";
                targets = [ native ];
                packages = [
                  "lib-a"
                  "app"
                ];
                features = [ "lib-a/y" ];
                checks = false;
              };
              musl-check = {
                mode = "check";
                targets = [ musl ];
              };
            }
            # cargo-hack's per-package matrix for lib-a, one feature at a
            # time (field-trial gap 10).
            // breakbulk.variants.packageFeaturePowerset {
              root = fixtures + "/variants";
              path = "ws";
              packages = [ "lib-a" ];
              eachFeature = true;
              mode = "check";
              profile = "release";
              targets = [ native ];
            };
          };
        }
      ];
      w = repo.workspaces.main;
      n = w.target.${native};
      m = w.target.${musl};
      names = lib.attrNames (lib.filterAttrs (_: c: !(c.breakbulkCheckGroup or false)) repo.checks);
      under = prefix: lib.filter (lib.hasPrefix prefix) names;
      planCmd = vName: kind: w.instances.${native}.${vName}.plans.${kind}.drvAttrs.buildCommand;
      selects = vName: kind: pkg: lib.hasInfix " -p ${lib.escapeShellArg pkg} " (planCmd vName kind);
      yRun = repo.checks."main/${native}/variant-y-only/lib-a/test-lib";
      defaultRun = repo.checks."main/${native}/lib-a/test-lib";
      bad = lib.attrNames (
        lib.filterAttrs (_: ok: !ok) {
          nativeVariants = lib.attrNames n.variants == [
            "default"
            "hack-lib-a.all-features"
            "hack-lib-a.default"
            "hack-lib-a.no-default-features"
            "hack-lib-a.x"
            "hack-lib-a.y"
            "quiet"
            "y-only"
          ];
          hackPlan =
            selects "hack-lib-a.y" "build" "lib-a"
            && lib.hasInfix " --features y " (planCmd "hack-lib-a.y" "build")
            && lib.hasInfix " --no-default-features " (planCmd "hack-lib-a.y" "build");
          hackInChecks = repo.checks ? "main/${native}/variant-hack-lib-a.y/check";
          muslVariants = lib.attrNames m.variants == [ "musl-check" ];
          muslEmpty = m.packages == { } && m.tests == { } && m.testRuns == { } && m.doctests == { };
          muslChecks = under "main/${musl}/" == [ "main/${musl}/variant-musl-check/check" ];
          # `tests = [ "lib-a" ]`: the test plan is `-p lib-a`, the build
          # plan stays `--workspace`.
          testsNarrowed = lib.attrNames n.tests == [ "lib-a" ] && lib.attrNames n.testRuns == [ "lib-a" ];
          testPlanSelects = selects "default" "test" "lib-a" && !(selects "default" "build" "lib-a");
          productsKept = n.packages ? app;
          # `packages` narrows both plans of a variant.
          variantSelects = selects "y-only" "build" "lib-a" && !(selects "y-only" "build" "app");
          yInChecks = repo.checks ? "main/${native}/variant-y-only/lib-a/test-lib";
          yDiffers = yRun.drvPath != defaultRun.drvPath;
          quietOut = under "main/${native}/variant-quiet/" == [ ] && n.variants.quiet.packages ? app;
          defaultKept = repo.checks ? "main/${native}/lib-a/test-lib";
        }
      );
      unknown = mkRepo (fixtures + "/variants") [
        {
          workspaces.main = {
            path = "ws";
            variants.default.targets = [ "riscv64gc-unknown-linux-gnu" ];
          };
        }
      ];
      unknownEval = builtins.tryEval (builtins.attrNames unknown.workspaces.main.target.${native}.variants);
    in
    assert lib.assertMsg (bad == [ ]) "variants-narrowing: failed ${toString bad}; checks: ${builtins.toJSON names}";
    assert lib.assertMsg (!unknownEval.success) "variants-narrowing: a variant target outside the workspace's targets was accepted";
    pkgs.runCommand "variants-narrowing"
      {
        inherit yRun;
        hack = repo.checks."main/${native}/variant-hack-lib-a.y/check";
        report = builtins.toJSON names;
      }
      ''
        printf '%s\n' "$report" > $out
      '';

  # Per-target variant settings: castaway's shape (one `default` variant,
  # a feature only on another target, through that target's
  # `variantDefaults`), a variant replacing the defaults in its own target
  # layer, a package run keeping its own features over the defaults, and
  # `allTargets = false` on one target only. wasm32 stands in for msvc,
  # with a rust-overlay toolchain that has its std.
  # A target only built (wasm32, `tests = false`) next to one only tested
  # (native, `products = false`): repo.checks has the native test runs and
  # doctests and no native product or product check, nor any wasm test
  # run; `products = [ "app" ]` keeps app's product only.
  tests-only =
    let
      wasm = "wasm32-unknown-unknown";
      wasmRust = overlayRust.override { targets = [ wasm ]; };
      repoWith =
        nativeTarget:
        mkRepo (fixtures + "/variants") [
          {
            workspaces.main = {
              path = "ws";
              variants.default.profile = "dev";
              toolchain = {
                rustc = wasmRust;
                cargo = wasmRust;
              };
              targets = {
                ${native} = nativeTarget;
                ${wasm}.tests = false;
              };
            };
          }
        ];
      repo = repoWith { products = false; };
      # Three packages with products (cdylib, staticlib, bin).
      partial = mkRepo (fixtures + "/crate-types") [
        {
          workspaces.main = {
            path = ".";
            variants.default.profile = "dev";
            targets.${native}.products = [ "app" ];
          };
        }
      ];
      leaves = r: lib.attrNames (lib.filterAttrs (_: c: !(c.breakbulkCheckGroup or false)) r.checks);
      nativeChecks = lib.filter (lib.hasPrefix "main/${native}/") (leaves repo);
      wasmChecks = lib.filter (lib.hasPrefix "main/${wasm}/") (leaves repo);
      isRun = n: lib.hasInfix "/test-" n || lib.hasSuffix "/doctest" n;
      t = repo.workspaces.main.target;
    in
    assert lib.assertMsg (t.${native}.packages == { }) "products-tests-only: native products ${toString (lib.attrNames t.${native}.packages)}";
    assert lib.assertMsg (
      nativeChecks != [ ] && lib.all isRun nativeChecks && lib.any (lib.hasSuffix "/doctest") nativeChecks
    ) "products-tests-only: native checks ${toString nativeChecks}";
    assert lib.assertMsg (
      wasmChecks != [ ] && !(lib.any isRun wasmChecks)
    ) "products-tests-only: wasm checks ${toString wasmChecks}";
    assert lib.assertMsg (
      lib.attrNames partial.workspaces.main.target.${native}.packages == [ "app" ]
    ) "products-tests-only: with a list, native products ${toString (lib.attrNames partial.workspaces.main.target.${native}.packages)}";
    evalCheck "products-tests-only" (builtins.toJSON { inherit nativeChecks wasmChecks; });

  variants-per-target =
    let
      wasm = "wasm32-unknown-unknown";
      wasmRust = overlayRust.override { targets = [ wasm ]; };
      repoWith =
        extra:
        mkRepo (fixtures + "/variants") [
          {
            workspaces.main = lib.mkMerge [
              {
                path = "ws";
                toolchain = {
                  rustc = wasmRust;
                  cargo = wasmRust;
                };
                targets = {
                  ${native} = { };
                  ${wasm}.variantDefaults.features = [ "lib-a/y" ];
                };
              }
              extra
            ];
          }
        ];
      repo = repoWith {
        variants = {
          default.profile = "release";
          own = {
            profile = "release";
            features = [ "lib-a/x" ];
            target.${wasm} = {
              features = lib.mkForce [ ];
              noDefaultFeatures = true;
            };
          };
          gate = {
            mode = "check";
            profile = "release";
            target.${wasm}.allTargets = false;
          };
        }
        // breakbulk.variants.packageFeaturePowerset {
          root = fixtures + "/variants";
          path = "ws";
          packages = [ "lib-a" ];
          eachFeature = true;
          mode = "check";
          profile = "release";
        };
      };
      w = repo.workspaces.main;
      planCmd = triple: vName: kind: w.instances.${triple}.${vName}.plans.${kind}.drvAttrs.buildCommand;
      has = triple: vName: s: lib.hasInfix " ${s} " (planCmd triple vName "build");
      unitsOf = triple: lib.length w.target.${triple}.variants.gate.check.units;
      planUnits =
        triple: kind:
        lib.length (lib.concatMap (u: u.outputs) (lib.attrValues w.instances.${triple}.gate.units.${kind}));
      fails =
        extra:
        !(builtins.tryEval (
          builtins.deepSeq (lib.mapAttrs (_: lib.mapAttrs (_: p: p.build.drvPath)) (repoWith extra).workspaces.main.plans) true
        )).success;
      bad = lib.attrNames (
        lib.filterAttrs (_: ok: !ok) {
          # The default variant: lib-a/y on wasm only.
          defaultNative = !(has native "default" "--features");
          defaultWasm = has wasm "default" "--features lib-a/y";
          # `own`: its feature natively; on wasm its layer replaces both.
          ownNative = has native "own" "--features lib-a/x" && !(has native "own" "--no-default-features");
          ownWasm = !(has wasm "own" "--features") && has wasm "own" "--no-default-features";
          # A `-p lib-a` run keeps exactly its own features on wasm.
          hackWasm =
            has wasm "hack-lib-a.x" "--features x"
            && !(lib.hasInfix "lib-a/y" (planCmd wasm "hack-lib-a.x" "build"));
          hackNoDefault =
            !(has wasm "hack-lib-a.no-default-features" "--features")
            && has wasm "hack-lib-a.no-default-features" "--no-default-features";
          # `allTargets = false` on wasm only: the build plan's units there,
          # both plans' natively.
          gateWasm = unitsOf wasm == planUnits wasm "build";
          gateNative = unitsOf native == planUnits native "build" + planUnits native "test";
          # A build variant cannot take `allTargets = false`, on one
          # target either.
          rejectsBuildAllTargets = fails { variants.default.target.${wasm}.allTargets = false; };
          # A layer for a target the variant is not planned for.
          rejectsUnplanned = fails {
            variants.default = {
              targets = [ native ];
              target.${wasm}.profile = "dev";
            };
          };
          # A single value set in the variant and its layer conflicts
          # without mkForce.
          conflicts = fails {
            variants.default = {
              profile = "release";
              target.${wasm}.profile = "dev";
            };
          };
        }
      );
    in
    assert lib.assertMsg (bad == [ ]) "variants-per-target: failed ${toString bad}";
    pkgs.runCommand "variants-per-target" { gate = w.target.${wasm}.variants.gate.check; } ''
      cp $gate/units $out
    '';

  source-paths =
    let
      i = inst sourcePaths;
      depView = i.sources.workspace.dep;
      itoaSrc = lib.head (
        lib.attrValues (lib.filterAttrs (id: _: lib.hasSuffix "#itoa@1.0.11" id) i.sources.crates)
      );
      build = renderedUnits sourcePaths "build";
      test = renderedUnits sourcePaths "test";
      scopes = lib.mapAttrs (_: u: u.remapScope or null) (
        lib.filterAttrs (_: u: u.kind == "compile") (build // test)
      );
      want = {
        "app-0.1.0-bin" = "macro,diagnostics";
        "dep-0.1.0-lib" = "macro,diagnostics";
        "itoa-1.0.11-lib" = "macro,diagnostics";
        "app-0.1.0-test" = null;
        "dep-0.1.0-test" = null;
      };
      bad = lib.filterAttrs (n: s: (scopes.${n} or "missing") != s) want;
    in
    assert lib.assertMsg (bad == { }) "source-paths: remap scopes ${builtins.toJSON scopes}";
    assert lib.assertMsg (
      spApp.stageOrder == [
        "splitDebug"
        "install"
      ]
    ) "source-paths: stages ${builtins.toJSON spApp.stageOrder}";
    pkgs.runCommand "source-paths"
      {
        nativeBuildInputs = [ pkgs.gdb ];
        app = spApp;
        debug = spApp.debug;
        debugClosure = pkgs.closureInfo { rootPaths = [ spApp.debug ]; };
        # Negative control: before splitDebug, the binary does reference
        # the sources (debug info keeps real paths), so noSourceReferences
        # is not passing vacuously.
        linkedClosure = pkgs.closureInfo { rootPaths = [ spApp.stages.linked ]; };
        noSrc = spApp.checks.noSourceReferences;
        depView = builtins.unsafeDiscardStringContext "${depView}";
        itoaSrc = builtins.unsafeDiscardStringContext "${itoaSrc}";
        depTests = sourcePaths.workspaces.main.testRuns.dep."lib/dep";
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        cat run.txt
        grep -qxF 'dep is dep/src/lib.rs' run.txt
        grep -qxF 'formatted 42' run.txt
        grep -qxF 'panicked at dep/src/lib.rs:16' run.txt
        # The debug output references exactly the sources a debugger needs.
        grep -qxF "$depView" $debugClosure/store-paths
        grep -qxF "$itoaSrc" $debugClosure/store-paths
        grep -qxF "$depView" $linkedClosure/store-paths
        # gdb finds the split debug info by build ID: it runs the product
        # to a breakpoint in the dependency, prints the backtrace through
        # it with source files and lines, and lists the source.
        ${gdbCheck}
        touch $out
      '';

  source-paths-dwp =
    let
      p = sourcePaths.workspaces.main.target.${native}.variants.packed.packages.app;
    in
    pkgs.runCommand "source-paths-dwp"
      {
        nativeBuildInputs = [
          pkgs.gdb
          pkgs.binutils-unwrapped
        ];
        app = p;
        debug = p.debug;
        linkedDebug = p.stages.linked.debug;
        noSrc = p.checks.noSourceReferences;
        depView = builtins.unsafeDiscardStringContext "${(inst sourcePaths).sources.workspace.dep}";
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        grep -qxF 'formatted 42' run.txt
        # rustc wrote a .dwp (packed) and the link unit kept it.
        test -f $linkedDebug/app.dwp
        readelf -S -W $linkedDebug/app.dwp | grep -q '\.debug_info\.dwo'
        # splitDebug put it next to the separate debug file, under the
        # binary's name; the install-layout path is a link to it.
        id=$(readelf -n $app/bin/app | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
        test -f $debug/lib/debug/.build-id/''${id:0:2}/app.dwp
        test -L $debug/bin/app.dwp
        test -f $debug/bin/app.dwp
        ${gdbCheck}
        mkdir -p $out
        cp gdb.txt $out/
      '';

  source-paths-dwo = dwoCheck "source-paths-dwo" sourcePaths 4;
  source-paths-dwo5 = dwoCheck "source-paths-dwo5" sourcePathsDwarf5 5;

  trim-paths =
    let
      wsOf = w: trimPathsRepo.workspaces.${w};
      instOf = w: (wsOf w).instances.${native}.default;
      planOf =
        w: kind:
        builtins.fromJSON (
          builtins.unsafeDiscardStringContext (builtins.readFile "${(instOf w).plans.${kind}}/plan.json")
        );
      compiles = p: lib.filterAttrs (_: u: u.kind == "compile") p.units;
      hasArg = pred: u: lib.any pred (map (a: if builtins.isString a then a else "") u.args);
      rendered =
        w: kind:
        lib.listToAttrs (
          map (
            u:
            lib.nameValuePair u.name (
              builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)
            )
          ) (lib.attrValues (instOf w).units.${kind})
        );
      plans = lib.genAttrs [ "set" "default" ] (w: lib.genAttrs [ "build" "test" ] (planOf w));
      allCompiles = w: compiles plans.${w}.build // compiles plans.${w}.test;
      # The shared crate's library unit key in a plan.
      sharedKey =
        p:
        lib.attrNames (
          lib.filterAttrs (
            _: u: u.kind == "compile" && u.crate.name == "shared" && u.crate.types == [ "lib" ]
          ) p.units
        );
      renderedCompiles =
        w: lib.filterAttrs (_: u: u.kind == "compile") (rendered w "build" // rendered w "test");
      ownRemaps = w: lib.filterAttrs (_: u: (u.remap or [ ]) != [ ]) (renderedCompiles w);
      scopes = w: lib.mapAttrs (_: u: u.remapScope or null) (renderedCompiles w);
      wantDefault = {
        "app-0.1.0-bin" = "macro,diagnostics";
        "shared-0.1.0-lib" = "macro,diagnostics";
        "itoa-1.0.11-lib" = "macro,diagnostics";
        "lib-0.1.0-test" = null;
      };
      badDefault = lib.filterAttrs (n: s: ((scopes "default").${n} or "missing") != s) wantDefault;
      setScoped = lib.filterAttrs (_: s: s != null) (scopes "set");
      setNoScope = lib.filterAttrs (
        _: u: !(hasArg (a: a == "--remap-path-scope=all") u)
      ) (allCompiles "set");
      defaultScope = lib.filterAttrs (
        _: u: hasArg (lib.hasPrefix "--remap-path-scope") u
      ) (allCompiles "default");
      # A build-directory remap per run named (`<run out>=/cargo/build-dir`:
      # the out copies Cargo's build directory), as the shared crate's lib has.
      sharedLib = lib.head (
        lib.attrValues (
          lib.filterAttrs (
            _: u: u.kind == "compile" && u.crate.name == "shared" && u.crate.types == [ "lib" ]
          ) plans.default.build.units
        )
      );
      buildDirRemaps = lib.filter (
        a: builtins.isList a && builtins.isString (lib.last a) && lib.last a == "=/cargo/build-dir"
      ) sharedLib.args;
      app = w: (wsOf w).packages.app;
      # The planner run directly on the `default` workspace's skeleton at
      # another location than /build/skeleton.
      planAt =
        name: rust: dir:
        let
          ws = wsOf "default";
          i = instOf "default";
        in
        pkgs.runCommand "trim-paths-plan-${name}" { } ''
          mkdir -p "$(dirname ${dir})"
          cp -r --no-preserve=mode ${i.skeleton} ${dir}
          mkdir -p $out
          ${tools.breakbulk-plan}/bin/breakbulk-plan             --cargo ${rust}/bin/cargo --rustc ${rust}/bin/rustc --rustdoc ${rust}/bin/rustdoc             --shim ${tools.breakbulk-shim}/bin/breakbulk-shim             --skeleton ${dir} --workspace default --canonical-root /build/skeleton             --kind build --target ${native} --profile dev             --config ${i.vendor.configFile}             --capabilities ${
            breakbulk.toolchainFacts.capabilitiesFile
              (breakbulk.toolchainFacts.of {
                inherit pkgs;
                rustc = rust;
                cargo = rust;
              }).capabilities
          }             --scratch $NIX_BUILD_TOP/scratch --forbid $NIX_BUILD_TOP --forbid $HOME             --out $out/plan.json 2> $out/log || true
          cat $out/log
        '';
      readPlanAt =
        d:
        let
          f = "${d}/plan.json";
        in
        builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile f));
      atA = planAt "a" trimRust "$NIX_BUILD_TOP/a/skeleton";
      atB = planAt "b" trimRust "$NIX_BUILD_TOP/elsewhere/b/sk";
      stableAt = planAt "stable" pkgs.rust-bin.stable."1.99.0".minimal "$NIX_BUILD_TOP/a/skeleton";
    in
    assert lib.assertMsg (
      plans.set.build.trimPaths && !(plans.set.build.trimPathsDefault or false)
    ) "trim-paths: set's plan: trimPaths ${builtins.toJSON plans.set.build.trimPaths}";
    assert lib.assertMsg (
      plans.default.build.trimPaths && plans.default.build.trimPathsDefault
      && plans.default.test.trimPathsDefault
    ) "trim-paths: the planner did not turn trim-paths on for default's plans";
    assert lib.assertMsg (
      setNoScope == { }
    ) "trim-paths: set's units without Cargo's scope: ${toString (lib.attrNames setNoScope)}";
    assert lib.assertMsg (
      defaultScope == { }
    ) "trim-paths: default's units kept Cargo's scope: ${toString (lib.attrNames defaultScope)}";
    assert lib.assertMsg (ownRemaps "set" == { } && ownRemaps "default" == { })
      "trim-paths: breakbulk added remaps: ${toString (lib.attrNames (ownRemaps "set" // ownRemaps "default"))}";
    assert lib.assertMsg (setScoped == { }) "trim-paths: set's units got a breakbulk scope: ${builtins.toJSON setScoped}";
    assert lib.assertMsg (
      badDefault == { }
    ) "trim-paths: default's scopes ${builtins.toJSON (scopes "default")}";
    assert lib.assertMsg (
      lib.length buildDirRemaps == 1
    ) "trim-paths: shared's build-directory remaps: ${builtins.toJSON buildDirRemaps}";
    # Hashed without its absolute path: one key in both workspaces and at
    # two other locations.
    assert lib.assertMsg (
      sharedKey plans.set.build == sharedKey plans.default.build
      && lib.length (sharedKey plans.set.build) == 1
    ) "trim-paths: shared's keys ${builtins.toJSON [ (sharedKey plans.set.build) (sharedKey plans.default.build) ]}";
    assert lib.assertMsg (
      sharedKey (readPlanAt atA) == sharedKey plans.default.build
      && sharedKey (readPlanAt atB) == sharedKey plans.default.build
    ) "trim-paths: shared's key depends on the skeleton location";
    pkgs.runCommand "trim-paths"
      {
        nativeBuildInputs = [ pkgs.gdb ];
        setApp = app "set";
        defaultApp = app "default";
        defaultDebug = (app "default").debug;
        setDebugClosure = pkgs.closureInfo { rootPaths = [ (app "set").debug ]; };
        defaultDebugClosure = pkgs.closureInfo { rootPaths = [ (app "default").debug ]; };
        noSrcSet = (app "set").checks.noSourceReferences;
        noSrcDefault = (app "default").checks.noSourceReferences;
        sharedView = builtins.unsafeDiscardStringContext "${(instOf "default").sources.workspace.shared}";
        tests = (wsOf "default").testRuns.lib."lib/lib";
        inherit stableAt;
      }
      ''
        set -euo pipefail
        for a in $setApp $defaultApp; do
          $a/bin/app > run.txt
          cat run.txt
          grep -qxF 'main is app/src/main.rs' run.txt
          grep -qxF 'shared is /cargo/deps/shared-0.1.0/src/lib.rs' run.txt
          grep -qE '^generated is /cargo/build-dir/${native}/debug/build/shared[-/][0-9a-f]+/out/gen.rs$' run.txt
          grep -qxF 'formatted 42' run.txt
          grep -qxF 'panicked at /cargo/deps/shared-0.1.0/src/lib.rs:18' run.txt
        done
        # default: debug info keeps store paths (scope macro,diagnostics),
        # so the debug output references the sources and gdb lists them.
        grep -qxF "$sharedView" $defaultDebugClosure/store-paths
        gdb -batch -nx -iex "set debug-file-directory $defaultDebug/lib/debug"           -ex 'list shared::boom' $defaultApp/bin/app > gdb.txt 2>&1 || true
        cat gdb.txt
        grep -qF 'panic!("boom {n}");' gdb.txt
        # set: the project's scope (all) remaps debug info too.
        if grep -qxF "$sharedView" $setDebugClosure/store-paths; then
          echo "set's debug output references the shared crate's source" >&2; exit 1
        fi
        # Stable 1.99 has no trim-paths: at another location, planning
        # refuses, naming the crate whose absolute path Cargo would hash.
        grep -q 'shared 0.1.0' $stableAt/log
        test ! -e $stableAt/plan.json
        touch $out
      '';

  trim-paths-cc =
    let
      repo = trimCcRepo { };
      off = trimCcRepo { cargoTrimPaths = false; };
      keep = trimCcRepo { sourcePaths = "keep"; };
      planOf =
        r:
        builtins.fromJSON (
          builtins.unsafeDiscardStringContext (builtins.readFile "${(inst r).plans.build}/plan.json")
        );
      runOf =
        r:
        lib.head (lib.attrValues (lib.filterAttrs (n: _: lib.hasPrefix "r-cfile-" n) (inst r).units.build));
      renderedRun = r: builtins.fromJSON (builtins.unsafeDiscardStringContext (runOf r).drvAttrs.BREAKBULK_UNIT);
      run = renderedRun repo;
      cargoNamed = to: to == "." || lib.hasPrefix "/cargo/" to || lib.hasPrefix "/rustc/" to;
      offRun = renderedRun off;
      keepUnits = map (u: builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)) (
        lib.attrValues (inst keep).units.build
      );
      keepRemaps = lib.filter (u: (u.remap or [ ]) != [ ] || (u.remapScope or null) != null || (u.outDirRemap or null) != null) keepUnits;
      # trim-paths for one package only: planning fails naming both sides.
      mixed = pkgs.testers.testBuildFailure (inst (
        mkRepo (edited "trim-paths-cc" "printf '\\n[profile.dev.package.cc]\\ntrim-paths = \"all\"\\n' >> Cargo.toml") [
          (oneWs "." "dev")
          {
            workspaces.main.toolchain = {
              rustc = trimRust;
              cargo = trimRust;
            };
          }
        ]
      )).plans.build;
      view = builtins.unsafeDiscardStringContext "${(inst repo).sources.workspace.cfile}";
      product = repo.workspaces.main.packages.cfile;
    in
    assert lib.assertMsg ((planOf repo).trimPaths && (planOf repo).trimPathsDefault) "trim-paths-cc: trim-paths is not on";
    assert lib.assertMsg (
      lib.all (p: cargoNamed (lib.elemAt p 1)) run.remap && run.remap != [ ]
    ) "trim-paths-cc: the run's C prefix maps: ${builtins.toJSON run.remap}";
    assert lib.assertMsg ((run.outDirRemap or "") == "/cargo/build-dir") "trim-paths-cc: outDirRemap ${builtins.toJSON (run.outDirRemap or null)}";
    assert lib.assertMsg (
      !(planOf off).trimPaths && lib.hasPrefix "/breakbulk/build/" (offRun.outDirRemap or "")
    ) "trim-paths-cc: cargoTrimPaths = false: ${builtins.toJSON offRun.outDirRemap}";
    assert lib.assertMsg (!(planOf keep).trimPaths && keepRemaps == [ ]) "trim-paths-cc: sourcePaths = keep added remaps";
    assert lib.assertMsg (
      !(keep.workspaces.main.packages.cfile.checks ? noSourceReferences)
    ) "trim-paths-cc: sourcePaths = keep still has noSourceReferences";
    pkgs.runCommand "trim-paths-cc"
      {
        nativeBuildInputs = [ pkgs.binutils ];
        inherit product mixed view;
        runOut = (runOf repo).out;
        noSrc = product.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        $product/bin/cfile | tee run.txt
        grep -qxF 'c is ./cfile/c/where.c' run.txt
        a=$(find $runOut -name 'libwhere.a')
        strings -a $a | grep -qxF './cfile/c/where.c'
        if strings -a $a | grep -F "$view"; then
          echo "the C object names the source view" >&2; exit 1
        fi
        readelf --debug-dump=info $a > info.txt
        grep -E 'DW_AT_(name|comp_dir)' info.txt
        grep -qE 'DW_AT_name.*: \./cfile/c/where\.c' info.txt
        grep -qE 'DW_AT_comp_dir.*: \./cfile$' info.txt
        if grep -E 'DW_AT_(name|comp_dir)' info.txt | grep -q /nix/store; then
          echo "the C object's debug info names a store path" >&2; exit 1
        fi
        grep -q 'on: cc 1.11.1; off: ' $mixed/testBuildFailure.log
        grep -q 'cfile 0.1.0' $mixed/testBuildFailure.log
        touch $out
      '';

  source-paths-readme =
    let
      before = sourcePaths.workspaces.main.tests.dep.lib;
      after = sourcePathsReadme.workspaces.main.tests.dep.lib;
    in
    assert lib.assertMsg (
      before.drvPath != after.drvPath
    ) "source-paths-readme: the README edit changed no derivation";
    pkgs.runCommand "source-paths-readme" { inherit before after; } ''
      cmp $before/bin/dep $after/bin/dep
      touch $out
    '';

  # A toolchain with the rust-src component (rust-overlay's `default`
  # profile has it): rustc names std's files by the local copy's store path,
  # so without the planner's /rustc/<hash> remap the product referenced the
  # whole toolchain (field trials: every datboi2 binary and wasm component).
  # The product's runtime references stay glibc and gcc's libs.
  rust-src =
    let
      repo = rustSrcRepo;
      plan = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (
          builtins.readFile "${repo.workspaces.main.plans.${native}.default.build}/plan.json"
        )
      );
    in
    assert lib.assertMsg (plan ? rustSrcRemap) "rust-src: the plan has no rustSrcRemap";
    pkgs.runCommand "rust-src"
      {
        app = repo.workspaces.main.packages.stdpaths;
        refs = pkgs.writeClosure [ repo.workspaces.main.packages.stdpaths ];
      }
      ''
        $app/bin/stdpaths x | grep -qx 'a,b,x'
        # Any rust-overlay path (the joined toolchain or a component).
        if grep -e '-rust-' $refs; then
          echo "the product references the toolchain" >&2
          exit 1
        fi
        touch $out
      '';

  # Field-trial gap 9: noSourceReferences also fails on the toolchain's
  # store paths. `app` compiles its GIT_REV in, set here to rustc's sysroot,
  # so the product references the toolchain; `tool` does not.
  no-toolchain-references =
    let
      sysroot = pkgs.rustc.unwrapped;
      repo = mkRepo (fixtures + "/stamps") [
        (oneWs "." "dev")
        { packages.app.env.GIT_REV = "${sysroot}"; }
      ];
      ps = repo.workspaces.main.packages;
      listed = lib.splitString "\n" (
        builtins.readFile ps.app.checks.noSourceReferences.drvAttrs.toolchainList
      );
      want = map (p: builtins.unsafeDiscardStringContext "${p}") [
        pkgs.rustc
        sysroot
        pkgs.cargo
      ];
      missing = lib.filter (p: !(lib.elem p listed)) want;
    in
    assert lib.assertMsg (missing == [ ]) "no-toolchain-references: not looked for: ${toString missing}";
    pkgs.runCommand "no-toolchain-references"
      {
        failure = pkgs.testers.testBuildFailure ps.app.checks.noSourceReferences;
        clean = ps.tool.checks.noSourceReferences;
      }
      ''
        cat $failure/testBuildFailure.log
        grep -qF 'references the Rust toolchain ${builtins.unsafeDiscardStringContext "${sysroot}"}' $failure/testBuildFailure.log
        touch $out
      '';

  # A staticlib keeps its objects' debug information, with real source
  # paths, for the final link to split or strip: noSourceReferences allows
  # sources named only by the archive. A source that another file of the
  # same product names still fails.
  staticlib-sources =
    let
      repo =
        extra:
        mkRepo (fixtures + "/crate-types") (
          [
            (oneWs "." "dev")
          ]
          ++ extra
        );
      plain = (repo [ ]).workspaces.main.packages.stat;
      naming = (repo [
        {
          packages.stat.stages.nameSource = {
            after = "splitDebug";
            before = "install";
            run =
              { input, product, pkgs, ... }:
              pkgs.runCommand "stat-name-source" { } ''
                cp -r --no-preserve=mode ${input} $out
                echo ${toString product.sourcePaths} > $out/where.txt
              '';
          };
        }
      ]).workspaces.main.packages.stat;
    in
    pkgs.runCommand "staticlib-sources"
      {
        clean = plain.checks.noSourceReferences;
        failure = pkgs.testers.testBuildFailure naming.checks.noSourceReferences;
      }
      ''
        # The archive names a source, so the passing check allowed it.
        named=0
        while IFS= read -r s; do
          if [ -n "$s" ] && grep -aqF "$s" ${plain}/lib/libstat*.a; then named=1; fi
        done < ${plain.checks.noSourceReferences.drvAttrs.sourcesList}
        [ "$named" = 1 ] || { echo "the archive names no source: the test proves nothing" >&2; exit 1; }
        cat $failure/testBuildFailure.log
        # where.txt names every source, the archive's too: none is allowed.
        grep -q 'references source' $failure/testBuildFailure.log
        if grep -q ': allowed$' $failure/testBuildFailure.log; then exit 1; fi
        touch $out
      '';

  # A product linked with `-C prefer-dynamic` loads
  # libstd-*.so from the sysroot, which its RUNPATH names. With nixpkgs'
  # rustc the sysroot (rustc.unwrapped) is the only toolchain path in its
  # closure, and its NEEDED libstd is there: the check passes. With
  # rust-overlay's toolchain the RUNPATH names the joined toolchain, whose
  # closure has the rustc and cargo components, which hold no library the
  # product loads: the check fails naming cargo, and allows the joined
  # sysroot and rust-std.
  prefer-dynamic =
    let
      repo =
        toolchain:
        mkRepo (fixtures + "/stamps") [
          (oneWs "." "dev")
          {
            workspaces.main = { inherit toolchain; };
            targets.${native}.rustflags = [
              "-C"
              "prefer-dynamic"
            ];
          }
        ];
      nixpkgsTool = (repo { inherit (pkgs) rustc cargo; }).workspaces.main.packages.tool;
      tc = pkgs.rust-bin.stable."1.99.0".minimal;
      overlayTool =
        (repo {
          rustc = tc;
          cargo = tc;
        }).workspaces.main.packages.tool;
      cargoComponent = lib.findFirst (p: builtins.match "[a-z0-9]{32}-cargo-.*" (baseNameOf "${p}") != null) null tc.paths;
    in
    assert lib.assertMsg (cargoComponent != null) "prefer-dynamic: no cargo component in ${tc}";
    pkgs.runCommand "prefer-dynamic"
      {
        tool = nixpkgsTool;
        refs = pkgs.writeClosure [ nixpkgsTool ];
        clean = nixpkgsTool.checks.noSourceReferences;
        failure = pkgs.testers.testBuildFailure overlayTool.checks.noSourceReferences;
      }
      ''
        $tool/bin/tool | grep -q 'tool rev='
        ${pkgs.buildPackages.binutils-unwrapped}/bin/readelf -d $tool/bin/tool | grep -q 'NEEDED.*libstd-'
        grep -qxF ${builtins.unsafeDiscardStringContext "${pkgs.rustc.unwrapped}"} $refs
        cat $failure/testBuildFailure.log
        grep -qF 'references the Rust toolchain ${builtins.unsafeDiscardStringContext "${cargoComponent}"}' $failure/testBuildFailure.log
        grep -q 'loads libstd-.*: allowed' $failure/testBuildFailure.log
        if grep -qF 'references the Rust toolchain ${builtins.unsafeDiscardStringContext "${tc}"}' $failure/testBuildFailure.log; then
          echo "the joined sysroot, which holds libstd, was not allowed" >&2
          exit 1
        fi
        touch $out
      '';

  # What happens to debug info is a target property,
  # `targets.<t>.debugInfo`. It inserts the stage (splitDebug for "split",
  # strip for "strip", none for "keep") and sets the units' remap scope and
  # build ID; neither the target's nor a package's `stages` may remove that
  # stage or add `splitDebug` where it inserts none (an evaluation error
  # naming `debugInfo`), but they may override its attributes.
  debug-info =
    let
      mk = extra: mkRepo (fixtures + "/post-link") ([ (oneWs "." "dev") ] ++ extra);
      base = mk [ ];
      keep = mk [ { targets.${native}.debugInfo = "keep"; } ];
      strip = mk [ { targets.${native}.debugInfo = "strip"; } ];
      pk = r: r.workspaces.main.packages;
      unitOf = r: p: (pk r).${p}.roots."bin/${p}".drvPath;
      fails = r: p: !(builtins.tryEval (pk r).${p}.stageOrder).success;
      unitEnv = r: p: (pk r).${p}.roots."bin/${p}".drvAttrs.BREAKBULK_UNIT or "";
      report = {
        orders = map (r: (pk r).tool.stageOrder) [
          base
          keep
          strip
        ];
        # Removing the inserted stage, at package or target level.
        packageRemoves = fails (mk [ { packages.tool.stages.splitDebug = lib.mkForce null; } ]) "tool";
        targetRemoves = fails (mk [ { targets.${native}.stages.splitDebug = lib.mkForce null; } ]) "tool";
        stripRemoved = fails (mk [
          {
            targets.${native}.debugInfo = "strip";
            packages.tool.stages.strip = lib.mkForce null;
          }
        ]) "tool";
        # Adding splitDebug where the target keeps debug info.
        packageAdds = fails (mk [
          {
            targets.${native}.debugInfo = "keep";
            packages.server.stages.splitDebug = {
              after = "linked";
              run = helpers.splitDebug;
            };
          }
        ]) "server";
        # A non-ELF target cannot split.
        wasmSplit =
          !(builtins.tryEval (
            breakbulk.products.debugInfoOf {
              triple = "wasm32-unknown-unknown";
              debugInfo = "split";
            }
          )).success;
        # Overriding the inserted stage's attributes is allowed.
        override =
          (pk (mk [
            {
              packages.server.stages.splitDebug.run = helpers.splitDebug { binutils = pkgs.binutils-unwrapped; };
            }
          ])).server.stageOrder;
        # The remap scope and build ID follow debugInfo: keep and strip
        # units are the same, and differ from split's.
        keepIsStrip = unitOf keep "tool" == unitOf strip "tool";
        splitDiffers = unitOf base "tool" != unitOf keep "tool";
        splitScope = lib.hasInfix ''"remapScope":"macro,diagnostics"'' (unitEnv base "tool");
        keepScope = !(lib.hasInfix "remapScope" (unitEnv keep "tool"));
      };
      ok =
        report.orders == [
          [
            "splitDebug"
            "install"
          ]
          [ "install" ]
          [
            "strip"
            "install"
          ]
        ]
        && report.packageRemoves
        && report.targetRemoves
        && report.stripRemoved
        && report.packageAdds
        && report.wasmSplit
        && report.override == [
          "splitDebug"
          "install"
        ]
        && report.keepIsStrip
        && report.splitDiffers
        && report.splitScope
        && report.keepScope;
    in
    assert lib.assertMsg ok "debug-info: ${builtins.toJSON report}";
    evalCheck "debug-info" (builtins.toJSON report);

  post-link =
    let
      checkNames = lib.attrNames postLink.checks;
      want = map (n: "main/${native}/${n}") [
        "server/build"
        "server/noSourceReferences"
        "server/unstripped"
        "tool/build"
        "tool/noSourceReferences"
        "tool/unstripped"
      ];
    in
    assert lib.assertMsg (
      plServer.stageOrder == [
        "splitDebug"
        "stamp"
        "sign"
        "install"
      ]
    ) "post-link: server stages ${builtins.toJSON plServer.stageOrder}";
    assert lib.assertMsg (
      plTool.stageOrder == [
        "splitDebug"
        "strip"
        "install"
      ]
    ) "post-link: tool stages ${builtins.toJSON plTool.stageOrder}";
    assert lib.assertMsg (lib.all (
      n: lib.elem n checkNames
    ) want) "post-link: checks ${builtins.toJSON checkNames}";
    pkgs.runCommand "post-link"
      {
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
        server = plServer;
        serverLinked = plServer.stages.linked;
        serverDebug = plServer.debug;
        tool = plTool;
        unstripped = plServer.checks.unstripped;
        toolUnstripped = plTool.checks.unstripped;
        noSrc = plServer.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        # has FILE SECTION: whether FILE has SECTION (no pipe into grep -q,
        # which can fail with SIGPIPE under pipefail).
        has() { readelf -S -W "$1" > sections; grep -qF " $2 " sections; }
        [ "$($server/bin/server)" = "server 1" ]
        [ "$($tool/bin/tool)" = tool ]
        # Stage order as the marker stages saw it.
        [ "$(cat $server/stages.txt)" = "$(printf 'stamp\nsign')" ]
        # linked holds the unstripped binary under its target name.
        has $serverLinked/server .debug_info
        # splitDebug moved it to the debug output; no strip ran on server
        # (its symbol table is still there), but tool was stripped.
        ! has $server/bin/server .debug_info
        has $server/bin/server .symtab
        ! has $tool/bin/tool .symtab
        has $server/bin/server .gnu_debuglink
        ls $serverDebug/lib/debug/.build-id/*/*.debug
        touch $out
      '';
}
