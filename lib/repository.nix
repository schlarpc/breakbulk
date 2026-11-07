# mkRepository: the module-system entry point ("Nix library" in
# docs/implementation.md).
#
#   repo = breakbulk.mkRepository {
#     inherit pkgs;
#     root = ./.;
#     modules = [ ./nix/rust.nix ];
#   };
#
# It evaluates breakbulk's options (lib/modules) with the user's modules
# and the curated -sys defaults (lib/sys-defaults.nix), then makes one
# mkWorkspace call per (workspace, target, variant). Outputs:
#
#   repo.workspaces.<ws>.packages.<pkg>                  native target, default variant
#   repo.workspaces.<ws>.tests.<pkg>.<test>              the same, test binaries
#   repo.workspaces.<ws>.target.<triple>.packages.<pkg>
#   repo.workspaces.<ws>.target.<triple>.tests.<pkg>.<test>
#   repo.workspaces.<ws>.target.<triple>.variants.<v>.{packages,tests}
#   repo.workspaces.<ws>.plans.<triple>.<v>.{build,test}  the plan derivations
#   repo.workspaces.<ws>.devShell
#   repo.workspaces.<ws>.instances.<triple>.<v>           the mkWorkspace results
#   repo.checks."<ws>/<triple>/<pkg>/<name>"              flattened
#   repo.sources.<crate> / ."<crate>@<version>"           fetched crate sources
#   repo.explainSharing { a; b; package; }                why units differ
#   repo.config, repo.options                             the evaluated modules
#   repo.optionsDoc                                       nixosOptionsDoc of them
#
# A product (`packages.<pkg>`) is the package's build-plan roots (bins in
# bin/, cdylibs, dylibs and staticlibs in lib/), copied into one output.
# Roots Cargo did not build (required features) are left out and listed in
# `.unbuilt`; when no root was built, the product is the first stub, which
# fails with the reason. Every root is also under `.roots."<kind>/<target>"`.
# Stages, debug outputs and test runs come with M4.
#
# Test names (`tests.<pkg>.<name>`): an integration test by its name, the
# library's unit tests as `lib`, a bin's unit tests as `bin-<name>`, an
# example as `example-<name>`. When two of these collide, both use the
# full root name `<kind>/<name>`.
{
  lib,
  util,
  lockfile,
  manifest,
  envCapture,
  mkFetch,
  mkTools,
  mkWorkspace,
}:
let
  versionReq = import ./modules/version-req.nix { inherit lib; };
  bt = import ./modules/types.nix { inherit lib; };
  bbModules = import ./modules;
  sysDefaults = ./sys-defaults.nix;
  mkDevShell = import ./devshell.nix { inherit lib; };
in
{
  pkgs,
  root,
  modules ? [ ],
  specialArgs ? { },
  tools ? mkTools pkgs,
}@args:
let
  userModules = args.modules or [ ];

  eval = lib.evalModules {
    modules = bbModules ++ [ sysDefaults ] ++ userModules;
    specialArgs = {
      inherit pkgs;
    }
    // specialArgs;
  };
  cfg = eval.config;

  nativeTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  fetchArgs = {
    inherit (cfg)
      registries
      gitHashes
      gitTrees
      gitSubdirs
      gitSubmodules
      ;
  };
  fetch = mkFetch pkgs fetchArgs;

  # --- lockfiles -------------------------------------------------------------

  wsDirOf = ws: util.normalizeRel ws.path;
  lockOf =
    wsName: ws:
    let
      p = root + "/${util.joinRel (wsDirOf ws) "Cargo.lock"}";
    in
    if builtins.pathExists p then
      lockfile.read p
    else
      throw "breakbulk: workspaces.${wsName}: ${util.joinRel (wsDirOf ws) "Cargo.lock"} does not exist; run `cargo generate-lockfile` and commit it";
  locks = lib.mapAttrs lockOf cfg.workspaces;
  allEntries = lib.concatLists (lib.attrValues locks);

  # --- per-package overrides -------------------------------------------------

  # "name" or "name@<requirement>".
  parseKey =
    k:
    let
      m = builtins.match "([^@]+)@(.+)" k;
    in
    if m == null then
      {
        name = k;
        req = null;
      }
    else
      {
        name = builtins.elemAt m 0;
        req = builtins.elemAt m 1;
      };

  overrideMatches =
    k: e:
    let
      p = parseKey k;
      o = cfg.packages.${k};
    in
    p.name == e.name
    && (p.req == null || versionReq.matches p.req e.version)
    && (o.version == null || versionReq.matches o.version e.version);

  # Keys some module other than the curated defaults defined.
  userKeys = lib.unique (
    lib.concatMap (d: lib.attrNames d.value) (
      lib.filter (d: d.file != "breakbulk/lib/sys-defaults.nix") eval.options.packages.definitionsWithLocations
    )
  );
  unmatchedWarnings = map (
    k:
    "breakbulk: `packages.${lib.strings.escapeNixIdentifier k}` matches no package in any workspace's Cargo.lock${
      lib.optionalString (cfg.packages.${k}.version != null) " (version requirement `${cfg.packages.${k}.version}`)"
    }; it has no effect."
  ) (lib.filter (k: !(lib.any (overrideMatches k) allEntries)) userKeys);

  # Unversioned keys first, so a versioned override wins over a plain one.
  orderedKeys = lib.sort (
    a: b:
    let
      pa = parseKey a;
      pb = parseKey b;
      va = pa.req != null || cfg.packages.${a}.version != null;
      vb = pb.req != null || cfg.packages.${b}.version != null;
    in
    if va != vb then vb else a < b
  ) (lib.attrNames cfg.packages);

  emptyOverride = {
    env = { };
    nativeInputs = _: [ ];
    inputs = _: [ ];
    extraSources = [ ];
    host = {
      env = { };
      nativeInputs = _: [ ];
      inputs = _: [ ];
    };
    target = { };
    strictSources = null;
  };
  catFn = f: g: p: f p ++ g p;
  mergeSide = a: b: {
    env = a.env // b.env;
    nativeInputs = catFn a.nativeInputs b.nativeInputs;
    inputs = catFn a.inputs b.inputs;
  };
  mergeOverride = a: b: {
    env = a.env // b.env;
    nativeInputs = catFn a.nativeInputs b.nativeInputs;
    inputs = catFn a.inputs b.inputs;
    extraSources = a.extraSources ++ b.extraSources;
    host = mergeSide a.host b.host;
    target = lib.zipAttrsWith (_: lib.foldl' mergeSide (mergeSide emptyOverride.host emptyOverride.host)) [
      a.target
      b.target
    ];
    strictSources = if b.strictSources != null then b.strictSources else a.strictSources;
  };

  # The merged override for one lockfile entry, or null.
  overrideFor =
    e:
    let
      ks = lib.filter (k: overrideMatches k e) orderedKeys;
    in
    if ks == [ ] then null else lib.foldl' (acc: k: mergeOverride acc cfg.packages.${k}) emptyOverride ks;

  envStrings = lib.mapAttrs (_: bt.envString);

  # The package set of a target's units. Cross package sets come with the
  # presets (M3).
  targetPkgs =
    triple:
    if triple == nativeTriple then
      pkgs
    else
      throw "breakbulk: package inputs on target ${triple} need that target's package set, which comes with the toolchain presets (M3)";

  # instantiate's overrides for one workspace on one target, keyed
  # "<name>@<version>".
  instOverrides =
    entries: triple:
    lib.listToAttrs (
      lib.concatMap (
        e:
        let
          o = overrideFor e;
          t = o.target.${triple} or (mergeSide emptyOverride.host emptyOverride.host);
          capture =
            platform: nativeInputs: inputs:
            let
              p = targetPkgs triple;
              sets =
                if platform == "target" then
                  {
                    host = p;
                    build = p.buildPackages;
                  }
                else
                  {
                    host = p.buildPackages;
                    build = p.buildPackages.buildPackages;
                  };
            in
            if nativeInputs sets.build == [ ] && inputs sets.host == [ ] then
              null
            else
              envCapture.forPackage {
                pkgs = p;
                inherit platform nativeInputs inputs;
                name = e.name;
              };
        in
        lib.optional (o != null) (
          lib.nameValuePair "${e.name}@${e.version}" {
            host = {
              env = envStrings (o.env // o.host.env);
              envCapture = capture "host" (catFn o.nativeInputs o.host.nativeInputs) (catFn o.inputs o.host.inputs);
            };
            target = {
              env = envStrings (o.env // t.env);
              envCapture = capture "target" (catFn o.nativeInputs t.nativeInputs) (catFn o.inputs t.inputs);
            };
            inherit (o) strictSources;
          }
        )
      ) entries
    );

  # extraSources by package name, from every matching override.
  extraSourcesOf =
    entries:
    lib.foldl' (
      acc: e:
      let
        o = overrideFor e;
      in
      if o == null || o.extraSources == [ ] then
        acc
      else
        acc // { ${e.name} = lib.unique ((acc.${e.name} or [ ]) ++ o.extraSources); }
    ) { } entries;

  # --- workspaces --------------------------------------------------------------

  checkMode =
    wsName: vName: v:
    if v.mode != "build" then
      throw "breakbulk: workspaces.${wsName}.variants.${vName}: mode `${v.mode}` is not implemented yet (M4)"
    else
      v;

  instance =
    wsName: ws: triple: vName:
    let
      v = checkMode wsName vName ws.variants.${vName};
      entries = locks.${wsName};
      sel = ws.targets.${triple}.packages;
    in
    mkWorkspace pkgs {
      inherit root tools fetchArgs;
      path = ws.path;
      toolchain = {
        inherit (ws.toolchain) rustc cargo;
      };
      target = triple;
      inherit (v)
        profile
        features
        noDefaultFeatures
        allFeatures
        ;
      variant = vName;
      select = if sel == null then [ ] else sel;
      extraSources = extraSourcesOf entries;
      packageOverrides = instOverrides entries triple;
      inherit (cfg) strictSources;
      targetEnv = envStrings (cfg.targets.${triple}.env or { });
      name = "${wsName}-${triple}-${vName}";
    };

  rootName = r: "${r.breakbulkRoot.kind}/${r.breakbulkRoot.target}";

  # One product per package from its build-plan roots.
  products =
    inst: sel:
    let
      byPkg = lib.groupBy (r: r.breakbulkRoot.package) (lib.attrValues inst.roots);
      selected = if sel == null then byPkg else lib.filterAttrs (n: _: lib.elem n sel) byPkg;
      product =
        pkg: rs:
        let
          built = lib.filter (r: r.breakbulkRoot.unit != null) rs;
          unbuilt = lib.filter (r: r.breakbulkRoot.unit == null) rs;
          roots = lib.listToAttrs (map (r: lib.nameValuePair (rootName r) r) rs);
          dirOf = r: if r.breakbulkRoot.kind == "bin" then "bin" else "lib";
          drv =
            if built == [ ] then
              lib.head rs
            else
              pkgs.runCommand pkg { } (
                ''
                  mkdir -p $out
                ''
                + lib.concatMapStrings (
                  r:
                  if r.breakbulkRoot.kind == "bin" then
                    # Cargo's own copy is named after the target, without
                    # the -C extra-filename hash.
                    ''
                      files=(${r}/*)
                      if [ ''${#files[@]} -ne 1 ]; then
                        echo "expected one file in ${r}, found: ''${files[*]}" >&2
                        exit 1
                      fi
                      install -D -m755 "''${files[0]}" $out/bin/${r.breakbulkRoot.target}
                    ''
                  else
                    ''
                      mkdir -p $out/${dirOf r}
                      cp -L --no-preserve=mode ${r}/* $out/${dirOf r}/
                    ''
                ) built
              );
        in
        drv
        // {
          inherit roots;
          unbuilt = map (r: {
            root = rootName r;
            inherit (r.breakbulkRoot) reason;
          }) unbuilt;
        };
    in
    lib.mapAttrs product selected;

  testName =
    r:
    let
      b = r.breakbulkRoot;
    in
    if b.kind == "test" then
      b.target
    else if b.kind == "lib" then
      "lib"
    else
      "${b.kind}-${b.target}";

  # tests.<pkg>.<name>: test-plan roots installed as $out/bin/<target>
  # (stubs as they are).
  testsOf =
    inst: sel:
    let
      byPkg = lib.groupBy (r: inst.tests.${r}.breakbulkRoot.package) (lib.attrNames inst.tests);
      selected = if sel == null then byPkg else lib.filterAttrs (n: _: lib.elem n sel) byPkg;
    in
    lib.mapAttrs (
      _: names:
      let
        named = map (n: {
          root = n;
          short = testName inst.tests.${n};
          long = rootName inst.tests.${n};
        }) names;
        counts = lib.groupBy (x: x.short) named;
      in
      lib.listToAttrs (
        map (
          x: lib.nameValuePair (if lib.length counts.${x.short} > 1 then x.long else x.short) inst.testBins.${x.root}
        ) named
      )
    ) selected;

  workspaceOut =
    wsName: ws:
    let
      instances = lib.mapAttrs (triple: _: lib.mapAttrs (vName: _: instance wsName ws triple vName) ws.variants) ws.targets;
      perTarget = lib.mapAttrs (
        triple: vs:
        let
          sel = ws.targets.${triple}.packages;
          variants = lib.mapAttrs (_: inst: {
            packages = products inst sel;
            tests = testsOf inst sel;
          }) vs;
          dflt =
            variants.${ws.defaultVariant}
              or (throw "breakbulk: workspaces.${wsName}.defaultVariant `${ws.defaultVariant}` is not one of its variants (${lib.concatStringsSep ", " (lib.attrNames ws.variants)})");
        in
        {
          inherit variants;
          inherit (dflt) packages tests;
        }
      ) instances;
    in
    {
      inherit instances;
      target = perTarget;
      packages = perTarget.${nativeTriple}.packages or { };
      tests = perTarget.${nativeTriple}.tests or { };
      plans = lib.mapAttrs (_: lib.mapAttrs (_: inst: inst.plans)) instances;
      devShell = mkDevShell {
        inherit pkgs nativeTriple;
        name = wsName;
        inherit (ws) toolchain;
        inherit (ws.devShell) setTarget;
        overrides = lib.filter (o: o != null) (map overrideFor locks.${wsName});
        targetEnv = envStrings (cfg.targets.${nativeTriple}.env or { });
      };
    };

  workspaces = lib.mapAttrs workspaceOut cfg.workspaces;

  # repo.checks: every product that built something, and every test
  # binary (test runs come with M4).
  checks = lib.concatMapAttrs (
    wsName: w:
    lib.concatMapAttrs (
      triple: t:
      lib.concatMapAttrs (
        pkg: p:
        lib.optionalAttrs (p.unbuilt == [ ] || lib.length p.unbuilt < lib.length (lib.attrNames p.roots)) {
          "${wsName}/${triple}/${pkg}/build" = p;
        }
      ) t.packages
      // lib.concatMapAttrs (
        pkg: ts: lib.mapAttrs' (n: d: lib.nameValuePair "${wsName}/${triple}/${pkg}/test-${n}" d) ts
      ) t.tests
    ) w.target
  ) workspaces;

  # --- warnings and mode -----------------------------------------------------

  warnings = cfg.warnings ++ unmatchedWarnings;
  warned = x: lib.foldr (w: acc: lib.warn w acc) x warnings;
  checkedMode =
    x:
    if cfg.mode == "dynamic" then
      throw "breakbulk: mode = \"dynamic\" is not implemented yet (M5); use \"ifd\" or \"auto\""
    else
      x;
  guard = x: checkedMode (warned x);

  # --- explainSharing --------------------------------------------------------
  #
  #   repo.explainSharing {
  #     a = repo.workspaces.one.plans.x86_64-unknown-linux-gnu.default.build;
  #     b = "two/x86_64-unknown-linux-gnu/default/build";   # or { workspace; target; variant; kind; }
  #     package = "shared";      # or null (the default): every unit
  #   }
  #
  # pairs the package's units in the two plans (by kind, crate name, crate
  # types, platform and test mode) and, for each pair, says whether the
  # unit derivations are the same and, when not, which fields of the
  # rendered units differ: argv (as added and removed arguments), env, cwd,
  # the env capture, and which dependency units differ. Store paths are
  # compared with their hashes removed, so a field that differs only by a
  # dependency's store path shows up under `deps` and not as its own
  # reason. Unit keys (`-C metadata`) are never compared: they leave out
  # rustflags (spike A, S13). `.text` is a readable report.

  discard = builtins.unsafeDiscardStringContext;
  planIndex = lib.concatMapAttrs (
    wsName: w:
    lib.concatMapAttrs (
      triple: vs:
      lib.concatMapAttrs (
        vName: inst:
        lib.mapAttrs' (
          kind: plan:
          lib.nameValuePair (discard plan.outPath) {
            inherit inst kind;
            label = "${wsName}/${triple}/${vName}/${kind}";
          }
        ) inst.plans
      ) vs
    ) w.instances
  ) workspaces;

  resolvePlan =
    h:
    let
      fromParts =
        {
          workspace,
          target ? nativeTriple,
          variant ? cfg.workspaces.${workspace}.defaultVariant,
          kind ? "build",
        }:
        {
          inst =
            workspaces.${workspace}.instances.${target}.${variant}
              or (throw "breakbulk: explainSharing: no plan ${workspace}/${target}/${variant}");
          inherit kind;
          label = "${workspace}/${target}/${variant}/${kind}";
        };
    in
    if builtins.isString h then
      let
        ps = lib.splitString "/" h;
        n = lib.length ps;
      in
      fromParts (
        {
          workspace = lib.elemAt ps 0;
        }
        // lib.optionalAttrs (n > 1) { target = lib.elemAt ps 1; }
        // lib.optionalAttrs (n > 2) { variant = lib.elemAt ps 2; }
        // lib.optionalAttrs (n > 3) { kind = lib.elemAt ps 3; }
      )
    else if h ? outPath then
      planIndex.${discard h.outPath} or (throw "breakbulk: explainSharing: ${discard h.outPath} is not a plan of this repository")
    else
      fromParts h;

  readPlanOf =
    r: builtins.fromJSON (discard (builtins.readFile "${r.inst.plans.${r.kind}}/plan.json"));

  pkgNameOf =
    id:
    let
      frag = lib.last (lib.splitString "#" id);
      at = builtins.match "([^@]+)@(.*)" frag;
      url = lib.head (lib.splitString "?" (lib.head (lib.splitString "#" id)));
    in
    if at != null then lib.head at else lib.last (lib.splitString "/" (lib.removeSuffix "/" url));

  isTestUnit = u: lib.elem "--test" (lib.filter builtins.isString (u.args or [ ]));
  unitLabel =
    u:
    if u.kind == "run" then
      "${pkgNameOf u.package} build-script run (${u.platform})"
    else
      "${pkgNameOf u.package} ${u.crate.name} [${lib.concatStringsSep "," u.crate.types}]${lib.optionalString (isTestUnit u) " test"} (${u.platform})";

  # Units of one plan, by label, for one package (or all, when null).
  labelled =
    plan: pkg:
    let
      ids = lib.filter (id: pkg == null || pkgNameOf plan.units.${id}.package == pkg) (lib.attrNames plan.units);
      groups = lib.groupBy (id: unitLabel plan.units.${id}) ids;
    in
    lib.concatMapAttrs (
      l: is:
      if lib.length is == 1 then
        { ${l} = lib.head is; }
      else
        lib.listToAttrs (lib.imap0 (i: id: lib.nameValuePair "${l} #${toString i}" id) (lib.sort (a: b: a < b) is))
    ) groups;

  # Unit ids a plan unit refers to (its dependencies, its script, its runs).
  refsOf =
    v:
    if builtins.isAttrs v then
      (if v ? out then [ v.out ] else [ ]) ++ (if v ? splice then [ v.splice ] else [ ]) ++ lib.concatMap refsOf (lib.attrValues v)
    else if builtins.isList v then
      lib.concatMap refsOf v
    else
      [ ];

  noHash =
    s:
    lib.concatStrings (
      map (p: if builtins.isString p then p else "${builtins.storeDir}/…-") (
        builtins.split "${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-" s
      )
    );
  normalize =
    v:
    if builtins.isString v then
      noHash v
    else if builtins.isList v then
      map normalize v
    else if builtins.isAttrs v then
      lib.mapAttrs (_: normalize) v
    else
      v;

  renderedOf =
    drv:
    let
      u = drv.drvAttrs.BREAKBULK_UNIT or null;
    in
    if u == null then { } else builtins.fromJSON (discard u);

  listDiff = a: b: {
    onlyA = lib.filter (x: !(lib.elem x b)) a;
    onlyB = lib.filter (x: !(lib.elem x a)) b;
    sameElementsOtherOrder = a != b && lib.sort lib.lessThan (map builtins.toJSON a) == lib.sort lib.lessThan (map builtins.toJSON b);
  };
  attrDiff =
    a: b:
    lib.filterAttrs (_: x: x != null) (
      lib.genAttrs (lib.unique (lib.attrNames a ++ lib.attrNames b)) (
        k:
        if (a.${k} or null) == (b.${k} or null) then
          null
        else
          {
            a = a.${k} or null;
            b = b.${k} or null;
          }
      )
    );

  fieldDiffs =
    ra: rb:
    let
      a = normalize ra;
      b = normalize rb;
      fields = lib.unique (lib.attrNames a ++ lib.attrNames b);
      one =
        f:
        let
          x = a.${f} or null;
          y = b.${f} or null;
        in
        if x == y then
          null
        else if f == "args" && builtins.isList x && builtins.isList y then
          listDiff x y
        else if builtins.isAttrs x && builtins.isAttrs y then
          attrDiff x y
        else
          {
            a = x;
            b = y;
          };
    in
    lib.filterAttrs (_: d: d != null) (lib.genAttrs fields one);

  explainSharing =
    {
      a,
      b,
      package ? null,
    }:
    let
      what = if package == null then "all packages" else package;
      ra = resolvePlan a;
      rb = resolvePlan b;
      pa = readPlanOf ra;
      pb = readPlanOf rb;
      ua = ra.inst.units.${ra.kind};
      ub = rb.inst.units.${rb.kind};
      la = labelled pa package;
      lb = labelled pb package;
      allA = labelled pa null;
      allB = labelled pb null;
      revA = lib.mapAttrs' (l: id: lib.nameValuePair id l) allA;
      revB = lib.mapAttrs' (l: id: lib.nameValuePair id l) allB;
      labels = lib.sort (x: y: x < y) (lib.unique (lib.attrNames la ++ lib.attrNames lb));
      pair =
        l:
        let
          ia = la.${l} or null;
          ib = lb.${l} or null;
        in
        if ia == null || ib == null then
          {
            unit = l;
            same = false;
            onlyIn = if ia == null then rb.label else ra.label;
          }
        else
          let
            da = ua.${ia};
            db = ub.${ib};
            same = da.drvPath == db.drvPath;
            depsA = lib.unique (map (r: revA.${r} or r) (refsOf pa.units.${ia}));
            depsB = lib.unique (map (r: revB.${r} or r) (refsOf pb.units.${ib}));
            depDiff = lib.filter (
              dl:
              let
                x = allA.${dl} or null;
                y = allB.${dl} or null;
              in
              x == null || y == null || ua.${x}.drvPath != ub.${y}.drvPath
            ) (lib.unique (depsA ++ depsB));
          in
          {
            unit = l;
            inherit same;
            drvA = da.drvPath;
            drvB = db.drvPath;
          }
          // lib.optionalAttrs (!same) {
            fields = fieldDiffs (renderedOf da) (renderedOf db);
            deps = depDiff;
          };
      units = map pair labels;
      show = v: builtins.toJSON v;
      fieldText =
        f: d:
        if d ? onlyA then
          "    ${f}: only in a: ${show d.onlyA}\n    ${f}: only in b: ${show d.onlyB}\n"
          + lib.optionalString d.sameElementsOtherOrder "    ${f}: same elements, different order\n"
        else if d ? a then
          "    ${f}: a = ${show d.a}\n    ${f}: b = ${show d.b}\n"
        else
          lib.concatStrings (lib.mapAttrsToList (k: x: "    ${f}.${k}: a = ${show x.a}, b = ${show x.b}\n") d);
      unitText =
        u:
        if u ? onlyIn then
          "  ${u.unit}: only in ${u.onlyIn}\n"
        else if u.same then
          "  ${u.unit}: shared (${u.drvA})\n"
        else
          "  ${u.unit}: differs\n"
          + lib.concatStrings (lib.mapAttrsToList fieldText u.fields)
          + lib.optionalString (u.deps != [ ]) "    dependencies that differ: ${lib.concatStringsSep "; " u.deps}\n";
    in
    {
      inherit package units;
      a = ra.label;
      b = rb.label;
      shared = lib.all (u: u.same) units;
      text =
        "explainSharing ${what}: a = ${ra.label}, b = ${rb.label}\n"
        + (if units == [ ] then "  no units of ${what} in either plan\n" else lib.concatMapStrings unitText units);
    };
in
{
  workspaces = guard workspaces;
  checks = guard checks;
  sources = fetch.byName (fetch.sourcesFor (lockfile.merge (lib.attrValues locks)));
  inherit explainSharing warnings;
  inherit (eval) config options;
  optionsDoc = pkgs.nixosOptionsDoc {
    options = removeAttrs eval.options [
      "_module"
      "warnings"
    ];
    warningsAreErrors = false;
  };
}
