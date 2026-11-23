# repo.explainSharing: why the units of two plans are or are not shared.
#
#   repo.explainSharing {
#     a = repo.workspaces.one.plans.x86_64-unknown-linux-gnu.default.build;
#     b = "two/x86_64-unknown-linux-gnu/default/build";   # or { workspace; target; variant; kind; }
#     package = "shared";      # or null (the default): every unit
#   }
#
# pairs the package's units in the two plans (by kind, crate name, crate
# types, platform and test mode; among several such, identical units
# first, then those with the same outputs) and, for each pair, says whether the
# unit derivations are the same and, when not, which fields of the
# rendered units differ: argv (as added and removed arguments), env, cwd,
# the env capture, and which dependency units differ. Store paths are
# compared with their hashes removed, so a field that differs only by a
# dependency's store path shows up under `deps` and not as its own
# reason. Unit keys (`-C metadata`) are never compared: they leave out
# rustflags (spike A, S13). `.text` is a readable report.
#
# In dynamic-derivation mode it reads the unit derivations through IFD
# mode (importing units.json, which builds breakbulk-instantiate and the
# plans): they are the same derivations the outer derivation writes,
# except units downstream of an embedded product, which IFD mode
# describes as IFD mode would build them.
{ lib, featureGates }:
{
  workspaces,
  # Variant of a workspace when a plan is named without one.
  defaultVariantOf,
  nativeTriple,
  nixFeatures,
}:
let
  # explainSharing reads plans and units.json in either mode and is not
  # counted in repo.nixFeatures (it is a function to call, not an output).
  explainFeatures = nixFeatures // {
    importFromDerivation = true;
  };
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
          variant ? defaultVariantOf workspace,
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
      planIndex.${discard h.outPath}
      or (throw "breakbulk: explainSharing: ${discard h.outPath} is not a plan of this repository")
    else
      fromParts h;

  readPlanOf =
    r:
    builtins.fromJSON (
      discard (
        featureGates.readOutput explainFeatures "explainSharing (plan.json)"
          "${r.inst.plans.${r.kind}}/plan.json"
      )
    );

  pkgNameOf =
    id:
    let
      frag = lib.last (lib.splitString "#" id);
      at = builtins.match "([^@]+)@(.*)" frag;
      url = lib.head (lib.splitString "?" (lib.head (lib.splitString "#" id)));
    in
    if at != null then lib.head at else lib.last (lib.splitString "/" (lib.removeSuffix "/" url));

  isTestUnit = u: u.test or false;
  unitLabel =
    u:
    if u.kind == "run" then
      "${pkgNameOf u.package} build-script run (${u.platform})"
    else
      "${pkgNameOf u.package} ${u.crate.name} [${lib.concatStringsSep "," u.crate.types}]${lib.optionalString (isTestUnit u) " test"} (${u.platform})";

  # Unit ids of one plan, by label, sorted, for one package (or all, when
  # null).
  grouped =
    plan: pkg:
    lib.mapAttrs (_: lib.sort (a: b: a < b)) (
      lib.groupBy (id: unitLabel plan.units.${id}) (
        lib.filter (id: pkg == null || pkgNameOf plan.units.${id}.package == pkg) (lib.attrNames plan.units)
      )
    );

  # Units of one plan, by label, for one package (or all, when null).
  labelled =
    plan: pkg:
    lib.concatMapAttrs (
      l: is:
      if lib.length is == 1 then
        { ${l} = lib.head is; }
      else
        lib.listToAttrs (lib.imap0 (i: id: lib.nameValuePair "${l} #${toString i}" id) is)
    ) (grouped plan pkg);

  # Unit ids a plan unit refers to (its dependencies, its script, its runs).
  refsOf =
    v:
    if builtins.isAttrs v then
      (if v ? out then [ v.out ] else [ ])
      ++ (if v ? splice then [ v.splice ] else [ ])
      ++ lib.concatMap refsOf (lib.attrValues v)
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
    sameElementsOtherOrder =
      a != b
      && lib.sort lib.lessThan (map builtins.toJSON a) == lib.sort lib.lessThan (map builtins.toJSON b);
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

in
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
  # Through IFD mode in both modes: in dynamic-derivation mode the unit
  # derivations are not known at evaluation time, and IFD mode's are the
  # same derivations (except downstream of an embedded product).
  unitsOf = r: r.inst.ifdUnits.${r.kind};
  ua = unitsOf ra;
  ub = unitsOf rb;
  ga = grouped pa package;
  gb = grouped pb package;
  allA = labelled pa null;
  allB = labelled pb null;
  revA = lib.mapAttrs' (l: id: lib.nameValuePair id l) allA;
  revB = lib.mapAttrs' (l: id: lib.nameValuePair id l) allB;
  labels = lib.sort (x: y: x < y) (lib.unique (lib.attrNames ga ++ lib.attrNames gb));
  outputsOf = plan: id: lib.attrNames (plan.units.${id}.outputs or { });
  # The units of one label, paired: identical derivations first, then
  # units with the same outputs (a check plan both checks and builds a
  # proc macro that is a member), then in unit id order. Several
  # entries are numbered.
  entriesOf =
    l:
    let
      step =
        match: st:
        lib.foldl' (
          acc: x:
          let
            y = lib.findFirst (match x) null acc.bs;
          in
          if y == null then
            acc // { as = acc.as ++ [ x ]; }
          else
            acc
            // {
              pairs = acc.pairs ++ [
                {
                  ia = x;
                  ib = y;
                }
              ];
              bs = lib.remove y acc.bs;
            }
        ) (st // { as = [ ]; }) st.as;
      paired =
        lib.pipe
          {
            pairs = [ ];
            as = ga.${l} or [ ];
            bs = gb.${l} or [ ];
          }
          [
            (step (x: y: ua.${x}.drvPath == ub.${y}.drvPath))
            (step (x: y: outputsOf pa x == outputsOf pb y))
            (step (_: _: true))
          ];
      entries =
        paired.pairs
        ++ map (x: {
          ia = x;
          ib = null;
        }) paired.as
        ++ map (y: {
          ia = null;
          ib = y;
        }) paired.bs;
    in
    if lib.length entries == 1 then
      [ (lib.head entries // { unit = l; }) ]
    else
      lib.imap0 (i: e: e // { unit = "${l} #${toString i}"; }) entries;
  pair =
    {
      unit,
      ia,
      ib,
    }:
    let
      l = unit;
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
  units = map pair (lib.concatMap entriesOf labels);
  show = v: builtins.toJSON v;
  fieldText =
    f: d:
    if d ? onlyA then
      "    ${f}: only in a: ${show d.onlyA}\n    ${f}: only in b: ${show d.onlyB}\n"
      + lib.optionalString d.sameElementsOtherOrder "    ${f}: same elements, different order\n"
    else if d ? a then
      "    ${f}: a = ${show d.a}\n    ${f}: b = ${show d.b}\n"
    else
      lib.concatStrings (
        lib.mapAttrsToList (k: x: "    ${f}.${k}: a = ${show x.a}, b = ${show x.b}\n") d
      );
  unitText =
    u:
    if u ? onlyIn then
      "  ${u.unit}: only in ${u.onlyIn}\n"
    else if u.same then
      "  ${u.unit}: shared (${u.drvA})\n"
    else
      "  ${u.unit}: differs\n"
      + lib.concatStrings (lib.mapAttrsToList fieldText u.fields)
      + lib.optionalString (
        u.deps != [ ]
      ) "    dependencies that differ: ${lib.concatStringsSep "; " u.deps}\n";
in
{
  inherit package units;
  a = ra.label;
  b = rb.label;
  shared = lib.all (u: u.same) units;
  text =
    "explainSharing ${what}: a = ${ra.label}, b = ${rb.label}\n"
    + (
      if units == [ ] then
        "  no units of ${what} in either plan\n"
      else
        lib.concatMapStrings unitText units
    );
}
