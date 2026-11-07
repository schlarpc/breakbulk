# Test runs and doctests ("Tests as products" in docs/design.md; "Tests" in
# docs/implementation.md).
#
#   t = breakbulk.testRuns.mkTestRuns {
#     pkgs;
#     plan;          # the test plan derivation ($out/plan.json)
#     inst;          # breakbulk.instantiate's result for that plan
#     sources;       # { workspace; crates; } as given to instantiate
#     tools;         # tool name -> store path, as given to instantiate
#                    # (`rustc-sysroot` names the sysroot)
#     target;        # the target triple
#     runner = null;      # null (native) or [ program arg … ]
#     testSystem = null;  # e.g. "aarch64-linux": run tests on that system
#     testPkgs = <pkgs for testSystem>;
#     packages = { };     # packages.<name>.test, as in the module options
#     ca = null;          # null: automatic (stages.caAuto); true; false
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
#   - its environment: the dynamic-library path, then the package's build
#     script `rustc-env` values, then `CARGO`, `CARGO_MANIFEST_DIR`,
#     `CARGO_MANIFEST_PATH` and `CARGO_PKG_*` from the test unit's recorded
#     env, then `test.env`, `test.path` on `PATH`, and
#     `RUST_TEST_THREADS=$NIX_BUILD_CORES`;
#   - the dynamic-library path holds, sorted as Cargo sorts paths, the
#     search paths printed by any target-platform run that lie inside some
#     target-platform run's `out` (Cargo: inside the target's output
#     directory), then the sysroot's target library directory;
#   - `/tmp/breakbulk-target-tmp`, the planner's `CARGO_TARGET_TMPDIR`, is
#     created first;
#   - `$out/log` holds the output; the run fails when the binary does.
#
# Test binaries the plan lacks (required features) are instantiation's
# stubs, which succeed and log why.
{ lib, stages }:
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

  # Values of the recorded env that a test process gets at run time
  # (`fill_env`). The others (`CARGO_CRATE_NAME`, `CARGO_BIN_EXE_*`,
  # `OUT_DIR`, `CARGO_TARGET_TMPDIR`, …) are compile-time only.
  isRuntimeVar =
    k:
    k == "CARGO"
    || k == "CARGO_MANIFEST_DIR"
    || k == "CARGO_MANIFEST_PATH"
    || lib.hasPrefix "CARGO_PKG_" k;

  # The dynamic-library path, computed at run time from the runs' `flags`
  # outputs: every search path value (sorted by path component, as Cargo's
  # BTreeSet<PathBuf> does, then deduplicated), without its kind prefix,
  # kept when it lies inside one of `outs`.
  dylibJq = ''
    def strip: if test("^(native|crate|dependency|framework|all)=") then sub("^[a-z]+="; "") else . end;
    [inputs | .libraryPaths[].value]
    | unique_by(split("/"))
    | map(strip)
    | map(select(. as $p | $outs | any(. as $o | $p == $o or ($p | startswith($o + "/")))))
    | join(":")
  '';
in
rec {
  inherit binaryKey;

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
    }:
    let
      unit = plan.units.${root.unit};
      env = lib.mapAttrs (_: resolve.text) (lib.filterAttrs (k: _: isRuntimeVar k) unit.env);
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
      inherit env;
      # The package directory, relative to the repository root.
      packageDir = if manifestRef == null then null else manifestRef.rel;
      sourceDir = env.CARGO_MANIFEST_DIR;
      # Runs whose `rustc-env` values the process gets: the package's build
      # script (Cargo's `script_metas`).
      envFlags = map (s: units.${s.splice}.flags) unit.envSplices;
      dylib = {
        flags = lib.mapAttrsToList (id: _: units.${id}.flags) runs;
        outs = lib.mapAttrsToList (id: _: units.${id}.out) runs;
        extra = lib.optional (sysroot != null) "${sysroot}/lib/rustlib/${target}/lib";
      };
    };

  # Shell lines that set up a test process's environment from a spec, for
  # bash. `jq` is the jq executable; `vars` replaces values of `spec.env`.
  envScript =
    {
      spec,
      jq,
      vars ? { },
    }:
    let
      outs = toJSON (map toString spec.dylib.outs);
      dylibs = lib.concatMapStringsSep " " (
        f: lib.escapeShellArg "${f}/directives.json"
      ) spec.dylib.flags;
      env = spec.env // vars;
    in
    ''
      __bb_dylib=${
        if spec.dylib.flags == [ ] then
          "''"
        else
          "$(${jq} -rn --argjson outs ${lib.escapeShellArg outs} ${lib.escapeShellArg dylibJq} ${dylibs})"
      }
      for __bb_p in ${lib.escapeShellArgs spec.dylib.extra}; do
        __bb_dylib=''${__bb_dylib:+$__bb_dylib:}$__bb_p
      done
      export LD_LIBRARY_PATH=$__bb_dylib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
      unset __bb_dylib __bb_p
    ''
    + lib.concatMapStrings (f: ''
      eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' ${lib.escapeShellArg "${f}/directives.json"})"
    '') spec.envFlags
    + lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") env);

  # The package's test configuration, with defaults.
  testConfig =
    packages: pkg:
    {
      env = { };
      path = [ ];
      args = [ ];
      includeIgnored = false;
      binaries = { };
    }
    // (packages.${pkg}.test or { });

  binaryConfig =
    cfg: binary:
    {
      args = [ ];
      enable = true;
    }
    // (cfg.binaries.${binary} or { });

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
      testPkgs ?
        if testSystem == null || testSystem == pkgs.stdenv.buildPlatform.system then
          pkgs
        else
          import pkgs.path { system = testSystem; },
      packages ? { },
      ca ? null,
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
      sysroot = tools.rustc-sysroot or null;

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
            ;
          root = r.breakbulkRoot;
        };

      # The binary a run executes: a content-addressed copy when `ca`.
      binaryOf =
        s:
        if !useCa then
          s.unitOut
        else
          pkgs.runCommand "${s.name}-bin" caAttrs ''
            files=(${s.unitOut}/*)
            [ ''${#files[@]} -eq 1 ] || { echo "expected one file in ${s.unitOut}" >&2; exit 1; }
            mkdir -p $out
            cp "''${files[0]}" $out/
          '';

      run =
        r:
        let
          s = spec r;
          cfg = testConfig packages s.package;
          args = testArgs cfg s.binary;
          bin = binaryOf s;
        in
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
            mkdir -p /tmp/breakbulk-target-tmp $out
            files=(${bin}/*)
            cd ${lib.escapeShellArg s.sourceDir}
            set +e
            ${lib.escapeShellArgs runnerList} "''${files[0]}" ${lib.escapeShellArgs args} 2>&1 | tee $out/log
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
        pkg: attrs:
        let
          cfg = testConfig packages pkg;
        in
        derivation (
          attrs
          // {
            BREAKBULK_TEST_RUNNER = toJSON runnerList;
            BREAKBULK_TEST_ARGS = toJSON (cfg.args ++ lib.optional cfg.includeIgnored "--include-ignored");
            BREAKBULK_TEST_ENV = toJSON (
              cfg.env // lib.optionalAttrs (cfg.path != [ ]) { PATH = lib.makeBinPath cfg.path; }
            );
          }
        )
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
