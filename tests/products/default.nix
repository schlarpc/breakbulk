# Products, stages, source paths, products as inputs and variants,
# through mkRepository (IFD mode, native target). Wired into the flake's
# checks as `products-*`.
#
#   nix build -f tests/products post-link
#
#   debug-info       `targets.<t>.debugInfo` (split, keep, strip) inserts
#                    its stages (packDwo before splitDebug, packDwo alone,
#                    strip) and sets the units' remap scope; removing
#                    splitDebug or strip, or adding `splitDebug` against
#                    it, at target or package level, fails evaluation; a
#                    stage with no `after` runs after the inserted ones
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
#                    debug output with the bin's, and packDwo packs the
#                    ones the binary names into app.dwp;
#                    gdb's backtrace and source lines as above
#   source-paths-dwo5 the same with DWARF 5 (`-C dwarf-version=5`), which
#                    binutils' dwp packs into an empty .dwp
#   staticlib-dwp    crate-types' staticlib, calling a dependency, with
#                    split-debuginfo = "unpacked": the debug output holds
#                    lib/<archive>.dwp with the units of both crates; a C
#                    program linked against the archive, with
#                    `llvm-dwp <archive>.dwp -o <program>.dwp`, has gdb
#                    give a source line of the dependency's function, and
#                    not without it
#   debug-info-keep  `debugInfo = "keep"` and "unpacked": packDwo ships
#                    bin/app.dwp and no `.dwo`; gdb reads the dependency's
#                    arguments with the `.dwp` beside the binary, and not
#                    without it
#   debug-info-strip `debugInfo = "strip"` and "unpacked": no `.dwo` ships;
#                    and "packed": no `.dwp`
#   pack-dwo-removed `packages.app.stages.packDwo = null` ships the loose
#                    `.dwo` files beside splitDebug's debug file
#   product-attributes   the `product` a stage and a check get has the
#                    attributes docs/src/reference/stage-functions.md
#                    lists for each (evaluation only)
#   cdylib-debug-packed   a bin whose dependency is also a cdylib, with
#                    split-debuginfo = "packed": the bin's `linked` debug
#                    output holds app.dwp only, not the dependency's own
#                    libplugin.so.dwp, which stays in its product
#   cdylib-debug-unpacked the same with "unpacked": the `.dwo` files of
#                    the bin and of the dependency, and nothing else
#   source-paths-readme   editing dep's README changes its test binary's
#                    derivation but not its bytes
#   staticlib-sources   crate-types' staticlib passes noSourceReferences:
#                    sources named only by the archive (its objects' debug
#                    info) are allowed; a stage adding a file that names
#                    the same sources fails it
#   manifest-dir     a bin keeping env!("CARGO_MANIFEST_DIR") in a string:
#                    noSourceReferences fails, naming the cause and the
#                    removeSourceReferences stage at its place; with that
#                    stage only hash bytes change (to `e`), the check
#                    passes and the product runs
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
#                    and clippy variants' unit checks build;
#                    `packages.lib-a.variant.clippy` reaches the clippy
#                    variant's lib-a units and no other variant's units
#   variants-test-profile   `testProfile`: the default test plan is
#                    `--profile test`, where a test that needs debug
#                    assertions passes, and shares no dependency unit with
#                    the release build plan; `testProfile = "release"`
#                    shares every common unit; check variants keep
#                    `profile`
#   variants-cargo-config   `cargoConfig` (cargo-config): `panic =
#                    "abort"` on the variant's build-plan target units
#                    only; its `[env]` variable and `build.rustflags` reach
#                    product and test run beside the target's rustflags
#                    (both readers saw the file); owned keys are refused
#   variants-narrowing   `variants.<v>.targets`, `variants.<v>.packages`
#                    and `variants.<v>.tests` narrow plans and outputs per
#                    target; other variants' test runs are in repo.checks
#                    under `variant-<v>/` unless `checks.tests = false`; a
#                    test-only variant; `packages = false`
#   tests-only       `tests = false` on wasm32 and `products = false` on
#                    the native target, through the targets'
#                    `variantDefaults`: native test runs and doctests
#                    only; `products = [ "app" ]`
#   variants-per-target   `targets.<t>.variantDefaults` and
#                    `variants.<v>.target.<t>` (wasm32 with rust-overlay's
#                    1.99): a feature on one target only, a variant's
#                    layer replacing the defaults, a package run taking
#                    the defaults' features its package accepts and a
#                    user's own, `tests = false` on one check variant's
#                    target; a single value in the variant's target layer
#                    wins over the variant and `variantDefaults` without
#                    mkForce, priorities still count (`checks` on one
#                    target only); `testProfile` per target (check
#                    variants keep `profile`); invalid layers fail evaluation
#   variants-clippy-strict   `clippyArgs = [ "-D" "clippy::len_zero" ]`
#                    fails the member's clippy unit naming the lint
#   variants-driver   a toy rustc driver (it writes `<stem>.side` beside
#                    each crate file, folding in what it finds beside each
#                    `--extern`'s real path) as `rustcWrapper` with
#                    `sideFiles = [ ".side" ]`: app's side file carries
#                    lib-a's, which carries hostdep's, and the proc
#                    macro's, and finds every crate's side file beside
#                    its link in the dependency directory; hostdep's
#                    build-script run gets it as RUSTC_WRAPPER; as
#                    `rustcWorkspaceWrapper`, dependency units
#                    are the check variant's and only members get side
#                    files; a clippy variant refuses a workspace wrapper
#   variants-clippy-conf   clippy units find `clippy.toml` above the
#                    workspace (a root `disallowed-methods` fails
#                    `rooted`) and a member's own file instead of the
#                    root's (`own`); an edit to the root file changes
#                    only clippy units, and a `CLIPPY_CONF_DIR` in `env`
#                    replaces breakbulk's
#   variants-clippy-lint-groups   clippy's `lint_groups_priority`, which
#                    reads the compile's working directory's `Cargo.toml`
#                    (the workspace root's): a member taking a
#                    `[workspace.lints]` with a group at a lint's priority
#                    fails its clippy units naming the group, with
#                    predicted views and without; the same conflict in a
#                    member's own `[lints]` passes; plain `cargo clippy`
#                    does the same on both
#   port-from-crane  the worked example of the porting how-to, its module
#                    read from the page: a host workspace, a wasm component
#                    workspace (built on wasm32, tested natively) and a
#                    nightly workspace, each with its own lockfile and
#                    rust-toolchain.toml; the server embeds the component
#                    and its build script runs the nightly generator, both
#                    through `forTarget.env`; the server runs, and the
#                    checks the page names exist and pass
#   variants-clippy-host   a member that is both a dependency and a
#                    build-dependency (clippy-host), with a `--cfg` in the
#                    project's `build.rustflags`: the cfg reaches the
#                    target copy only (the product prints both copies'
#                    values); the clippy variant (`-D warnings`) fails the
#                    host copy on an unused variable, and
#                    `packages.runtime.variant.clippy.forHost.env.CLIPPY_ARGS`
#                    lets it pass, leaving the target copy and the default
#                    variant's units unchanged
#   variants-clippy-toolchain   with rust-overlay's 1.99 as rustc and
#                    cargo, `toolchain.clippy` defaults to that toolchain
#                    and the clippy plan builds; nixpkgs' clippy (another
#                    sysroot) and a toolchain without clippy-driver fail
#                    planning naming `workspaces.main.toolchain.clippy`
#   variants-coverage   the coverage product writes a profile, and the
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
#   ui-dist          the first example of the configuration page: `app`
#                    embeds (`packages.app.env.UI_DIST`) the wasmWeb
#                    product of `ui`, a member of the same workspace; the
#                    app carries the wasm and its JS glue
#   source-overlay   `packages.assets.sourceOverlay."ui/dist"` places
#                    ui-dist's wasm product (another repository's) where
#                    rust-embed reads it, replacing the repository's
#                    placeholder; `server` serves the embedded files and
#                    assets' unit test sees them; the workspace's
#                    instantiation and `other`'s units do not depend on
#                    the product, the units of assets and of its
#                    dependent `server` do
#   same-workspace-products   products of the plan that uses them: `app`'s
#                    build script runs `tool` (`nativeInputs`), `app` links
#                    `shared`'s cdylib (`inputs`) and embeds `tool`'s
#                    binary (`env`), declared in `productInputs`; the app
#                    runs with an empty environment and the embedded
#                    binary runs
#   nested-cargo     a build script that runs Cargo (`outer`'s builds the
#                    member `inner`, which has a registry dependency), with
#                    the workspace as `extraSources` and
#                    `repo.workspaces.<ws>.vendor.cargoHome` as CARGO_HOME:
#                    the product embeds the nested build's binary, which
#                    runs; noSourceReferences fails on the product, naming
#                    a source view; inner's test runs `cargo run -p inner`
#                    with the same CARGO_HOME in `test.env` and the rest of
#                    the workspace in `test.sourceScope`
#   nested-cargo-rustflags   the same with linuxStatic and a `--cfg` in the
#                    target's rustflags: the nested Cargo reads both from
#                    the run's CARGO_ENCODED_RUSTFLAGS (the inner binary is
#                    static and sees the cfg)
#   rustc-private    an integration test linked against the compiler's
#                    crates (`rustc_private`, with nixpkgs' rustc): it runs,
#                    finding librustc_driver through the RUNPATH nixpkgs'
#                    linker wrapper gives it, not the test run's copy of the
#                    sysroot's libraries
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
#                    `/cargo/build-dir/…`). `sourcePaths = "remap"`: no
#                    trim-paths, breakbulk's own names; `sourcePaths =
#                    "keep"`: no remaps at all and no noSourceReferences
#                    check; trim-paths set for one package only (a profile
#                    override) fails planning naming the packages on and off
#   build-script-outputs   a product installs a dependency's build-script
#                    outputs: a header published as `links` metadata
#                    (`include`) and a file in another package's OUT_DIR
#                    (`buildScriptPath`); the runs' metadata.json name
#                    their packages, versions and `links`
#   benches          a libtest-harness bench and a Criterion bench come
#                    from the bench variant only (`cargo bench --no-run`,
#                    bench profile, opt-level 3); the test plan has none;
#                    each runs once with `--test` as a check of the
#                    bench variant, but the one `test.binaries` disables
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

  inst = repo: repo.workspaces.main.internal.instances.${native}.default;

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
        lib.attrValues repo.workspaces.main.internal.instances.${native}.${vName}.units.${kind}
      )
    );
  drvsOf =
    repo: vName: kind:
    lib.mapAttrs (_: u: u.drvPath) (unitsOf repo vName kind);

  # lint-groups-priority's two workspaces with a clippy variant, with or
  # without predicted views for every member.
  lintGroupsRepo =
    predict:
    mkRepo (fixtures + "/lint-groups-priority") [
      {
        workspaces = lib.genAttrs [ "inherited" "own" ] (path: {
          inherit path;
          variants.clippy.mode = "clippy";
          memberDefaults.predictSources.enable = predict;
        });
      }
    ];

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
  sourcePathsReadme = mkRepo (edited "source-paths" "echo 'More words.' >> dep/README.md") spModules;

  # --- manifest-dir ------------------------------------------------------------

  manifestDir = extra: mkRepo (fixtures + "/manifest-dir") ([ (oneWs "." "dev") ] ++ extra);
  manifestDirRepo = manifestDir [
    {
      packages.app.stages.removeSourceReferences = {
        after = "splitDebug";
        run = helpers.removeSourceReferences;
      };
    }
  ];

  # --- product-attributes ------------------------------------------------------

  # A stage and a check that record the names of the `product` they get.
  probe =
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand "${product.name}-probe" { passthru.productNames = lib.attrNames product; } ''
      cp -RL --no-preserve=mode,ownership ${input} $out
    '';
  probeRepo = mkRepo (fixtures + "/source-paths") (
    spModules
    ++ [
      {
        targets.${native} = {
          stages.probe = {
            after = "install";
            run = probe;
          };
          checks.probe.run = probe;
        };
      }
    ]
  );
  # The `product` attributes docs/src/reference/stage-functions.md lists
  # for stages and for checks: its table's rows, by their "Given to".
  documentedProduct =
    let
      page = builtins.readFile ../../docs/src/reference/stage-functions.md;
      section = lib.last (lib.splitString "\n## `product`\n" page);
      rows = lib.concatMap (
        l:
        let
          m = builtins.match "[|] `([A-Za-z]+)` [|] ([a-z ]+) [|].*" l;
        in
        lib.optional (m != null) {
          name = lib.elemAt m 0;
          givenTo = lib.elemAt m 1;
        }
      ) (lib.splitString "\n" section);
      namesFor =
        what: lib.sort lib.lessThan (map (r: r.name) (lib.filter (r: lib.hasInfix what r.givenTo) rows));
    in
    {
      stages = namesFor "stages";
      checks = namesFor "checks";
    };
  spApp = sourcePaths.workspaces.main.packages.app;

  # --- cdylib-debug --------------------------------------------------------------

  cdylibDebug = mkRepo (fixtures + "/cdylib-debug") spModules;

  # The `kind` variant's app and plugin: the app runs, and the file names in
  # app's `linked` debug output, one per line, sorted, are in $names.
  cdylibDebugCheck =
    kind: script:
    let
      ps = cdylibDebug.workspaces.main.target.${native}.variants.${kind}.packages;
    in
    pkgs.runCommand "cdylib-debug-${kind}"
      {
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
        app = ps.app;
        debug = ps.app.debug;
        linkedDebug = ps.app.stages.linked.debug;
        pluginLinkedDebug = ps.plugin.stages.linked.debug;
      }
      ''
        set -euo pipefail
        $app/bin/app > run.txt
        grep -qxF 'plugin says 42' run.txt
        ls $linkedDebug | sort > names
        cat names
        ${script}
        # splitDebug packed app's DWARF into app.dwp.
        test -f $debug/bin/app.dwp
        readelf -S -W $debug/bin/app.dwp | grep -q '\.debug_info\.dwo'
        touch $out
      '';

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

  # The `unpacked` variant's app through packDwo and splitDebug, with
  # every split unit at DWARF `version`: the `.dwo` files reach the linked
  # stage, packDwo packs them into app.dwp, and gdb reads the dependency's arguments from
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
        # packDwo packed them into app.dwp and dropped the loose ones;
        # splitDebug moved it next to the separate debug file, as rustc's
        # own .dwp is with `packed`.
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

  # crate-types with split-debuginfo = "unpacked" as its only profile, and
  # `stat` (the staticlib) calling its new dependency `both`.
  staticlibUnpacked = mkRepo (edited "crate-types" ''
    printf '\n[profile.unpacked]\ninherits = "dev"\nsplit-debuginfo = "unpacked"\n' >> Cargo.toml
    printf '\n[dependencies]\nboth = { path = "../both" }\n' >> stat/Cargo.toml
    printf 'dependencies = [\n "both",\n]\n' >> Cargo.lock
    cat > stat/src/lib.rs <<'EOF'
    #[unsafe(no_mangle)]
    pub extern "C" fn stat_answer() -> u32 {
        both::both_answer() / 6
    }
    EOF
  '') [ (oneWs "." "unpacked") ];

  # source-paths' `variant` on a target whose debugInfo is `v`, and with
  # `extra` modules.
  debugInfoApp =
    variant: v: extra:
    (mkRepo (fixtures + "/source-paths") (
      spModules ++ [ { targets.${native}.debugInfo = v; } ] ++ extra
    )).workspaces.main.target.${native}.variants.${variant}.packages.app;
  unpackedApp = debugInfoApp "unpacked";

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

  variantsModules = variantsBase ++ [
    # One member's units in one variant's plans only.
    { packages.lib-a.variant.clippy.env.LINT_ONLY = "1"; }
  ];
  variantsBase = [
    {
      workspaces.main = {
        path = "ws";
        variants = {
          default.profile = "release";
          custom.profile = "release-custom";
          # Tests built as the products are: lib-a's `debug_assertions_on`
          # fails there, so its runs stay out of repo.checks.
          release-tests = {
            profile = "release";
            testProfile = "release";
            checks = {
              products = false;
              tests = false;
            };
          };
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
            tests = false;
          };
          strict = {
            mode = "clippy";
            profile = "release";
            clippyArgs = [
              "-D"
              "clippy::len_zero"
            ];
          };
        };
        imports = [
          (breakbulk.variants.featurePowerset {
            scope = "workspace";
            features = [
              "lib-a/x"
              "lib-a/y"
            ];
            prefix = "fp";
            variant.profile = "release";
          })
        ];
      };
    }
  ];
  variantsRepo = mkRepo (fixtures + "/variants") variantsModules;
  variantsBaseRepo = mkRepo (fixtures + "/variants") variantsBase;

  # A toy rustc driver (see variants-driver): runs rustc, then writes
  # `lib<crate><extra>.side` beside the metadata rustc wrote, naming the
  # crate and, for each `--extern`, the side file beside its real path;
  # and, for each crate file in the `-L dependency=` directory, whether a
  # side file is beside it there, symlinks unresolved (where rustc says it
  # loaded a crate from, for Verus's transitive imports).
  toyDriver = pkgs.writeShellScript "toy-driver" ''
    set -eu
    rustc=$1
    shift
    out= name= extra= next= depdir=
    externs=()
    for a in "$@"; do
      case $next in
        out) out=$a ;;
        name) name=$a ;;
        extern) externs+=("$a") ;;
        codegen) case $a in extra-filename=*) extra=''${a#extra-filename=} ;; esac ;;
        search) case $a in dependency=*) depdir=''${a#dependency=} ;; esac ;;
      esac
      next=
      case $a in
        --out-dir) next=out ;;
        --crate-name) next=name ;;
        --extern) next=extern ;;
        -C) next=codegen ;;
        -L) next=search ;;
      esac
    done
    "$rustc" "$@"
    [ -n "$out" ] && [ -n "$name" ] || exit 0
    {
      echo "$name"
      for e in "''${externs[@]}"; do
        p=''${e#*=}
        [ "$p" != "$e" ] || continue
        side=$(${pkgs.coreutils}/bin/realpath "$p")
        side=''${side%.*}.side
        if [ -e "$side" ]; then
          echo "extern ''${e%%=*}:"
          ${pkgs.gnused}/bin/sed 's/^/  /' "$side"
        else
          echo "extern ''${e%%=*}: none"
        fi
      done
      for c in "$depdir"/*.rmeta "$depdir"/*.rlib "$depdir"/*.so; do
        [ -e "$c" ] || continue
        c=''${c##*/}
        if [ -e "$depdir/''${c%.*}.side" ]; then
          echo "dep ''${c%.*}: side"
        else
          echo "dep ''${c%.*}: none"
        fi
      done
    } > "$out/lib$name$extra.side"
  '';
  driverRepo =
    extra:
    mkRepo (fixtures + "/variants") [
      {
        workspaces.main = {
          path = "ws";
          variants = {
            default.profile = "release";
            check = {
              mode = "check";
              profile = "release";
            };
            driven = {
              mode = "check";
              profile = "release";
              rustcWrapper = "${toyDriver}";
              sideFiles = [ ".side" ];
            };
            members = {
              mode = "check";
              profile = "release";
              rustcWorkspaceWrapper = "${toyDriver}";
              sideFiles = [ ".side" ];
            };
          }
          // extra;
        };
      }
    ];
  vt = variantsRepo.workspaces.main.target.${native};

  # `cargoConfig` (see variants-cargo-config): the target's own rustflags
  # make the planner choose where the toolchain spec's flags go, which the
  # variant's `build.rustflags` changes.
  cargoConfigModules = [
    {
      workspaces.main = {
        path = ".";
        variants = {
          default.profile = "release";
          dist = {
            profile = "release";
            cargoConfig = {
              profile.release.panic = "abort";
              env.FROM_CARGO_CONFIG = "dist";
              build.rustflags = [
                "--cfg"
                "from_cargo_config"
              ];
            };
          };
        };
      };
      targets.${native}.rustflags = [
        "--cfg"
        "from_spec"
      ];
    }
  ];
  cargoConfigRepo = mkRepo (fixtures + "/cargo-config") cargoConfigModules;

  # An upstream toolchain, for the tests that need rust-overlay's.
  overlayRust = pkgs.rust-bin.stable."1.99.0".minimal;
  coverageRepo = mkRepo (fixtures + "/variants") [
    {
      workspaces.main = {
        path = "ws";
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
  hostInst = repo: repo.workspaces.host.internal.instances.${native}.default;
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

  # The first example of docs/src/explanation/configuration.md, with a
  # toolchain that has the wasm target, a fixed GIT_REV and without the
  # parts this fixture has nothing for (openssl-sys, the clippy variant).
  uiDistRepo = mkRepo (fixtures + "/ui-dist") [
    (
      { repo, ... }:
      {
        workspaces.default.toolchain = {
          rustc = wasmRust;
          cargo = wasmRust;
        };
        workspaces.default.targets = {
          ${native} = { };
          wasm32-unknown-unknown.variantDefaults.packages = [ "ui" ];
        };
        targets.wasm32-unknown-unknown.preset = breakbulk.presets.wasmWeb;

        packages.app.env.GIT_REV = "dirty";
        packages.app.env.UI_DIST = repo.workspaces.default.target.wasm32-unknown-unknown.packages.ui;
      }
    )
  ];
  wasmRust = overlayRust.override { targets = [ "wasm32-unknown-unknown" ]; };

  # The wasm product of ui-dist's `ui`, at the path rust-embed reads in
  # `assets`.
  uiProduct = uiDistRepo.workspaces.default.target.wasm32-unknown-unknown.packages.ui;
  sourceOverlayRepo = mkRepo (fixtures + "/source-overlay") [
    (oneWs "." "dev")
    {
      packages.assets.sourceOverlay."ui/dist" = uiProduct;
      # The check reads the test run's output.
      packages.assets.test.postRun = ''cp "$log" "$out/log"'';
    }
  ];

  # Products of one plan as another member's `env`, `inputs` and
  # `nativeInputs`, declared in `productInputs`. sameWsUses is the
  # settings without the declaration.
  sameWsUses =
    { repo, ... }:
    let
      p = repo.workspaces.main.packages;
    in
    {
      packages.app = {
        env.TOOL_BIN = "${p.tool}/bin/tool";
        nativeInputs = _: [ p.tool ];
        inputs = _: [ p.shared ];
      };
    };
  sameWsRepo = mkRepo (fixtures + "/same-workspace-products") [
    (oneWs "." "dev")
    sameWsUses
    {
      packages.app.productInputs = [
        "tool"
        "shared"
      ];
    }
  ];

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

  # --- nested-cargo --------------------------------------------------------------

  # The settings of docs/src/how-to/nested-cargo.md.
  nestedCargoModules = [
    (oneWs "." "dev")
    (
      { repo, pkgs, ... }:
      {
        packages.outer = {
          extraSources = [
            "Cargo.toml"
            "Cargo.lock"
            "inner"
          ];
          forTarget.env.CARGO_HOME = repo.workspaces.main.vendor.cargoHome;
        };
        # inner's test runs `cargo run -p inner`.
        packages.inner.test = {
          sourceScope = [
            "Cargo.toml"
            "Cargo.lock"
            "outer"
          ];
          env = {
            CARGO_HOME = repo.workspaces.main.vendor.cargoHome;
            CARGO_TARGET_DIR = "/tmp/nested-target";
          };
          path = [
            repo.workspaces.main.toolchain.rustc
            pkgs.stdenv.cc
          ];
        };
      }
    )
  ];
  nestedCargo = mkRepo (fixtures + "/nested-cargo") nestedCargoModules;
  nestedCargoFlags = mkRepo (fixtures + "/nested-cargo") (
    nestedCargoModules
    ++ [
      {
        targets.${native} = {
          preset = breakbulk.presets.linuxStatic;
          rustflags = [
            "--cfg"
            "nested_cfg"
          ];
        };
      }
    ]
  );
  # --- rustc-private -------------------------------------------------------------

  # A `rustc_private` test, built with the default toolchain (nixpkgs'
  # rustc, whose sysroot has the compiler's crates). librustc_driver
  # links against nixpkgs' LLVM, which the sysroot does not hold.
  rustcPrivate = mkRepo (fixtures + "/rustc-private") [
    (oneWs "." "dev")
    (
      { repo, ... }:
      {
        packages.driver-user.env.RUSTC_BOOTSTRAP = "1";
        targets.${native}.rustflags = [
          "-L"
          "${repo.workspaces.main.toolchain.rustc.unwrapped.llvm.lib}/lib"
        ];
      }
    )
  ];

  # Runs the product, and the inner binary it embeds, which is static or
  # not.
  nestedCargoRun =
    name: product: expect: static:
    pkgs.runCommand name
      {
        inherit product;
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
      }
      ''
        set -euo pipefail
        $product/bin/outer $TMPDIR/inner | tee $out
        grep -q '^outer embeds [0-9]* bytes, magic 7f454c46$' $out
        chmod +x $TMPDIR/inner
        $TMPDIR/inner | tee -a $out
        grep -qxF ${lib.escapeShellArg expect} $out
        readelf -l $TMPDIR/inner > $TMPDIR/headers
        ${if static then "! " else ""}grep -q 'Requesting program interpreter' $TMPDIR/headers
      '';

  # --- benches -------------------------------------------------------------------

  benchesRepo = mkRepo (fixtures + "/benches") [
    {
      workspaces.main = {
        path = ".";
        # `benches` reads the bench runs' output.
        memberDefaults.test.postRun = ''cp "$log" "$out/log"'';
        # A bench run's settings: `bench`, then the binary's.
        memberDefaults.bench.env.BENCHER_RUN = "bench";
        memberDefaults.test.binaries."bench/libtest".enable = false;
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

  # app's product takes hdr-sys's header by its `links` metadata and gen's
  # data file by package and path in OUT_DIR, after `install`; `runs`
  # records what the runs' metadata.json say, without store paths, so
  # that both delivery modes write the same bytes.
  buildScriptOutputs = mkRepo (fixtures + "/build-script-outputs") [
    (oneWs "." "dev")
    {
      packages.app.stages = {
        headers = {
          after = "install";
          run = helpers.buildScriptPath {
            links = "hdr";
            key = "include";
            to = "include";
          };
        };
        data = {
          after = "headers";
          run = helpers.buildScriptPath {
            package = "gen";
            from = "data";
            to = "share/gen";
          };
        };
        runs = {
          after = "data";
          run =
            {
              input,
              pkgs,
              ...
            }@args:
            pkgs.runCommand "app-runs" { nativeBuildInputs = [ pkgs.jq ]; } ''
              set -euo pipefail
              ${helpers.buildScriptLookups args}
              cp -RL ${input} $out
              chmod -R u+w $out
              buildScriptRuns | jq -cS '{ package, version, links, keys: [.metadata[][0]] }' \
                | LC_ALL=C sort > $out/share/runs.json
              buildScriptMetadata hdr answer > $out/share/answer
            '';
        };
      };
    }
  ];

  # --- docs --------------------------------------------------------------------

  # With dependencies at Cargo's default profile for `cargo doc`, `dev`:
  # Cargo's `cargo doc --release --target <host triple>` fails with
  # "document output filename collision" on this workspace (the proc macro
  # `derive` is a member and a dependency of `util`), as it does outside
  # breakbulk (rust-lang/cargo#10368); `--no-deps` and `dev` do not.
  # `checks.docs` from the target's `variantDefaults`, replaced in the check
  # variant's own target settings: only the default variant's docs are in
  # repo.checks.
  docsRepo =
    noDeps: profile:
    mkRepo (fixtures + "/docs") [
      {
        workspaces.main = {
          path = ".";
          variantDefaults.docs.noDeps = noDeps;
          targets.${native}.variantDefaults.checks.docs = true;
          variants.default = { inherit profile; };
          variants.check = {
            mode = "check";
            inherit profile;
            target.${native}.checks.docs = false;
          };
        };
      }
    ];
  docsNoDeps = docsRepo true "release";
  docsDeps = docsRepo false "dev";

  # Plain `cargo doc` over the fixture, offline against the same vendor
  # directory, without `--target`: Cargo then writes every crate, proc
  # macros too, into the one folder `target/doc`, as the docs derivation
  # does. Each of `runs` is one `cargo doc` with those arguments, into the
  # same folder. Under `--no-deps` Cargo does not order the members'
  # rustdocs (with one job it documented `util` before `base`, leaving
  # util's links to base unresolved), so that reference documents them one
  # package at a time, in the docs derivation's order.
  cargoDoc =
    repo: runs:
    pkgs.runCommandCC "docs-cargo-doc"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${fixtures + "/docs"} "$NIX_BUILD_TOP/ws"
        cd "$NIX_BUILD_TOP/ws"
        ${lib.concatMapStrings (args: ''
          cargo doc --frozen --offline ${args} \
            --config ${(inst repo).vendor.configFile} 2> doc.log || { cat doc.log; exit 1; }
        '') runs}
        cp -r target/doc $out
        rm $out/.lock
      '';

  # --- clippy-host ---------------------------------------------------------------

  # The clippy variant of docs/src/how-to/ci.md, and its setting for the
  # host copy of `runtime`.
  clippyHostModules = [
    {
      workspaces.main = {
        path = ".";
        variants = {
          default.profile = "dev";
          clippy = {
            mode = "clippy";
            profile = "dev";
            clippyArgs = [
              "-D"
              "warnings"
            ];
          };
        };
      };
    }
  ];
  clippyHostFix = {
    packages.runtime.variant.clippy.forHost.env.CLIPPY_ARGS =
      lib.concatMapStrings (a: a + "__CLIPPY_HACKERY__")
        [
          "-D"
          "warnings"
          "-A"
          "unused_variables"
        ];
  };
  # --- port-from-crane -----------------------------------------------------------

  # The module of docs/src/how-to/port-from-crane.md, read from the page.
  portFromCrane =
    let
      page = builtins.readFile ../../docs/src/how-to/port-from-crane.md;
      blocks = lib.filter builtins.isList (builtins.split "```nix\n(# nix/rust.nix\n[^`]*)```" page);
    in
    assert lib.assertMsg (
      lib.length blocks == 1
    ) "port-from-crane: no `# nix/rust.nix` block in docs/src/how-to/port-from-crane.md";
    mkRepo (fixtures + "/port-from-crane") [
      (import (builtins.toFile "rust.nix" (lib.head (lib.head blocks))))
    ];

  clippyHost = mkRepo (fixtures + "/clippy-host") clippyHostModules;
  clippyHostFixed = mkRepo (fixtures + "/clippy-host") (clippyHostModules ++ [ clippyHostFix ]);
in
{
  modules.variants = variantsModules;
  modules.nestedCargo = nestedCargoModules;
  repos = {
    inherit
      postLink
      sourcePaths
      sourcePathsReadme
      cdylibDebug
      manifestDirRepo
      trimPathsRepo
      variantsRepo
      benchesRepo
      embed
      uiDistRepo
      sourceOverlayRepo
      sameWsRepo
      coverageRepo
      rustSrcRepo
      buildScriptOutputs
      nestedCargo
      nestedCargoFlags
      rustcPrivate
      cargoConfigRepo
      docsNoDeps
      docsDeps
      clippyHostFixed
      portFromCrane
      ;
    trimCc = trimCcRepo { };
    driver = driverRepo { };
  };

  build-script-outputs =
    pkgs.runCommand "build-script-outputs" { app = buildScriptOutputs.workspaces.main.packages.app; }
      ''
        set -euo pipefail
        [ "$($app/bin/app)" = '42 gen.txt' ]
        grep -qx '#define HDR_ANSWER 42' $app/include/hdr.h
        grep -qx generated $app/share/gen/gen.txt
        [ "$(cat $app/share/answer)" = 42 ]
        cat $app/share/runs.json
        diff $app/share/runs.json - <<'EOF'
        {"keys":["include","answer"],"links":"hdr","package":"hdr-sys","version":"0.1.0"}
        {"keys":[],"links":null,"package":"gen","version":"0.1.0"}
        EOF
        touch $out
      '';

  docs =
    let
      check = repo: repo.workspaces.main.internal.instances.${native}.check;
      drvSet = us: lib.genAttrs (map (u: builtins.unsafeDiscardStringContext u.drvPath) us) (_: true);
      # The doc plan's units against the check variant's build plan: each
      # is shared (the check plan also has the members' own units, which
      # `cargo doc` needs only for the members other members use).
      sharing =
        repo:
        let
          e = repo.explainSharing {
            a = (inst repo).plans.doc;
            b = (check repo).plans.build;
          };
          docUnits = lib.filter (u: (u.onlyIn or null) != e.b) e.units;
        in
        {
          inherit e;
          notShared = lib.filter (u: !u.same) docUnits;
          shared = lib.length docUnits;
        };
      # The unit derivations the docs derivation names as inputs: all of
      # them the check variant's.
      inputsOf =
        repo:
        let
          docs = (inst repo).docsDrv;
          ctx = lib.attrNames (builtins.getContext docs.drvAttrs.BREAKBULK_UNIT);
          units = drvSet (lib.attrValues (inst repo).units.doc);
        in
        lib.filter (d: units ? ${d}) ctx;
      notCheckUnits =
        repo: lib.filter (d: !((drvSet (lib.attrValues (check repo).units.build)) ? ${d})) (inputsOf repo);
      sharedNoDeps = sharing docsNoDeps;
      sharedDeps = sharing docsDeps;
      docsChecks = lib.filter (lib.hasSuffix "/docs") (lib.attrNames docsNoDeps.checks);
    in
    assert lib.assertMsg (
      sharedNoDeps.notShared == [ ] && sharedNoDeps.shared > 0
    ) "docs: doc-plan units not shared with the check variant:\n${sharedNoDeps.e.text}";
    assert lib.assertMsg (
      sharedDeps.notShared == [ ] && sharedDeps.shared > 0
    ) "docs: doc-plan units not shared with the check variant (deps):\n${sharedDeps.e.text}";
    assert lib.assertMsg (inputsOf docsDeps != [ ] && notCheckUnits docsDeps == [ ])
      "docs: the docs derivation names units that are not the check variant's: ${builtins.toJSON (notCheckUnits docsDeps)}";
    assert lib.assertMsg (
      docsChecks == [ "main/${native}/docs" ]
    ) "docs: docs in repo.checks: ${toString docsChecks}";
    pkgs.runCommand "docs"
      {
        docsCheck = docsNoDeps.checks."main/${native}/docs";
        # The default target's, as `repo.workspaces.<ws>.docs`.
        wsDocs = docsNoDeps.workspaces.main.docs;
        noDeps = docsNoDeps.workspaces.main.target.${native}.variants.default.docs;
        noDepsRef = cargoDoc docsNoDeps (
          map (p: "--no-deps --release -p ${p}") [
            "base"
            "derive"
            "util"
            "app"
          ]
        );
        deps = docsDeps.workspaces.main.target.${native}.variants.default.docs;
        depsRef = cargoDoc docsDeps [ "-j1" ];
        # The default target's, and the default variant's.
        variantDocs = docsNoDeps.workspaces.main.target.${native}.variants.default.docs;
      }
      ''
        set -euo pipefail
        [ "$noDeps" = "$variantDocs" ] && [ "$noDeps" = "$wsDocs" ] && [ "$noDeps" = "$docsCheck" ]
        # The same files and bytes, but for the store path of the registry
        # crate's source, which its source pages name (its fetched source
        # here, the vendor directory under Cargo).
        same() {
          for d in "$1" "$2"; do
            rm -rf "$TMPDIR/cmp"; mkdir "$TMPDIR/cmp"; cp -r --no-preserve=mode "$d/." "$TMPDIR/cmp"
            find "$TMPDIR/cmp" -type f -exec sed -i -E \
              's#${builtins.storeDir}/[a-z0-9]{32}-(breakbulk-vendor/[0-9a-f]+/)?#/SOURCE/#g' {} +
            mv "$TMPDIR/cmp" "$TMPDIR/cmp-$(basename "$d")"
          done
          diff -r "$TMPDIR/cmp-$(basename "$1")" "$TMPDIR/cmp-$(basename "$2")"
        }
        same "$noDeps" "$noDepsRef"
        same "$deps" "$depsRef"
        # Cross-crate links: to a member, to the proc macro, and with deps
        # to the registry crate's pages in the same folder.
        for d in "$deps" "$noDeps"; do
          grep -q 'href="../util/fn.make.html"' "$d/app/index.html"
          grep -q 'href="../base/struct.Widget.html"' "$d/app/index.html"
          grep -q 'href="../derive/derive.Describe.html"' "$d/util/struct.Gadget.html"
        done
        grep -q 'href="../itoa/struct.Buffer.html"' "$deps/base/trait.Render.html"
        [ ! -e "$noDeps/itoa" ] && [ -d "$deps/itoa" ]
        # The implementors of base's trait from util, merged in.
        grep -q util "$deps/trait.impl/base/trait.Render.js"
        # The build script's cfg and env reached rustdoc.
        grep -q 'Set by the build script.' "$deps/util/fn.generated.html"
        mkdir $out
      '';

  ui-dist = pkgs.runCommand "ui-dist" { app = uiDistRepo.workspaces.default.packages.app; } ''
    $app/bin/app | tee $out
    grep -q '^app dirty embeds [0-9]* bytes of wasm, magic true, glue exports greet: true$' $out
  '';

  source-overlay =
    let
      i = sourceOverlayRepo.workspaces.main.internal.instances.${native}.default;
      units = lib.attrValues i.units.build ++ lib.attrValues i.units.test;
      member =
        u:
        lib.any (p: lib.hasPrefix p u.name) [
          "assets-"
          "server-"
          "other-"
        ];
    in
    pkgs.runCommand "source-overlay"
      {
        server = sourceOverlayRepo.workspaces.main.packages.server;
        serverChecks = lib.attrValues sourceOverlayRepo.workspaces.main.packages.server.checks;
        assetsTest = i.testRuns.assets."lib/assets";
        uiDrv = builtins.unsafeDiscardStringContext uiProduct.drvPath;
        # The closures of the workspace's instantiation (both plans) and
        # of each member unit's derivation.
        exportReferencesGraph = [
          "instBuild"
          (drvOnly i.unitsJson.build)
          "instTest"
          (drvOnly i.unitsJson.test)
        ]
        ++ lib.concatMap (u: [
          "unit-${u.name}"
          (drvOnly u)
        ]) (lib.filter member units);
      }
      ''
        set -euo pipefail
        for g in instBuild instTest; do
          if grep -qxF "$uiDrv" $g; then
            echo "$g depends on the product $uiDrv" >&2
            exit 1
          fi
        done
        [ "$(grep -lxF "$uiDrv" unit-* | sort | tr '\n' ' ')" = \
          "unit-assets-0.1.0-lib unit-assets-0.1.0-test unit-server-0.1.0-bin unit-server-0.1.0-test " ]
        $server/bin/server | tee files.txt
        grep -qx pkg/ui_bg.wasm files.txt
        grep -qx pkg/ui.js files.txt
        ! grep -q placeholder files.txt
        [ "$($server/bin/server pkg/ui_bg.wasm | head -c 4 | od -An -c | tr -d ' ')" = '\0asm' ]
        $server/bin/server pkg/ui.js | grep -q greet
        ! $server/bin/server missing.txt
        grep -q 'test tests::has_the_wasm ... ok' $assetsTest/log
        touch $out
      '';

  same-workspace-products =
    pkgs.runCommand "same-workspace-products" { app = sameWsRepo.workspaces.main.packages.app; }
      ''
        set -euo pipefail
        # An empty environment: `shared` is found through the rpath.
        env -i $app/bin/app $TMPDIR/tool | tee $out
        grep -qx 'build script ran: tool says hi' $out
        grep -qx 'shared says 42' $out
        grep -q '^embeds [0-9]* bytes, elf true$' $out
        chmod +x $TMPDIR/tool
        [ "$($TMPDIR/tool)" = "tool says hi" ]
      '';

  # IFD mode's check of `productInputs`: same-workspace-products without
  # its declaration names both products and the line to add, and
  # repo.checks fails with it; with the declaration it finds nothing.
  product-inputs-undeclared =
    let
      undeclared = mkRepo (fixtures + "/same-workspace-products") [
        (oneWs "." "dev")
        sameWsUses
      ];
      errorsOf = r: r.workspaces.main.internal.productInputErrors.${native}.default;
      got = errorsOf undeclared;
      want = [
        "breakbulk: the settings of `app` use products of the plan that builds it (workspace main, target ${native}, variant default) that `packages.app.productInputs` does not name: `env.TOOL_BIN` uses `tool`; `inputs` uses `shared`; `nativeInputs` uses `tool`. Dynamic-derivation mode needs them named (it cannot find them: there, this is an infinite recursion). Add: packages.app.productInputs = [ \"shared\" \"tool\" ];"
      ];
      checkFails = !(builtins.tryEval undeclared.checks."main/${native}/app/build".drvPath).success;
    in
    assert lib.assertMsg (got == want) "product-inputs-undeclared: ${builtins.toJSON got}";
    assert lib.assertMsg checkFails "product-inputs-undeclared: repo.checks evaluated";
    assert lib.assertMsg (
      errorsOf sameWsRepo == [ ]
    ) "product-inputs-undeclared: declared: ${builtins.toJSON (errorsOf sameWsRepo)}";
    evalCheck "product-inputs-undeclared" (lib.concatStringsSep "\n" got);

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

  nested-cargo =
    let
      p = nestedCargo.workspaces.main.packages.outer;
      view = builtins.unsafeDiscardStringContext "${(inst nestedCargo).sources.workspace.outer}";
    in
    pkgs.runCommand "nested-cargo"
      {
        run = nestedCargoRun "nested-cargo-run" p "inner says 42, nested_cfg false" false;
        failure = pkgs.testers.testBuildFailure p.checks.noSourceReferences;
        testRun = nestedCargo.workspaces.main.target.${native}.variants.default.testRuns.inner.nested;
      }
      ''
        set -euo pipefail
        cat $run
        # The nested build's paths are not remapped: the embedded binary
        # names the source view the build script ran in.
        cat $failure/testBuildFailure.log
        grep -qF ${lib.escapeShellArg view} $failure/testBuildFailure.log
        touch $out
      '';

  # The test binary loads librustc_driver, which the test run's copy of
  # the sysroot's libraries lacks: it finds the driver through the RUNPATH
  # nixpkgs' linker wrapper gives it.
  rustc-private =
    let
      w = rustcPrivate.workspaces.main;
      sysroot = w.toolchain.rustc.unwrapped;
    in
    pkgs.runCommand "rustc-private"
      {
        run = w.target.${native}.variants.default.testRuns.driver-user.driver;
        test = w.target.${native}.variants.default.tests.driver-user.driver;
        nativeBuildInputs = [ pkgs.binutils-unwrapped ];
      }
      ''
        set -euo pipefail
        bin=$(find $test -type f -executable | head -n1)
        readelf -d "$bin" | tee $TMPDIR/dynamic
        grep -q 'NEEDED.*librustc_driver-' $TMPDIR/dynamic
        grep -q 'RUNPATH.*${builtins.unsafeDiscardStringContext sysroot.outPath}/lib/rustlib/${native}/lib' $TMPDIR/dynamic
        touch $out
      '';

  nested-cargo-rustflags =
    nestedCargoRun "nested-cargo-rustflags" nestedCargoFlags.workspaces.main.packages.outer
      "inner says 42, nested_cfg true"
      true;

  benches =
    let
      w = benchesRepo.workspaces.main;
      t = w.target.${native};
      b = t.variants.bench;
      readPlan =
        drv: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${drv}/plan.json"));
      benchPlan = readPlan b.plans.bench;
      testPlans = map (v: readPlan t.variants.${v}.plans.test) [
        "default"
        "bench"
      ];
      kinds = plan: map (r: r.kind) plan.roots;
      critUnit = (unitsOf benchesRepo "bench" "bench")."bencher-0.1.0-test-crit" or null;
      critArgs = lib.filter builtins.isString (
        (builtins.fromJSON (builtins.unsafeDiscardStringContext critUnit.drvAttrs.BREAKBULK_UNIT)).args
      );
      smoke = lib.filterAttrs (
        n: c: lib.hasInfix "/bench/" n && !(c.breakbulkCheckGroup or false)
      ) benchesRepo.checks;
      # `checks.benches = false` leaves the bench runs out of repo.checks,
      # not out of `benchRuns`; the bench plan selected by a list.
      viaRecord = mkRepo (fixtures + "/benches") [
        {
          workspaces.main = {
            path = ".";
            memberDefaults.test.postRun = ''cp "$log" "$out/log"'';
            variants = {
              default.profile = "dev";
              bench = {
                profile = "bench";
                benches = [ "bencher" ];
                checks.benches = false;
              };
            };
          };
        }
      ];
      recordRuns = lib.filterAttrs (
        n: c: lib.hasInfix "/bench/" n && !(c.breakbulkCheckGroup or false)
      ) viaRecord.checks;
    in
    assert lib.assertMsg (
      lib.attrNames b.benches.bencher == [
        "bench/crit"
        "bench/libtest"
        "lib/bencher"
      ]
    ) "benches: ${builtins.toJSON (lib.attrNames b.benches.bencher)}";
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
      lib.attrNames smoke == [
        "main/${native}/variant-bench/bencher/bench/bench/crit"
        "main/${native}/variant-bench/bencher/bench/lib/bencher"
      ]
    ) "benches: bench-run checks ${builtins.toJSON (lib.attrNames smoke)}";
    assert lib.assertMsg (
      b.benchRuns.bencher ? "bench/libtest"
    ) "benches: the disabled bench run is gone from benchRuns";
    assert lib.assertMsg (
      lib.all (d: lib.hasInfix "export BENCHER_RUN=bench" d.drvAttrs.buildCommand) (lib.attrValues smoke)
      && lib.all (r: !(lib.hasInfix "BENCHER_RUN" r.drvAttrs.buildCommand)) (
        lib.attrValues (
          lib.filterAttrs (n: _: lib.hasPrefix "test/" n) w.internal.instances.${native}.bench.checks
        )
      )
    ) "benches: `bench` env reaches bench runs only";
    assert lib.assertMsg (
      recordRuns == { } && viaRecord.workspaces.main.target.${native}.variants.bench.benchRuns ? bencher
    ) "benches: checks.benches = false kept ${builtins.toJSON (lib.attrNames recordRuns)}";
    pkgs.runCommand "benches"
      (
        {
          crit = b.benches.bencher."bench/crit";
          libtest = b.benches.bencher."bench/libtest";
        }
        // lib.mapAttrs' (n: v: lib.nameValuePair (lib.replaceStrings [ "/" ] [ "_" ] n) v) smoke
      )
      ''
        set -euo pipefail
        [ -x $crit/bin/crit ]
        [ -x $libtest/bin/libtest ]
        cat ${lib.concatMapStringsSep " " (d: "${d}/log") (lib.attrValues smoke)}
        grep -q Success ${smoke."main/${native}/variant-bench/bencher/bench/bench/crit"}/log
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
      # `packages.lib-a.variant.clippy`: the clippy variant's units of
      # lib-a have it, no other variant's units change.
      envOf =
        vName: k: n:
        (builtins.fromJSON (
          builtins.unsafeDiscardStringContext (unitsOf variantsRepo vName k).${n}.drvAttrs.BREAKBULK_UNIT
        )).env;
      namesWith = prefix: lib.filter (lib.hasPrefix prefix) (lib.attrNames (d "clippy" "build"));
      variantLayer = {
        clippyHasIt =
          namesWith "lib-a-" != [ ]
          && lib.all (n: (envOf "clippy" "build" n) ? LINT_ONLY) (namesWith "lib-a-");
        appLacksIt = lib.all (n: !((envOf "clippy" "build" n) ? LINT_ONLY)) (namesWith "app-");
        othersUnchanged = lib.all (
          vName:
          lib.all (k: drvsOf variantsRepo vName k == drvsOf variantsBaseRepo vName k) [
            "build"
            "test"
          ]
        ) (lib.filter (v: v != "clippy") (lib.attrNames vt.variants));
        clippyChanged = drvsOf variantsRepo "clippy" "build" != drvsOf variantsBaseRepo "clippy" "build";
      };
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
    assert lib.assertMsg (lib.all lib.id (
      lib.attrValues variantLayer
    )) "variants: packages.lib-a.variant.clippy: ${builtins.toJSON variantLayer}";
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
    assert lib.assertMsg (lib.any (lib.hasPrefix "main/${native}/variant-coverage/lib-a/test/") (
      lib.attrNames variantsRepo.checks
    )) "variants: the coverage variant's test runs are not in repo.checks";
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

  # A check variant with `tests = false` checks the build plan's units only
  # (`cargo check`); the default also checks the test plan's (`cargo check
  # --all-targets`); with `products = false`, the test plan's only, and
  # the build plan is not traced.
  variants-all-targets =
    let
      outsOf =
        us:
        lib.sort lib.lessThan (
          map (o: builtins.unsafeDiscardStringContext o) (lib.concatMap (u: map (o: u.${o}) u.outputs) us)
        );
      lib' = vt.variants.check-lib.check;
      all = vt.variants.check.check;
      ci = variantsRepo.workspaces.main.internal.instances.${native}.check-lib;
      buildOuts = outsOf (lib.attrValues ci.units.build);
      # A check builds each plan's `allUnits`, which lists the plan's unit
      # outputs at build time.
      got = map builtins.unsafeDiscardStringContext lib'.units;
      allGot = map builtins.unsafeDiscardStringContext all.units;
      testsOnly = mkRepo (fixtures + "/variants") [
        {
          workspaces.main = {
            path = "ws";
            variants.default = {
              mode = "check";
              profile = "release";
              products = false;
            };
          };
        }
      ];
      tw = testsOnly.workspaces.main;
      ti = tw.internal.instances.${native}.default;
      testOuts = outsOf (lib.attrValues ti.units.test);
      testsGot = map builtins.unsafeDiscardStringContext tw.target.${native}.variants.default.check.units;
      discardAll = map builtins.unsafeDiscardStringContext;
    in
    assert lib.assertMsg (
      got == discardAll [ ci.allUnits.build.outPath ]
    ) "variants-all-targets: check-lib does not check exactly the build plan";
    assert lib.assertMsg (
      lib.length allGot > lib.length got
    ) "variants-all-targets: the default does not check more than the build plan";
    assert lib.assertMsg (
      testsGot == discardAll [ ti.allUnits.test.outPath ]
      && lib.attrNames tw.target.${native}.variants.default.buildScriptPaths == [ "test" ]
    ) "variants-all-targets: products = false does not check exactly the test plan";
    pkgs.runCommand "variants-all-targets"
      {
        check = lib';
        buildUnits = ci.allUnits.build;
        testUnits = ti.allUnits.test;
        buildOuts = builtins.toFile "build-outs" (lib.concatLines buildOuts);
        testOuts = builtins.toFile "test-outs" (lib.concatLines testOuts);
      }
      ''
        sort $buildUnits/units | diff - $buildOuts
        sort $testUnits/units | diff - $testOuts
        cp $check/units $out
      '';

  # `testProfile`: a build variant's test plan is `--profile test` by
  # default, where lib-a's `debug_assertions_on` passes, and shares no
  # dependency unit with the build plan (`release`); `release-tests`
  # (`testProfile = "release"`) shares every unit the two plans have in
  # common. A check variant's test plan keeps its `profile`.
  variants-test-profile =
    let
      d = drvsOf variantsRepo;
      i = variantsRepo.workspaces.main.internal.instances.${native};
      common = vName: lib.filter (n: (d vName "build") ? ${n}) (lib.attrNames (d vName "test"));
      same = vName: lib.filter (n: (d vName "build").${n} == (d vName "test").${n}) (common vName);
      deps = lib.filter (n: lib.hasPrefix "pm-" n || lib.hasPrefix "hostdep-" n);
      profiles = lib.mapAttrs (_: v: lib.mapAttrs (_: p: p.profile) v.plans) {
        inherit (i) default release-tests check;
      };
    in
    assert lib.assertMsg (
      profiles == {
        default = {
          build = "release";
          doc = "release";
          test = "test";
        };
        release-tests = {
          build = "release";
          doc = "release";
          test = "release";
        };
        check = {
          build = "release";
          doc = "release";
          test = "release";
        };
      }
    ) "variants-test-profile: plan profiles ${builtins.toJSON profiles}";
    assert lib.assertMsg (deps (common "default") != [ ] && deps (same "default") == [ ])
      "variants-test-profile: dependency units shared between the release build plan and the test-profile test plan: ${builtins.toJSON (same "default")}";
    assert lib.assertMsg
      (lib.length (deps (common "release-tests")) >= 3 && same "release-tests" == common "release-tests")
      "variants-test-profile: release-tests' plans differ in ${builtins.toJSON (lib.subtractLists (same "release-tests") (common "release-tests"))}";
    pkgs.runCommand "variants-test-profile"
      { run = variantsRepo.checks."main/${native}/lib-a/test/lib/lib_a"; }
      ''
        echo "$run" > $out
      '';

  # `cargoConfig`: `dist`'s `profile.release.panic = "abort"` reaches its
  # build plan's target units (`-C panic=abort`), not its host units nor
  # its test plan (`test` profile; Cargo builds tests and build scripts
  # unwinding), nor the default variant; its product aborts on a panic.
  # Its `[env]` variable and `build.rustflags` reach the product and its
  # test run beside the target's own rustflags, which the planner then
  # passes under `build.rustflags` (its reader saw the variant's). Keys
  # breakbulk sets are refused, from the variant and from a target's
  # `variantDefaults`.
  variants-cargo-config =
    let
      w = cargoConfigRepo.workspaces.main;
      t = w.target.${native};
      rendered =
        vName: kind:
        lib.mapAttrs (
          _: u: builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)
        ) (lib.filterAttrs (_: u: u ? drvAttrs) (unitsOf cargoConfigRepo vName kind));
      compiles = vName: kind: lib.filterAttrs (_: u: u.kind == "compile") (rendered vName kind);
      abortsIn =
        vName: kind:
        lib.sort lib.lessThan (
          lib.attrNames (
            lib.filterAttrs (_: u: lib.hasInfix "panic=abort" (builtins.toJSON u.args)) (compiles vName kind)
          )
        );
      targetCompiles =
        vName: kind:
        lib.sort lib.lessThan (
          lib.attrNames (lib.filterAttrs (_: u: u.platform == "target") (compiles vName kind))
        );
      planCmd = vName: w.internal.instances.${native}.${vName}.plans.build.drvAttrs.buildCommand;
      refused =
        modules:
        !(builtins.tryEval (
          builtins.deepSeq
            (mkRepo (fixtures + "/cargo-config") (cargoConfigModules ++ modules))
            .workspaces.main.target.${native}.variants.default.plans
            true
        )).success;
      bad = lib.attrNames (
        lib.filterAttrs (_: ok: !ok) {
          distAborts =
            abortsIn "dist" "build" == targetCompiles "dist" "build" && abortsIn "dist" "build" != [ ];
          hostUnwinds =
            lib.length (lib.attrNames (compiles "dist" "build")) > lib.length (abortsIn "dist" "build");
          testsUnwind = abortsIn "dist" "test" == [ ];
          defaultUnwinds = abortsIn "default" "build" == [ ];
          # Only `dist`'s planner gets a file.
          distFile =
            lib.hasInfix "--cargo-config" (planCmd "dist")
            && !(lib.hasInfix "--cargo-config" (planCmd "default"));
          ownedKey = refused [ { workspaces.main.variants.dist.cargoConfig.build.rustc = "/bin/false"; } ];
          ownedTargetKey = refused [
            { targets.${native}.variantDefaults.cargoConfig.target.${native}.linker = "/bin/false"; }
          ];
          ownedSource = refused [
            { workspaces.main.variants.dist.target.${native}.cargoConfig.source.crates-io.replace-with = "x"; }
          ];
        }
      );
    in
    assert lib.assertMsg (bad == [ ])
      "variants-cargo-config: failed ${toString bad}: aborts ${
        builtins.toJSON {
          dist = abortsIn "dist" "build";
          target = targetCompiles "dist" "build";
        }
      }";
    pkgs.runCommand "variants-cargo-config"
      {
        dist = t.variants.dist.packages.app;
        default = t.packages.app;
        distTest = cargoConfigRepo.checks."main/${native}/variant-dist/app/test/bin/app";
        defaultTest = cargoConfigRepo.checks."main/${native}/app/test/bin/app";
      }
      ''
        set -euo pipefail
        [ "$($dist/bin/app)" = "env=dist cfg=true spec=true dep=7" ]
        [ "$($default/bin/app)" = "env=none cfg=false spec=true dep=7" ]
        rc=0; $default/bin/app panic || rc=$?
        [ $rc = 101 ]
        rc=0; $dist/bin/app panic || rc=$?
        [ $rc = 134 ]
        echo "$distTest $defaultTest" > $out
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
        ]).workspaces.main.internal.instances.${native}.clippy.plans.build;
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
        run = t.variants.default.testRuns.lib-a."lib/lib_a";
      }
      ''
        set -euo pipefail
        LLVM_PROFILE_FILE=$TMPDIR/app.profraw $app/bin/app
        [ -s $TMPDIR/app.profraw ]
        ls -l $run/profraw/
        [ -s "$(echo $run/profraw/*.profraw)" ]
        touch $out
      '';

  variants-driver =
    let
      repo = driverRepo { };
      d = drvsOf repo;
      u = unitsOf repo;
      deps = lib.filter (n: lib.hasPrefix "pm-" n || lib.hasPrefix "hostdep-" n) (
        lib.attrNames (d "check" "build")
      );
      members = lib.filter (n: lib.hasPrefix "app-" n || lib.hasPrefix "lib-a-" n) (
        lib.attrNames (d "check" "build")
      );
      sharedDeps = lib.filter (n: (d "check" "build").${n} != (d "members" "build").${n}) deps;
      sharedAll = lib.filter (n: (d "check" "build").${n} == (d "driven" "build").${n}) (
        lib.attrNames (d "check" "build")
      );
      sharedMembers = lib.filter (n: (d "check" "build").${n} == (d "members" "build").${n}) members;
      # Cargo gives build-script runs its rustc wrapper, for their probes.
      runWrapper =
        v:
        lib.any (a: builtins.isString a && lib.hasInfix "\"RUSTC_WRAPPER\":" a) (
          lib.attrValues (u v "build")."hostdep-0.1.0-build-run".drvAttrs
        );
      clippyWrapped = builtins.tryEval (
        (driverRepo {
          clippy = {
            mode = "clippy";
            rustcWorkspaceWrapper = "${toyDriver}";
          };
        }).workspaces.main.internal.instances.${native}.clippy.units.build
      );
    in
    assert lib.assertMsg (deps != [ ] && members != [ ]) "variants-driver: no units ${toString deps}";
    assert lib.assertMsg (
      sharedDeps == [ ]
    ) "variants-driver: workspace wrapper changed dependency units ${toString sharedDeps}";
    assert lib.assertMsg (
      sharedMembers == [ ]
    ) "variants-driver: workspace wrapper left members unchanged ${toString sharedMembers}";
    assert lib.assertMsg (
      sharedAll == [ ]
    ) "variants-driver: rustc wrapper left units unchanged ${toString sharedAll}";
    assert lib.assertMsg (!clippyWrapped.success) "variants-driver: clippy took a workspace wrapper";
    assert lib.assertMsg (
      runWrapper "driven" && !runWrapper "members"
    ) "variants-driver: RUSTC_WRAPPER of build-script runs";
    pkgs.runCommand "variants-driver"
      {
        app = (u "driven" "build")."app-0.1.0-bin".rmeta;
        libA = (u "driven" "build")."lib-a-0.1.0-lib".rmeta;
        memberApp = (u "members" "build")."app-0.1.0-bin".rmeta;
        memberLibA = (u "members" "build")."lib-a-0.1.0-lib".rmeta;
        checkLibA = (u "check" "build")."lib-a-0.1.0-lib".rmeta;
        hostdep = (u "members" "build")."hostdep-0.1.0-lib".rmeta;
      }
      ''
        set -x
        side() { cat "$1"/*.side; }
        side $app
        # app reads lib-a's side file, which read hostdep's; and pm's.
        side $app | grep -qx 'extern lib_a:'
        side $app | grep -qx '  lib_a'
        side $app | grep -qx '  extern hostdep:'
        side $app | grep -qx '    hostdep'
        side $app | grep -qx 'extern pm:'
        side $libA | grep -qx 'extern hostdep:'
        # hostdep, below app only through lib-a: its side file is beside
        # its crate file in app's dependency directory too.
        side $app | grep -qx 'dep libhostdep-[0-9a-f]*: side'
        side $app | grep -qx 'dep liblib_a-[0-9a-f]*: side'
        ! side $app | grep -q '^dep .*: none'
        # Beside the crate file, under its stem.
        for f in $libA/*.rmeta; do [ -e "''${f%.rmeta}.side" ]; done
        # Members only: dependencies keep nothing, so members find none.
        side $memberApp | grep -qx '  extern hostdep: none'
        side $memberApp | grep -qx 'dep libhostdep-[0-9a-f]*: none'
        # (stdenv's nullglob: a glob that matches nothing is no argument.)
        [ -z "$(find $hostdep $checkLibA -name '*.side')" ]
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
    assert lib.assertMsg
      (
        changed "clippy" "build" == [
          "own-0.1.0-lib"
          "rooted-0.1.0-lib"
        ]
      )
      "variants-clippy-conf: clippy units changed by a root clippy.toml edit: ${builtins.toJSON (changed "clippy" "build")}";
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

  variants-clippy-lint-groups =
    let
      src = fixtures + "/lint-groups-priority";
      unitsAt =
        predict: ws: kind:
        lib.listToAttrs (
          map (u: lib.nameValuePair u.name u) (
            lib.attrValues
              (lintGroupsRepo predict).workspaces.${ws}.internal.instances.${native}.clippy.units.${kind}
          )
        );
      message = "lint group `pedantic` has the same priority (0) as a lint";
      # The clippy units of both workspaces, with or without predicted views.
      unitsWith =
        predict:
        let
          at = unitsAt predict;
        in
        [
          (expectFailure "inherited-lib" (at "inherited" "build")."inherited-0.1.0-lib" [ message ])
          (expectFailure "inherited-test" (at "inherited" "test")."inherited-0.1.0-test" [ message ])
          (at "own" "build")."own-0.1.0-lib"
          (at "own" "test")."own-0.1.0-test"
        ];
    in
    pkgs.runCommand "variants-clippy-lint-groups"
      {
        breakbulk = unitsWith false ++ unitsWith true;
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.clippy
          pkgs.rustc
        ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r --no-preserve=mode ${src} fixture
        # Plain `cargo clippy` over the same trees: fails on `inherited`
        # naming the group, passes on `own`.
        (cd fixture/inherited && ! cargo clippy --offline --locked --all-targets) 2>&1 | tee inherited.log
        grep -qF ${lib.escapeShellArg message} inherited.log
        (cd fixture/own && cargo clippy --offline --locked --all-targets)
        touch $out
      '';

  # The worked example of docs/src/how-to/port-from-crane.md, with the
  # module read from the page.
  port-from-crane =
    let
      r = portFromCrane;
      names = lib.attrNames (lib.filterAttrs (_: c: !(c.breakbulkCheckGroup or false)) r.checks);
      expected = [
        "greet/wasm32-unknown-unknown/greet/build"
        "greet/${native}/greet/test/lib/greet"
        "host/fmt"
        "host/${native}/server/build"
        "host/${native}/server/test/bin/server"
        "host/${native}/variant-clippy/check"
        "squares/${native}/squares/build"
      ];
      missing = lib.subtractLists names expected;
      # Built for wasm32 only, tested natively only.
      unexpected = lib.filter (
        n:
        lib.hasPrefix "greet/wasm32-unknown-unknown/greet/test/" n
        || lib.hasPrefix "greet/${native}/greet/build" n
      ) names;
    in
    assert lib.assertMsg (
      missing == [ ] && unexpected == [ ]
    ) "port-from-crane: checks missing ${toString missing}, unexpected ${toString unexpected}";
    pkgs.runCommand "port-from-crane"
      {
        server = r.workspaces.host.packages.server;
        component = r.workspaces.greet.target.wasm32-unknown-unknown.packages.greet;
        checks = map (n: r.checks.${n}) expected;
      }
      ''
        set -euo pipefail
        [ -f $component/lib/greet.wasm ]
        $server/bin/server | tee $out
        [ "$(cat $out)" = "component true, squares [0, 1, 4, 9, 16]" ]
      '';

  # The example of docs/src/how-to/ci.md (a member compiled for both
  # sides, linted twice).
  variants-clippy-host =
    let
      unitsIn =
        repo: vName: lib.attrValues repo.workspaces.main.internal.instances.${native}.${vName}.units.build;
      platformOf =
        u: (builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)).platform;
      runtimeLibs = repo: vName: lib.filter (u: u.name == "runtime-0.1.0-lib") (unitsIn repo vName);
      runtimeLib =
        repo: vName: platform:
        lib.findFirst (u: platformOf u == platform) (throw "no ${platform} runtime lib in ${vName}") (
          runtimeLibs repo vName
        );
      drvs = repo: vName: lib.sort lib.lessThan (map (u: u.drvPath) (unitsIn repo vName));
    in
    assert lib.assertMsg (
      lib.sort lib.lessThan (map platformOf (runtimeLibs clippyHost "clippy")) == [
        "host"
        "target"
      ]
    ) "variants-clippy-host: runtime is not compiled once per side";
    assert lib.assertMsg (
      drvs clippyHost "default" == drvs clippyHostFixed "default"
    ) "variants-clippy-host: the clippy variant's package setting changed the default variant's units";
    assert lib.assertMsg (
      (runtimeLib clippyHost "clippy" "target").drvPath == (runtimeLib clippyHostFixed "clippy" "target")
      .drvPath
    ) "variants-clippy-host: the forHost setting changed the target copy";
    pkgs.runCommand "variants-clippy-host"
      {
        # The project's rustflags reach the target copy only.
        app = clippyHost.workspaces.main.packages.app;
        failure = expectFailure "runtime-host-clippy" (runtimeLib clippyHost "clippy" "host") [
          "unused variable: `n`"
          "-D unused-variables"
        ];
        target = runtimeLib clippyHost "clippy" "target";
        fixed = clippyHostFixed.workspaces.main.target.${native}.variants.clippy.check;
      }
      ''
        set -euo pipefail
        [ "$($app/bin/app)" = "host=1 target=2" ]
        cat $failure/log
        touch $out
      '';

  # Field-trial gaps 4 and 5: variants and test plans narrowed per target
  # (`variants.<v>.targets`, `variants.<v>.packages`, `tests` from the
  # target's `variantDefaults`), and every variant's test runs in
  # repo.checks under `variant-<v>/`; a variant that is only tested
  # (`products = false`), and one that plans nothing (`packages = false`).
  # The musl target is never planned: only a check variant is planned for
  # it, without its test plan (`tests = false`), and nothing here builds
  # it.
  variants-narrowing =
    let
      musl = "x86_64-unknown-linux-musl";
      repo = mkRepo (fixtures + "/variants") [
        {
          workspaces.main = {
            path = "ws";
            targets = {
              ${native}.variantDefaults.tests = [ "lib-a" ];
              # The toolchain as Cargo finds it: nothing here builds it.
              ${musl} = {
                preset = null;
                variantDefaults.tests = false;
              };
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
                checks = {
                  products = false;
                  tests = false;
                };
              };
              musl-check = {
                mode = "check";
                targets = [ musl ];
              };
              test-only = {
                profile = "release";
                targets = [ native ];
                products = false;
              };
              nothing = {
                targets = [ native ];
                packages = false;
              };
            };
            # cargo-hack's per-package matrix for lib-a, one feature at a
            # time (field-trial gap 10).
            imports = [
              (breakbulk.variants.featurePowerset {
                scope = "package";
                packages = [ "lib-a" ];
                eachFeature = true;
                variant = {
                  mode = "check";
                  profile = "release";
                  targets = [ native ];
                };
              })
            ];
          };
        }
      ];
      w = repo.workspaces.main;
      n = w.target.${native};
      m = w.target.${musl};
      names = lib.attrNames (lib.filterAttrs (_: c: !(c.breakbulkCheckGroup or false)) repo.checks);
      under = prefix: lib.filter (lib.hasPrefix prefix) names;
      planCmd = vName: kind: w.internal.instances.${native}.${vName}.plans.${kind}.drvAttrs.buildCommand;
      selects =
        vName: kind: pkg:
        lib.hasInfix " -p ${lib.escapeShellArg pkg} " (planCmd vName kind);
      yRun = repo.checks."main/${native}/variant-y-only/lib-a/test/lib/lib_a";
      defaultRun = repo.checks."main/${native}/lib-a/test/lib/lib_a";
      bad = lib.attrNames (
        lib.filterAttrs (_: ok: !ok) {
          nativeVariants =
            lib.attrNames n.variants == [
              "default"
              "hack-lib-a.all-features"
              "hack-lib-a.default"
              "hack-lib-a.no-default-features"
              "hack-lib-a.x"
              "hack-lib-a.y"
              "nothing"
              "quiet"
              "test-only"
              "y-only"
            ];
          hackPlan =
            selects "hack-lib-a.y" "build" "lib-a"
            && lib.hasInfix " --features y " (planCmd "hack-lib-a.y" "build")
            && lib.hasInfix " --no-default-features " (planCmd "hack-lib-a.y" "build");
          hackInChecks = repo.checks ? "main/${native}/variant-hack-lib-a.y/check";
          muslVariants = lib.attrNames m.variants == [ "musl-check" ];
          muslEmpty = m.packages == { };
          muslChecks =
            under "main/${musl}/" == [
              "main/${musl}/variant-musl-check/buildScriptPaths/build"
              "main/${musl}/variant-musl-check/check"
            ];
          # `tests = [ "lib-a" ]`: the test plan is `-p lib-a`, the build
          # plan stays `--workspace`.
          testsNarrowed =
            lib.attrNames n.variants.default.tests == [ "lib-a" ]
            && lib.attrNames n.variants.default.testRuns == [ "lib-a" ];
          testPlanSelects = selects "default" "test" "lib-a" && !(selects "default" "build" "lib-a");
          productsKept = n.packages ? app;
          # `packages` narrows both plans of a variant.
          variantSelects = selects "y-only" "build" "lib-a" && !(selects "y-only" "build" "app");
          yInChecks = repo.checks ? "main/${native}/variant-y-only/lib-a/test/lib/lib_a";
          yDiffers = yRun.drvPath != defaultRun.drvPath;
          quietOut = under "main/${native}/variant-quiet/" == [ ] && n.variants.quiet.packages ? app;
          defaultKept = repo.checks ? "main/${native}/lib-a/test/lib/lib_a";
          testOnly =
            let
              t = n.variants.test-only;
              c = under "main/${native}/variant-test-only/";
            in
            t.packages == { }
            && lib.attrNames t.testRuns == [ "lib-a" ]
            && lib.attrNames t.buildScriptPaths == [ "test" ]
            && c != [ ]
            && lib.all (
              x: lib.hasInfix "/test/" x || lib.hasSuffix "/doctest" x || lib.hasSuffix "/buildScriptPaths/test" x
            ) c;
          nothing =
            let
              t = n.variants.nothing;
            in
            t.packages == { }
            && t.tests == { }
            && t.testRuns == { }
            && t.doctests == { }
            && t.buildScriptPaths == { }
            && under "main/${native}/variant-nothing/" == [ ];
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
      unknownEval = builtins.tryEval (
        builtins.attrNames unknown.workspaces.main.target.${native}.variants
      );
    in
    assert lib.assertMsg (
      bad == [ ]
    ) "variants-narrowing: failed ${toString bad}; checks: ${builtins.toJSON names}";
    assert lib.assertMsg (
      !unknownEval.success
    ) "variants-narrowing: a variant target outside the workspace's targets was accepted";
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
  # layer, a package run taking only the defaults' features its package
  # accepts and a plain `features` of the user's, and a check variant's
  # `tests = false` on one target only. wasm32 stands in for msvc,
  # with a rust-overlay toolchain that has its std.
  # A target only built (wasm32, `tests = false` in its `variantDefaults`)
  # next to one only tested (native, `products = false`): repo.checks has
  # the native test runs and doctests and no native product or product
  # check, nor any wasm test run; `products = [ "app" ]` keeps app's
  # product only.
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
                # rust-overlay's rust-lld, as Cargo finds it.
                ${wasm} = {
                  preset = null;
                  variantDefaults.tests = false;
                };
              };
            };
          }
        ];
      repo = repoWith { variantDefaults.products = false; };
      # Three packages with products (cdylib, staticlib, bin).
      partial = mkRepo (fixtures + "/crate-types") [
        {
          workspaces.main = {
            path = ".";
            variants.default.profile = "dev";
            targets.${native}.variantDefaults.products = [ "app" ];
          };
        }
      ];
      leaves = r: lib.attrNames (lib.filterAttrs (_: c: !(c.breakbulkCheckGroup or false)) r.checks);
      nativeChecks = lib.filter (lib.hasPrefix "main/${native}/") (leaves repo);
      wasmChecks = lib.filter (lib.hasPrefix "main/${wasm}/") (leaves repo);
      # The test plan's buildScriptPaths check comes with the test runs.
      isRun =
        n:
        lib.hasInfix "/test/" n || lib.hasSuffix "/doctest" n || lib.hasSuffix "/buildScriptPaths/test" n;
      t = repo.workspaces.main.target;
    in
    assert lib.assertMsg (t.${native}.packages == { })
      "products-tests-only: native products ${toString (lib.attrNames t.${native}.packages)}";
    assert lib.assertMsg (
      nativeChecks != [ ] && lib.all isRun nativeChecks && lib.any (lib.hasSuffix "/doctest") nativeChecks
    ) "products-tests-only: native checks ${toString nativeChecks}";
    assert lib.assertMsg (
      wasmChecks != [ ] && !(lib.any isRun wasmChecks)
    ) "products-tests-only: wasm checks ${toString wasmChecks}";
    assert lib.assertMsg (lib.attrNames partial.workspaces.main.target.${native}.packages == [ "app" ])
      "products-tests-only: with a list, native products ${
        toString (lib.attrNames partial.workspaces.main.target.${native}.packages)
      }";
    evalCheck "products-tests-only" (builtins.toJSON { inherit nativeChecks wasmChecks; });

  variants-per-target =
    let
      wasm = "wasm32-unknown-unknown";
      wasmRust = overlayRust.override { targets = [ wasm ]; };
      repoWith =
        extra:
        mkRepo (fixtures + "/variants") [
          (
            top:
            let
              inherit (top.config.workspaces.main) members;
            in
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
                    # `extra` is app's feature, not lib-a's: a variant
                    # that selects packages gets only what one of them
                    # accepts.
                    ${wasm} = {
                      # rust-overlay's rust-lld, as Cargo finds it.
                      preset = null;
                      variantDefaults =
                        { config, ... }:
                        {
                          features =
                            lib.filter
                              (
                                f:
                                !(builtins.isList config.packages)
                                || lib.any (p: breakbulk.acceptsFeature members.${p} f) config.packages
                              )
                              [
                                "lib-a/y"
                                "extra"
                              ];
                          testProfile = "release";
                        };
                    };
                  };
                }
                extra
              ];
            }
          )
        ];
      repo = repoWith {
        variants = lib.mkMerge [
          ({
            default.profile = "release";
            own = {
              profile = "release";
              features = [ "lib-a/x" ];
              target.${wasm} = {
                features = lib.mkForce [ ];
                noDefaultFeatures = true;
                testProfile = lib.mkForce "dev";
              };
            };
            gate = {
              mode = "check";
              profile = "release";
              target.${wasm}.tests = false;
            };
          })
          # A plain definition next to the generated one.
          { "hack-lib-a.x".features = [ "y" ]; }
        ];
        imports = [
          (breakbulk.variants.featurePowerset {
            scope = "package";
            packages = [ "lib-a" ];
            eachFeature = true;
            variant = {
              mode = "check";
              profile = "release";
            };
          })
        ];
      };
      w = repo.workspaces.main;
      # The package runs are check variants: their test plans keep
      # `profile`.
      hackProfiles = lib.mapAttrs (_: _: "release") (
        lib.filterAttrs (n: _: lib.hasPrefix "hack-" n) w.internal.instances.${native}
      );
      planCmd =
        triple: vName: kind:
        w.internal.instances.${triple}.${vName}.plans.${kind}.drvAttrs.buildCommand;
      has =
        triple: vName: s:
        lib.hasInfix " ${s} " (planCmd triple vName "build");
      # A check builds the `allUnits` of each plan it traces.
      unitsOf =
        triple: map builtins.unsafeDiscardStringContext w.target.${triple}.variants.gate.check.units;
      planUnits = triple: kind: [
        (builtins.unsafeDiscardStringContext w.internal.instances.${triple}.gate.allUnits.${kind}.outPath)
      ];
      fails =
        extra:
        !(builtins.tryEval (
          builtins.deepSeq (lib.mapAttrs (
            _: t: lib.mapAttrs (_: v: v.plans.build.drvPath) t.variants
          ) (repoWith extra).workspaces.main.target) true
        )).success;
      bad = lib.attrNames (
        lib.filterAttrs (_: ok: !ok) {
          # The default variant: lib-a/y on wasm only.
          defaultNative = !(has native "default" "--features");
          defaultWasm = has wasm "default" "--features lib-a/y" && has wasm "default" "--features extra";
          # `own`: its feature natively; on wasm its layer replaces both.
          ownNative = has native "own" "--features lib-a/x" && !(has native "own" "--no-default-features");
          ownWasm = !(has wasm "own" "--features") && has wasm "own" "--no-default-features";
          # A `-p lib-a` run: its own features, the user's, and of the
          # defaults only lib-a's.
          hackWasm =
            has wasm "hack-lib-a.x" "--features x"
            && has wasm "hack-lib-a.x" "--features y"
            && has wasm "hack-lib-a.x" "--features lib-a/y"
            && !(lib.hasInfix "extra" (planCmd wasm "hack-lib-a.x" "build"));
          hackNative =
            has native "hack-lib-a.x" "--features x"
            && has native "hack-lib-a.x" "--features y"
            && !(lib.hasInfix "lib-a/y" (planCmd native "hack-lib-a.x" "build"));
          hackNoDefault =
            has wasm "hack-lib-a.no-default-features" "--features lib-a/y"
            && !(lib.hasInfix "extra" (planCmd wasm "hack-lib-a.no-default-features" "build"))
            && has wasm "hack-lib-a.no-default-features" "--no-default-features";
          # `tests = false` on wasm only: the build plan's units there, both
          # plans' natively.
          # `testProfile` from wasm's defaults, and `own`'s layer over it;
          # the check variant keeps `profile`.
          testProfiles =
            lib.mapAttrs (_: t: lib.mapAttrs (_: i: i.plans.test.profile) t) w.internal.instances == {
              ${native} = {
                default = "test";
                own = "test";
                gate = "release";
              }
              // hackProfiles;
              ${wasm} = {
                default = "release";
                own = "dev";
                gate = "release";
              }
              // hackProfiles;
            };
          gateWasm = unitsOf wasm == planUnits wasm "build";
          gateNative = unitsOf native == planUnits native "build" ++ planUnits native "test";
          # A check variant cannot take `benches`, on one target either.
          rejectsCheckBenches = fails {
            variants.gate = {
              mode = "check";
              target.${wasm}.benches = true;
            };
          };
          # A layer for a target the variant is not planned for.
          rejectsUnplanned = fails {
            variants.default = {
              targets = [ native ];
              target.${wasm}.profile = "dev";
            };
          };
          # A single value: the variant's target layer wins over the
          # variant and `variantDefaults` without mkForce; mkForce in the
          # variant wins over a plain value in the layer, a plain value in
          # the variant over mkDefault in the layer.
          layerWins =
            let
              r = repoWith {
                variants.default = {
                  profile = "release";
                  target.${wasm}.profile = "dev";
                };
                targets.${wasm}.variantDefaults.profile = "bench";
              };
              p = t: r.workspaces.main.internal.instances.${t}.default.plans.build.drvAttrs.buildCommand;
            in
            lib.hasInfix " --profile dev " (p wasm) && lib.hasInfix " --profile release " (p native);
          forcedWins =
            let
              r = repoWith {
                variants.default = {
                  profile = lib.mkForce "release";
                  target.${wasm}.profile = "dev";
                };
              };
            in
            lib.hasInfix " --profile release "
              r.workspaces.main.internal.instances.${wasm}.default.plans.build.drvAttrs.buildCommand;
          mkDefaultLoses =
            let
              r = repoWith {
                variants.default = {
                  profile = "release";
                  target.${wasm}.profile = lib.mkDefault "dev";
                };
              };
            in
            lib.hasInfix " --profile release "
              r.workspaces.main.internal.instances.${wasm}.default.plans.build.drvAttrs.buildCommand;
          # The variant's own plain value wins over a plain value in the
          # target's `variantDefaults`; mkForce there wins over it.
          defaultsLose =
            let
              p =
                d:
                (repoWith {
                  variants.default.profile = "release";
                  targets.${wasm}.variantDefaults.profile = d;
                }).workspaces.main.internal.instances.${wasm}.default.plans.build.drvAttrs.buildCommand;
            in
            lib.hasInfix " --profile release " (p "bench")
            && lib.hasInfix " --profile bench " (p (lib.mkForce "bench"));
          # The workspace's `variantDefaults`, under the target's and the
          # variant's own; a function module reads the variant's settings
          # with every layer applied (the target layer's `mode` here).
          workspaceDefaults =
            let
              r = repoWith {
                variantDefaults =
                  { config, ... }:
                  {
                    profile = "dev";
                    features = lib.optional (config.mode == "check") "lib-a/x";
                  };
                targets.${wasm}.variantDefaults.profile = lib.mkForce "bench";
                variants.default = { };
                variants.own = {
                  profile = "release";
                  target.${wasm}.mode = "check";
                };
              };
              p = t: v: r.workspaces.main.internal.instances.${t}.${v}.plans.build.drvAttrs.buildCommand;
            in
            lib.hasInfix " --profile dev " (p native "default")
            && lib.hasInfix " --profile bench " (p wasm "default")
            && lib.hasInfix " --profile release " (p native "own")
            && !(lib.hasInfix "lib-a/x" (p native "own"))
            && lib.hasInfix " --features lib-a/x " (p wasm "own")
            && !(lib.hasInfix "lib-a/x" (p wasm "default"));
          # The example of the docs: test runs and products in repo.checks
          # on wasm only.
          checksOnOneTarget =
            let
              names =
                lib.attrNames
                  (repoWith {
                    variants.default = {
                      profile = "release";
                      checks = {
                        products = false;
                        tests = false;
                      };
                      target.${wasm}.checks = {
                        products = true;
                        tests = true;
                      };
                    };
                  }).checks;
            in
            lib.elem "main/${wasm}/app/build" names && !(lib.any (lib.hasPrefix "main/${native}/app/") names);
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
        "packDwo"
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
        depTests = sourcePaths.workspaces.main.target.${native}.variants.default.testRuns.dep."lib/dep";
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

  # The `product` a stage and a check get has exactly the attributes the
  # reference documents, on a product whose `linked` stage has a `debug`
  # output (`split-debuginfo = "packed"`), so every optional one is there.
  product-attributes =
    let
      p = probeRepo.workspaces.main.target.${native}.variants.packed.packages.app;
      actual = {
        stages = lib.sort lib.lessThan p.stages.probe.productNames;
        checks = lib.sort lib.lessThan p.checks.probe.productNames;
      };
    in
    assert lib.assertMsg (
      lib.length documentedProduct.stages > 5
    ) "product-attributes: no `product` table found in docs/src/reference/stage-functions.md";
    assert lib.assertMsg (actual == documentedProduct)
      "product-attributes: docs/src/reference/stage-functions.md documents ${builtins.toJSON documentedProduct}, but a product has ${builtins.toJSON actual}";
    evalCheck "product-attributes" (builtins.toJSON actual);

  source-paths-dwo = dwoCheck "source-paths-dwo" sourcePaths 4;
  source-paths-dwo5 = dwoCheck "source-paths-dwo5" sourcePathsDwarf5 5;

  # A staticlib built with split-debuginfo = "unpacked" keeps its skeleton
  # units and ships `lib/<archive>.dwp`, with the units of the crate and
  # of its dependency. A C program linked against the archive gets the
  # DWARF through the documented recipe (`llvm-dwp <archive>.dwp … -o
  # <program>.dwp`), and not without it.
  staticlib-dwp =
    let
      stat = staticlibUnpacked.workspaces.main.packages.stat;
    in
    pkgs.runCommandCC "staticlib-dwp"
      {
        nativeBuildInputs = [
          pkgs.gdb
          pkgs.llvm
          pkgs.binutils-unwrapped
        ];
        inherit stat;
        debug = stat.debug;
      }
      ''
        set -euo pipefail
        find $debug
        a=$(cd $stat/lib && echo libstat*.a)
        test -f $debug/lib/$a.dwp
        test -z "$(find $debug -name '*.dwo')"
        llvm-dwarfdump --debug-info $debug/lib/$a.dwp > units.txt
        grep -F '("stat/src/lib.rs/@/' units.txt
        grep -F '("both/src/lib.rs/@/' units.txt
        # The archive keeps the skeleton units that name the .dwo files.
        readelf --debug-dump=info --dwarf-depth=1 $stat/lib/$a > skeletons.txt 2>/dev/null
        grep -qE 'DW_AT_(GNU_)?dwo_name' skeletons.txt
        cat > main.c <<'EOF'
        #include <stdio.h>
        unsigned int stat_answer(void);
        int main(void) { printf("c %u\n", stat_answer()); return 0; }
        EOF
        mkdir bin
        cc main.c $stat/lib/$a -lpthread -ldl -lm -o bin/cuser
        [ "$(bin/cuser)" = "c 7" ]
        llvm-dwp $debug/lib/$a.dwp -o bin/cuser.dwp
        query() {
          gdb -batch -nx -ex 'info line both::both_answer' -ex 'info scope stat::stat_answer' bin/cuser > "$1" 2>&1 || true
          cat "$1"
        }
        query gdb.txt
        grep -E '^Line [0-9]+ of "both/src/lib.rs"' gdb.txt
        # Negative control: without cuser.dwp, gdb has no full DWARF.
        rm bin/cuser.dwp
        query nodwp.txt
        ! grep -E '^Line [0-9]+ of "both/src/lib.rs"' nodwp.txt
        touch $out
      '';

  # `debugInfo = "keep"` with split-debuginfo = "unpacked": packDwo packs
  # the `.dwo` files into `bin/app.dwp` and ships none loose; gdb, on the
  # binary with the `.dwp` beside it (a profile with both outputs), reads
  # the dependency's arguments from it, and not without it.
  debug-info-keep =
    let
      p = unpackedApp "keep" [ ];
    in
    pkgs.runCommand "debug-info-keep"
      {
        nativeBuildInputs = [ pkgs.gdb ];
        app = p;
        debug = p.debug;
        linkedDebug = p.stages.linked.debug;
      }
      ''
        set -euo pipefail
        ls $linkedDebug | grep -qE '^dep[-.].*\.dwo$'
        find $debug
        test -f $debug/bin/app.dwp
        test -z "$(find $debug -name '*.dwo')"
        mkdir -p env/bin
        ln -s $app/bin/app env/bin/app
        ln -s $debug/bin/app.dwp env/bin/app.dwp
        trace() {
          gdb -batch -nx -ex 'break dep::boom' -ex run -ex bt env/bin/app > "$1" 2>&1 || true
          cat "$1"
        }
        trace gdb.txt
        grep -qF 'dep::boom (n=7)' gdb.txt
        rm env/bin/app.dwp
        trace nodwp.txt
        ! grep -qF 'dep::boom (n=7)' nodwp.txt
        touch $out
      '';

  # `debugInfo = "strip"` with split-debuginfo = "unpacked": no `.dwo`
  # ships, as the skeleton units that name them are stripped; with
  # "packed", no `.dwp`.
  debug-info-strip =
    let
      p = unpackedApp "strip" [ ];
      packed = debugInfoApp "packed" "strip" [ ];
    in
    pkgs.runCommand "debug-info-strip"
      {
        app = p;
        debug = p.debug;
        linkedDebug = p.stages.linked.debug;
        packedApp = packed;
        packedLinkedDebug = packed.stages.linked.debug;
        packedDebug = packed.stages.strip.debug or "";
      }
      ''
        set -euo pipefail
        ls $linkedDebug | grep -qE '^dep[-.].*\.dwo$'
        test -z "$(find -L $app $debug -name '*.dwo')"
        test -f $packedLinkedDebug/app.dwp
        test -z "$(find -L $packedApp $packedDebug -name '*.dwp')"
        touch $out
      '';

  # `packages.app.stages.packDwo = null` ships the loose `.dwo` files
  # again, next to splitDebug's separate debug file.
  pack-dwo-removed =
    let
      p = unpackedApp "split" [ { packages.app.stages.packDwo = lib.mkForce null; } ];
    in
    assert lib.assertMsg (
      p.stageOrder == [
        "splitDebug"
        "install"
      ]
    ) "pack-dwo-removed: ${builtins.toJSON p.stageOrder}";
    pkgs.runCommand "pack-dwo-removed" { debug = p.debug; } ''
      set -euo pipefail
      find $debug
      ls $debug/bin | grep -qE '^app[-.].*\.dwo$'
      ls $debug/bin | grep -qE '^dep[-.].*\.dwo$'
      test ! -e $debug/bin/app.dwp
      ls $debug/lib/debug/.build-id/*/*.debug
      touch $out
    '';

  # plugin's unit links a cdylib and writes its own libplugin.so.dwp, which
  # stays in plugin's product: app's linked debug output holds app.dwp only.
  cdylib-debug-packed = cdylibDebugCheck "packed" ''
    test "$(cat names)" = app.dwp
    test -f $pluginLinkedDebug/libplugin.so.dwp
  '';

  # The `.dwo` files of app and of plugin, and nothing else.
  cdylib-debug-unpacked = cdylibDebugCheck "unpacked" ''
    grep -qE '^app[-.].*\.dwo$' names
    grep -qE '^plugin[-.].*\.dwo$' names
    test -z "$(grep -vE '^(app|plugin)[-.].*\.dwo$' names)"
  '';

  trim-paths =
    let
      wsOf = w: trimPathsRepo.workspaces.${w};
      instOf = w: (wsOf w).internal.instances.${native}.default;
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
      setNoScope = lib.filterAttrs (_: u: !(hasArg (a: a == "--remap-path-scope=all") u)) (
        allCompiles "set"
      );
      defaultScope = lib.filterAttrs (_: u: hasArg (lib.hasPrefix "--remap-path-scope") u) (
        allCompiles "default"
      );
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
      plans.default.build.trimPaths
      && plans.default.build.trimPathsDefault
      && plans.default.test.trimPathsDefault
    ) "trim-paths: the planner did not turn trim-paths on for default's plans";
    assert lib.assertMsg (
      setNoScope == { }
    ) "trim-paths: set's units without Cargo's scope: ${toString (lib.attrNames setNoScope)}";
    assert lib.assertMsg (
      defaultScope == { }
    ) "trim-paths: default's units kept Cargo's scope: ${toString (lib.attrNames defaultScope)}";
    assert lib.assertMsg (ownRemaps "set" == { } && ownRemaps "default" == { })
      "trim-paths: breakbulk added remaps: ${
        toString (lib.attrNames (ownRemaps "set" // ownRemaps "default"))
      }";
    assert lib.assertMsg (
      setScoped == { }
    ) "trim-paths: set's units got a breakbulk scope: ${builtins.toJSON setScoped}";
    assert lib.assertMsg (
      badDefault == { }
    ) "trim-paths: default's scopes ${builtins.toJSON (scopes "default")}";
    assert lib.assertMsg (
      lib.length buildDirRemaps == 1
    ) "trim-paths: shared's build-directory remaps: ${builtins.toJSON buildDirRemaps}";
    # Hashed without its absolute path: one key in both workspaces and at
    # two other locations.
    assert lib.assertMsg
      (
        sharedKey plans.set.build == sharedKey plans.default.build
        && lib.length (sharedKey plans.set.build) == 1
      )
      "trim-paths: shared's keys ${
        builtins.toJSON [
          (sharedKey plans.set.build)
          (sharedKey plans.default.build)
        ]
      }";
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
        tests = (wsOf "default").target.${native}.variants.default.testRuns.lib."lib/lib";
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
      off = trimCcRepo { variantDefaults.sourcePaths = "remap"; };
      keep = trimCcRepo { variantDefaults.sourcePaths = "keep"; };
      planOf =
        r:
        builtins.fromJSON (
          builtins.unsafeDiscardStringContext (builtins.readFile "${(inst r).plans.build}/plan.json")
        );
      runOf =
        r:
        lib.head (lib.attrValues (lib.filterAttrs (n: _: lib.hasPrefix "r-cfile-" n) (inst r).units.build));
      renderedRun =
        r: builtins.fromJSON (builtins.unsafeDiscardStringContext (runOf r).drvAttrs.BREAKBULK_UNIT);
      run = renderedRun repo;
      cargoNamed = to: to == "." || lib.hasPrefix "/cargo/" to || lib.hasPrefix "/rustc/" to;
      offRun = renderedRun off;
      keepUnits = map (
        u: builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)
      ) (lib.attrValues (inst keep).units.build);
      keepRemaps = lib.filter (
        u: (u.remap or [ ]) != [ ] || (u.remapScope or null) != null || (u.outDirRemap or null) != null
      ) keepUnits;
      # trim-paths for one package only: planning fails naming both sides.
      mixed =
        pkgs.testers.testBuildFailure
          (inst (
            mkRepo
              (edited "trim-paths-cc" "printf '\\n[profile.dev.package.cc]\\ntrim-paths = \"all\"\\n' >> Cargo.toml")
              [
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
    assert lib.assertMsg (
      (planOf repo).trimPaths && (planOf repo).trimPathsDefault
    ) "trim-paths-cc: trim-paths is not on";
    assert lib.assertMsg (
      lib.all (p: cargoNamed (lib.elemAt p 1)) run.remap && run.remap != [ ]
    ) "trim-paths-cc: the run's C prefix maps: ${builtins.toJSON run.remap}";
    assert lib.assertMsg ((run.outDirRemap or "") == "/cargo/build-dir")
      "trim-paths-cc: outDirRemap ${builtins.toJSON (run.outDirRemap or null)}";
    assert lib.assertMsg (
      !(planOf off).trimPaths && lib.hasPrefix "/breakbulk/build/" (offRun.outDirRemap or "")
    ) "trim-paths-cc: sourcePaths = remap: ${builtins.toJSON offRun.outDirRemap}";
    assert lib.assertMsg (
      !(planOf keep).trimPaths && keepRemaps == [ ]
    ) "trim-paths-cc: sourcePaths = keep added remaps";
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
      before = sourcePaths.workspaces.main.target.${native}.variants.default.tests.dep."lib/dep";
      after = sourcePathsReadme.workspaces.main.target.${native}.variants.default.tests.dep."lib/dep";
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
          builtins.readFile "${repo.workspaces.main.target.${native}.variants.default.plans.build}/plan.json"
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
    assert lib.assertMsg (
      missing == [ ]
    ) "no-toolchain-references: not looked for: ${toString missing}";
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
      naming =
        (repo [
          {
            packages.stat.stages.nameSource = {
              after = "splitDebug";
              before = "install";
              run =
                {
                  input,
                  product,
                  pkgs,
                  ...
                }:
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

  manifest-dir =
    let
      plain = (manifestDir [ ]).workspaces.main.packages.app;
      scrubbed = manifestDirRepo.workspaces.main.packages.app;
      fillerHash = lib.fixedWidthString 32 "e" "";
    in
    pkgs.runCommand "manifest-dir"
      {
        failure = pkgs.testers.testBuildFailure plain.checks.noSourceReferences;
        passing = scrubbed.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        log=$failure/testBuildFailure.log
        cat $log
        grep -q 'references source' $log
        grep -qF 'usually comes from env!("CARGO_MANIFEST_DIR") kept in a string' $log
        grep -qxF 'When the program never reads that path, blank its hash: packages.app.stages.removeSourceReferences = { after = "splitDebug"; before = "install"; run = breakbulk.stageHelpers.removeSourceReferences; };' $log
        test "$(tail -n1 $log)" = 'or, when app may reference them: packages.app.checks.noSourceReferences = null;'
        # The stage changed only hash bytes, each to an `e` (octal 145).
        before=${plain.stages.splitDebug}/app
        after=${scrubbed.stages.removeSourceReferences}/app
        test "$(stat -c %s $before)" = "$(stat -c %s $after)"
        cmp -l $before $after > diff || true
        test -s diff
        if awk '$3 != 145' diff | grep -q .; then echo "bytes other than the hash changed" >&2; exit 1; fi
        ${scrubbed}/bin/app | tee run.txt
        grep -qx "assets: ${builtins.storeDir}/${fillerHash}-.*/assets" run.txt
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
      cargoComponent = lib.findFirst (
        p: builtins.match "[a-z0-9]{32}-cargo-.*" (baseNameOf "${p}") != null
      ) null tc.paths;
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
  # `targets.<t>.debugInfo`. It inserts its stages (packDwo then splitDebug
  # for "split", strip for "strip", packDwo for "keep") and sets the units'
  # remap scope and build ID; neither the target's nor a package's `stages`
  # may remove splitDebug or strip or add `splitDebug` where it inserts
  # none (an evaluation error naming `debugInfo`), but they may override
  # their attributes.
  debug-info =
    let
      mk = extra: mkRepo (fixtures + "/post-link") ([ (oneWs "." "dev") ] ++ extra);
      base = mk [ ];
      keep = mk [ { targets.${native}.debugInfo = "keep"; } ];
      strip = mk [ { targets.${native}.debugInfo = "strip"; } ];
      pk = r: r.workspaces.main.packages;
      rootUnit =
        r: p: r.workspaces.main.internal.instances.${native}.default.rootUnits.build."${p}/bin/${p}";
      unitOf = r: p: (rootUnit r p).drvPath;
      fails = r: p: !(builtins.tryEval (pk r).${p}.stageOrder).success;
      unitEnv = r: p: (rootUnit r p).drvAttrs.BREAKBULK_UNIT or "";
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
        # A target whose traits have no stages for a value cannot take it
        # (wasm: no "split" or "strip" entry)...
        wasmSplit =
          !(builtins.tryEval (
            breakbulk.products.debugInfoOf {
              triple = "wasm32-unknown-unknown";
              debugInfo = "split";
            }
          )).success;
        # ...until its traits give them: the entry's stages come first,
        # and no stage set may remove them.
        wasmStripGiven =
          let
            triple = "wasm32-unknown-unknown";
            traits = breakbulk.targetTraits.resolve {
              inherit triple;
              traits.debugStages.strip = [
                {
                  name = "wasmStrip";
                  run = helpers.wasmOpt;
                }
              ];
            };
            set =
              targetStages:
              breakbulk.products.targetStageSet {
                inherit triple traits targetStages;
                debugInfo = "strip";
              };
          in
          lib.attrNames (set { }) == [ "wasmStrip" ]
          && !(builtins.tryEval (
            lib.attrNames (set {
              wasmStrip = null;
            })
          )).success;
        # A stage with no `after` runs after the inserted stages, whichever
        # the target's debugInfo inserts.
        noAfter =
          map
            (
              v:
              (pk (mk [
                {
                  targets.${native}.debugInfo = v;
                  packages.tool.stages.mine.run = helpers.patchelfRpath { libs = [ ]; };
                }
              ])).tool.stageOrder
            )
            [
              "split"
              "keep"
              "strip"
            ];
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
            "packDwo"
            "splitDebug"
            "install"
          ]
          [
            "packDwo"
            "install"
          ]
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
        && report.wasmStripGiven
        &&
          report.noAfter == [
            [
              "packDwo"
              "splitDebug"
              "mine"
              "install"
            ]
            [
              "packDwo"
              "mine"
              "install"
            ]
            [
              "strip"
              "mine"
              "install"
            ]
          ]
        &&
          report.override == [
            "packDwo"
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
        "packDwo"
        "splitDebug"
        "stamp"
        "sign"
        "install"
      ]
    ) "post-link: server stages ${builtins.toJSON plServer.stageOrder}";
    assert lib.assertMsg (
      plTool.stageOrder == [
        "packDwo"
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
