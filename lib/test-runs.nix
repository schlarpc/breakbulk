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
#     packages = { };     # packages.<name>.test, as in the module options
#     ca = null;          # null: automatic (stages.caAuto); true; false
#     coverage = false;   # coverage variants: each run keeps its profiles
#                         # in $out/profraw (`postRunSnippets`)
#     name = "breakbulk";
#   };
#
#   t.runs.<pkg>.<binary>     one test-run derivation per test binary
#   t.doctests.<pkg>          one doctest derivation per library, with the
#                             runner, `test.args`, `test.includeIgnored`,
#                             `test.env`, `test.path` and `test.doctest`
#                             (not per-binary settings)
#   t.checks."test/<pkg>/<binary>", t.checks."doctest/<pkg>"
#                             every enabled run and doctest
#   t.specs.<pkg>.<binary>    what a run needs (lib/test-apps.nix uses it)
#
# Binary names within a package: an integration test by its name (`it`);
# the library's unit tests as `lib/<lib name>`; a bin's as `bin/<bin name>`;
# an example or bench built as a test as `example/<name>`, `bench/<name>`.
# Integration test names cannot contain `/`, so names never collide.
#
# A test run, as `cargo test` runs a test binary (Cargo's `cmd_builds` and
# `Compilation::fill_env`, `src/cargo/ops/cargo_test.rs` and
# `src/cargo/core/compiler/compilation.rs`):
#
#   - the binary (a content-addressed copy when `ca`, so that a
#     byte-identical binary is not re-run) runs under the target's runner,
#     in the package directory of its source view, with `test.args`,
#     `test.binaries.<binary>.args` and `--include-ignored` when
#     `test.includeIgnored`;
#   - its environment: a fresh, empty `HOME` in `$TMPDIR` (`homeScript`),
#     then the dynamic-library path, then the project's
#     `[env]` config variables (the plan's `configEnv`, with the values
#     Cargo gave the test unit), then the package's build script
#     `rustc-env` values, then `CARGO`, `CARGO_MANIFEST_DIR`,
#     `CARGO_MANIFEST_PATH` and `CARGO_PKG_*` from the test unit's recorded
#     env, then `test.env`, then `test.binaries.<binary>.env`, `test.path`
#     on `PATH`, and last `RUST_TEST_THREADS=$NIX_BUILD_CORES` only when
#     none of these set it. Cargo applies `[env]` last but never over a
#     variable it set itself (`apply_env_config`), so `[env]` loses to all
#     of Cargo's own;
#   - the dynamic-library path (the target's variable, `dylibPathOf`:
#     LD_LIBRARY_PATH on Linux, WINEPATH under wine, none for wasm) holds,
#     sorted as Cargo sorts paths, the
#     search paths printed by any run of the test's platform that lie inside
#     the printing run's `out` or the `out` of a run it received `DEP_*`
#     metadata from (Cargo: inside the target's output directory; the same
#     rule as for compiles, runs and doctests, `LibraryPath::for_dylib_path`
#     in breakbulk-unit), then the sysroot's target library directory;
#   - `/tmp/breakbulk-target-tmp`, the planner's `CARGO_TARGET_TMPDIR`, is
#     created first;
#   - the output goes to the build log and to `$log` in $TMPDIR, not to
#     `$out`: it holds timings and, with several test threads, lines in a
#     varying order, and `nix build --rebuild` compares every output. `$out`
#     is an empty directory, unless a `test.postRun` snippet (or `keepLog`)
#     puts something there after a passing run (`postRunScript`);
#   - the run fails when the binary does.
#
# With `test.runner = "nextest"`, the same environment is set up, then
# cargo-nextest runs the one binary in its reuse-build mode from the
# metadata breakbulk-instantiate synthesizes (`nextestSpec`), with the
# package's `test.nextest.profile` and `configFile`; libtest arguments go
# after `--`. nextest's `test-threads` defaults to `$NIX_BUILD_CORES`;
# the project's configuration and `NEXTEST_TEST_THREADS` override it.
# nextest's store (junit and the like) is `$nextestDir` for `test.postRun`.
#
# What each run needs from the plan (env, `[env]` values, the runs for the
# dynamic-library path and `rustc-env`, nextest's metadata) comes from
# breakbulk-instantiate, through `units.json` (`runSpec`).
#
# Test binaries the plan lacks (required features) are instantiation's
# stubs, which succeed and log why.
{
  lib,
  stages,
  util,
  targetTraits,
  runners,
}:
let
  inherit (builtins)
    replaceStrings
    toJSON
    ;

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

  # What test runs read from the Rust toolchain, the shared
  # libraries of the sysroot's target library directory (`libstd-*.so`, for
  # binaries linked with `-C prefer-dynamic` and the like), copied into a
  # small derivation laid out as a sysroot (`lib/rustlib/<target>/lib`).
  # Depending on the whole sysroot instead (over 1 GB) would make every
  # test run on a fresh machine fetch the toolchain. `null` without one.
  testLibs =
    pkgs: sysroot: target:
    if sysroot == null then
      null
    else
      pkgs.runCommand "rust-test-libs-${target}" { } ''
        dir=lib/rustlib/${target}/lib
        mkdir -p "$out/$dir"
        for f in ${sysroot}/$dir/*; do
          case "''${f##*/}" in
            *.so|*.so.*|*.dylib|*.dll) cp -L "$f" "$out/$dir/" ;;
          esac
        done
      '';

  # What one test binary needs to run, shared by test runs and test apps:
  # the root's test spec as breakbulk-instantiate computes it for both
  # delivery modes (`test_spec` in crates/breakbulk-instantiate/src/
  # dynamic.rs; dynamic mode reads the same from breakbulk-root.json), and
  # what only this side knows: the sysroot and the target's dylib variable.
  runSpec =
    {
      units,
      sysroot ? null,
      target,
      root,
      # dylibPathOf's result for the target.
      dylibPath,
    }:
    let
      t =
        root.testSpec
          or (throw "breakbulk: units.json has no test spec for ${root.package} ${root.target}");
    in
    {
      package = root.package;
      binary = binaryKey root;
      name = storeName "${root.package}-${binaryKey root}";
      # The unit's output: a directory holding the one binary.
      unitOut = units.${root.unit}.out;
      inherit (t) env configEnv envFlags;
      # The package directory, relative to the repository root.
      inherit (t) packageDir;
      sourceDir =
        t.env.CARGO_MANIFEST_DIR
          or (throw "breakbulk: the test unit ${root.unit} has no CARGO_MANIFEST_DIR");
      dylib = {
        flags = t.dylibFlags;
        extra = lib.optional (sysroot != null) "${sysroot}/lib/rustlib/${target}/lib";
      }
      # The variable and separator, when not LD_LIBRARY_PATH and `:`.
      // lib.optionalAttrs (dylibPath != linuxDylib) { path = dylibPath; };
    };

  linuxDylib = {
    var = "LD_LIBRARY_PATH";
    sep = ":";
  };
  # A spec's dynamic-library variable ({ var; sep; } or null).
  specDylib = spec: spec.dylib.path or linuxDylib;

  # Shell lines that set up a test process's environment from a spec, for
  # bash. `jq` is the jq executable; `vars` replaces values of `spec.env`.
  envScript =
    {
      spec,
      jq,
      vars ? { },
    }:
    let
      dylibs = lib.concatMapStringsSep " " (
        f: lib.escapeShellArg "${f}/directives.json"
      ) spec.dylib.flags;
      env = spec.env // vars;
      d = specDylib spec;
    in
    ''
      __bb_env=()
    ''
    + lib.optionalString (d != null) ''
      __bb_dylib=${
        if spec.dylib.flags == [ ] then
          "''"
        else
          "$(${jq} -rn ${lib.escapeShellArg (dylibJqWith d.sep)} ${dylibs})"
      }
      ${
        # Empty when off, so test runs without stable inputs are unchanged.
        lib.optionalString (spec.dylib.stable or null != null) ''
          for __bb_p in ${spec.dylib.stable}/dylib/*; do
            __bb_dylib=''${__bb_dylib:+$__bb_dylib${d.sep}}$__bb_p
          done
        ''
      }${exportDylib d spec.dylib.extra}unset __bb_dylib __bb_p
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") (spec.configEnv or { })
    )
    + lib.concatMapStrings (f: ''
      eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' ${lib.escapeShellArg "${f}/directives.json"})"
    '') spec.envFlags
    + lib.concatStrings (lib.mapAttrsToList exportOrEnv env);

  # `export` for a name the shell takes, else an entry of `__bb_env`, which
  # the run passes through `env`: Cargo's `CARGO_BIN_EXE_<bin>` keeps the
  # bin's name, hyphens included.
  exportOrEnv =
    k: v:
    if builtins.match "[A-Za-z_][A-Za-z0-9_]*" k != null then
      "export ${k}=${lib.escapeShellArg v}\n"
    else
      "__bb_env+=(${lib.escapeShellArg "${k}=${v}"})\n";

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

  # Stable inputs for content-addressed test runs. A run spec
  # names the `flags` of every build-script run of its platform
  # (the dynamic-library path, as Cargo builds it) and the `flags` of its
  # package's build script (`rustc-env`). Those are input-addressed, so an
  # edit to any package with a build script gives them new paths and
  # re-runs every test, even when nothing they hold changed. This returns
  # the spec with both replaced by small content-addressed copies:
  #
  #   - `<name>-test-dylibs`: `dylib/<NNNN>/` per dynamic-library path entry,
  #     in order, holding the entry's files (not its subdirectories, which
  #     the dynamic loader never searches), symlinks resolved;
  #     `spec.dylib.stable` (envScript puts each on the path);
  #   - `<name>-<package>-rustc-env`: `directives.json` with only the
  #     `rustc-env` values, in order (`spec.envFlags`).
  #
  # Identical contents give identical paths, so the test run (also
  # content-addressed) is not re-run. Only used when `ca` is on.
  # Dynamic-derivation mode makes the same copies at build time
  # (lib/dynamic.nix `stableInfo`).
  stableSpec =
    {
      pkgs,
      spec,
      caAttrs,
      name,
    }:
    let
      dylibs = pkgs.runCommand "${name}-test-dylibs" (caAttrs // { nativeBuildInputs = [ pkgs.jq ]; }) ''
        __bb_flags=(${
          lib.concatMapStringsSep " " (f: lib.escapeShellArg "${f}/directives.json") spec.dylib.flags
        })
        ${copyDylibsScript (specDylib spec).sep}
      '';
      env = pkgs.runCommand "${name}-${storeName spec.package}-rustc-env" (
        caAttrs // { nativeBuildInputs = [ pkgs.jq ]; }
      ) ''
        mkdir -p $out
        jq -s ${lib.escapeShellArg mergeRustcEnvJq} ${
          lib.concatMapStringsSep " " (f: lib.escapeShellArg "${f}/directives.json") spec.envFlags
        } > $out/directives.json
      '';
    in
    spec
    // {
      dylib = spec.dylib // {
        flags = [ ];
        stable = if spec.dylib.flags == [ ] || specDylib spec == null then null else dylibs;
      };
      envFlags = lib.optional (spec.envFlags != [ ]) env;
    };

  # `test.stripForRun`: shell lines defining `stripForRun`,
  # which strips debug info from the copy of a test binary its run
  # consumes, so the source paths that the debug info of workspace
  # libraries holds do not change the run's input. The GNU build ID goes
  # too: the linker computes it over the whole file, debug info included.
  # A file that is not ELF is left as it is.
  stripScript = ''
    stripForRun() {
      chmod u+w "$1"
      if [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
        objcopy --strip-debug --remove-section=.note.gnu.build-id "$1"
      else
        echo "stripForRun: $1 is not ELF; left unchanged"
      fi
    }
  '';

  # The copy of a test binary a run executes, from `src` (a shell glob
  # matching the one file): content-addressed when `caAttrs` says so,
  # debug-stripped with `strip`. `prelude` runs first; `attrs` are extra
  # derivation attributes.
  binaryCopy =
    {
      pkgs,
      name,
      caAttrs,
      strip,
      src,
      prelude ? "",
      attrs ? { },
    }:
    pkgs.runCommand "${name}-bin${lib.optionalString strip "-stripped"}"
      (
        attrs
        // caAttrs
        // lib.optionalAttrs strip { nativeBuildInputs = [ pkgs.binutils-unwrapped-all-targets ]; }
      )
      ''
        ${prelude}
        files=(${src})
        [ ''${#files[@]} -eq 1 ] || { echo "expected one file in ${src}" >&2; exit 1; }
        mkdir -p $out
        cp "''${files[0]}" $out/
        ${lib.optionalString strip ''
          ${stripScript}
          stripForRun "$out/''${files[0]##*/}"
        ''}
      '';

  # `test.runFiles`: a spec whose working directory and
  # runtime CARGO_MANIFEST_DIR are `dir`, the package directory of a view
  # holding only the listed files (lib/workspace.nix `runFilesDirs`).
  narrowSpec =
    dir: spec:
    spec
    // {
      sourceDir = dir;
      env = spec.env // {
        CARGO_MANIFEST_DIR = dir;
        CARGO_MANIFEST_PATH = "${dir}/Cargo.toml";
      };
    };

  # The package's test configuration, with defaults.
  testConfig =
    packages: pkg:
    let
      # Options left `null` take the defaults.
      t = lib.filterAttrs (_: v: v != null) (packages.${pkg}.test or { });
    in
    {
      env = { };
      path = [ ];
      args = [ ];
      includeIgnored = false;
      binaries = { };
      runner = "libtest";
      stripForRun = false;
      runFiles = null;
      postRun = "";
      keepLog = false;
    }
    // t
    // {
      doctest = {
        args = [ ];
        env = { };
        postRun = "";
        enable = true;
      }
      // lib.filterAttrs (_: v: v != null) (t.doctest or { });
      nextest = {
        profile = "default";
        configFile = null;
        package = null;
      }
      // lib.filterAttrs (_: v: v != null) (t.nextest or { });
    };

  # What nextest's reuse-build mode reads for one test binary: the
  # metadata breakbulk-instantiate synthesizes (`nextest_for` in
  # crates/breakbulk-instantiate/src/dynamic.rs, which says why each field
  # is what it is), with the target's sysroot library directory
  # (`"@LIBDIR@"`) filled in here. With `test.runFiles` (`spec` narrowed),
  # the tested package's manifest is in the narrowed view, as in dynamic
  # mode. `@BINARY@`, `@TARGET@` and `@WS@` are filled in by the test run.
  nextestSpec =
    {
      root,
      spec,
      target,
      sysroot ? null,
    }:
    let
      n = root.testSpec.nextest;
      orig = root.testSpec.env.CARGO_MANIFEST_DIR;
      # The sysroot's target library directory, which the run's
      # dynamic-library path already ends with; without it nextest warns.
      libdir =
        if sysroot != null then
          {
            status = "available";
            path = "${sysroot}/lib/rustlib/${target}/lib";
          }
        else
          {
            status = "unavailable";
            reason = "breakbulk";
          };
    in
    {
      inherit (n) binaryId;
      cargoMetadata =
        if spec.sourceDir == orig then
          n.cargoMetadata
        else
          replaceStrings [ (toJSON "${orig}/Cargo.toml") ] [ (toJSON "${spec.sourceDir}/Cargo.toml") ]
            n.cargoMetadata;
      binaries = replaceStrings [ "\"@LIBDIR@\"" ] [ (toJSON libdir) ] n.binaries;
    };

  binaryConfig =
    cfg: binary:
    {
      args = [ ];
      env = { };
      postRun = "";
      enable = true;
    }
    // (cfg.binaries.${binary} or { });

  # A run's raw output, besides the build log: `$log` in `test.postRun`.
  logFile = "$TMPDIR/breakbulk-test.log";

  # Coverage: the profiles go to $TMPDIR, and a snippet of
  # `postRunSnippets` moves them into $out. LLVM_PROFILE_FILE's `%p` (the
  # process ID) differs on every run, so they are renamed by content.
  # The counters themselves can still differ (hash seeds, timing), so
  # coverage runs are outside the `--rebuild` guarantee.
  coverageEnvScript = coverage: lib.optionalString coverage ''
    mkdir -p $TMPDIR/profraw
    export LLVM_PROFILE_FILE=$TMPDIR/profraw/%m-%p.profraw
  '';
  coverageCollect = ''
    mkdir -p "$out/profraw"
    for f in "$TMPDIR"/profraw/*.profraw; do
      [ -e "$f" ] || continue
      b=''${f##*/}
      cp "$f" "$out/profraw/''${b%-*}-$(sha256sum "$f" | cut -c1-32).profraw"
    done
  '';

  # What runs after a passing run, in order: breakbulk's own (coverage),
  # the package's `test.postRun`, the binary's (`binary`: its key) or,
  # without a binary, the doctest run's, then `keepLog`'s copy.
  postRunSnippets =
    {
      cfg,
      binary ? null,
      coverage ? false,
    }:
    let
      own = if binary == null then cfg.doctest else binaryConfig cfg binary;
    in
    lib.optional coverage coverageCollect
    ++ lib.optional (cfg.postRun != "") cfg.postRun
    ++ lib.optional (own.postRun != "") own.postRun
    ++ lib.optional cfg.keepLog ''cp "$log" "$out/log"'';

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

  # Shell lines that export a test binary's configuration: `test.env`, then
  # `test.binaries.<binary>.env`, then `test.path` on PATH.
  configScript =
    cfg: binary:
    lib.concatStrings (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") (
        cfg.env // (binaryConfig cfg binary).env
      )
    )
    + lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}\n";

  # A test process's home: fresh, empty and writable, as a test's home is
  # under `cargo test`, without reading the user's (doctests get the same
  # from breakbulk-unit, `Outer::test_base`). It comes before the other
  # layers so that `[env]` and `test.env` can replace it. `XDG_*` stay
  # unset, so tools fall back to directories under it.
  homeScript = ''
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
  '';

  # Only a default: the variable may already hold a value from `[env]` or
  # the test configuration, which wins.
  threadsScript = ''
    export RUST_TEST_THREADS=''${RUST_TEST_THREADS:-$NIX_BUILD_CORES}
  '';

  # nextest does not read RUST_TEST_THREADS. Its default goes in a tool
  # config file, not NEXTEST_TEST_THREADS: nextest ranks that variable over
  # the project's `test-threads` and a tool config file under it, so the
  # user's variable and profile both still win.
  nextestThreadsScript = ''
    printf '[profile.default]\ntest-threads = %s\n' "$NIX_BUILD_CORES" > $TMPDIR/breakbulk-nextest.toml
  '';
  nextestThreadsFlag = "--tool-config-file breakbulk:$TMPDIR/breakbulk-nextest.toml";

  # The attributes a package's doctest derivation gets from its test
  # configuration: the runner (a list), `test.args` and
  # `test.doctest.args` with `--include-ignored` when
  # `test.includeIgnored`, and `test.env`, `test.doctest.env` and
  # `test.path` as PATH. Dynamic-derivation mode passes the same strings to
  # its outer derivation (lib/dynamic.nix), so both modes write the same
  # doctest derivation.
  doctestConfig =
    {
      pkgs,
      packages,
      runner ? null,
    }:
    pkg:
    let
      cfg = testConfig packages pkg;
      snippets = postRunSnippets { inherit cfg; };
    in
    {
      # A script, run in $TMPDIR with `$log` and `$out` set, after passing
      # doctests (breakbulk-unit's doctest.rs).
      BREAKBULK_TEST_POST_RUN =
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
      BREAKBULK_TEST_RUNNER = toJSON (if runner == null then [ ] else lib.toList runner);
      BREAKBULK_TEST_ARGS = toJSON (
        cfg.args ++ cfg.doctest.args ++ lib.optional cfg.includeIgnored "--include-ignored"
      );
      BREAKBULK_TEST_ENV = toJSON (
        cfg.env
        // cfg.doctest.env
        // lib.optionalAttrs (cfg.path != [ ]) { PATH = lib.makeBinPath cfg.path; }
      );
    };

  # Whether a package's doctest run is in the check set
  # (`test.doctest.enable`).
  doctestEnabled = packages: pkg: (testConfig packages pkg).doctest.enable;

  # libtest arguments of one binary.
  testArgs =
    cfg: binary:
    cfg.args ++ (binaryConfig cfg binary).args ++ lib.optional cfg.includeIgnored "--include-ignored";

  mkTestRuns =
    {
      pkgs,
      inst,
      tools,
      target,
      runner ? null,
      testSystem ? null,
      traits ? targetTraits.resolve { triple = target; },
      dylibPath ? dylibPathOf { inherit traits runner; },
      testPkgs ? runners.testPkgsFor { inherit pkgs testSystem; },
      packages ? { },
      # runFilesDirs.<package> = the package directory of its `test.runFiles`
      # view, for packages that set it (lib/workspace.nix).
      runFilesDirs ? { },
      ca ? null,
      coverage ? false,
      name ? "breakbulk",
    }:
    let
      inherit (inst) units;
      useCa = stages.resolveCa ca;
      caAttrs = lib.optionalAttrs useCa stages.caAttrs;
      runnerList = if runner == null then [ ] else lib.toList runner;
      # The sysroot's target libraries only (`testLibs`), laid out as a
      # sysroot.
      sysroot = testLibs pkgs (tools.rustc-sysroot or null) target;

      testRoots = lib.filterAttrs (_: r: r.breakbulkRoot.test) inst.roots;
      byPackage = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues testRoots);

      spec =
        r:
        runSpec {
          inherit
            units
            sysroot
            target
            dylibPath
            ;
          root = r.breakbulkRoot;
        };

      # The binary a run executes: a content-addressed copy when `ca`, a
      # debug-stripped one with `test.stripForRun`, else the unit's output.
      binaryOf =
        s: cfg:
        if !useCa && !cfg.stripForRun then
          s.unitOut
        else
          binaryCopy {
            inherit pkgs caAttrs;
            inherit (s) name;
            strip = cfg.stripForRun;
            src = "${s.unitOut}/*";
          };

      # A test run through nextest's reuse-build mode: nextest reads the
      # synthesized metadata (`nextestSpec`) and runs the one binary with
      # the project's nextest configuration (retries, timeouts, default
      # filter, test groups). libtest arguments go after `--`, which
      # nextest emulates (`--skip`, `--exact`, `--include-ignored`, …).
      nextestRun =
        r: s: cfg: args: bin:
        let
          nx = nextestSpec {
            inherit sysroot target;
            spec = s;
            root = r.breakbulkRoot;
          };
          nextest = if cfg.nextest.package != null then cfg.nextest.package else testPkgs.cargo-nextest;
          runnerVar = util.cargoTargetEnvVar target "RUNNER";
        in
        testPkgs.runCommand "${name}-${s.name}-run"
          (
            {
              passthru = {
                breakbulkTest = s // {
                  inherit args;
                  inherit (nx) binaryId;
                };
                binary = bin;
              };
              nextestCargoMetadata = nx.cargoMetadata;
              nextestBinaries = nx.binaries;
              passAsFile = [
                "nextestCargoMetadata"
                "nextestBinaries"
              ];
            }
            // caAttrs
          )
          ''
            ${homeScript}
            ${envScript {
              spec = s;
              jq = "${testPkgs.jq}/bin/jq";
            }}
            ${configScript cfg s.binary}
            ${threadsScript}
            ${nextestThreadsScript}
            ${lib.optionalString (
              runnerList != [ ]
            ) "export ${runnerVar}=${lib.escapeShellArg (lib.concatStringsSep " " runnerList)}"}
            ${coverageEnvScript coverage}
            ws=$TMPDIR/nextest-ws
            log=${logFile}
            mkdir -p /tmp/breakbulk-target-tmp $out $ws/target
            touch $ws/Cargo.toml
            files=(${bin}/*)
            subst() { sed -e "s|@BINARY@|''${files[0]}|g" -e "s|@TARGET@|$ws/target|g" -e "s|@WS@|$ws|g" "$1"; }
            subst "$nextestBinariesPath" > $TMPDIR/binaries-metadata.json
            subst "$nextestCargoMetadataPath" > $TMPDIR/cargo-metadata.json
            cd $TMPDIR
            set +e
            env "''${__bb_env[@]}" ${nextest}/bin/cargo-nextest nextest run \
              --binaries-metadata $TMPDIR/binaries-metadata.json \
              --cargo-metadata $TMPDIR/cargo-metadata.json \
              ${lib.optionalString (cfg.nextest.configFile != null) "--config-file ${cfg.nextest.configFile}"} \
              --profile ${lib.escapeShellArg cfg.nextest.profile} \
              ${nextestThreadsFlag} \
              --no-tests=warn --color never \
              ${lib.optionalString (args != [ ]) "-- ${lib.escapeShellArgs args}"} 2>&1 | tee "$log"
            status=''${PIPESTATUS[0]}
            set -e
            if [ "$status" -ne 0 ]; then
              echo "test binary ${s.package} ${s.binary} failed under nextest (exit status $status)" >&2
              exit "$status"
            fi
            nextestDir=$ws/target/nextest
            ${postRunScript {
              inherit cfg coverage;
              binary = s.binary;
            }}
          '';

      run =
        r:
        let
          cfg = testConfig packages r.breakbulkRoot.package;
          base = spec r;
          narrowed =
            if cfg.runFiles == null then
              base
            else
              narrowSpec (
                runFilesDirs.${base.package}
                  or (throw "breakbulk: packages.${base.package}.test.runFiles is set, but the package has no source view")
              ) base;
          s =
            if useCa then
              stableSpec {
                inherit pkgs caAttrs name;
                spec = narrowed;
              }
            else
              narrowed;
          args = testArgs cfg s.binary;
          bin = binaryOf s cfg;
        in
        if cfg.runner == "nextest" then
          nextestRun r s cfg args bin
        else if cfg.runner != "libtest" then
          throw "breakbulk: packages.${s.package}.test.runner must be \"libtest\" or \"nextest\", not ${toJSON cfg.runner}"
        else
          testPkgs.runCommand "${name}-${s.name}-run"
            (
              {
                passthru = {
                  breakbulkTest = s // {
                    inherit args;
                  };
                  binary = bin;
                };
              }
              // caAttrs
            )
            ''
              ${homeScript}
              ${envScript {
                spec = s;
                jq = "${testPkgs.jq}/bin/jq";
              }}
              ${configScript cfg s.binary}
              ${threadsScript}
              ${coverageEnvScript coverage}
              mkdir -p /tmp/breakbulk-target-tmp $out
              log=${logFile}
              files=(${bin}/*)
              cd ${lib.escapeShellArg s.sourceDir}
              set +e
              env "''${__bb_env[@]}" ${lib.escapeShellArgs runnerList} "''${files[0]}" ${lib.escapeShellArgs args} 2>&1 | tee "$log"
              status=''${PIPESTATUS[0]}
              set -e
              if [ "$status" -ne 0 ]; then
                echo "test binary ${s.package} ${s.binary} failed (exit status $status)" >&2
                exit "$status"
              fi
              ${postRunScript {
                inherit cfg coverage;
                binary = s.binary;
              }}
            '';

      runs = lib.mapAttrs (
        _: rs:
        lib.listToAttrs (
          map (
            r: lib.nameValuePair (binaryKey r.breakbulkRoot) (if r.breakbulkRoot.unit == null then r else run r)
          ) rs
        )
      ) byPackage;

      specs = lib.mapAttrs (
        _: rs:
        lib.listToAttrs (
          map (r: lib.nameValuePair (binaryKey r.breakbulkRoot) (spec r)) (
            lib.filter (r: r.breakbulkRoot.unit != null) rs
          )
        )
      ) byPackage;

      doctests = lib.mapAttrs (
        pkg: attrs: derivation (attrs // doctestConfig { inherit pkgs packages runner; } pkg)
      ) (inst.doctestAttrs or { });

      checks =
        lib.concatMapAttrs (
          pkg: bs:
          lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
            lib.filterAttrs (b: _: (binaryConfig (testConfig packages pkg) b).enable) bs
          )
        ) runs
        // lib.mapAttrs' (pkg: d: lib.nameValuePair "doctest/${pkg}" d) (
          lib.filterAttrs (pkg: _: doctestEnabled packages pkg) doctests
        );
    in
    {
      inherit
        runs
        doctests
        checks
        specs
        testPkgs
        ;
      runner = runnerList;
    };
}
