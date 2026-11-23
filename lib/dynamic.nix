# Dynamic-derivation mode ("Dynamic-derivation mode" and "Mode selection" in
# docs/src/explanation/internals/instantiation.md).
#
#   d = breakbulk.dynamic;
#   d.available                  whether `mode` defaults to dynamic
#                                (breakbulk.nixFeatures.available)
#   d.checkMode mode             mode, or an error for "dynamic" on an
#                                evaluator without dynamic derivations
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
#     docs = false;              # doc plans: the plan has a docs derivation
#     nixFeatures = <standalone>;  # the record the outer derivation and
#                                # outputOf are checked against
#                                # (lib/nix-features.nix; repo.nixFeatures)
#     split = null;              # or { packages; owner; }: two outer
#                                # derivations (below); `owner key` is the
#                                # package whose settings an input holds
#   };
#   i.outer                      the outer derivation (CA, text-hashed,
#                                requiredSystemFeatures = builder-rpc-v0)
#                                that writes every unit of the plan
#   i.writers                    every outer derivation of the plan: `outer`,
#                                or with `split` the first and `outer`
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
#   i.docs                       doc plans: a small derivation linking the
#                                docs derivation's output, resolved at
#                                build time; null for other plans
#   i.allUnits                  a derivation that depends on every output
#                                of every unit of the plan (the outer
#                                derivation's `units.drv` output)
#   i.buildScriptRuns            { runsFile; }: a file listing the `flags`
#                                output of every build-script run of the
#                                plan (the outer derivation's `runs.drv`
#                                output), read at build time; IFD mode's
#                                is the list of those outputs
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
# With `split` (packages whose settings use products of this plan:
# `productInputs`), a plan has two outer derivations. The first takes no
# input of `split.packages` and leaves their units out (outer.json
# `leave`), so it never depends on their settings, which may name its
# products. The second, `<outer name>-product-users`, takes every input,
# writes every unit (the same .drv files as the first, where both write
# one) and submits the roots and doctests of `split.packages` (outer.json
# `submit`).
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
  featureGates,
}:
let
  inherit (builtins)
    getContext
    toFile
    toJSON
    unsafeDiscardStringContext
    ;

  inherit (featureGates) available;

  checkMode =
    mode:
    if mode == "dynamic" && !featureGates.hasOutputOf then
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

  # For `tools` without a breakbulk-drv.
  mkBreakbulkDrv = pkgs: (import ./tools.nix { inherit lib; } pkgs).breakbulk-drv;

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
      docs ? false,
      nixFeatures ? featureGates.standalone { dynamic = true; },
      split ? null,
      ...
    }:
    let
      # Only `ifdUnits` reads base's units.json: explainSharing, which
      # always imports from derivations and is not counted in the record.
      base = instantiate (
        removeAttrs args [
          "breakbulkDrv"
          "coreutils"
          "outerName"
          "doctests"
          "docs"
          "split"
        ]
        // {
          nixFeatures = nixFeatures // {
            importFromDerivation = true;
          };
        }
      );
      # An output of outer derivation `w` (`outer`, by default).
      outputOfIn =
        w: what: output:
        featureGates.outputOf nixFeatures "the ${what} of `${w.name}`" w.${output}.outPath "out";
      outputOf = outputOfIn outer;
      # Without predicted roots (check and clippy plans) the outer
      # derivation has only its `units.drv` output.
      predicted = if roots == null then [ ] else roots.roots;

      # With `split`, the second outer derivation's packages: it writes
      # them, and the first takes none of their inputs.
      second = p: split != null && lib.elem p split.packages;

      # Predicted views are the outer derivation's to make (from their
      # specs): their values in `base.inputs` come from import from
      # derivation.
      allValues =
        removeAttrs base.inputs (lib.attrNames base.predictedSpecs)
        // {
          "dynamic:coreutils" = "${coreutils}";
        }
        # Each doctest's test configuration (crate::dynamic::doctest_key).
        // lib.concatMapAttrs (
          pkg: attrs: lib.mapAttrs' (k: v: lib.nameValuePair "doctest:${pkg}:${k}" v) attrs
        ) doctests;

      names = map rootName predicted;
      # `<package>.doctest.drv`: package names have no `.`, so these cannot
      # be named like a root's (`<package>.<kind>.<target>.drv`).
      doctestOutputs = lib.mapAttrs (pkg: _: outputName "${pkg}/doctest") doctests;
      # A derivation on every output of every unit; root outputs always have
      # a `.` before `.drv`, so they cannot be named like it.
      unitsOutput = "units.drv";
      # A derivation on the `flags` output of every build-script run.
      runsOutput = "runs.drv";
      # Likewise the docs derivation's wrapper.
      docsOutput = "docs.drv";

      # One outer derivation: `mine p` says whether it submits package p's
      # roots and doctest; `full` whether it writes every unit (and the
      # docs), else it leaves the second outer derivation's packages out.
      mkOuter =
        {
          name,
          mine,
          full,
        }:
        let
          values = lib.mapAttrs (_: util.devirtualize) (
            if full then allValues else lib.filterAttrs (k: _: !second (split.owner k)) allValues
          );
          valuesJson = lib.mapAttrs (k: v: {
            value = unsafeDiscardStringContext v;
            context = contextList k v;
          }) values;
          predict = lib.filterAttrs (k: _: full || !second (split.owner k)) base.predictedSpecs;
          predictJson = lib.mapAttrsToList (
            key: spec:
            spec
            // {
              inherit key;
              view = unsafeDiscardStringContext (util.devirtualize spec.view);
            }
          ) predict;
          # Every store path any value depends on, as a plain path: a
          # derivation output becomes its .drv file (drv-only: nothing is
          # built).
          contextPaths = lib.unique (
            lib.concatMap (v: lib.attrNames (getContext v)) (
              lib.attrValues values ++ map (p: util.devirtualize p.view) (lib.attrValues predict)
            )
          );
          context = builtins.appendContext "" (
            lib.genAttrs contextPaths (_: {
              path = true;
            })
          );
          outputs = lib.genAttrs (lib.filter (n: mine (lib.head (lib.splitString "/" n))) names) outputName;
          outputList = lib.attrValues outputs;
          doctests = lib.filterAttrs (p: _: mine p) doctestOutputs;
          dupes = lib.filter (o: lib.count (x: x == o) outputList > 1) outputList;
          hasDocs = docs && full;
        in
        derivation (
          {
            inherit name system;
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
              "--predict"
              (toFile "predict.json" (toJSON predictJson))
              "--outer"
              (toFile "outer.json" (
                toJSON (
                  {
                    inherit name outputs doctests;
                    units = unitsOutput;
                    runs = runsOutput;
                  }
                  // lib.optionalAttrs hasDocs { docs = docsOutput; }
                  // lib.optionalAttrs (split != null) (
                    if full then { submit = split.packages; } else { leave = split.packages; }
                  )
                )
              ))
            ];
            outputs =
              if dupes != [ ] then
                throw "breakbulk: roots with the same dynamic-derivation output name: ${toString dupes}"
              else
                outputList
                ++ lib.attrValues doctests
                ++ [
                  unitsOutput
                  runsOutput
                ]
                ++ lib.optional hasDocs docsOutput;
            BREAKBULK_INPUTS = context;
            requiredSystemFeatures = [ "builder-rpc-v0" ];
          }
          // featureGates.caAttrs nixFeatures "the outer derivation `${name}`"
          // {
            outputHashMode = "text";
          }
        );

      # Without `split`, one outer derivation writes everything. With it,
      # the first writes every package but the second's, and the second
      # writes every unit (it cannot read the first's) with every input,
      # and submits its packages' roots and doctests. The first never
      # depends on the second, so the second's packages' settings can use
      # the first's products.
      first = mkOuter {
        name = outerName;
        mine = p: !second p;
        full = split == null;
      };
      outer =
        if split == null then
          first
        else
          mkOuter {
            name = "${outerName}-product-users";
            mine = second;
            full = true;
          };
      outerOf = p: if second p then outer else first;

      wrapperOf = n: outputOfIn (outerOf (lib.head (lib.splitString "/" n))) "root `${n}`" (outputName n);

      # Building it builds every unit of the plan (`$out/units` lists their
      # outputs): what check and clippy variants build.
      allUnits = derivation {
        name = "${outerName}-units";
        inherit system;
        units = outputOf "units" unitsOutput;
        builder = tools.shell;
        args = [
          "-c"
          ''${coreutils}/bin/ln -s "$units" "$out"''
        ];
      };

      # Building it builds every build-script run of the plan, on both
      # platforms, and nothing else (`$out/runs` lists their `flags`
      # outputs): what the plan's `buildScriptPaths` check reads.
      allRuns = derivation {
        name = "${outerName}-runs";
        inherit system;
        runs = outputOf "runs" runsOutput;
        builder = tools.shell;
        args = [
          "-c"
          ''${coreutils}/bin/ln -s "$runs" "$out"''
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
              # The prediction's, which instantiation checks against the
              # plan: test runs pick their system by it at evaluation time.
              platform
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
          wrapper = outputOfIn (outerOf pkg) "doctest of `${pkg}`" doctestOutputs.${pkg};
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

      # The docs derivation's output, through its wrapper's `root`.
      docsOut = derivation {
        name = outerName;
        inherit system;
        wrapper = outputOf "docs" docsOutput;
        builder = tools.shell;
        args = [
          "-c"
          ''${coreutils}/bin/ln -s "$wrapper/root" "$out"''
        ];
      };
    in
    {
      inherit outer allUnits;
      buildScriptRuns = {
        runsFile = "${allRuns}/runs";
      };
      writers = [ first ] ++ lib.optional (split != null) outer;
      inherit (base) files inputs;
      delivery = "dynamic";
      roots = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) (mkRoot r)) predicted);
      doctests = lib.mapAttrs (pkg: _: mkDoctest pkg) doctests;
      docs = if docs then docsOut else null;
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
      # Whether `$info` is a stable copy's (`runInfo` with `ca`, in mkTestRuns),
      # with the dynamic-library path in `$specDylibs/dylib/*` and the
      # `rustc-env` values in `$spec/rustc-env`.
      stable ? false,
    }:
    lib.optionalString (dylibPath != null) ''
      mapfile -t __bb_flags < <(${jq} -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
      __bb_dylib=
      if [ ''${#__bb_flags[@]} -gt 0 ]; then
        __bb_dylib=$(${jq} -rn ${lib.escapeShellArg (testRuns.dylibJqWith dylibPath.sep)} "''${__bb_flags[@]}")
      fi
      ${lib.optionalString stable ''
        for __bb_p in "$specDylibs"/dylib/*; do
          [ -d "$__bb_p" ] || continue
          __bb_dylib=''${__bb_dylib:+$__bb_dylib${dylibPath.sep}}$__bb_p
        done
      ''}${testRuns.exportDylib dylibPath extra}unset __bb_dylib __bb_p __bb_flags
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
      # As testRuns.mkTestRuns's: the target's package set.
      packageSet ? if target == breakbulkTraits.nativeTriple pkgs then pkgs else null,
      # As testRuns.mkTestRuns's: the host triple's settings.
      host ? testRuns.defaultHost {
        inherit
          pkgs
          target
          runner
          testSystem
          dylibPath
          ;
      },
      packages ? { },
      # As testRuns.mkTestRuns's: the package directories of "run" views.
      runDirs ? { },
      # As testRuns.mkTestRuns's: "test", or "bench".
      kind ? "test",
      ca ? featureGates.defaultCa,
      nixFeatures ? featureGates.standalone {
        inherit ca;
        dynamic = true;
      },
      coverage ? false,
      name ? "breakbulk",
      ...
    }:
    let
      useCa = ca;
      caAttrs = lib.optionalAttrs useCa (
        featureGates.caAttrs nixFeatures "the test runs of `${name}` (`ca`)"
      );
      # The predicted platform picks the run's system, so it must be known
      # at evaluation time; instantiation checks it against the plan.
      platforms = testRuns.testPlatforms {
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

      # Each run's settings, once, as in IFD mode.
      configs = lib.mapAttrs (
        pkg: rs:
        lib.listToAttrs (
          map (
            r:
            let
              key = testRuns.binaryKey r.breakbulkRoot;
            in
            lib.nameValuePair key (testRuns.runConfig packages pkg kind key)
          ) rs
        )
      ) byPackage;
      configOf = r: configs.${r.breakbulkRoot.package}.${testRuns.binaryKey r.breakbulkRoot};

      # Whether a run executes something other than the binary its spec
      # links: the output of its stages, or a content-addressed copy
      # (testRuns.runBinary).
      copiesBinary = cfg: useCa || lib.any (v: v != null) (lib.attrValues cfg.stages);

      # The binary, copied out of its wrapper; for a binary Cargo did not
      # build, the marker that makes the stages skip
      # (stages.noBinariesMarker; the run itself skips before it reads the
      # binary).
      binaryCopy =
        r: n:
        testRuns.binaryCopy {
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

      # What a run reads from its wrapper, copied out of it, so that the run
      # does not depend on the wrapper: the wrapper's closure holds the
      # package's whole source view (its breakbulk-root.json names it) and
      # the unit's debuginfo (`debug`), which IFD mode's run does not get.
      # `out` holds `breakbulk-root.json` with `reason` and `testSpec`
      # only, narrowed to the "run" view and without nextest's metadata for
      # a libtest run (it names the package view), as IFD mode's run spec
      # (testRuns.narrowSpec, nextestSpec).
      #
      # With `ca`, it is content-addressed and also stands in for the
      # input-addressed paths the spec names, as testRuns.stableSpec does in
      # IFD mode: the `flags` lists are empty, `rustc-env/directives.json`
      # holds the `rustc-env` values, and `dylibs` the dynamic-library
      # path's copies. The name is not per binary, so test binaries whose
      # copies have the same contents share its path, and the copies are
      # stored once.
      #
      # Without `ca`, the `flags` stay, as in IFD mode's spec, and `root`
      # links the test binary (the unit's output) unless the run takes a
      # copy of it.
      runInfo =
        r: cfg:
        pkgs.runCommand "${name}-test-spec"
          (
            caAttrs
            // {
              inherit (r.breakbulkRoot) wrapper;
              outputs = [ "out" ] ++ lib.optional useCa "dylibs";
              nativeBuildInputs = [ pkgs.jq ];
              narrowDir =
                let
                  d = runDir r.breakbulkRoot.package;
                in
                if d == null then "" else d;
              keepNextest = cfg.runner == "nextest";
              stable = useCa;
            }
          )
          ''
            info=$wrapper/breakbulk-root.json
            mkdir -p $out ${lib.optionalString useCa "$dylibs"}
            if [ -n "$(jq -r '.reason // ""' "$info")" ]; then
              jq '{reason}' "$info" > $out/breakbulk-root.json
              exit 0
            fi
            ${
              if useCa then
                ''
                  ${lib.optionalString ((platformOf r).dylibPath != null) ''
                    mapfile -t __bb_flags < <(jq -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
                    ${testRuns.copyDylibsScript (platformOf r).dylibPath.sep}
                  ''}
                  mapfile -t envFlags < <(jq -r '.testSpec.envFlags[] | . + "/directives.json"' "$info")
                  if [ ''${#envFlags[@]} -gt 0 ]; then
                    mkdir -p $out/rustc-env
                    jq -s ${lib.escapeShellArg testRuns.mergeRustcEnvJq} "''${envFlags[@]}" > $out/rustc-env/directives.json
                  fi
                ''
              else
                lib.optionalString (!copiesBinary cfg) ''
                  ln -s "$(readlink "$wrapper/root")" $out/root
                ''
            }
            jq --arg dir "$narrowDir" --arg nextest "$keepNextest" --arg stable "$stable" '
              .testSpec
              | if $stable == "1" then .dylibFlags = [] | .envFlags = [] else . end
              | (.env.CARGO_MANIFEST_DIR + "/Cargo.toml") as $orig
              | if $dir == "" then . else
                  .env.CARGO_MANIFEST_DIR = $dir
                  | .env.CARGO_MANIFEST_PATH = ($dir + "/Cargo.toml")
                  | .nextest.cargoMetadata.packages |= map(
                      if .manifest_path == $orig then .manifest_path = ($dir + "/Cargo.toml") else . end)
                end
              | if $nextest == "1" then . else del(.nextest) end
              | {reason: null, testSpec: .}
            ' "$info" > $out/breakbulk-root.json
          '';

      # What both runners share: the skip check, the environment, the run's
      # env, PATH and `preRun` entries.
      prelude = p: cfg: ''
        info=$spec/breakbulk-root.json
        reason=$(${jqOf p} -r '.reason // ""' "$info")
        if [ -n "$reason" ]; then
          # As IFD mode's test stub: the reason, in a file.
          printf 'skipped: %s\n' "$reason"
          printf '%s\n' "$reason" > $out
          exit 0
        fi
        ${envFromInfo {
          jq = jqOf p;
          inherit (p) dylibPath;
          extra = lib.optional (p.libDir != null) p.libDir;
          stable = useCa;
        }}
        ${testRuns.configScript p.testPkgs cfg}
        ${testRuns.preRunScript cfg coverage}
        log=${testRuns.logFile}
      '';

      # As testRuns.mkTestRuns's nextestRun, with the metadata from the
      # wrapper (TestSpec's `nextest`); `"@LIBDIR@"` becomes the sysroot
      # library directory of the binary's platform, as test-runs.nix's
      # nextestSpec fills it in.
      nextestScript =
        p: b: cfg: bin:
        let
          jq = jqOf p;
          nextest = if cfg.nextest.package != null then cfg.nextest.package else p.testPkgs.cargo-nextest;
          libdir = toJSON (testRuns.nextestLibdir p.libDir);
          wrapper = testRuns.wrapperOf p.testPkgs cfg;
        in
        ''
          ${lib.optionalString (wrapper != null) (testRuns.sourceRootExport jq null)}
          ${testRuns.nextestRunnerScript {
            pkgs = p.testPkgs;
            inherit (p) triple runner;
            inherit wrapper;
          }}
          ws=$TMPDIR/nextest-ws
          mkdir -p $out $ws/target
          touch $ws/Cargo.toml
          files=(${bin})
          ${testRuns.workdirScript p.testPkgs}
          __bb_workdir "''${files[0]}" "$CARGO_MANIFEST_DIR"
          libdir=${lib.escapeShellArg libdir}
          subst() { sed -e "s|@BINARY@|''${files[0]}|g" -e "s|@TARGET@|$ws/target|g" -e "s|@WS@|$ws|g" -e "s|\"@LIBDIR@\"|$libdir|g"; }
          ${jq} -c '.testSpec.nextest.binaries' "$info" | subst > $TMPDIR/binaries-metadata.json
          ${jq} -c '.testSpec.nextest.cargoMetadata' "$info" | subst | ${testRuns.nextestWorkdirJq jq ''"$CARGO_MANIFEST_DIR"''} > $TMPDIR/cargo-metadata.json
          cd $TMPDIR
          set +e
          env "''${__bb_env[@]}" ${nextest}/bin/cargo-nextest nextest run \
            --binaries-metadata $TMPDIR/binaries-metadata.json \
            --cargo-metadata $TMPDIR/cargo-metadata.json \
            ${lib.optionalString (cfg.nextest.configFile != null) "--config-file ${cfg.nextest.configFile}"} \
            --profile ${lib.escapeShellArg cfg.nextest.profile} \
            "''${__bb_nextest[@]}" \
            --no-tests=warn --color never \
            ${lib.optionalString (cfg.args != [ ]) "-- ${lib.escapeShellArgs cfg.args}"} 2>&1 | tee "$log"
          status=''${PIPESTATUS[0]}
          set -e
          if [ "$status" -ne 0 ]; then
            echo "test binary ${b.package} ${testRuns.binaryKey b} failed under nextest (exit status $status)" >&2
            ${hint p b cfg}
            exit "$status"
          fi
          nextestDir=$ws/target/nextest
          ${testRuns.postRunScript { inherit cfg coverage; }}
        '';

      # testRuns.hintScript, with the spec read from `$info`.
      hint =
        p: b: cfg:
        testRuns.hintScript
          {
            inherit tools pkgs;
            inherit (p) testPkgs;
          }
          ''"$(${jqOf p} -c --arg package ${lib.escapeShellArg b.package} --arg widen ${lib.escapeShellArg (testRuns.hintWiden cfg)} '.testSpec | {$package, packageDir, testOnly: (.testOnly // []), junk: (.junk // []), custom: (.custom // false), $widen}' "$info")"'';

      libtestScript =
        p: b: cfg: bin:
        let
          wrapper = testRuns.wrapperOf p.testPkgs cfg;
        in
        ''
          mkdir -p $out
          files=(${bin})
          ${lib.optionalString (wrapper != null) (testRuns.sourceRootExport (jqOf p) null)}
          ${testRuns.workdirScript p.testPkgs}
          __bb_workdir "''${files[0]}" "$CARGO_MANIFEST_DIR"
          cd "$__bb_wd"
          set +e
          env "''${__bb_env[@]}" ${
            testRuns.launchWords {
              pkgs = p.testPkgs;
              inherit (p) runner;
              inherit wrapper;
            }
          } "''${files[0]}" ${lib.escapeShellArgs cfg.args} 2>&1 | tee "$log"
          status=''${PIPESTATUS[0]}
          set -e
          if [ "$status" -ne 0 ]; then
            echo "test binary ${b.package} ${testRuns.binaryKey b} failed (exit status $status)" >&2
            ${hint p b cfg}
            exit "$status"
          fi
          ${testRuns.postRunScript { inherit cfg coverage; }}
        '';

      run =
        r:
        let
          b = r.breakbulkRoot;
          p = platformOf r;
          key = testRuns.binaryKey b;
          n = storeName "${b.package}-${key}";
          cfg = configOf r;
          info = runInfo r cfg;
          bin =
            if copiesBinary cfg then
              testRuns.runBinary {
                inherit pkgs cfg nixFeatures;
                name = n;
                ca = useCa;
                platform = p;
                linked = binaryCopy r n;
                copy = binaryCopy r n;
              }
            else
              "${info.out}/root";
          inputs = {
            spec = info.out;
          }
          // lib.optionalAttrs useCa { specDylibs = info.dylibs; };
        in
        p.testPkgs.runCommand "${name}-${n}-run"
          (
            {
              passthru = {
                breakbulkTest = {
                  package = b.package;
                  binary = key;
                  inherit (cfg) args;
                };
                binary = bin;
              };
            }
            // inputs
            // caAttrs
          )
          (
            prelude p cfg
            + (
              if cfg.runner == "nextest" then
                nextestScript p b cfg "${bin}/*"
              else
                libtestScript p b cfg "${bin}/*"
            )
          );

      runs = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (testRuns.binaryKey r.breakbulkRoot) (run r)) rs)
      ) byPackage;

      doctests = lib.optionalAttrs (kind == "test") (inst.doctests or { });

      checks =
        lib.concatMapAttrs (
          pkg: bs:
          lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
            lib.filterAttrs (b: _: configs.${pkg}.${b}.enable) bs
          )
        ) runs
        // lib.mapAttrs' (pkg: d: lib.nameValuePair "doctest/${pkg}" d) (
          lib.filterAttrs (pkg: _: testRuns.doctestEnabled packages pkg) doctests
        );
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
      inherit platforms;
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
          p = t.platforms.${b.platform};
          n = storeName "${b.package}-${testRunsLib.binaryKey b}";
          cfg = testRunsLib.runConfig packages b.package "test" (testRunsLib.binaryKey b);
          wrapper = testRunsLib.wrapperOf pkgs cfg;
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
              inherit (p) dylibPath;
              extra = lib.optional (p.libDir != null) p.libDir;
            }}
            ${
              if checkout == null then
                "dir=$CARGO_MANIFEST_DIR"
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
            ${testRunsLib.configScript pkgs cfg}
            ${lib.optionalString (wrapper != null) (testRunsLib.sourceRootExport jq checkout)}
            files=(${b.wrapper}/root/*)
            ${testRunsLib.appRunScript {
              inherit pkgs;
              dir = ''"$dir"'';
              command = ''${pkgs.coreutils}/bin/env "''${__bb_env[@]}" ${
                testRunsLib.launchWords {
                  inherit pkgs wrapper;
                  inherit (p) runner;
                }
              } "''${files[0]}" "$@"'';
            }}
          '';
        in
        script;
    in
    lib.mapAttrs (_: lib.mapAttrs (_: app)) t.roots;
in
{
  inherit
    available
    checkMode
    rootName
    outputName
    mkBreakbulkDrv
    mkTestRuns
    mkTestApps
    ;
  instantiate = instantiateDynamic;
}
