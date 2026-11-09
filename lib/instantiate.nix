# Instantiation in IFD mode: run `breakbulk-instantiate --emit json` over a
# plan in a derivation, import its `units.json`, and turn each entry into a
# unit derivation.
#
#   inst = breakbulk.instantiate { ... };
#   inst.units.<unit id>        the unit derivations (fixed point)
#   inst.roots."<package>/<kind>/<target>"
#                               a root: the root unit's output, or a stub
#                               (`.breakbulkRoot` says which)
#   inst.unitsJson              the instantiate derivation (its output is
#                               units.json)
#   inst.doctestAttrs.<package> the attributes of a library's doctest
#                               derivation (test plans), before `derivation`
#
# The instantiate derivation sees only names and tool paths, never a value
# with string context: units.json names every input by key, and this file
# substitutes the real value, with its context, for each key. So importing
# units.json realises the plan and the breakbulk-instantiate binary and
# nothing else: no toolchain, crate source, env capture or override value is
# built, and a source edit or a changed env value does not rerun the
# instantiate derivation at all (only the plan's and the keys' changes do).
# See crates/breakbulk-instantiate/src/output.rs for the format.
{ lib }:
let
  inherit (builtins)
    fromJSON
    isAttrs
    isPath
    isString
    readFile
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
      #   units (`test.sourceScope`): its `--test` compiles and doctests
      # sources.clippyConf."<dir>" = a member's clippy config tree
      #   (sourceViews.clippyConfTree), for clippy-driver's CLIPPY_CONF_DIR
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
      #   strictSources = null;
      # }
      # with package-wide and per-triple settings already merged per platform.
      overrides ? { },
      strictSources ? false,
      # { variant = "<name>"; roots = [ { package; target; kind; test;
      # requiredFeatures; } ]; } (see predictedRoots), or null to take the
      # plan's roots as they are.
      roots ? null,
      # The `--remap-path-scope` of non-test target compile units, for targets
      # whose products split debug info off (`"macro,diagnostics"`), or
      # null for every scope. See inputs.rs `shipped_remap_scope`.
      shippedRemapScope ? null,
      # `sourcePaths = "keep"`: no remaps of breakbulk's own.
      keepSourcePaths ? false,
      # The target's traits as breakbulk-instantiate reads them
      # (`breakbulk.targetTraits.forRust`, lib/target-traits.nix).
      targetTraits,
      # The toolchain's capabilities (`breakbulk.toolchainFacts.of`'s
      # `capabilities`): whether rustc takes `--remap-path-scope`.
      capabilities,
      name ? "breakbulk-units",
      storeDir ? builtins.storeDir,
    }:
    let
      workspace = sources.workspace or { };
      workspaceTest = sources.workspaceTest or { };
      clippyConf = sources.clippyConf or { };
      crates = sources.crates or { };
      spec = p: { env = { }; envCapture = null; } // p;
      platformSpec = { inherit host target; };
      ovPlatform = o: p: spec (o.${p} or { });

      # --- the instantiate derivation's inputs: keys and tool paths only ---

      noCtx = v: unsafeDiscardStringContext (str v);
      platformJson = s: {
        env = lib.attrNames (spec s).env;
        envCapture = (spec s).envCapture != null;
      };
      sourcesFile = toFile "sources.json" (toJSON (
        {
          workspace = lib.attrNames workspace;
          crates = lib.attrNames crates;
        }
        // lib.optionalAttrs (workspaceTest != { }) { workspaceTest = lib.attrNames workspaceTest; }
        // lib.optionalAttrs (clippyConf != { }) { clippyConf = lib.attrNames clippyConf; }
      ));
      toolchainsFile = toFile "toolchains.json" (toJSON ({
        inherit system storeDir targetTraits;
        inherit capabilities;
        tools = lib.mapAttrs (_: noCtx) tools;
        host = platformJson host;
        target = platformJson target;
      }
      // lib.optionalAttrs (shippedRemapScope != null) { inherit shippedRemapScope; }
      // lib.optionalAttrs keepSourcePaths { inherit keepSourcePaths; }));
      overridesFile = toFile "overrides.json" (toJSON {
        inherit strictSources;
        packages = lib.mapAttrs (
          _: o:
          lib.genAttrs platforms (p: platformJson (ovPlatform o p))
          // lib.optionalAttrs ((o.strictSources or null) != null) { inherit (o) strictSources; }
        ) overrides;
      });
      rootsFile = toFile "roots.json" (toJSON roots);

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
        ];
      };

      json = fromJSON (readFile unitsJson);

      # --- substitution -----------------------------------------------------

      # Every key units.json may name, with its value (and context).
      inputs =
        lib.mapAttrs' (d: v: lib.nameValuePair "src:${d}" (str v)) workspace
        // lib.mapAttrs' (d: v: lib.nameValuePair "test-src:${d}" (str v)) workspaceTest
        // lib.mapAttrs' (d: v: lib.nameValuePair "clippy-conf:${d}" (str v)) clippyConf
        // lib.mapAttrs' (id: v: lib.nameValuePair "crate:${id}" (str v)) crates
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
        set.${k} or (throw "breakbulk: units.json names the input `${k}`, which was not given to instantiate");

      part =
        p:
        if isString p then
          p
        else if p ? unit then
          # A weak reference names a path the unit reaches through its
          # dependencies' references (their manifests), not as an input.
          (if p.weak or false then unsafeDiscardStringContext else lib.id)
            units.${p.unit}.${p.output}.outPath
        else if p ? join then
          # A list-like variable set by several env layers: the non-empty
          # layers, joined (breakbulk_unit::env::append).
          lib.concatStringsSep p.sep (lib.filter (s: s != "") (map (lib.concatMapStrings part) p.join))
        else if p.json or false then
          input inputsJson p.input
        else
          input inputs p.input;

      value = v: if isAttrs v then lib.concatMapStrings part v.parts else v;

      drvAttrs =
        d:
        let
          attrs = lib.mapAttrs (_: value) d.attrs;
          big = attrs ? BREAKBULK_UNIT && stringLength attrs.BREAKBULK_UNIT > json.passAsFileAbove;
        in
        attrs // lib.optionalAttrs big { passAsFile = [ "BREAKBULK_UNIT" ]; };
      mkDrv = d: derivation (drvAttrs d);

      units =
        assert lib.assertMsg (json.version == 2) "breakbulk: units.json version ${toString json.version} is not supported";
        lib.mapAttrs (_: mkDrv) json.units;

      rootsOut = lib.mapAttrs (
        _: r:
        (if r ? unit then units.${r.unit}.${r.output} else mkDrv r.stub)
        // {
          breakbulkRoot = {
            inherit (r)
              package
              target
              kind
              test
              ;
            unit = r.unit or null;
            reason = r.reason or null;
            # Test roots: nextest's metadata (lib/test-runs.nix nextestSpec).
            nextest = r.nextest or null;
            # Product roots: the target-platform runs below the unit (#23).
            buildScriptRuns = r.buildScriptRuns or [ ];
            # Product roots: the `debug` outputs of the units below (the
            # libraries' `.dwo` files with split-debuginfo = "unpacked"),
            # for the `linked` stage.
            debugBelow = map (id: units.${id}.debug) (r.debugUnits or [ ]);
          };
        }
      ) json.roots;
    in
    {
      inherit units unitsJson;
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
      roots = rootsOut;
      # Test plans: package name to the attributes of its doctest derivation
      # (`breakbulk-unit doctest`), for lib/test-runs.nix to add the test
      # configuration to before calling `derivation`.
      doctestAttrs = lib.mapAttrs' (
        id: d: lib.nameValuePair (lib.removePrefix "d-" id) (drvAttrs d)
      ) (json.doctests or { });
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
