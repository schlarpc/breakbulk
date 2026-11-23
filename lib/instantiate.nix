# Instantiation in IFD mode: run `breakbulk-instantiate --emit json` over a
# plan in a derivation, import its `units.json`, and turn each entry into a
# unit derivation, and each root's wrapper into a derivation: the same
# root shape as dynamic-derivation mode's (`rootShape`).
#
#   inst = breakbulk.instantiate { ... };
#   inst.units.<unit id>        the unit derivations (fixed point)
#   inst.roots."<package>/<kind>/<target>"
#                               a root (`rootShape`)
#   inst.doctests.<package>     the predicted doctests (`rootShape`)
#   inst.docs                   doc plans: the docs (`cargo doc`'s folder);
#                               null for other plans
#   inst.allUnits               a derivation on every output of every unit
#   inst.buildScriptRuns        { runsFile; }: a file listing the `flags`
#                               output of every build-script run, read at
#                               build time
#   inst.unitsJson              the instantiate derivation (its output is
#                               units.json)
#
# The instantiate derivation sees only names and tool paths, never a value
# with string context: units.json names every input by key, and this file
# substitutes the real value, with its context, for each key. So importing
# units.json realises the plan and the breakbulk-instantiate binary and
# nothing else: no toolchain, crate source, env capture or override value is
# built, and a source edit or a changed env value does not rerun the
# instantiate derivation at all (only the plan's and the keys' changes do).
# See crates/breakbulk-instantiate/src/output.rs for the format.
{
  lib,
  featureGates,
  util,
}:
let
  inherit (builtins)
    fromJSON
    isAttrs
    isPath
    isString
    stringLength
    substring
    toFile
    toJSON
    unsafeDiscardStringContext
    ;

  # A value as a string, keeping its context. Paths are copied to the store
  # (`toString` of a path would give its original location).
  str = v: if isPath v || isAttrs v then "${v}" else toString v;

  # The inside of a JSON string literal; `toJSON` keeps the context.
  jsonInside =
    s:
    let
      j = toJSON s;
    in
    substring 1 (stringLength j - 2) j;

  platforms = [
    "host"
    "target"
  ];

  # What the plan's `empty` references resolve in: repository paths in the
  # units of registry and git crates, which have no source view. This
  # directory, copied with every entry left out. Not nixpkgs'
  # emptyDirectory: that is built with stdenv and changes with nixpkgs,
  # and with it every unit that names it. This store path depends only on
  # its name and its (empty) contents.
  emptyDir = builtins.path {
    name = "empty";
    path = ./.;
    filter = _: _: false;
  };

  # breakbulk_format::plan::RootKind, as it serializes.
  rootKinds = [
    "lib"
    "bin"
    "cdylib"
    "dylib"
    "staticlib"
    "example"
    "test"
    "bench"
  ];
in
rec {
  instantiate =
    {
      # The breakbulk-instantiate package (with bin/breakbulk-instantiate).
      breakbulkInstantiate,
      # The system that runs the instantiate derivation and builds units.
      system,
      # plan.json: a path, or a string such as "${planDrv}/plan.json".
      plan,
      # sources.workspace."<dir relative to the repository root>" = source view
      # sources.workspaceTest."<dir>" = the wider view of that package's test
      #   units (`test.sourceScope`): the compile units plan.json marks
      #   `test`, and doctests
      # sources.workspaceTargets."<dir>"."<kind>/<name>" = the view of
      #   one Cargo target's units, in place of `workspace` for them (a
      #   build-script run's is its script's target)
      # sources.workspaceTestTargets."<dir>"."<kind>/<name>" = the same
      #   in place of `workspaceTest`
      # sources.targetRoots."<dir>" = [ "<path relative to the root>" ... ]
      #   the paths per-target views of that package leave out, for a hint
      # sources.predicted."<key>" = { spec; value; }: the keys (listed in
      #   workspaceTargets or workspaceTestTargets) whose views source
      #   prediction narrows (`predictSources`): `spec`, breakbulk-predict's
      #   ViewSpec (dynamic-derivation mode makes the view from it), and
      #   `value`, the view (IFD mode; never read in dynamic mode)
      # sources.wrapperConfig."<dir>" = a member's tree of the workspace
      #   wrapper's config files (sourceViews.wrapperConfigTree), for `wrapperConfigVar`
      # sources.testOnly."<dir>" = [ "<path relative to the root>" ... ]
      #   the paths left out of that package's normal view
      #   (sourceViews.testOnlyPaths), for a hint when a unit or test run
      #   fails reading one
      # sources.junk."<dir>" = [ "<path relative to the root>" ... ]: what
      #   every view of that package leaves out (sourceViews.junkPaths),
      #   for the same hints
      # sources.custom = [ "<dir>" ... ]: the packages whose `sources`
      #   functions choose their views' files, for the same hints
      # sources.crates."<Cargo package id>" = fetched crate source
      sources ? { },
      # Tool name to a store path or a path inside one. Must include
      # `breakbulk-unit` (the builder executable) and `shell` (bash, for root
      # stubs). Every literal store path in the plan must start with one.
      tools,
      # The toolchain spec per platform: env values, and the base env
      # capture (an env.json file) or null.
      host ? { },
      target ? { },
      # overrides."<name>" or ."<name>@<version>" = {
      #   host = { env = { }; envCapture = null; };
      #   target = { env = { }; envCapture = null; };
      #   outDirRemove = [ { beside; path; } ];  # buildScript.outDirRemove
      # }
      # with package-wide and per-triple settings already merged per platform.
      overrides ? { },
      # { variant = "<name>"; roots = [ { package; target; kind; test;
      # platform; requiredFeatures; } ]; } (see predictedRoots), or null to take the
      # plan's roots as they are.
      roots ? null,
      # The `--remap-path-scope` of non-test target compile units, for targets
      # whose products split debug info off (`"macro,diagnostics,coverage"`), or
      # null for every scope. See inputs.rs `shipped_remap_scope`.
      shippedRemapScope ? null,
      # `sourcePaths = "keep"`: no remaps of breakbulk's own.
      keepSourcePaths ? false,
      # The extensions of the side files that compile units run through a
      # wrapper keep beside their crate files (`variants.<v>.sideFiles`).
      sideFiles ? [ ],
      # The variable that names a unit's directory in its package's tree of
      # wrapper config files (`sources.wrapperConfig`), on the units the
      # workspace wrapper (the `rustc-workspace-wrapper` tool) runs on.
      wrapperConfigVar ? null,
      # The toolchain's capabilities (`breakbulk.toolchainFacts.of`'s
      # `capabilities`): whether rustc takes `--remap-path-scope`.
      capabilities,
      name ? "breakbulk-units",
      # What the root wrappers are named after (`<outerName>-<output>`, as
      # dynamic-derivation mode's outer derivation names them), and the
      # coreutils they run with.
      outerName ? name,
      coreutils,
      # Test plans: the predicted doctests, package name -> the attributes
      # its doctest derivation gets from the test configuration
      # (testRuns.doctestConfig).
      doctests ? { },
      # Doc plans: the plan has a docs derivation.
      docs ? false,
      storeDir ? builtins.storeDir,
      # The record importing units.json is checked against
      # (lib/nix-features.nix; repo.nixFeatures, from mkRepository).
      nixFeatures ? featureGates.standalone { },
    }:
    let
      workspace = sources.workspace or { };
      workspaceTest = sources.workspaceTest or { };
      workspaceTargets = sources.workspaceTargets or { };
      workspaceTestTargets = sources.workspaceTestTargets or { };
      targetRoots = sources.targetRoots or { };
      wrapperConfig = sources.wrapperConfig or { };
      testOnly = sources.testOnly or { };
      junk = sources.junk or { };
      custom = sources.custom or [ ];
      predicted = sources.predicted or { };
      crates = sources.crates or { };
      spec =
        p:
        {
          env = { };
          envCapture = null;
        }
        // p;
      platformSpec = { inherit host target; };
      ovPlatform = o: p: spec (o.${p} or { });

      # --- the instantiate derivation's inputs: keys and tool paths only ---

      noCtx = v: util.devirtualizeAndDiscard (str v);
      platformJson = s: {
        env = lib.attrNames (spec s).env;
        envCapture = (spec s).envCapture != null;
      };
      sourcesFile = toFile "sources.json" (
        toJSON (
          {
            workspace = lib.attrNames workspace;
            crates = lib.attrNames crates;
          }
          // lib.optionalAttrs (workspaceTest != { }) { workspaceTest = lib.attrNames workspaceTest; }
          // lib.optionalAttrs (workspaceTargets != { }) {
            workspaceTargets = lib.mapAttrs (_: lib.attrNames) workspaceTargets;
          }
          // lib.optionalAttrs (workspaceTestTargets != { }) {
            workspaceTestTargets = lib.mapAttrs (_: lib.attrNames) workspaceTestTargets;
          }
          // lib.optionalAttrs (targetRoots != { }) { inherit targetRoots; }
          // lib.optionalAttrs (wrapperConfig != { }) { wrapperConfig = lib.attrNames wrapperConfig; }
          // lib.optionalAttrs (testOnly != { }) { inherit testOnly; }
          // lib.optionalAttrs (junk != { }) { inherit junk; }
          // lib.optionalAttrs (custom != [ ]) { inherit custom; }
          // lib.optionalAttrs (predicted != { }) { predicted = lib.attrNames predicted; }
        )
      );
      toolchainsFile = toFile "toolchains.json" (
        toJSON (
          {
            inherit system storeDir;
            inherit capabilities;
            tools = lib.mapAttrs (_: noCtx) tools;
            host = platformJson host;
            target = platformJson target;
          }
          // lib.optionalAttrs (shippedRemapScope != null) { inherit shippedRemapScope; }
          // lib.optionalAttrs keepSourcePaths { inherit keepSourcePaths; }
          // lib.optionalAttrs (sideFiles != [ ]) { inherit sideFiles; }
          // lib.optionalAttrs (wrapperConfigVar != null) { inherit wrapperConfigVar; }
        )
      );
      overridesFile = toFile "overrides.json" (toJSON {
        packages = lib.mapAttrs (
          _: o:
          lib.genAttrs platforms (p: platformJson (ovPlatform o p))
          // lib.optionalAttrs ((o.outDirRemove or [ ]) != [ ]) { inherit (o) outDirRemove; }
        ) overrides;
      });
      rootsFile = toFile "roots.json" (toJSON roots);
      rootList = if roots == null then [ ] else roots.roots;
      outerFile = toFile "outer.json" (
        toJSON (outerOf {
          inherit outerName docs;
          roots = rootList;
          doctests = lib.attrNames doctests;
        })
      );

      unitsJson = derivation {
        name = "${name}.json";
        inherit system;
        builder = "${breakbulkInstantiate}/bin/breakbulk-instantiate";
        args = [
          "--emit"
          "json"
          "--plan"
          plan
          "--sources"
          sourcesFile
          "--toolchains"
          toolchainsFile
          "--overrides"
          overridesFile
        ]
        ++ lib.optionals (roots != null) [
          "--roots"
          rootsFile
        ]
        ++ [
          "--outer"
          outerFile
        ];
      };

      json = fromJSON (
        featureGates.readOutput nixFeatures "the units of `${name}` (units.json)" unitsJson
      );

      # --- substitution -----------------------------------------------------

      # Every key units.json may name, with its value (and context).
      inputs =
        lib.mapAttrs' (d: v: lib.nameValuePair "src:${d}" (str v)) workspace
        // lib.mapAttrs' (d: v: lib.nameValuePair "test-src:${d}" (str v)) workspaceTest
        // lib.concatMapAttrs (
          d: ts: lib.mapAttrs' (t: v: lib.nameValuePair "src:${d}#${t}" (str v)) ts
        ) workspaceTargets
        // lib.concatMapAttrs (
          d: ts: lib.mapAttrs' (t: v: lib.nameValuePair "test-src:${d}#${t}" (str v)) ts
        ) workspaceTestTargets
        // lib.mapAttrs (_: p: str p.value) predicted
        // lib.mapAttrs' (d: v: lib.nameValuePair "wrapper-config:${d}" (str v)) wrapperConfig
        // lib.mapAttrs' (id: v: lib.nameValuePair "crate:${id}" (str v)) crates
        // {
          "empty-dir" = str emptyDir;
          "wrapper:coreutils" = str coreutils;
        }
        # Each doctest's test configuration (shape.rs `doctest_key`).
        // lib.concatMapAttrs (
          pkg: attrs: lib.mapAttrs' (k: v: lib.nameValuePair "doctest:${pkg}:${k}" (str v)) attrs
        ) doctests
        // lib.mapAttrs' (n: v: lib.nameValuePair "tool:${n}" (str v)) tools
        // lib.concatMapAttrs (
          p: s:
          lib.mapAttrs' (k: v: lib.nameValuePair "env:${p}:${k}" (str v)) (spec s).env
          // lib.optionalAttrs ((spec s).envCapture != null) { "capture:${p}" = str (spec s).envCapture; }
        ) platformSpec
        // lib.concatMapAttrs (
          pkg: o:
          lib.concatMapAttrs (
            p: _:
            let
              s = ovPlatform o p;
            in
            lib.mapAttrs' (k: v: lib.nameValuePair "override:${pkg}:env:${p}:${k}" (str v)) s.env
            // lib.optionalAttrs (s.envCapture != null) { "override:${pkg}:capture:${p}" = str s.envCapture; }
          ) platformSpec
        ) overrides;
      inputsJson = lib.mapAttrs (_: jsonInside) inputs;

      input =
        set: k:
        set.${k}
          or (throw "breakbulk: units.json names the input `${k}`, which was not given to instantiate");

      part =
        p:
        if isString p then
          p
        else if p ? unit then
          # A weak reference names a path the unit reaches through its
          # dependencies' references (their manifests), not as an input.
          (if p.weak or false then unsafeDiscardStringContext else lib.id) drvs.${p.unit}.${p.output}.outPath
        else if p ? join then
          # A list-like variable set by several env layers: the non-empty
          # layers, joined (breakbulk_unit::env::append).
          lib.concatStringsSep p.sep (lib.filter (s: s != "") (map (lib.concatMapStrings part) p.join))
        else if p.json or false then
          input inputsJson p.input
        else
          input inputs p.input;

      value = v: if isAttrs v then lib.concatMapStrings part v.parts else v;

      # A unit always has `passAsFile`, empty when its text is short: were
      # the attribute present only for long texts, the names of a unit's
      # attributes, and so selecting any of its outputs, would need its
      # substituted text, which can name a product of this same plan.
      drvAttrs =
        d:
        let
          attrs = lib.mapAttrs (_: value) d.attrs;
        in
        attrs
        // lib.optionalAttrs (d.attrs ? BREAKBULK_UNIT) {
          passAsFile = lib.optional (
            stringLength attrs.BREAKBULK_UNIT > json.passAsFileAbove
          ) "BREAKBULK_UNIT";
        };
      mkDrv = d: derivation (drvAttrs d);

      units =
        assert lib.assertMsg (
          json.version == 4
        ) "breakbulk: units.json version ${toString json.version} is not supported";
        lib.mapAttrs (_: mkDrv) json.units;
      # What parts name: units, and the stubs, doctests and docs the
      # wrappers link (`nodes`, whose keys are no unit ids).
      drvs = units // lib.mapAttrs (_: mkDrv) (json.nodes or { });
      wrappers = lib.mapAttrs (_: mkDrv) (json.wrappers or { });
      shape = rootShape {
        inherit
          system
          coreutils
          outerName
          docs
          ;
        roots = rootList;
        shell = tools.shell;
        doctests = lib.attrNames doctests;
        wrapperOf =
          _: what: output:
          (wrappers.${output} or (throw "breakbulk: units.json has no wrapper for the ${what}")).outPath;
      };

    in
    {
      inherit units unitsJson;
      # The unit derivations, under the name dynamic-derivation mode gives
      # them (explainSharing).
      ifdUnits = units;
      # Test plans: each doctest derivation the wrappers link, by package
      # (their attributes, for tests that run one by hand).
      doctestDrvs = lib.mapAttrs' (k: d: lib.nameValuePair (lib.removePrefix "doctest:" k) d) (
        lib.filterAttrs (k: _: lib.hasPrefix "doctest:" k) drvs
      );
      # Doc plans: the docs derivation the docs' wrapper links.
      docsDrv = drvs.docs or null;
      # Each root's unit output, or null for one Cargo did not build (its
      # wrapper's `root`), for tests and debugging.
      rootUnits = lib.mapAttrs (_: r: if r ? unit then units.${r.unit}.${r.output} else null) json.roots;
      delivery = "ifd";
      inherit (shape)
        roots
        doctests
        docs
        allUnits
        buildScriptRuns
        ;
      # For dynamic-derivation mode (lib/dynamic.nix), which runs the same
      # instantiation inside its outer derivation: the files given to
      # breakbulk-instantiate, and every input key's value with its context.
      # Neither forces units.json.
      files = {
        inherit
          sourcesFile
          toolchainsFile
          overridesFile
          rootsFile
          ;
      };
      inherit inputs;
      # The predicted views' specs by key, for dynamic-derivation mode's
      # outer derivation, which makes those views itself: `inputs` has
      # them too, but from import from derivation.
      predictedSpecs = lib.mapAttrs (_: p: p.spec) predicted;
    };

  # The output name of a root's or doctest's wrapper (`n` a root name, or
  # `<package>/doctest`): `<package>.<kind>.<target>.drv`. A dynamic
  # derivation's output must be a valid derivation name, and both modes
  # name wrappers alike. Package and target names cannot contain `.` or
  # `/`.
  outputName =
    n:
    let
      o = "${lib.replaceStrings [ "/" ] [ "." ] n}.drv";
    in
    if builtins.match "[A-Za-z0-9+._?=-]+" o != null && !(lib.hasPrefix "." o) then
      o
    else
      throw "breakbulk: the root `${n}` has a name that cannot be a derivation output name";

  # outer.json without `leave` or `submit`: every predicted root's wrapper
  # (`roots`, in predictedRoots' shape), each predicted doctest's
  # (`doctests`, package names), the docs' (`docs`), and the `units.drv`
  # and `runs.drv` ones. Root outputs always have a `.` before `.drv`, and
  # package names none, so no two can be named alike.
  outerOf =
    {
      outerName,
      roots,
      doctests,
      docs,
    }:
    {
      name = outerName;
      outputs = lib.listToAttrs (
        map (
          r:
          let
            n = rootName r;
          in
          lib.nameValuePair n (outputName n)
        ) roots
      );
      doctests = lib.genAttrs doctests (pkg: outputName "${pkg}/doctest");
      units = "units.drv";
      runs = "runs.drv";
    }
    // lib.optionalAttrs docs { docs = "docs.drv"; };

  # What a plan's instantiation gives, from its wrappers, in both delivery
  # modes: each wrapper's output (`wrapperOf package what output`, a store
  # path string; `package` is null for the plan-wide ones) is a directory
  # read at build time (crates/breakbulk-instantiate/src/shape.rs).
  #
  #   roots."<pkg>/<kind>/<target>"   a small derivation symlinking the
  #                        wrapper's `root`, with `breakbulkRoot` = { package;
  #                        target; kind; test; platform; requiredFeatures;
  #                        wrapper; } (the prediction's, which
  #                        instantiation checks against the plan; test runs
  #                        pick their system by `platform`). A product root
  #                        Cargo did not build (required features) fails
  #                        with the reason; a test root's is the stub, which
  #                        succeeds and logs it.
  #   doctests.<pkg>       a small derivation linking the doctest's output
  #                        (its `log`), or a log saying why the plan has no
  #                        doctest for the package; `breakbulkDoctest`
  #   docs                 the docs derivation's output, or null
  #   allUnits             building it builds every unit of the plan
  #                        (`$out/units` lists their outputs): what check
  #                        variants build
  #   buildScriptRuns      { runsFile; }: a file listing the `flags` output
  #                        of every build-script run of the plan, on both
  #                        platforms, and building nothing else
  rootShape =
    {
      system,
      shell,
      coreutils,
      outerName,
      roots,
      doctests,
      docs,
      wrapperOf,
    }:
    let
      storeName = s: lib.replaceStrings [ "/" ] [ "-" ] s;
      link =
        name: what: output:
        derivation {
          inherit name system;
          target = wrapperOf null what output;
          builder = shell;
          args = [
            "-c"
            ''${coreutils}/bin/ln -s "$target" "$out"''
          ];
        };
      mkRoot =
        r:
        let
          n = rootName r;
          wrapper = wrapperOf r.package "root `${n}`" (outputName n);
        in
        derivation {
          name = storeName "${r.package}-${r.kind}${
            lib.optionalString (r.test && r.kind != "test") "-test"
          }-${r.target}";
          inherit system wrapper;
          builder = shell;
          # A product root Cargo did not build has no `root`, only the
          # reason (`not-built`): fail with it.
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
              platform
              ;
            # Whether Cargo builds the root is known at build time only
            # (the wrapper's `not-built`).
            requiredFeatures = r.requiredFeatures or null;
            inherit wrapper;
          };
        };
      mkDoctest =
        pkg:
        let
          wrapper = wrapperOf pkg "doctest of `${pkg}`" (outputName "${pkg}/doctest");
        in
        derivation {
          name = storeName "${pkg}-doctest";
          inherit system wrapper;
          builder = shell;
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
            inherit wrapper;
          };
        };
      docsOut = derivation {
        name = outerName;
        inherit system;
        wrapper = wrapperOf null "docs" "docs.drv";
        builder = shell;
        args = [
          "-c"
          ''${coreutils}/bin/ln -s "$wrapper/root" "$out"''
        ];
      };
      allRuns = link "${outerName}-runs" "runs" "runs.drv";
    in
    {
      roots = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) (mkRoot r)) roots);
      doctests = lib.genAttrs doctests mkDoctest;
      docs = if docs then docsOut else null;
      allUnits = link "${outerName}-units" "units" "units.drv";
      buildScriptRuns = {
        runsFile = "${allRuns}/runs";
      };
    };

  # A root name as instantiation names roots: `<package>/<kind>/<target>`,
  # with `-test` added to the kind of test roots other than test targets
  # (`root_name` in breakbulk-instantiate). Package and target names have
  # no `/`.
  rootNameRegex =
    let
      kinds = lib.concatStringsSep "|" rootKinds;
    in
    "([^/]+)/(${kinds}|(${lib.concatStringsSep "|" (lib.remove "test" rootKinds)})-test)/([^/]+)";

  # A root's name (rootNameRegex) from its predicted form.
  rootName =
    r: "${r.package}/${if r.test && r.kind != "test" then "${r.kind}-test" else r.kind}/${r.target}";

  # The roots of one plan kind, in the shape `instantiate` takes: `names`
  # (the `roots` option's list for the kind) when given, else the
  # prediction from the manifests. An entry of `names` is a root name or
  # `{ name; platform; }`. A bare name, or a null platform, takes the
  # platform the prediction gives that root, else `target`.
  planRoots =
    {
      workspaceRoots,
      planKind,
      variant,
      names ? null,
    }:
    let
      predicted = predictedRoots { inherit workspaceRoots planKind variant; };
      byName = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) r) predicted.roots);
      named =
        e:
        let
          n = if builtins.isString e then e else e.name;
          m = builtins.match rootNameRegex n;
          kind = builtins.elemAt m 1;
          base = lib.removeSuffix "-test" kind;
          p = byName.${n} or { };
          given = if builtins.isAttrs e then e.platform or null else null;
        in
        if m == null then
          throw "breakbulk: `${n}` is not a root name (`<package>/<kind>/<target>`, the kind one of ${lib.concatStringsSep ", " rootKinds}, with `-test` for test roots)"
        else
          {
            package = builtins.elemAt m 0;
            target = builtins.elemAt m 3;
            kind = base;
            test = kind == "test" || base != kind;
            requiredFeatures = p.requiredFeatures or null;
            platform = if given != null then given else p.platform or "target";
          };
    in
    if names == null then
      predicted
    else
      {
        inherit variant;
        roots = map named names;
      };

  # The predicted roots of one plan kind ("build", "test" or "bench"), in the
  # shape `instantiate` takes, from roots.workspaceRoots.
  #
  # A library is a root of a build plan once per linkable crate type
  # (cdylib, dylib, staticlib). In the test and bench plans its own unit-test
  # binary is a root of kind `lib` (`<pkg>/lib-test/<target>`).
  predictedRoots =
    {
      workspaceRoots,
      planKind,
      variant,
    }:
    let
      one =
        pkg: r:
        let
          base = {
            package = pkg;
            target = r.name;
            requiredFeatures = r.requiredFeatures;
            test = r.mode != "build";
            # Cargo builds a target for the build machine (a proc macro's
            # unit tests) as a host unit (`CompileKind::for_target`).
            platform = if r.forHost then "host" else "target";
          };
        in
        if r.kind == "lib" then
          if r.mode == "build" then
            map (k: base // { kind = k; }) (
              lib.filter (k: lib.elem k r.crateTypes) [
                "cdylib"
                "dylib"
                "staticlib"
              ]
            )
          else
            # The library's own test harness (`--test` on the lib target).
            [ (base // { kind = "lib"; }) ]
        else
          [ (base // { inherit (r) kind; }) ];
    in
    {
      inherit variant;
      roots = lib.concatLists (
        lib.mapAttrsToList (pkg: p: lib.concatMap (one pkg) p.roots.${planKind}) workspaceRoots
      );
    };
}
