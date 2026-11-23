# Test runs and doctests ("Tests as products" in
# docs/src/explanation/products.md; "Tests" in
# docs/src/explanation/internals/products.md).
#
#   t = breakbulk.testRuns.mkTestRuns {
#     pkgs;
#     inst;          # breakbulk.instantiate's result for a test plan
#     tools;         # tool name -> store path, as given to instantiate
#                    # (`rustc-sysroot` names the sysroot; runs get only
#                    # its target libraries, see `testLibs`)
#     target;        # the target triple
#     runner = null;      # null (native) or [ program arg … ]
#     testSystem = null;  # e.g. "aarch64-linux": run tests on that system
#     traits = <built-in>;  # the target's traits (lib/target-traits.nix)
#     dylibPath = <from the runner or the traits>;  # { var; sep; } or null:
#                         # the variable the test process finds shared
#                         # libraries through (`dylibPathOf`)
#     testPkgs = <pkgs for testSystem>;
#     packageSet = <pkgs for the native triple, else null>;  # the target's
#                         # package set, for the stages of run binaries
#     host = <defaultHost>;  # the same settings for the build machine's
#                         # triple, which a host unit's test (a proc macro's
#                         # unit tests) runs with (`testPlatforms`)
#     packages = { };     # packages.<name>: settings with `runs`
#                         # (lib/package-settings.nix `runsOf`)
#     kind = "test";      # "bench": the runs of a bench plan, with the
#                         # `bench` run settings, and no doctests
#     ca = breakbulk.nixFeatures.defaultCa;   # true; false
#     nixFeatures = <standalone>;  # as stages.mkProduct's
#     name = "breakbulk";
#   };
#
#   t.runs.<pkg>.<binary>     one test-run derivation per test binary;
#                             `.enabled` says whether it is in the checks
#   t.doctests.<pkg>          one doctest derivation per library, with its
#                             platform's target runner and the doctest
#                             run's settings (`doctestConfig`); `.enabled`
#   t.checks."test/<pkg>/<binary>", t.checks."doctest/<pkg>"
#                             every enabled run and doctest
#   t.roots.<pkg>.<binary>    the test roots (lib/test-apps.nix uses them)
#   t.platforms               how each platform's tests run (`testPlatforms`)
#
# Binary names within a package: an integration test by its name (`it`);
# the library's unit tests as `lib/<lib name>`; a bin's as `bin/<bin name>`;
# an example or bench built as a test as `example/<name>`, `bench/<name>`.
# Integration test names cannot contain `/`, so names never collide.
#
# Each run has its run settings (`runConfig`: `test`, refined by
# `test.binaries.<binary>` and, for a bench run, `bench`). A test run, as
# `cargo test` runs a test binary (Cargo's `cmd_builds` and
# `Compilation::fill_env`, `src/cargo/ops/cargo_test.rs` and
# `src/cargo/core/compiler/compilation.rs`):
#
#   - the binary, through the run's `stages` (`runBinary`: by default,
#     with `ca`, a debug-stripped content-addressed copy, so that a binary
#     whose code did not change is not re-run), runs under its platform's
#     runner (`testPlatforms`: a host unit's is the build machine's, not
#     the target's), in the package directory of its source view, with
#     the run's `args`;
#   - its environment: the dynamic-library path, then the project's
#     `[env]` config variables (the plan's `configEnv`, with the values
#     Cargo gave the test unit), then the package's build script
#     `rustc-env` values, then `CARGO`, `CARGO_MANIFEST_DIR`,
#     `CARGO_MANIFEST_PATH` and `CARGO_PKG_*` from the test unit's recorded
#     env, then the run's `env`, its `path` on `PATH`, and last its
#     `preRun` entries (a fresh `HOME` and `RUST_TEST_THREADS` by default,
#     each only when the environment has not set one). Cargo applies
#     `[env]` last but never over a variable it set itself
#     (`apply_env_config`), so `[env]` loses to all of Cargo's own;
#   - the dynamic-library path (its platform's variable, `dylibPathOf`:
#     LD_LIBRARY_PATH on Linux, WINEPATH under wine, none for wasm) holds,
#     sorted as Cargo sorts paths, the
#     search paths printed by the runs of the test's platform in its
#     closure (the units its binary depends on, the bins named in
#     `CARGO_BIN_EXE_<name>` included; Cargo: every run of the build) that
#     lie inside the printing run's `out` or the `out` of a run it received
#     `DEP_*` metadata from (Cargo: inside the target's output directory;
#     the same rule as for compiles, runs and doctests,
#     `LibraryPath::for_dylib_path` in breakbulk-unit), then the sysroot's
#     library directory of its platform's triple;
#   - a binary that contains the planner's relative `CARGO_TARGET_TMPDIR`
#     runs in a private copy of the package directory made of symbolic
#     links, with a real, writable `target/tmp` (`workdirScript`);
#   - with a test wrapper (the run's `wrapper`), the wrapper starts the
#     binary, and the target runner runs inside it (`launchWords`);
#   - the output goes to the build log and to `$log` in $TMPDIR, not to
#     `$out`: it holds timings and, with several test threads, lines in a
#     varying order, and `nix build --rebuild` compares every output.
#     `$out` is an empty directory, unless a `postRun` snippet puts
#     something there after a passing run (`postRunScript`);
#   - the run fails when the binary does, then prints a hint for each path
#     its output names that its source view lacks (`hintScript`).
#
# What starts the binary is the run's test runner (`runner`, a function
# from the run's facts to a shell snippet: lib/test-runners.nix), which
# owns its protocol's defaults (libtest's RUST_TEST_THREADS for `direct`,
# the default; nextest's `test-threads` for `nextest`).
#
# What each run needs from the plan (env, `[env]` values, the runs for the
# dynamic-library path and `rustc-env`, the path-package graph) comes from
# breakbulk-instantiate, through the root wrapper's `breakbulk-root.json`
# (`TestSpec` in crates/breakbulk-instantiate/src/test_spec.rs), read at
# build time in both delivery modes.
#
# A test binary Cargo did not build (required features) is known at
# build time only: its run succeeds and logs why.
{
  lib,
  stages,
  util,
  targetTraits,
  runners,
  featureGates,
}:
let
  inherit (builtins)
    toJSON
    ;
  bt = import ./modules/types.nix { inherit lib; };

  # The key of a test binary within its package.
  binaryKey = r: if r.kind == "test" then r.target else "${r.kind}/${r.target}";

  storeName = s: lib.replaceStrings [ "/" ] [ "-" ] s;

  # How a test process of a target finds shared libraries: `{ var; sep; }`,
  # or null when it has no such variable (wasm, bare metal). The runner's
  # own, when it declares one (`breakbulkDylibPath`: wine reads WINEPATH,
  # not the Windows PATH), else the target's traits (`dylibPathVar`,
  # `dylibPathSep`). Cargo itself sets its host's variable for the runner
  # (`dylib_path_envvar`), which wine does not read.
  dylibPathOf =
    {
      traits,
      runner ? null,
    }:
    let
      r = lib.findFirst (x: builtins.isAttrs x && x ? breakbulkDylibPath) null (lib.toList runner);
    in
    if r != null then
      r.breakbulkDylibPath
    else if traits.dylibPathVar == null then
      null
    else
      {
        var = traits.dylibPathVar;
        sep = traits.dylibPathSep;
      };

  # The dynamic-library path, computed at run time from the runs' `flags`
  # outputs: every search path value (sorted by path component, as Cargo's
  # BTreeSet<PathBuf> does, then deduplicated), without its kind prefix,
  # kept when the printing run classified it as inside its own `out` or an
  # upstream run's (`inOutDir`/`inBuildDir`, `LibraryPath::for_dylib_path`
  # in breakbulk-unit), joined with `sep`. The filter comes first: a value
  # one run printed inside its `out` is kept even if another run printed it
  # too. Then, as Cargo puts `<profile>` and `<profile>/deps` after the
  # search paths (`Compilation::fill_env`), the copies of them in run
  # outputs that hold files a script wrote there (`targetDirs`, #23):
  # every `<profile>`, then every `deps`.
  dylibJqWith = sep: ''
    def strip: if test("^(native|crate|dependency|framework|all)=") then sub("^[a-z]+="; "") else . end;
    [inputs] as $runs
    | ([$runs[] | .libraryPaths[] | select(.inOutDir or (.inBuildDir // false)) | .value]
       | unique_by(split("/"))
       | map(strip))
      + ([$runs[] | (.targetDirs // [])[]] | unique | sort_by(endswith("/deps")))
    | join("${sep}")
  '';
  dylibJq = dylibJqWith ":";

  # Shell lines (bash) that put `$__bb_dylib`, then `extra`, before the
  # test process's dynamic-library variable (`dylib`: { var; sep; } or
  # null, then nothing at all).
  exportDylib =
    dylib: extra:
    lib.optionalString (dylib != null) ''
      for __bb_p in ${lib.escapeShellArgs extra}; do
        __bb_dylib=''${__bb_dylib:+$__bb_dylib${dylib.sep}}$__bb_p
      done
      export ${dylib.var}=$__bb_dylib''${${dylib.var}:+${dylib.sep}${"$" + dylib.var}}
    '';
in
rec {
  inherit
    binaryKey
    dylibJq
    dylibJqWith
    dylibPathOf
    exportDylib
    ;

  # What test runs read from the Rust toolchain: the standard library's
  # shared library in the sysroot's target library directory (`libstd-*.so`
  # by the traits' shared-library prefix and suffix, for binaries linked
  # with `-C prefer-dynamic` and the like), copied into
  # a small derivation laid out as a sysroot (`lib/rustlib/<target>/lib`).
  # Depending on the whole sysroot instead (over 1 GB) would make every
  # test run on a fresh machine fetch the toolchain. The compiler's own
  # libraries there (`librustc_driver-*`, rustc-dev's proc macros) stay
  # out: with the driver on the dynamic-library path, a rustc the test
  # starts loads the copy and takes the copy as its sysroot. A
  # `rustc_private` test binary finds the driver through its RUNPATH
  # instead. `null` without a sysroot.
  testLibs =
    pkgs: sysroot: traits:
    if sysroot == null then
      null
    else
      pkgs.runCommand "rust-test-libs-${traits.triple}" { } ''
        dir=lib/rustlib/${traits.triple}/lib
        mkdir -p "$out/$dir"
        for f in ${sysroot}/$dir/*; do
          case "''${f##*/}" in
            ${lib.escapeShellArg traits.sharedLibraryPrefix}std-*${lib.escapeShellArg traits.sharedLibrarySuffix}) cp -L "$f" "$out/$dir/" ;;
          esac
        done
      '';

  # `copyDylibsScript sep`: shell lines (bash, `jq` on PATH) that copy
  # the dynamic-library path of the `directives.json` files in the array
  # `__bb_flags` into `$dylibs/dylib/<NNNN>/` (default `$out`).
  copyDylibsScript = sep: ''
    __bb_dest=''${dylibs:-$out}/dylib
    mkdir -p "$__bb_dest"
    if [ ''${#__bb_flags[@]} -gt 0 ]; then
      shopt -s nullglob
      __bb_paths=$(jq -rn ${lib.escapeShellArg (dylibJqWith sep)} "''${__bb_flags[@]}")
      IFS=${lib.escapeShellArg sep} read -ra __bb_ps <<< "$__bb_paths"
      __bb_i=0
      for __bb_p in "''${__bb_ps[@]}"; do
        __bb_d=$__bb_dest/$(printf %04d $__bb_i)
        mkdir -p "$__bb_d"
        for __bb_f in "$__bb_p"/*; do
          if [ -e "$__bb_f" ] && [ ! -d "$__bb_f" ]; then cp -L "$__bb_f" "$__bb_d/"; fi
        done
        __bb_i=$((__bb_i + 1))
      done
    fi
  '';
  # The `rustc-env` values of several `directives.json` files (`jq -s`), in
  # order, as one.
  mergeRustcEnvJq = "{env: (map(.env) | add)}";

  # A copy of a test binary, from `src` (a shell glob matching the one
  # file), content-addressed when `caAttrs` says so. `prelude` runs
  # first; `attrs` are extra derivation attributes.
  binaryCopy =
    {
      pkgs,
      name,
      caAttrs,
      src,
      prelude ? "",
      attrs ? { },
    }:
    pkgs.runCommand "${name}-bin" (attrs // caAttrs) ''
      ${prelude}
      files=(${src})
      [ ''${#files[@]} -eq 1 ] || { echo "expected one file in ${src}" >&2; exit 1; }
      mkdir -p $out
      cp "''${files[0]}" $out/
    '';

  # The binary a run executes: `linked` (a directory holding it) through
  # the run's `stages` (`test.stages`), as a product's stages run
  # (stages.mkProduct; no `install`, no checks), for `platform`
  # (testPlatforms). Without a stage, `copy` (a content-addressed copy
  # when `ca`, so that a byte-identical binary is not re-run) or `linked`
  # itself.
  runBinary =
    {
      pkgs,
      name,
      linked,
      copy,
      cfg,
      platform,
      ca,
      nixFeatures,
    }:
    let
      live = lib.filterAttrs (_: stages.isLive) cfg.stages;
    in
    if live == { } then
      (if ca then copy else linked)
    else
      stages.mkProduct {
        name = "${name}-bin";
        inherit
          pkgs
          linked
          ca
          nixFeatures
          ;
        stages = cfg.stages // {
          install = null;
        };
        target = {
          inherit (platform) triple traits packageSet;
        };
      };

  # Packages' settings with every function value of their runs' `env`
  # applied to the facts of the runs that read them, `facts.<package>`
  # (`{ workspaceRoot }`). Each kind of run has its own facts: a test run
  # reads its "run" view, a doctest its test view, a test app possibly
  # the checkout.
  resolveTestEnv =
    facts: packages:
    let
      resolve =
        f: t:
        t // { env = lib.mapAttrs (_: bt.envMapValues (v: if lib.isFunction v then v f else v)) t.env; };
      one =
        pkg: p:
        if !(p ? runs) then
          p
        else
          let
            f =
              facts.${pkg}
                or (throw "breakbulk: a test env value of `${pkg}` is a function of the run, but `${pkg}` has no source view in this workspace");
          in
          p
          // {
            runs = {
              test = key: resolve f (p.runs.test key);
              doctest = resolve f p.runs.doctest;
              bench = key: resolve f (p.runs.bench key);
            };
          };
    in
    lib.mapAttrs one packages;

  # The run settings of one run of package `pkg` (`packages.<name>.runs`,
  # lib/package-settings.nix `runsOf`): `kind` "test" or "bench", with the
  # binary's key; "doctest" without one.
  runConfig =
    packages: pkg: kind: key:
    let
      r = packages.${pkg}.runs;
    in
    if kind == "doctest" then r.doctest else r.${kind} key;

  # A run's test wrapper (`wrapper` of its run settings `cfg`) as a
  # program on `pkgs`' system, or null. A function is called with `pkgs`
  # (`wrappers.cargoTargetLayout`'s result is one); a derivation with
  # `meta.mainProgram` names that program.
  wrapperOf =
    pkgs: cfg:
    let
      w = cfg.wrapper;
      v = if builtins.isFunction w then w pkgs else w;
    in
    if v == null then
      null
    else if lib.isDerivation v && v.meta ? mainProgram then
      lib.getExe v
    else
      toString v;

  # BREAKBULK_NEXT: the program a test wrapper hands the binary and its
  # arguments to, which starts it under `runner` (a list, possibly empty).
  nextScript =
    pkgs: runner:
    pkgs.writeShellScript "breakbulk-test-next" ''
      exec ${lib.escapeShellArgs runner} "$@"
    '';

  # The words (shell) that start a test binary given after them: under a
  # test wrapper (`wrapperOf`, or null), the wrapper with BREAKBULK_NEXT
  # and, when known (`sourceRoot`, a shell word, or null),
  # BREAKBULK_SOURCE_ROOT, as `env` assignments; else the runner. The
  # wrapper is outermost, so it runs on the machine that runs the test,
  # and `current_exe()` under an emulator names what the wrapper started.
  launchWords =
    {
      pkgs,
      runner,
      wrapper,
      sourceRoot ? null,
    }:
    if wrapper == null then
      lib.escapeShellArgs runner
    else
      "BREAKBULK_NEXT=${nextScript pkgs runner} "
      + lib.optionalString (sourceRoot != null) "BREAKBULK_SOURCE_ROOT=${sourceRoot} "
      + lib.escapeShellArg wrapper;

  # A program that starts the program given after it, with its
  # arguments, as `launchWords` do (the wrapper with BREAKBULK_NEXT, else
  # the runner), or null with neither: a test runner's `launcher`, one
  # word, for runners that take a program (nextest's
  # CARGO_TARGET_<T>_RUNNER). BREAKBULK_SOURCE_ROOT comes from the
  # environment.
  launcherOf =
    {
      pkgs,
      runner,
      wrapper,
    }:
    if wrapper == null && runner == [ ] then
      null
    else
      "${pkgs.writeShellScript "breakbulk-test-launcher" (
        if wrapper == null then
          ''
            exec ${lib.escapeShellArgs runner} "$@"
          ''
        else
          ''
            export BREAKBULK_NEXT=${nextScript pkgs runner}
            exec ${lib.escapeShellArg wrapper} "$@"
          ''
      )}";

  # Shell lines that export BREAKBULK_SOURCE_ROOT, the root of a run's
  # source view, from `breakbulk-root.json` (`$info`; `jq`, the jq
  # executable), when its package directory is inside one: the root of
  # `checkout` (a string), or with null of the root's own view.
  sourceRootExport =
    jq: checkout:
    let
      filter = ''
        .testSpec
        | if .packageDir == null then empty
          elif $checkout != "" then $checkout
          elif .packageDir == "" then .env.CARGO_MANIFEST_DIR
          else .packageDir as $p | .env.CARGO_MANIFEST_DIR | rtrimstr("/" + $p)
          end
      '';
      c = if checkout == null then "" else lib.removeSuffix "/" (toString checkout);
    in
    ''
      __bb_root=$(${jq} -r --arg checkout ${lib.escapeShellArg c} ${lib.escapeShellArg filter} "$info")
      if [ -n "$__bb_root" ]; then export BREAKBULK_SOURCE_ROOT=$__bb_root; fi
    '';

  # A run's raw output, besides the build log: `$log` in `test.postRun`.
  logFile = "$TMPDIR/breakbulk-test.log";

  # The option that adds a path to a test run's view: `test.runFiles` when
  # the run is narrowed to it, else the option of the "test" kind, also
  # when a `sources` function chose the run's files.
  hintWiden = cfg: if cfg.runFiles or null == null then "test.sourceScope" else "test.runFiles";

  # Shell lines (bash, `$log` set) for a failed run: a hint for each path
  # the log names that the run's source view lacks
  # (`breakbulk-hints`, which finds the view from `CARGO_MANIFEST_DIR`).
  # `spec` is a shell word expanding to its JSON. Not breakbulk-unit: with
  # `ca` on, every breakbulk-unit change would re-run every test run.
  # Nothing without breakbulk-hints in `tools` (built with `pkgs`), and
  # nothing when the run builds on another system (`testPkgs`, a
  # `testSystem`), where that breakbulk-hints cannot run.
  hintScript =
    {
      tools,
      pkgs,
      testPkgs,
    }:
    spec:
    lib.optionalString
      (
        tools ? breakbulk-hints && testPkgs.stdenv.buildPlatform.system == pkgs.stdenv.buildPlatform.system
      )
      ''
        ${tools.breakbulk-hints} ${spec} "$log" || true
      '';

  # What runs after a passing run: the run's `postRun` (its layers'
  # snippets, concatenated).
  postRunSnippets = { cfg }: lib.optional (cfg.postRun != "") cfg.postRun;

  # The snippets in a subshell, so that a snippet's `cd` or `exit` stays
  # its own; `$log` and `$out` are set.
  postRunScript =
    args:
    let
      snippets = postRunSnippets args;
    in
    lib.optionalString (snippets != [ ]) ''
      (
        set -euo pipefail
        ${lib.concatStringsSep "\n" snippets}
      )
    '';

  # The packages of a run's `path` (a function of a package set, or a
  # list) for the machine whose package set is `pkgs`.
  pathOf = pkgs: cfg: if lib.isFunction cfg.path then cfg.path pkgs else cfg.path;

  # Shell lines that export a run's configuration (its run settings
  # `cfg`): `env`, then `path` (packages of `pkgs`, the set of the machine
  # that runs it) on PATH.
  configScript =
    pkgs: cfg:
    let
      path = pathOf pkgs cfg;
    in
    lib.concatStrings (
      lib.mapAttrsToList (
        k: v:
        let
          spec = bt.envSpec (cfg.envSeparators or { }) k v;
        in
        if isAppend spec then
          "export ${k}=\"\${${k}:+\$${k}${spec.sep}}\"${lib.escapeShellArg spec.append}\n"
        else
          "export ${k}=${lib.escapeShellArg spec}\n"
      ) cfg.env
    )
    + lib.optionalString (path != [ ]) "export PATH=$PATH:${lib.makeBinPath path}\n";

  # An env spec that appends (types.nix `envSpec`).
  isAppend = v: builtins.isAttrs v && v ? append && !lib.isDerivation v;

  # A run's env as one layer of breakbulk-unit's (`LayerValue`s).
  envLayerOf =
    cfg:
    lib.mapAttrs (
      k: v:
      let
        spec = bt.envSpec (cfg.envSeparators or { }) k v;
      in
      if isAppend spec then
        {
          value = spec.append;
          inherit (spec) sep;
        }
      else
        {
          value = spec;
          sep = "";
        }
    ) cfg.env;

  # A run's `preRun` entries, without the removed ones.
  preRunEntries = cfg: lib.filterAttrs (_: v: v != null) cfg.preRun;

  # Shell lines that run a run's `preRun` entries in name order, in the
  # run's shell (their exports reach the test).
  preRunScript =
    cfg: lib.concatStrings (lib.mapAttrsToList (n: v: "# preRun.${n}\n${v}\n") (preRunEntries cfg));

  # `CARGO_TARGET_TMPDIR` as the planner bakes it into integration tests
  # and benches (`TARGET_TMPDIR` in crates/breakbulk-plan/src/graph.rs).
  targetTmpdir = "target/tmp";

  # Shell lines (bash) defining `__bb_workdir BINARY DIR`, which sets
  # `__bb_wd` to the working directory of a run of BINARY whose package
  # directory is DIR. A binary that contains `targetTmpdir` (a byte search:
  # `env!` bakes the value in) gets a fresh directory, private to this run,
  # holding a symbolic link per entry of DIR and a real, empty, writable
  # `target/tmp`; DIR's own `target`, if any, is left out. Any other binary
  # gets DIR itself. `pkgs` gives grep and coreutils, so the lines work
  # with any PATH (test apps).
  workdirScript = pkgs: ''
    __bb_workdir() {
      __bb_wd=$2
      if ${pkgs.gnugrep}/bin/grep -qF ${targetTmpdir} "$1"; then
        __bb_wd=$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/breakbulk-run.XXXXXX")
        for __bb_e in "$2"/* "$2"/.[!.]* "$2"/..?*; do
          [ -e "$__bb_e" ] || [ -L "$__bb_e" ] || continue
          [ "''${__bb_e##*/}" = target ] || ${pkgs.coreutils}/bin/ln -s "$__bb_e" "$__bb_wd/"
        done
        ${pkgs.coreutils}/bin/mkdir -p "$__bb_wd/${targetTmpdir}"
      fi
    }
  '';

  # The end of a test app's script: run `command` (shell words naming the
  # binary as "${files[0]}") in the binary's working directory
  # (`workdirScript`) for package directory `dir` (a shell word). A
  # private working directory is removed when the run ends, so only a run
  # without one replaces the script's process; the other waits for it,
  # passing INT and TERM on (`util.forwardSignalsScript`).
  appRunScript =
    {
      pkgs,
      dir,
      command,
    }:
    ''
      ${workdirScript pkgs}
      __bb_workdir "''${files[0]}" ${dir}
      cd "$__bb_wd"
      if [ "$__bb_wd" = ${dir} ]; then
        exec ${command}
      fi
      trap '${pkgs.coreutils}/bin/rm -rf "$__bb_wd"' EXIT
      ${util.forwardSignalsScript "${pkgs.coreutils}/bin/env"}
      __bb_run ${command}
    '';

  # The runner of each platform's test processes, `{ host; target; }`
  # (lists), from the target's runner and the host's (`defaultHost`; null
  # or a list): Cargo picks it by the unit's compile kind
  # (`Compilation::target_runner`). A host unit (a proc macro) is built for
  # the build machine, so it gets the build machine's triple's runner: none
  # in a cross plan, the target's own in a native plan.
  runnersByPlatform =
    {
      runner ? null,
      hostRunner ? null,
    }:
    let
      toRunner = r: if r == null then [ ] else lib.toList r;
    in
    {
      host = toRunner hostRunner;
      target = toRunner runner;
    };

  # The test settings of the build machine's triple, `{ triple; runner;
  # testSystem; dylibPath; }`, when the caller gives none: Cargo looks up a
  # host unit's runner under the host triple (`target.<host>.runner`, with
  # the default `target-applies-to-host`), so in a native plan they are the
  # target's own; otherwise no runner, the build machine, and the variable
  # of the host triple's traits. mkRepository passes the workspace's host
  # spec's (`workspaces.<ws>.host`).
  defaultHost =
    {
      pkgs,
      target,
      runner ? null,
      testSystem ? null,
      dylibPath ? null,
    }:
    let
      triple = targetTraits.nativeTriple pkgs;
    in
    if triple == target then
      {
        inherit
          triple
          runner
          testSystem
          dylibPath
          ;
      }
    else
      {
        inherit triple;
        runner = null;
        testSystem = null;
        dylibPath = dylibPathOf { traits = targetTraits.resolve { inherit triple; }; };
      };

  # How the test processes of each platform run, `{ host; target; }`, from
  # each platform's settings (`{ triple; runner; testSystem; dylibPath; }`,
  # `testPkgs`, `packageSet` and `traits` optional). Cargo runs a test unit
  # with its compile kind's runner (`target_runner(unit.kind)`), library
  # directories and sysroot library directory (`fill_env`, `sysroot_target_libdir[&kind]`); a host
  # unit (a proc macro's unit tests) is built for the build machine, so it
  # gets the host's, never `testSystem` or the target's runner. Each entry:
  #
  #   triple
  #   runner      a list (runnersByPlatform)
  #   testPkgs    the package set its runs build with (runners.testPkgsFor)
  #   dylibPath   { var; sep; } or null (dylibPathOf)
  #   traits      its traits (default: the triple's built-in ones)
  #   packageSet  its nixpkgs package set, or null (`targets.<t>.packageSet`;
  #               default: `pkgs` for the native triple), for the stages
  #               of its runs' binaries (`runBinary`)
  #   libDir      the sysroot's library directory for the triple, in a
  #               copy holding its shared libraries only (testLibs), or null
  testPlatforms =
    {
      pkgs,
      tools,
      target,
      host,
    }:
    let
      runnerLists = runnersByPlatform {
        inherit (target) runner;
        hostRunner = host.runner;
      };
      sysroot = tools.rustc-sysroot or null;
      one =
        name: s:
        let
          traits = s.traits or (targetTraits.resolve { inherit (s) triple; });
          libs = testLibs pkgs sysroot traits;
        in
        {
          inherit (s) triple dylibPath;
          inherit traits;
          packageSet = s.packageSet or (if s.triple == targetTraits.nativeTriple pkgs then pkgs else null);
          runner = runnerLists.${name};
          testPkgs =
            s.testPkgs or (runners.testPkgsFor {
              inherit pkgs;
              inherit (s) testSystem;
            });
          libDir = if libs == null then null else "${libs}/lib/rustlib/${s.triple}/lib";
        };
    in
    {
      host = one "host" host;
      target = one "target" target;
    };

  # A package's doctest configuration, from its doctest run's settings
  # (`runConfig`): the runners (`runnersByPlatform`; not the settings'
  # `runner` or `wrapper`, which a doctest cannot honour), `args`, `env`
  # with `path` as PATH (packages of `pkgs`, the build machine, where the
  # doctest runs), and the `postRun` program. Each is a string, an input
  # value of its doctest's rendered unit (`test`,
  # breakbulk_unit::spec::DoctestConfig; keyed `doctest:<pkg>:<name>`).
  # Dynamic-derivation mode passes the same strings to its outer
  # derivation (lib/dynamic.nix), so both modes write the same doctest
  # derivation.
  doctestConfig =
    {
      pkgs,
      packages,
      runner ? null,
      hostRunner ? null,
    }:
    pkg:
    let
      cfg = runConfig packages pkg "doctest" null;
      snippets = postRunSnippets { inherit cfg; };
      path = pathOf pkgs cfg;
    in
    {
      # A script, run in $TMPDIR with `$log` and `$out` set, after passing
      # doctests (breakbulk-doctest).
      postRun =
        if snippets == [ ] then
          ""
        else
          # The doctest derivation has no PATH; snippets get stdenv's basic
          # tools, as test runs (runCommand) do.
          "${pkgs.writeShellScript "breakbulk-${pkg}-doctest-post-run" (
            "set -euo pipefail\n"
            + "export PATH=${lib.makeBinPath pkgs.stdenv.initialPath}\${PATH:+:$PATH}\n"
            + lib.concatStringsSep "\n" snippets
          )}";
      runners = toJSON (runnersByPlatform {
        inherit runner hostRunner;
      });
      args = toJSON cfg.args;
      env = toJSON (
        [ (envLayerOf cfg) ]
        ++ lib.optional (path != [ ]) {
          PATH = {
            value = lib.makeBinPath path;
            sep = ":";
          };
        }
      );
    };

  # Whether a package's doctest run is in the check set (its `enable`).
  doctestEnabled = packages: pkg: (runConfig packages pkg "doctest" null).enable;

  # What a run reads from its wrapper, copied out of it, so that the run
  # does not depend on the wrapper: the wrapper's closure holds the
  # package's whole source view (its breakbulk-root.json names it) and
  # the unit's debuginfo (`debug`), which a run does not need. `out`
  # holds `breakbulk-root.json` with `reason` and `testSpec` only, its
  # package directory narrowed to the "run" view (`narrowDir`), and
  # without the path-package graph (`pathPackagesOf` in mkTestRuns).
  #
  # With `stable` (with `ca`, and content-addressed: `caAttrs`) it also
  # stands in for the input-addressed paths the spec names: the `flags`
  # of the runs below
  # the test (the dynamic-library path) and of its package's build
  # script (`rustc-env`) get new paths with every edit to a package
  # with a build script below the test, even when nothing they hold
  # changed. So the `flags` lists are empty, `rustc-env/directives.json`
  # holds the `rustc-env` values, and `dylibs` the dynamic-library
  # path's copies (`dylib/<NNNN>/` per entry, in order, holding the
  # entry's files, not its subdirectories, which the dynamic loader
  # never searches). The name is not per binary, so test binaries
  # whose copies have the same contents share its path, and the copies
  # are stored once.
  #
  # Without it, the `flags` stay, and with `linkRoot` `root` links the
  # test binary (the unit's output), for a run that takes no copy of it.
  runInfo =
    {
      pkgs,
      name,
      wrapper,
      # The platform's dylibPathOf result.
      dylibPath,
      caAttrs ? { },
      stable ? false,
      narrowDir ? null,
      linkRoot ? false,
    }:
    pkgs.runCommand name
      (
        caAttrs
        // {
          inherit wrapper;
          outputs = [ "out" ] ++ lib.optional stable "dylibs";
          nativeBuildInputs = [ pkgs.jq ];
          narrowDir = if narrowDir == null then "" else narrowDir;
          inherit stable;
        }
      )
      ''
        info=$wrapper/breakbulk-root.json
        mkdir -p $out ${lib.optionalString stable "$dylibs"}
        if [ -n "$(jq -r '.reason // ""' "$info")" ]; then
          jq '{reason}' "$info" > $out/breakbulk-root.json
          exit 0
        fi
        ${
          if stable then
            ''
              ${lib.optionalString (dylibPath != null) ''
                mapfile -t __bb_flags < <(jq -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
                ${copyDylibsScript dylibPath.sep}
              ''}
              mapfile -t envFlags < <(jq -r '.testSpec.envFlags[] | . + "/directives.json"' "$info")
              if [ ''${#envFlags[@]} -gt 0 ]; then
                mkdir -p $out/rustc-env
                jq -s ${lib.escapeShellArg mergeRustcEnvJq} "''${envFlags[@]}" > $out/rustc-env/directives.json
              fi
            ''
          else
            lib.optionalString linkRoot ''
              ln -s "$(readlink "$wrapper/root")" $out/root
            ''
        }
        jq --arg dir "$narrowDir" --arg stable "$stable" '
          .testSpec
          | del(.packageId, .pathPackages)
          | if $stable == "1" then .dylibFlags = [] | .envFlags = [] else . end
          | if $dir == "" then . else
              .env.CARGO_MANIFEST_DIR = $dir
              | .env.CARGO_MANIFEST_PATH = ($dir + "/Cargo.toml")
            end
          | {reason: null, testSpec: .}
        ' "$info" > $out/breakbulk-root.json
      '';

  # Shell lines (bash) that set up a test process's environment from a
  # test root's `breakbulk-root.json` at `$info`: the dynamic-library path
  # (then `extra`),
  # the project's `[env]`, the build script's `rustc-env`, then the runtime
  # `CARGO_*` variables (names the shell cannot export go to `__bb_env`,
  # for `env`).
  envScript =
    {
      jq,
      extra,
      # dylibPathOf's result for the target.
      dylibPath ? {
        var = "LD_LIBRARY_PATH";
        sep = ":";
      },
      # Whether `$info` is a stable copy's (`runInfo` with `ca`, in mkTestRuns),
      # with the dynamic-library path in `$specDylibs/dylib/*` and the
      # `rustc-env` values in `$spec/rustc-env`.
      stable ? false,
    }:
    lib.optionalString (dylibPath != null) ''
      mapfile -t __bb_flags < <(${jq} -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
      __bb_dylib=
      if [ ''${#__bb_flags[@]} -gt 0 ]; then
        __bb_dylib=$(${jq} -rn ${lib.escapeShellArg (dylibJqWith dylibPath.sep)} "''${__bb_flags[@]}")
      fi
      ${lib.optionalString stable ''
        for __bb_p in "$specDylibs"/dylib/*; do
          [ -d "$__bb_p" ] || continue
          __bb_dylib=''${__bb_dylib:+$__bb_dylib${dylibPath.sep}}$__bb_p
        done
      ''}${exportDylib dylibPath extra}unset __bb_dylib __bb_p __bb_flags
    ''
    + ''
      eval "$(${jq} -r '.testSpec.configEnv // {} | to_entries[] | "export \(.key)=\(.value | @sh)"' "$info")"
      for __bb_f in $(${jq} -r '.testSpec.envFlags[]' "$info"); do
        eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' "$__bb_f/directives.json")"
      done
      unset __bb_f
      ${lib.optionalString stable ''
        if [ -e "$spec/rustc-env/directives.json" ]; then
          eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' "$spec/rustc-env/directives.json")"
        fi
      ''}
      __bb_env=()
      eval "$(${jq} -r '.testSpec.env | to_entries[] | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) then "export \(.key)=\(.value | @sh)" else "__bb_env+=(\("\(.key)=\(.value)" | @sh))" end' "$info")"
    '';

  mkTestRuns =
    {
      pkgs,
      inst,
      tools,
      target,
      runner ? null,
      testSystem ? null,
      traits ? null,
      # dylibPathOf's result (default: from the traits and runner).
      dylibPath ? dylibPathOf {
        traits = if traits != null then traits else targetTraits.resolve { triple = target; };
        inherit runner;
      },
      testPkgs ? runners.testPkgsFor { inherit pkgs testSystem; },
      # The target's package set, or null (testPlatforms).
      packageSet ? if target == targetTraits.nativeTriple pkgs then pkgs else null,
      host ? defaultHost {
        inherit
          pkgs
          target
          runner
          testSystem
          dylibPath
          ;
      },
      packages ? { },
      # runDirs.<package> = the package directory of its "run" view, or
      # null for the test binary's own view (lib/workspace.nix).
      runDirs ? { },
      # Whose run settings the runs take (`runConfig`): "test", or "bench"
      # for a bench plan's binaries.
      kind ? "test",
      ca ? featureGates.defaultCa,
      nixFeatures ? featureGates.standalone {
        inherit ca;
      },
      name ? "breakbulk",
      # The Cargo workspace's directory in the repository (a path), for a
      # test runner that reads the project's configuration.
      workspaceDir ? null,
    }:
    let
      useCa = ca;
      caAttrs = lib.optionalAttrs useCa (
        featureGates.caAttrs nixFeatures "the test runs of `${name}` (`ca`)"
      );
      # The predicted platform picks the run's system, so it must be known
      # at evaluation time; instantiation checks it against the plan.
      platforms = testPlatforms {
        inherit pkgs tools host;
        target = {
          triple = target;
          inherit
            runner
            testSystem
            dylibPath
            testPkgs
            packageSet
            ;
        }
        // lib.optionalAttrs (traits != null) { inherit traits; };
      };
      platformOf = r: platforms.${r.breakbulkRoot.platform};
      jqOf = p: "${p.testPkgs.jq}/bin/jq";
      testRoots = lib.filterAttrs (_: r: r.breakbulkRoot.test) inst.roots;
      byPackage = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues testRoots);

      # Each run's settings, once: resolving them evaluates the package's
      # settings modules again.
      configs = lib.mapAttrs (
        pkg: rs:
        lib.listToAttrs (
          map (
            r:
            let
              key = binaryKey r.breakbulkRoot;
            in
            lib.nameValuePair key (runConfig packages pkg kind key)
          ) rs
        )
      ) byPackage;
      configOf = r: configs.${r.breakbulkRoot.package}.${binaryKey r.breakbulkRoot};

      # Whether a run executes something other than the binary its spec
      # links: the output of its stages, or a content-addressed copy
      # (runBinary).
      copiesBinary = cfg: useCa || lib.any stages.isLive (lib.attrValues cfg.stages);

      # The binary, copied out of its wrapper; for a binary Cargo did not
      # build, the marker that makes the stages skip
      # (stages.noBinariesMarker; the run itself skips before it reads the
      # binary).
      copyOf =
        r: n:
        binaryCopy {
          inherit pkgs caAttrs;
          name = n;
          src = "\"$wrapper\"/root/*";
          attrs = { inherit (r.breakbulkRoot) wrapper; };
          prelude = ''
            reason=$(${pkgs.jq}/bin/jq -r '.reason // ""' "$wrapper/breakbulk-root.json")
            if [ -n "$reason" ]; then
              mkdir -p $out
              printf '%s\n' "$reason" > $out/${stages.noBinariesMarker}
              exit 0
            fi
          '';
        };

      runDir = pkg: runDirs.${pkg} or null;

      runInfoOf =
        r: cfg:
        runInfo {
          inherit pkgs caAttrs;
          inherit (r.breakbulkRoot) wrapper;
          name = "${name}-test-spec";
          stable = useCa;
          dylibPath = (platformOf r).dylibPath;
          narrowDir = runDir r.breakbulkRoot.package;
          linkRoot = !copiesBinary cfg;
        };

      # What both runners share: the skip check, the environment, the run's
      # env, PATH and `preRun` entries.
      prelude = p: cfg: ''
        info=$spec/breakbulk-root.json
        reason=$(${jqOf p} -r '.reason // ""' "$info")
        if [ -n "$reason" ]; then
          # As the test stub: the reason, in a file.
          printf 'skipped: %s\n' "$reason"
          printf '%s\n' "$reason" > $out
          exit 0
        fi
        ${envScript {
          jq = jqOf p;
          inherit (p) dylibPath;
          extra = lib.optional (p.libDir != null) p.libDir;
          stable = useCa;
        }}
        ${configScript p.testPkgs cfg}
        ${preRunScript cfg}
        log=${logFile}
      '';

      # hintScript, with the spec read from `$info`.
      hint =
        p: b: cfg:
        hintScript
          {
            inherit tools pkgs;
            inherit (p) testPkgs;
          }
          ''"$(${jqOf p} -c --arg package ${lib.escapeShellArg b.package} --arg widen ${lib.escapeShellArg (hintWiden cfg)} '.testSpec | {$package, packageDir, testOnly: (.testOnly // []), junk: (.junk // []), custom: (.custom // false), $widen}' "$info")"'';

      # The run: the binary, the working directory, the wrapper and the
      # test runner's script (`facts`, lib/test-runners.nix), its output
      # to the build log and `$log`; then a hint on failure, or the
      # `postRun` snippets.
      runScript =
        r: p: cfg: bin:
        let
          b = r.breakbulkRoot;
          wrapper = wrapperOf p.testPkgs cfg;
          facts = {
            pkgs = p.testPkgs;
            inherit (b) package;
            inherit kind;
            binary = {
              key = binaryKey b;
              inherit (b) kind;
              name = b.target;
            };
            inherit (cfg) args;
            inherit (b) platform;
            inherit (p) triple libDir;
            hostTriple = host.triple;
            targetTriple = target;
            launcher = launcherOf {
              pkgs = p.testPkgs;
              inherit (p) runner;
              inherit wrapper;
            };
            withEnv = ''env "''${__bb_env[@]}"'';
            pathPackages = pathPackagesOf r;
            inherit workspaceDir;
          };
        in
        ''
          mkdir -p $out
          files=(${bin})
          binary=''${files[0]}
          ${lib.optionalString (wrapper != null) (sourceRootExport (jqOf p) null)}
          ${workdirScript p.testPkgs}
          __bb_workdir "$binary" "$CARGO_MANIFEST_DIR"
          cd "$__bb_wd"
          set +e
          (
            ${cfg.runner facts}
          ) 2>&1 | tee "$log"
          status=''${PIPESTATUS[0]}
          set -e
          if [ "$status" -ne 0 ]; then
            echo "test binary ${b.package} ${binaryKey b} failed (exit status $status)" >&2
            ${hint p b cfg}
            exit "$status"
          fi
          ${postRunScript { inherit cfg; }}
        '';

      # The path-package graph of a test root (TestSpec's `pathPackages`),
      # for a test runner that reads it (`facts.pathPackages`), in a file of
      # its own: a run whose runner does not read it does not depend on
      # it, so a change to another package's targets does not re-run it.
      pathPackagesOf =
        r:
        pkgs.runCommand "${name}-path-packages"
          (
            caAttrs
            // {
              inherit (r.breakbulkRoot) wrapper;
              nativeBuildInputs = [ pkgs.jq ];
            }
          )
          ''
            jq -c '.testSpec // {} | {packageId, packages: .pathPackages}' "$wrapper/breakbulk-root.json" > $out
          '';

      run =
        r:
        let
          b = r.breakbulkRoot;
          p = platformOf r;
          key = binaryKey b;
          n = storeName "${b.package}-${key}";
          cfg = configOf r;
          info = runInfoOf r cfg;
          bin =
            if copiesBinary cfg then
              runBinary {
                inherit pkgs cfg nixFeatures;
                name = n;
                ca = useCa;
                platform = p;
                linked = copyOf r n;
                copy = copyOf r n;
              }
            else
              "${info.out}/root";
          inputs = {
            spec = info.out;
          }
          // lib.optionalAttrs useCa { specDylibs = info.dylibs; };
        in
        p.testPkgs.runCommand "${name}-${n}-run" (
          {
            passthru = {
              breakbulkTest = {
                package = b.package;
                binary = key;
                inherit (cfg) args;
                # The package directory of its "run" view, or null.
                runDir = runDir b.package;
              };
              binary = bin;
              # The test root, whose wrapper (`breakbulkRoot.wrapper`)
              # says what the run reads, and what it reads of it
              # (`runInfo`).
              root = r;
              spec = info;
              # Whether the run is in repo.checks (its `enable`).
              enabled = cfg.enable;
            };
          }
          // inputs
          // caAttrs
        ) (prelude p cfg + runScript r p cfg "${bin}/*");

      runs = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (binaryKey r.breakbulkRoot) (run r)) rs)
      ) byPackage;

      # Each with `enabled`: whether it is in repo.checks
      # (`test.doctest.enable`).
      doctests = lib.optionalAttrs (kind == "test") (
        lib.mapAttrs (pkg: d: d // { enabled = doctestEnabled packages pkg; }) inst.doctests
      );

      checks =
        lib.concatMapAttrs (
          pkg: bs:
          lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
            lib.filterAttrs (b: _: configs.${pkg}.${b}.enable) bs
          )
        ) runs
        // lib.mapAttrs' (pkg: d: lib.nameValuePair "doctest/${pkg}" d) (
          lib.filterAttrs (pkg: _: doctestEnabled packages pkg) doctests
        );
    in
    {
      inherit
        runs
        checks
        testPkgs
        doctests
        ;
      # Test roots by package and binary key, for mkTestApps.
      roots = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (binaryKey r.breakbulkRoot) r) rs)
      ) byPackage;
      inherit platforms;
    };

}
