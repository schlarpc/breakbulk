# Test runs and doctests ("Tests as products" in docs/design.md; "Tests" in
# docs/implementation.md).
#
#   t = breakbulk.testRuns.mkTestRuns {
#     pkgs;
#     plan;          # the test plan derivation ($out/plan.json)
#     inst;          # breakbulk.instantiate's result for that plan
#     sources;       # { workspace; crates; } as given to instantiate
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
#     coverage = false;   # coverage variants: LLVM_PROFILE_FILE points into
#                         # $out/profraw, so each run keeps its profiles
#     name = "breakbulk";
#   };
#
#   t.runs.<pkg>.<binary>     one test-run derivation per test binary
#   t.doctests.<pkg>          one doctest derivation per library, with the
#                             runner, `test.args`, `test.includeIgnored`,
#                             `test.env` and `test.path` (not per-binary
#                             settings)
#   t.checks."test/<pkg>/<binary>", t.checks."doctest/<pkg>"
#                             every enabled run and every doctest
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
#   - its environment: the dynamic-library path, then the project's
#     `[env]` config variables (the plan's `configEnv`, with the values
#     Cargo gave the test unit), then the package's build script
#     `rustc-env` values, then `CARGO`, `CARGO_MANIFEST_DIR`,
#     `CARGO_MANIFEST_PATH` and `CARGO_PKG_*` from the test unit's recorded
#     env, then `test.env`, `test.path` on `PATH`, and
#     `RUST_TEST_THREADS=$NIX_BUILD_CORES`. Cargo applies `[env]` last but
#     never over a variable it set itself (`apply_env_config`), so `[env]`
#     loses to all of Cargo's own;
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
#   - `$out/log` holds the output; the run fails when the binary does.
#
# With `test.runner = "nextest"`, the same environment is set up, then
# cargo-nextest runs the one binary in its reuse-build mode from
# synthesized metadata (`nextestSpec`), with the package's
# `test.nextest.profile` and `configFile`; libtest arguments go after
# `--`. nextest's store (junit and the like) is copied to `$out/nextest`.
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
    fromJSON
    isString
    readFile
    toJSON
    unsafeDiscardStringContext
    ;

  noCtx = v: unsafeDiscardStringContext (toString v);

  # The key of a test binary within its package.
  binaryKey = r: if r.kind == "test" then r.target else "${r.kind}/${r.target}";

  storeName = s: lib.replaceStrings [ "/" ] [ "-" ] s;

  # The variable that holds the dynamic-library path of a recorded
  # process: the build machine's, since every recorded process (rustc,
  # build scripts) ran there (Cargo's `dylib_path_envvar` for its host;
  # breakbulk_unit::splice::DYLIB_PATH_VAR).
  hostDylibPathVar = pkgs: (targetTraits.resolve { triple = targetTraits.nativeTriple pkgs.buildPackages; }).dylibPathVar;

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

  # Values of the recorded env that a test process gets at run time: one
  # list for both delivery modes, crates/breakbulk-instantiate's
  # runtime-env.json (its `description` says why each is there), which
  # breakbulk-instantiate reads too (`is_runtime_var` in dynamic.rs).
  runtimeEnv = builtins.fromJSON (builtins.readFile ../crates/breakbulk-instantiate/src/runtime-env.json);
  isRuntimeVar = k: lib.elem k runtimeEnv.exact || lib.any (p: lib.hasPrefix p k) runtimeEnv.prefixes;

  # The dynamic-library path, computed at run time from the runs' `flags`
  # outputs: every search path value (sorted by path component, as Cargo's
  # BTreeSet<PathBuf> does, then deduplicated), without its kind prefix,
  # kept when the printing run classified it as inside its own `out` or an
  # upstream run's (`inOutDir`/`inBuildDir`, `LibraryPath::for_dylib_path`
  # in breakbulk-unit), joined with `sep`. The filter comes first: a value
  # one run printed inside its `out` is kept even if another run printed it
  # too.
  dylibJqWith = sep: ''
    def strip: if test("^(native|crate|dependency|framework|all)=") then sub("^[a-z]+="; "") else . end;
    [inputs | .libraryPaths[] | select(.inOutDir or (.inBuildDir // false)) | .value]
    | unique_by(split("/"))
    | map(strip)
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
    hostDylibPathVar
    exportDylib
    ;

  # Decision 94: what test runs read from the Rust toolchain, the shared
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

  # Resolve plan text (a string, or a list of pieces) to a string with
  # string context: `src`, `crateSrc` and `out` references as instantiation
  # resolves them, and a literal store path at the start of a value as the
  # tool it lies in.
  mkResolver =
    {
      plan,
      units,
      sources,
      tools,
    }:
    let
      workspace = sources.workspace or { };
      crates = sources.crates or { };
      skeleton = lib.removeSuffix "/" plan.skeletonRoot;
      dirOf =
        id:
        let
          url = lib.removePrefix "path+file://" id;
          path = lib.head (lib.splitString "#" (lib.head (lib.splitString "?" url)));
          rel = lib.removePrefix "/" (lib.removePrefix skeleton path);
        in
        if lib.hasPrefix "path+file://" id && lib.hasPrefix skeleton path then
          rel
        else
          throw "breakbulk: ${id} is not a path package under ${skeleton}";
      relSuffix = rel: if rel == "" then "" else "/${rel}";
      toolList = lib.sort (a: b: lib.stringLength a.path > lib.stringLength b.path) (
        lib.mapAttrsToList (n: v: {
          path = noCtx v;
          value = v;
        }) tools
      );
      literal =
        s:
        let
          t = lib.findFirst (t: lib.hasPrefix t.path s) null toolList;
        in
        if t == null then s else "${t.value}${lib.removePrefix t.path s}";
      piece =
        p:
        if isString p then
          literal p
        else if p ? src then
          "${workspace.${dirOf p.src} or (throw "breakbulk: no source view for ${p.src}")}${relSuffix p.rel}"
        else if p ? crateSrc then
          "${crates.${p.crateSrc}}${relSuffix p.rel}"
        else
          let
            u = plan.units.${p.out};
            output =
              if u.kind == "run" then
                "out"
              else if p.output == "bin" then
                "out"
              else
                p.output;
          in
          "${units.${p.out}.${output}}${if p ? file then "/${p.file}" else ""}";
      text = t: if isString t then literal t else lib.concatMapStrings piece t;
    in
    {
      inherit text dirOf;
    };

  # What one test binary needs to run, shared by test runs and test apps.
  runSpec =
    {
      plan,
      units,
      resolve,
      sysroot ? null,
      target,
      root,
      # dylibPathOf's result for the target.
      dylibPath,
      # hostDylibPathVar: Cargo sets it on test processes itself.
      hostVar,
    }:
    let
      unit = plan.units.${root.unit};
      env = lib.mapAttrs (_: resolve.text) (lib.filterAttrs (k: _: isRuntimeVar k) unit.env);
      configEnv = lib.mapAttrs (_: resolve.text) (
        lib.filterAttrs (
          k: _: lib.elem k (plan.configEnv or [ ]) && !isRuntimeVar k && k != hostVar
        ) unit.env
      );
      manifest =
        unit.env.CARGO_MANIFEST_DIR
          or (throw "breakbulk: the test unit ${root.unit} has no CARGO_MANIFEST_DIR");
      manifestRef = lib.findFirst (p: !isString p && p ? src) null (
        if isString manifest then [ ] else manifest
      );
      runs = lib.filterAttrs (_: u: u.kind == "run" && u.platform == unit.platform) plan.units;
    in
    {
      package = root.package;
      binary = binaryKey root;
      name = storeName "${root.package}-${binaryKey root}";
      # The unit's output: a directory holding the one binary.
      unitOut = units.${root.unit}.out;
      inherit env configEnv;
      # The package directory, relative to the repository root.
      packageDir = if manifestRef == null then null else manifestRef.rel;
      sourceDir = env.CARGO_MANIFEST_DIR;
      # Runs whose `rustc-env` values the process gets: the package's build
      # script (Cargo's `script_metas`).
      envFlags = map (s: units.${s.splice}.flags) unit.envSplices;
      dylib = {
        flags = lib.mapAttrsToList (id: _: units.${id}.flags) runs;
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

  # Decision 61: stable inputs for content-addressed test runs. A run spec
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
  stableSpec =
    {
      pkgs,
      spec,
      caAttrs,
      name,
    }:
    let
      sep = (specDylib spec).sep;
      dylibs = pkgs.runCommand "${name}-test-dylibs" (caAttrs // { nativeBuildInputs = [ pkgs.jq ]; }) ''
        mkdir -p $out/dylib
        shopt -s nullglob
        paths=$(jq -rn ${lib.escapeShellArg (dylibJqWith sep)} ${
          lib.concatMapStringsSep " " (f: lib.escapeShellArg "${f}/directives.json") spec.dylib.flags
        })
        IFS=${lib.escapeShellArg sep} read -ra ps <<< "$paths"
        i=0
        for p in "''${ps[@]}"; do
          d=$out/dylib/$(printf %04d $i)
          mkdir -p "$d"
          for f in "$p"/*; do
            if [ -e "$f" ] && [ ! -d "$f" ]; then cp -L "$f" "$d/"; fi
          done
          i=$((i + 1))
        done
      '';
      env = pkgs.runCommand "${name}-${storeName spec.package}-rustc-env" (
        caAttrs // { nativeBuildInputs = [ pkgs.jq ]; }
      ) ''
        mkdir -p $out
        jq -s '{env: (map(.env) | add)}' ${
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

  # Decision 17, `test.stripForRun`: shell lines defining `stripForRun`,
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

  # Decision 61, `test.runFiles`: a spec whose working directory and
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
    }
    // t
    // {
      nextest = {
        profile = "default";
        configFile = null;
        package = null;
      }
      // lib.filterAttrs (_: v: v != null) (t.nextest or { });
    };

  # What nextest's reuse-build mode reads for one test binary: the
  # metadata breakbulk-instantiate synthesizes for both delivery modes
  # (`nextest_for` in crates/breakbulk-instantiate/src/dynamic.rs, which
  # says why each field is what it is), from the root's `nextest` in
  # units.json, with the source view's root (`@VIEW@`) and the target's
  # sysroot library directory (`"@LIBDIR@"`) filled in here. `@BINARY@`,
  # `@TARGET@` and `@WS@` are filled in by the test run.
  nextestSpec =
    {
      plan,
      resolve,
      spec,
      root,
      sysroot ? null,
    }:
    let
      unit = plan.units.${root.unit};
      pkgId = unit.package;
      viewRoot =
        let
          rel = resolve.dirOf pkgId;
          dir = noCtx spec.sourceDir;
        in
        if rel == "" then
          spec.sourceDir
        else if lib.hasSuffix "/${rel}" dir then
          lib.removeSuffix "/${rel}" spec.sourceDir
        else
          throw "breakbulk: nextest: the source view ${dir} does not end in ${rel}";
      # The sysroot's target library directory, which the run's
      # dynamic-library path already ends with; without it nextest warns.
      libdir =
        if sysroot != null then
          {
            status = "available";
            path = "${sysroot}/lib/rustlib/${plan.target}/lib";
          }
        else
          {
            status = "unavailable";
            reason = "breakbulk";
          };
      n =
        root.nextest
          or (throw "breakbulk: nextest: units.json has no nextest metadata for ${root.package} ${root.target}");
    in
    {
      inherit (n) binaryId;
      cargoMetadata = builtins.replaceStrings [ "@VIEW@" ] [ viewRoot ] n.cargoMetadata;
      binaries = builtins.replaceStrings [ "\"@LIBDIR@\"" ] [ (toJSON libdir) ] n.binaries;
    };

  binaryConfig =
    cfg: binary:
    {
      args = [ ];
      enable = true;
    }
    // (cfg.binaries.${binary} or { });

  # The attributes a package's doctest derivation gets from its test
  # configuration: the runner (a list), `test.args` with
  # `--include-ignored` when `test.includeIgnored`, and `test.env` with
  # `test.path` as PATH. Dynamic-derivation mode passes the same strings to
  # its outer derivation (lib/dynamic.nix), so both modes write the same
  # doctest derivation.
  doctestConfig =
    {
      packages,
      runner ? null,
    }:
    pkg:
    let
      cfg = testConfig packages pkg;
    in
    {
      BREAKBULK_TEST_RUNNER = toJSON (if runner == null then [ ] else lib.toList runner);
      BREAKBULK_TEST_ARGS = toJSON (cfg.args ++ lib.optional cfg.includeIgnored "--include-ignored");
      BREAKBULK_TEST_ENV = toJSON (
        cfg.env // lib.optionalAttrs (cfg.path != [ ]) { PATH = lib.makeBinPath cfg.path; }
      );
    };

  # libtest arguments of one binary.
  testArgs =
    cfg: binary:
    cfg.args ++ (binaryConfig cfg binary).args ++ lib.optional cfg.includeIgnored "--include-ignored";

  mkTestRuns =
    {
      pkgs,
      plan,
      inst,
      sources,
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
      planJson = fromJSON (unsafeDiscardStringContext (readFile "${plan}/plan.json"));
      inherit (inst) units;
      resolve = mkResolver {
        plan = planJson;
        inherit units sources tools;
      };
      useCa = if ca == null then stages.caAuto else ca;
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
          plan = planJson;
          inherit
            units
            resolve
            sysroot
            target
            dylibPath
            ;
          hostVar = hostDylibPathVar pkgs;
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
            plan = planJson;
            inherit resolve sysroot;
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
            ${envScript {
              spec = s;
              jq = "${testPkgs.jq}/bin/jq";
            }}
            ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") cfg.env)}
            ${lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}"}
            export RUST_TEST_THREADS=$NIX_BUILD_CORES
            ${lib.optionalString (
              runnerList != [ ]
            ) "export ${runnerVar}=${lib.escapeShellArg (lib.concatStringsSep " " runnerList)}"}
            ${lib.optionalString coverage ''
              mkdir -p $out/profraw
              export LLVM_PROFILE_FILE=$out/profraw/%m-%p.profraw
            ''}
            ws=$TMPDIR/nextest-ws
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
              --no-tests=warn --color never \
              ${lib.optionalString (args != [ ]) "-- ${lib.escapeShellArgs args}"} 2>&1 | tee $out/log
            status=''${PIPESTATUS[0]}
            set -e
            if [ -d $ws/target/nextest ]; then
              cp -r $ws/target/nextest $out/nextest
            fi
            if [ "$status" -ne 0 ]; then
              echo "test binary ${s.package} ${s.binary} failed under nextest (exit status $status)" >&2
              exit "$status"
            fi
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
              ${envScript {
                spec = s;
                jq = "${testPkgs.jq}/bin/jq";
              }}
              ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") cfg.env)}
              ${lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}"}
              export RUST_TEST_THREADS=$NIX_BUILD_CORES
              ${lib.optionalString coverage ''
                mkdir -p $out/profraw
                export LLVM_PROFILE_FILE=$out/profraw/%m-%p.profraw
              ''}
              mkdir -p /tmp/breakbulk-target-tmp $out
              files=(${bin}/*)
              cd ${lib.escapeShellArg s.sourceDir}
              set +e
              env "''${__bb_env[@]}" ${lib.escapeShellArgs runnerList} "''${files[0]}" ${lib.escapeShellArgs args} 2>&1 | tee $out/log
              status=''${PIPESTATUS[0]}
              set -e
              if [ "$status" -ne 0 ]; then
                echo "test binary ${s.package} ${s.binary} failed (exit status $status)" >&2
                exit "$status"
              fi
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
        pkg: attrs: derivation (attrs // doctestConfig { inherit packages runner; } pkg)
      ) (inst.doctestAttrs or { });

      checks =
        lib.concatMapAttrs (
          pkg: bs:
          lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
            lib.filterAttrs (b: _: (binaryConfig (testConfig packages pkg) b).enable) bs
          )
        ) runs
        // lib.mapAttrs' (pkg: d: lib.nameValuePair "doctest/${pkg}" d) doctests;
    in
    {
      inherit
        runs
        doctests
        checks
        specs
        testPkgs
        ;
      plan = planJson;
      runner = runnerList;
    };
}
