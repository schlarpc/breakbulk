# Dynamic-derivation mode ("Dynamic-derivation mode" and "Mode selection" in
# docs/src/explanation/internals/instantiation.md).
#
#   d = breakbulk.dynamic;
#   d.available                  whether `mode = "auto"` picks dynamic
#   d.resolveMode "auto"         "dynamic" or "ifd"
#   d.mkBreakbulkDrv pkgs        the outer derivation's builder
#   i = d.instantiate {
#     <every argument of breakbulk.instantiate>;   # roots is required
#     breakbulkDrv;              # d.mkBreakbulkDrv pkgs
#     coreutils;                 # for the root wrappers
#     outerName;                 # `<ws>-<triple>-<variant>[-test]`
#     doctests = { };            # test plans: the predicted doctests,
#                                # package name -> the attributes its
#                                # doctest derivation gets from the test
#                                # configuration (testRuns.doctestConfig)
#   };
#   i.outer                      the outer derivation (CA, text-hashed,
#                                requiredSystemFeatures = builder-rpc-v0)
#   i.roots."<pkg>/<kind>/<target>"
#                                a small derivation symlinking the root's
#                                output, resolved at build time; its
#                                `breakbulkRoot` as in IFD mode, with
#                                `dynamic = true`, `unit = "<dynamic>"` and
#                                `wrapper` (the root wrapper's output)
#                                A product root Cargo did not build
#                                (required features) fails with the
#                                reason; a test root's is the stub, which
#                                succeeds and logs it.
#   i.doctests.<pkg>             the doctest of each predicted library: a
#                                small derivation linking the doctest's
#                                output (its `log`), resolved at build
#                                time; a log saying why, when the plan has
#                                no doctest for the package
#   i.allUnits                   a derivation that depends on every output
#                                of every unit of the plan (the outer
#                                derivation's `units.drv` output)
#   i.units                      an error: units are not known at
#                                evaluation time
#   i.ifdUnits                   the same units through IFD mode (importing
#                                units.json), for explainSharing only
#   d.mkTestRuns { … }           test runs over i, as testRuns.mkTestRuns
#                                (libtest and nextest), and its doctests
#   d.mkTestApps { … }           test apps over d.mkTestRuns's result, as
#                                testApps.mkTestApps
#
# The outer derivation runs `breakbulk-drv`, which runs the same
# instantiation as IFD mode over the same input files, resolves each
# derivation with the real paths and their string context (values.json:
# the same input keys lib/instantiate.nix substitutes, with
# `builtins.getContext` of each), and writes units, test-root stubs,
# doctests and one wrapper per root and per doctest through the
# `builder-rpc-v0` socket. Each wrapper is
# submitted as the output `<root>.drv` (with `/` as `.`), named
# `<outer name>-<root>`, as Nix requires.
#
# Nothing but the plan is built before the outer derivation runs: every
# input's .drv is in the outer derivation's context as a plain path (the
# builder needs the .drv files to hash units), never its outputs.
{
  lib,
  instantiate,
  testRuns,
  stages,
  breakbulkTraits,
  runners,
  util,
}:
let
  inherit (builtins)
    getContext
    toFile
    toJSON
    unsafeDiscardStringContext
    ;

  # `builtins ? outputOf` is true exactly when the evaluator has the
  # `dynamic-derivations` feature (primops gated on a disabled feature are
  # not registered); builder-rpc-v0 is on Nix master since 2026-07-21 and
  # first released in 2.36. Master reports `2.36.0pre…`, which compares
  # below "2.36", hence "2.36pre". Determinate Nix reports its upstream
  # base (2.35.x) and lacks builder-rpc-v0.
  available = builtins ? outputOf && builtins.compareVersions builtins.nixVersion "2.36pre" >= 0;

  resolveMode =
    mode:
    if mode == "auto" then
      (if available then "dynamic" else "ifd")
    else if mode == "dynamic" && !(builtins ? outputOf) then
      throw "breakbulk: mode = \"dynamic\" needs an evaluator with the `dynamic-derivations` experimental feature (and `ca-derivations`), on Nix 2.36 or later; use mode = \"ifd\""
    else
      mode;

  # A root's name, as breakbulk-instantiate's `root_name`.
  rootName =
    r: "${r.package}/${if r.test && r.kind != "test" then "${r.kind}-test" else r.kind}/${r.target}";

  validName = s: builtins.match "[A-Za-z0-9+._?=-]+" s != null && !(lib.hasPrefix "." s);

  # The outer derivation's output for a root: `<package>.<kind>.<target>.drv`.
  # Package and target names cannot contain `.` or `/`.
  outputName =
    n:
    let
      o = "${lib.replaceStrings [ "/" ] [ "." ] n}.drv";
    in
    if validName o then
      o
    else
      throw "breakbulk: the root `${n}` has a name that cannot be a derivation output name in dynamic-derivation mode";

  # getContext as values.json takes it.
  contextList =
    key: v:
    lib.mapAttrsToList (
      p: c:
      if c.allOutputs or false then
        throw "breakbulk: the input `${key}` depends on all outputs of ${p} (a `drvPath` string); dynamic-derivation mode cannot pass that to a unit"
      else if c ? outputs then
        {
          drv = p;
          inherit (c) outputs;
        }
      else
        { path = p; }
    ) (getContext v);

  storeName = s: lib.replaceStrings [ "/" ] [ "-" ] s;

  # lib/test-runs.nix (mkTestApps takes a test-runs result named testRuns).
  testRunsLib = testRuns;

  mkBreakbulkDrv =
    pkgs:
    let
      root = ../.;
      fs = lib.fileset;
    in
    pkgs.rustPlatform.buildRustPackage {
      pname = "breakbulk-drv";
      version = "0.1.0";
      src = fs.toSource {
        inherit root;
        fileset = fs.unions [
          # Workspace inheritance of the path dependencies.
          (root + "/Cargo.toml")
          (root + "/crates/breakbulk-instantiate")
          (root + "/crates/breakbulk-format")
          (root + "/crates/breakbulk-unit")
          (root + "/crates/breakbulk-drv/Cargo.toml")
          (root + "/crates/breakbulk-drv/Cargo.lock")
          (root + "/crates/breakbulk-drv/src")
        ];
      };
      cargoRoot = "crates/breakbulk-drv";
      buildAndTestSubdir = "crates/breakbulk-drv";
      cargoLock = {
        lockFile = root + "/crates/breakbulk-drv/Cargo.lock";
        outputHashes."harmonia-protocol-3.3.0" = "sha256-LLWOdT+JwMLYDQ5WwK7HIxz6cUNSs79iKhsJV8Mg7Hw=";
      };
      doCheck = false;
    };

  instantiateDynamic =
    args@{
      breakbulkDrv,
      coreutils,
      outerName,
      system,
      plan,
      tools,
      roots,
      doctests ? { },
      ...
    }:
    let
      base = instantiate (
        removeAttrs args [
          "breakbulkDrv"
          "coreutils"
          "outerName"
          "doctests"
        ]
      );
      # Without predicted roots (check and clippy plans) the outer
      # derivation has only its `units.drv` output.
      predicted = if roots == null then [ ] else roots.roots;

      values =
        base.inputs
        // {
          "dynamic:coreutils" = "${coreutils}";
        }
        # Each doctest's test configuration (crate::dynamic::doctest_key).
        // lib.concatMapAttrs (
          pkg: attrs: lib.mapAttrs' (k: v: lib.nameValuePair "doctest:${pkg}:${k}" v) attrs
        ) doctests;
      valuesJson = lib.mapAttrs (k: v: {
        value = unsafeDiscardStringContext v;
        context = contextList k v;
      }) values;
      # Every store path any value depends on, as a plain path: a derivation
      # output becomes its .drv file (drv-only: nothing is built).
      contextPaths = lib.unique (lib.concatMap (v: lib.attrNames (getContext v)) (lib.attrValues values));
      context = builtins.appendContext "" (
        lib.genAttrs contextPaths (_: {
          path = true;
        })
      );

      names = map rootName predicted;
      outputs = lib.genAttrs names outputName;
      outputList = lib.attrValues outputs;
      # `<package>.doctest.drv`: package names have no `.`, so these cannot
      # be named like a root's (`<package>.<kind>.<target>.drv`).
      doctestOutputs = lib.mapAttrs (pkg: _: outputName "${pkg}/doctest") doctests;
      dupes = lib.filter (o: lib.count (x: x == o) outputList > 1) outputList;
      # A derivation on every output of every unit; root outputs always have
      # a `.` before `.drv`, so they cannot be named like it.
      unitsOutput = "units.drv";


      outer = derivation {
        name = outerName;
        inherit system;
        builder = "${breakbulkDrv}/bin/breakbulk-drv";
        args = [
          "--plan"
          plan
          "--sources"
          base.files.sourcesFile
          "--toolchains"
          base.files.toolchainsFile
          "--overrides"
          base.files.overridesFile
          "--roots"
          base.files.rootsFile
          "--values"
          (toFile "values.json" (toJSON valuesJson))
          "--outer"
          (toFile "outer.json" (toJSON {
            name = outerName;
            inherit outputs;
            units = unitsOutput;
            doctests = doctestOutputs;
          }))
        ];
        outputs =
          if dupes != [ ] then
            throw "breakbulk: roots with the same dynamic-derivation output name: ${toString dupes}"
          else
            outputList ++ lib.attrValues doctestOutputs ++ [ unitsOutput ];
        BREAKBULK_INPUTS = context;
        __contentAddressed = true;
        outputHashMode = "text";
        outputHashAlgo = "sha256";
        requiredSystemFeatures = [ "builder-rpc-v0" ];
      };

      wrapperOf = n: builtins.outputOf outer.${outputs.${n}}.outPath "out";

      # Building it builds every unit of the plan (`$out/units` lists their
      # outputs): what check and clippy variants build.
      allUnits = derivation {
        name = "${outerName}-units";
        inherit system;
        units = builtins.outputOf outer.${unitsOutput}.outPath "out";
        builder = tools.shell;
        args = [
          "-c"
          ''${coreutils}/bin/ln -s "$units" "$out"''
        ];
      };

      mkRoot =
        r:
        let
          n = rootName r;
          wrapper = wrapperOf n;
        in
        derivation {
          name = storeName "${r.package}-${r.kind}${
            lib.optionalString (r.test && r.kind != "test") "-test"
          }-${r.target}";
          inherit system wrapper;
          builder = tools.shell;
          # A product root Cargo did not build has no `root`, only the
          # reason (`not-built`): fail with it, as IFD mode's stub does.
          args = [
            "-c"
            ''
              if [ ! -e "$wrapper/root" ]; then
                printf 'error: %s\n' "$(<"$wrapper/not-built")" >&2
                exit 1
              fi
              ${coreutils}/bin/ln -s "$wrapper/root" "$out"
            ''
          ];
        }
        // {
          breakbulkRoot = {
            inherit (r)
              package
              target
              kind
              test
              ;
            unit = "<dynamic>";
            reason = null;
            dynamic = true;
            # Known at evaluation time only as the prediction: a root with
            # required features may or may not be built (lib/products.nix).
            requiredFeatures = r.requiredFeatures or null;
            inherit wrapper;
          };
        };

      # A doctest: its output (`log`), or, when the plan has no doctest for
      # the package, a log saying why (the wrapper's `not-built`).
      mkDoctest =
        pkg:
        let
          wrapper = builtins.outputOf outer.${doctestOutputs.${pkg}}.outPath "out";
        in
        derivation {
          name = storeName "${pkg}-doctest";
          inherit system wrapper;
          builder = tools.shell;
          args = [
            "-c"
            ''
              if [ -e "$wrapper/root" ]; then
                ${coreutils}/bin/ln -s "$wrapper/root" "$out"
              else
                ${coreutils}/bin/mkdir "$out"
                printf 'skipped: %s\n' "$(<"$wrapper/not-built")" > "$out/log"
                ${coreutils}/bin/cat "$out/log"
              fi
            ''
          ];
        }
        // {
          breakbulkDoctest = {
            package = pkg;
            dynamic = true;
            inherit wrapper;
          };
        };
    in
    {
      inherit outer allUnits;
      inherit (base) files inputs;
      delivery = "dynamic";
      roots = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) (mkRoot r)) predicted);
      doctests = lib.mapAttrs (pkg: _: mkDoctest pkg) doctests;
      units = throw "breakbulk: unit derivations are not known at evaluation time in dynamic-derivation mode (repo.explainSharing reads them through IFD mode)";
      # The unit derivations IFD mode would make: the same .drv paths as the
      # outer derivation writes, except downstream of an embedded product.
      # Only explainSharing uses them; reading them imports units.json.
      ifdUnits = base.units;
      unitsJson = null;
      doctestAttrs = { };
    };

  # Shell lines (bash) that set up a test process's environment from a
  # test root's `breakbulk-root.json` at `$info`, as testRuns.envScript does
  # from a run spec in IFD mode: the dynamic-library path (then `extra`),
  # the project's `[env]`, the build script's `rustc-env`, then the runtime
  # `CARGO_*` variables (names the shell cannot export go to `__bb_env`,
  # for `env`).
  envFromInfo =
    {
      jq,
      extra,
      # testRuns.dylibPathOf's result for the target.
      dylibPath ? {
        var = "LD_LIBRARY_PATH";
        sep = ":";
      },
    }:
    lib.optionalString (dylibPath != null) ''
      mapfile -t __bb_flags < <(${jq} -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
      __bb_dylib=
      if [ ''${#__bb_flags[@]} -gt 0 ]; then
        __bb_dylib=$(${jq} -rn ${lib.escapeShellArg (testRuns.dylibJqWith dylibPath.sep)} "''${__bb_flags[@]}")
      fi
      ${testRuns.exportDylib dylibPath extra}unset __bb_dylib __bb_p __bb_flags
    ''
    + ''
      eval "$(${jq} -r '.testSpec.configEnv // {} | to_entries[] | "export \(.key)=\(.value | @sh)"' "$info")"
      for __bb_f in $(${jq} -r '.testSpec.envFlags[]' "$info"); do
        eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' "$__bb_f/directives.json")"
      done
      unset __bb_f
      __bb_env=()
      eval "$(${jq} -r '.testSpec.env | to_entries[] | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) then "export \(.key)=\(.value | @sh)" else "__bb_env+=(\("\(.key)=\(.value)" | @sh))" end' "$info")"
    '';

  # Test runs over a dynamic instantiation: as testRuns.mkTestRuns, with
  # what the plan says about each test binary read at build time from its
  # wrapper's breakbulk-root.json (see crates/breakbulk-instantiate
  # src/dynamic.rs, TestSpec), and the instantiation's doctests.
  mkTestRuns =
    {
      pkgs,
      inst,
      tools,
      target,
      runner ? null,
      testSystem ? null,
      traits ? null,
      # testRuns.dylibPathOf's result (default: from the traits and runner).
      dylibPath ? testRuns.dylibPathOf {
        traits = if traits != null then traits else breakbulkTraits.resolve { triple = target; };
        inherit runner;
      },
      testPkgs ? runners.testPkgsFor { inherit pkgs testSystem; },
      packages ? { },
      # As testRuns.mkTestRuns's: the package directories of `test.runFiles`
      # views.
      runFilesDirs ? { },
      ca ? null,
      coverage ? false,
      name ? "breakbulk",
      ...
    }:
    let
      useCa = if ca == null then stages.caAuto else ca;
      caAttrs = lib.optionalAttrs useCa stages.caAttrs;
      runnerList = if runner == null then [ ] else lib.toList runner;
      sysroot = testRuns.testLibs pkgs (tools.rustc-sysroot or null) target;
      extraLibs = lib.optional (sysroot != null) "${sysroot}/lib/rustlib/${target}/lib";
      jq = "${testPkgs.jq}/bin/jq";
      testRoots = lib.filterAttrs (_: r: r.breakbulkRoot.test) inst.roots;
      byPackage = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues testRoots);

      # As in IFD mode: a content-addressed copy when `ca`, a debug-stripped
      # one with `test.stripForRun`; empty for a binary Cargo did not build.
      binaryOf =
        r: n: cfg:
        if !useCa && !cfg.stripForRun then
          r
        else
          testRuns.binaryCopy {
            inherit pkgs caAttrs;
            name = n;
            strip = cfg.stripForRun;
            src = "\"$wrapper\"/root/*";
            attrs = { inherit (r.breakbulkRoot) wrapper; };
            prelude = ''
              if [ "$(${jq} -r '.reason // ""' "$wrapper/breakbulk-root.json")" ]; then
                mkdir -p $out
                exit 0
              fi
            '';
          };

      # `test.runFiles`: the run's working directory and runtime
      # CARGO_MANIFEST_DIR are the package directory of the narrowed view,
      # set after the wrapper's environment.
      narrowScript =
        pkg: cfg:
        lib.optionalString (cfg.runFiles != null) (
          let
            dir =
              runFilesDirs.${pkg}
                or (throw "breakbulk: packages.${pkg}.test.runFiles is set, but the package has no source view");
          in
          ''
            __bb_orig_manifest_dir=$CARGO_MANIFEST_DIR
            export CARGO_MANIFEST_DIR=${lib.escapeShellArg dir}
            export CARGO_MANIFEST_PATH=${lib.escapeShellArg "${dir}/Cargo.toml"}
          ''
        );

      # What both runners share: the skip check, the environment, the test
      # configuration's env and PATH.
      prelude = cfg: ''
        info=$wrapper/breakbulk-root.json
        reason=$(${jq} -r '.reason // ""' "$info")
        if [ -n "$reason" ]; then
          # As IFD mode's test stub: the reason, in a file.
          printf 'skipped: %s\n' "$reason"
          printf '%s\n' "$reason" > $out
          exit 0
        fi
        ${envFromInfo {
          inherit jq dylibPath;
          extra = extraLibs;
        }}
        ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") cfg.env)}
        ${lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}"}
        export RUST_TEST_THREADS=$NIX_BUILD_CORES
        ${lib.optionalString coverage ''
          mkdir -p $out/profraw
          export LLVM_PROFILE_FILE=$out/profraw/%m-%p.profraw
        ''}
      '';

      # As testRuns.mkTestRuns's nextestRun, with the metadata from the
      # wrapper (TestSpec's `nextest`); `"@LIBDIR@"` becomes the sysroot's
      # target library directory, as test-runs.nix's nextestSpec fills it in.
      nextestScript =
        b: cfg: args: bin:
        let
          nextest = if cfg.nextest.package != null then cfg.nextest.package else testPkgs.cargo-nextest;
          runnerVar = util.cargoTargetEnvVar target "RUNNER";
          libdir = toJSON (
            if sysroot != null then
              {
                status = "available";
                path = "${sysroot}/lib/rustlib/${target}/lib";
              }
            else
              {
                status = "unavailable";
                reason = "breakbulk";
              }
          );
        in
        ''
          ${lib.optionalString (
            runnerList != [ ]
          ) "export ${runnerVar}=${lib.escapeShellArg (lib.concatStringsSep " " runnerList)}"}
          ws=$TMPDIR/nextest-ws
          mkdir -p /tmp/breakbulk-target-tmp $out $ws/target
          touch $ws/Cargo.toml
          files=(${bin})
          libdir=${lib.escapeShellArg libdir}
          subst() { sed -e "s|@BINARY@|''${files[0]}|g" -e "s|@TARGET@|$ws/target|g" -e "s|@WS@|$ws|g" -e "s|\"@LIBDIR@\"|$libdir|g"; }
          ${jq} -c '.testSpec.nextest.binaries' "$info" | subst > $TMPDIR/binaries-metadata.json
          ${jq} -c '.testSpec.nextest.cargoMetadata' "$info" | subst \
            | ${jq} -c --arg from "''${__bb_orig_manifest_dir:-}/Cargo.toml" --arg to "$CARGO_MANIFEST_DIR/Cargo.toml" \
              '.packages |= map(if .manifest_path == $from then .manifest_path = $to else . end)' \
            > $TMPDIR/cargo-metadata.json
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
            echo "test binary ${b.package} ${testRuns.binaryKey b} failed under nextest (exit status $status)" >&2
            exit "$status"
          fi
        '';

      libtestScript = b: args: bin: ''
        mkdir -p /tmp/breakbulk-target-tmp $out
        files=(${bin})
        cd "$CARGO_MANIFEST_DIR"
        set +e
        env "''${__bb_env[@]}" ${lib.escapeShellArgs runnerList} "''${files[0]}" ${lib.escapeShellArgs args} 2>&1 | tee $out/log
        status=''${PIPESTATUS[0]}
        set -e
        if [ "$status" -ne 0 ]; then
          echo "test binary ${b.package} ${testRuns.binaryKey b} failed (exit status $status)" >&2
          exit "$status"
        fi
      '';

      run =
        r:
        let
          b = r.breakbulkRoot;
          key = testRuns.binaryKey b;
          n = storeName "${b.package}-${key}";
          cfg = testRuns.testConfig packages b.package;
          args = testRuns.testArgs cfg key;
          bin = binaryOf r n cfg;
          binGlob = if useCa || cfg.stripForRun then "${bin}/*" else "\"$wrapper\"/root/*";
        in
        testPkgs.runCommand "${name}-${n}-run"
          (
            {
              passthru = {
                breakbulkTest = {
                  package = b.package;
                  binary = key;
                  inherit args;
                };
                binary = bin;
              };
              inherit (b) wrapper;
            }
            // caAttrs
          )
          (
            prelude cfg
            + narrowScript b.package cfg
            + (
              if cfg.runner == "nextest" then
                nextestScript b cfg args binGlob
              else if cfg.runner == "libtest" then
                libtestScript b args binGlob
              else
                throw "breakbulk: packages.${b.package}.test.runner must be \"libtest\" or \"nextest\", not ${toJSON cfg.runner}"
            )
          );

      runs = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (testRuns.binaryKey r.breakbulkRoot) (run r)) rs)
      ) byPackage;

      doctests = inst.doctests or { };

      checks =
        lib.concatMapAttrs (
          pkg: bs:
          lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
            lib.filterAttrs (b: _: (testRuns.binaryConfig (testRuns.testConfig packages pkg) b).enable) bs
          )
        ) runs
        // lib.mapAttrs' (pkg: d: lib.nameValuePair "doctest/${pkg}" d) doctests;
    in
    {
      inherit
        runs
        checks
        testPkgs
        doctests
        ;
      # IFD mode's specs need the plan; test apps here read the wrappers.
      specs = { };
      # Test roots by package and binary key, for mkTestApps.
      roots = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (testRuns.binaryKey r.breakbulkRoot) r) rs)
      ) byPackage;
      inherit extraLibs dylibPath;
      runner = runnerList;
    };

  # Test apps over mkTestRuns's result, as testApps.mkTestApps in IFD mode,
  # with everything it takes from the plan read at run time from the test
  # root's wrapper (`breakbulk-root.json`): the app script depends on the
  # wrapper, so it is resolved at build time, and `nix run` substitutes the
  # script's real path for its placeholder (Nix's `resolveString`,
  # src/nix/app.cc). A test binary Cargo did not build gets an app that
  # fails with the reason.
  mkTestApps =
    {
      pkgs,
      testRuns,
      checkout ? null,
      packages ? { },
      name ? "breakbulk",
    }:
    let
      t = testRuns;
      jq = "${pkgs.jq}/bin/jq";
      app =
        r:
        let
          b = r.breakbulkRoot;
          n = storeName "${b.package}-${testRunsLib.binaryKey b}";
          cfg = testRunsLib.testConfig packages b.package;
          checkoutDir = lib.removeSuffix "/" (toString checkout);
          script = pkgs.writeShellScriptBin "${name}-${n}" ''
            set -euo pipefail
            info=${b.wrapper}/breakbulk-root.json
            reason=$(${jq} -r '.reason // ""' "$info")
            if [ -n "$reason" ]; then
              printf 'breakbulk: %s\n' "$reason" >&2
              exit 1
            fi
            ${envFromInfo {
              inherit jq;
              inherit (t) dylibPath;
              extra = t.extraLibs;
            }}
            ${
              if checkout == null then
                ''dir=$CARGO_MANIFEST_DIR''
              else
                ''
                  if [ "$(${jq} -r '.testSpec.packageDir == null' "$info")" = true ]; then
                    echo "breakbulk: cannot place ${b.package} in the checkout: its CARGO_MANIFEST_DIR is not a source view path" >&2
                    exit 1
                  fi
                  dir=${lib.escapeShellArg checkoutDir}
                  __bb_rel=$(${jq} -r '.testSpec.packageDir' "$info")
                  if [ -n "$__bb_rel" ]; then dir=$dir/$__bb_rel; fi
                  export CARGO_MANIFEST_DIR=$dir CARGO_MANIFEST_PATH=$dir/Cargo.toml
                ''
            }
            ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") cfg.env)}
            ${lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}"}
            mkdir -p /tmp/breakbulk-target-tmp
            files=(${b.wrapper}/root/*)
            cd "$dir"
            exec ${pkgs.coreutils}/bin/env "''${__bb_env[@]}" ${lib.escapeShellArgs t.runner} "''${files[0]}" "$@"
          '';
        in
        {
          type = "app";
          program = "${script}/bin/${name}-${n}";
        };
    in
    lib.mapAttrs (_: lib.mapAttrs (_: app)) t.roots;
in
{
  inherit
    available
    resolveMode
    rootName
    outputName
    mkBreakbulkDrv
    mkTestRuns
    mkTestApps
    ;
  instantiate = instantiateDynamic;
}
