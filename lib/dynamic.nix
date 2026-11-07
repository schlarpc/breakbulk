# Dynamic-derivation mode ("Dynamic-derivation mode" and "Mode selection" in
# docs/implementation.md; spike B in docs/spikes/B-delivery.md).
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
#   };
#   i.outer                      the outer derivation (CA, text-hashed,
#                                requiredSystemFeatures = builder-rpc-v0)
#   i.roots."<pkg>/<kind>/<target>"
#                                a small derivation symlinking the root's
#                                output, resolved at build time; its
#                                `breakbulkRoot` as in IFD mode, with
#                                `dynamic = true`, `unit = "<dynamic>"` and
#                                `wrapper` (the root wrapper's output)
#   i.allUnits                   a derivation that depends on every output
#                                of every unit of the plan (the outer
#                                derivation's `units.drv` output)
#   i.units                      an error: units are not known at
#                                evaluation time
#   d.mkTestRuns { … }           test runs over i, as testRuns.mkTestRuns
#
# The outer derivation runs `breakbulk-drv`, which runs the same
# instantiation as IFD mode over the same input files, resolves each
# derivation with the real paths and their string context (values.json:
# the same input keys lib/instantiate.nix substitutes, with
# `builtins.getContext` of each), and writes units, root stubs and one
# wrapper per root through the `builder-rpc-v0` socket. Each wrapper is
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
          (root + "/breakbulk-drv/Cargo.toml")
          (root + "/breakbulk-drv/Cargo.lock")
          (root + "/breakbulk-drv/src")
        ];
      };
      cargoRoot = "breakbulk-drv";
      buildAndTestSubdir = "breakbulk-drv";
      cargoLock = {
        lockFile = root + "/breakbulk-drv/Cargo.lock";
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
      ...
    }:
    let
      base = instantiate (
        removeAttrs args [
          "breakbulkDrv"
          "coreutils"
          "outerName"
        ]
      );
      # Without predicted roots (check and clippy plans) the outer
      # derivation has only its `units.drv` output.
      predicted = if roots == null then [ ] else roots.roots;

      values = base.inputs // {
        "dynamic:coreutils" = "${coreutils}";
      };
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
          }))
        ];
        outputs =
          if dupes != [ ] then
            throw "breakbulk: roots with the same dynamic-derivation output name: ${toString dupes}"
          else
            outputList ++ [ unitsOutput ];
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
          args = [
            "-c"
            ''${coreutils}/bin/ln -s "$wrapper/root" "$out"''
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
            inherit wrapper;
          };
        };
    in
    {
      inherit outer allUnits;
      inherit (base) files inputs;
      delivery = "dynamic";
      roots = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) (mkRoot r)) predicted);
      units = throw "breakbulk: unit derivations are not known at evaluation time in dynamic-derivation mode";
      unitsJson = null;
      doctestAttrs = { };
    };

  # Test runs over a dynamic instantiation: as testRuns.mkTestRuns, with
  # what the plan says about each test binary read at build time from its
  # wrapper's breakbulk-root.json (see crates/breakbulk-instantiate
  # src/dynamic.rs, TestSpec). No doctests and no test apps yet.
  mkTestRuns =
    {
      pkgs,
      inst,
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
      coverage ? false,
      name ? "breakbulk",
      ...
    }:
    let
      useCa = if ca == null then stages.caAuto else ca;
      caAttrs = lib.optionalAttrs useCa stages.caAttrs;
      runnerList = if runner == null then [ ] else lib.toList runner;
      sysroot = tools.rustc-sysroot or null;
      jq = "${testPkgs.jq}/bin/jq";
      testRoots = lib.filterAttrs (_: r: r.breakbulkRoot.test) inst.roots;
      byPackage = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues testRoots);

      binaryOf =
        r: n:
        if !useCa then
          r
        else
          pkgs.runCommand "${n}-bin" (caAttrs // { inherit (r.breakbulkRoot) wrapper; }) ''
            if [ "$(${jq} -r '.reason // ""' "$wrapper/breakbulk-root.json")" ]; then
              mkdir -p $out
              exit 0
            fi
            files=("$wrapper"/root/*)
            [ ''${#files[@]} -eq 1 ] || { echo "expected one file in $wrapper/root" >&2; exit 1; }
            mkdir -p $out
            cp "''${files[0]}" $out/
          '';

      run =
        r:
        let
          b = r.breakbulkRoot;
          key = testRuns.binaryKey b;
          n = storeName "${b.package}-${key}";
          cfg = testRuns.testConfig packages b.package;
          args = testRuns.testArgs cfg key;
          bin = binaryOf r n;
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
          ''
            info=$wrapper/breakbulk-root.json
            reason=$(${jq} -r '.reason // ""' "$info")
            if [ -n "$reason" ]; then
              mkdir -p $out
              printf 'skipped: %s\n' "$reason" | tee $out/log
              exit 0
            fi
            mapfile -t dylibFlags < <(${jq} -r '.testSpec.dylibFlags[] | . + "/directives.json"' "$info")
            __bb_dylib=
            if [ ''${#dylibFlags[@]} -gt 0 ]; then
              __bb_dylib=$(${jq} -rn --argjson outs "$(${jq} -c '.testSpec.dylibOuts' "$info")" ${lib.escapeShellArg testRuns.dylibJq} "''${dylibFlags[@]}")
            fi
            for __bb_p in ${
              lib.escapeShellArgs (lib.optional (sysroot != null) "${sysroot}/lib/rustlib/${target}/lib")
            }; do
              __bb_dylib=''${__bb_dylib:+$__bb_dylib:}$__bb_p
            done
            export LD_LIBRARY_PATH=$__bb_dylib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            unset __bb_dylib __bb_p
            for f in $(${jq} -r '.testSpec.envFlags[]' "$info"); do
              eval "$(${jq} -r '.env[] | "export \(.[0])=\(.[1] | @sh)"' "$f/directives.json")"
            done
            # Names the shell cannot export (CARGO_BIN_EXE_<bin-with-hyphens>)
            # go through `env`, as in lib/test-runs.nix.
            __bb_env=()
            eval "$(${jq} -r '.testSpec.env | to_entries[] | if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) then "export \(.key)=\(.value | @sh)" else "__bb_env+=(\("\(.key)=\(.value)" | @sh))" end' "$info")"
            ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") cfg.env)}
            ${lib.optionalString (cfg.path != [ ]) "export PATH=$PATH:${lib.makeBinPath cfg.path}"}
            export RUST_TEST_THREADS=$NIX_BUILD_CORES
            ${lib.optionalString coverage ''
              mkdir -p $out/profraw
              export LLVM_PROFILE_FILE=$out/profraw/%m-%p.profraw
            ''}
            mkdir -p /tmp/breakbulk-target-tmp $out
            files=(${if useCa then "${bin}/*" else "\"$wrapper\"/root/*"})
            cd "$CARGO_MANIFEST_DIR"
            set +e
            env "''${__bb_env[@]}" ${lib.escapeShellArgs runnerList} "''${files[0]}" ${lib.escapeShellArgs args} 2>&1 | tee $out/log
            status=''${PIPESTATUS[0]}
            set -e
            if [ "$status" -ne 0 ]; then
              echo "test binary ${b.package} ${key} failed (exit status $status)" >&2
              exit "$status"
            fi
          '';

      runs = lib.mapAttrs (
        _: rs: lib.listToAttrs (map (r: lib.nameValuePair (testRuns.binaryKey r.breakbulkRoot) (run r)) rs)
      ) byPackage;

      checks = lib.concatMapAttrs (
        pkg: bs:
        lib.mapAttrs' (b: drv: lib.nameValuePair "test/${pkg}/${b}" drv) (
          lib.filterAttrs (b: _: (testRuns.binaryConfig (testRuns.testConfig packages pkg) b).enable) bs
        )
      ) runs;
    in
    {
      inherit runs checks testPkgs;
      doctests = { };
      specs = { };
      runner = runnerList;
    };
in
{
  inherit
    available
    resolveMode
    rootName
    outputName
    mkBreakbulkDrv
    mkTestRuns
    ;
  instantiate = instantiateDynamic;
}
