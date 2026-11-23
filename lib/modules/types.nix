# Option types and helpers shared by breakbulk's modules.
{ lib }:
let
  inherit (lib) types mkOption;
  req = import ./version-req.nix { inherit lib; };
in
rec {
  # A Cargo version requirement (`^1.2`, `>=0.42, <0.50`), checked when
  # the option is read, so that a bad one is an error on its option.
  versionReq = types.addCheck types.str req.isReq // {
    name = "versionReq";
    description = "Cargo version requirement";
  };

  # A list whose definitions concatenate without evaluating their elements,
  # so that its length is known before its values are: an element can be a
  # product of the plan that reads the list. Each element is checked
  # against `elemType` when it is read. Not `types.listOf`, which evaluates
  # every element to drop those under `mkIf false`.
  lazyListOf =
    elemType:
    lib.mkOptionType {
      name = "lazyListOf";
      description = "list of ${
        types.optionDescriptionPhrase (class: class == "noun" || class == "composite") elemType
      }";
      descriptionClass = "composite";
      check = builtins.isList;
      merge =
        loc: defs:
        lib.concatLists (
          lib.imap1 (
            n: def:
            lib.imap1 (
              m: value:
              (lib.mergeDefinitions (loc ++ [ "[definition ${toString n}-entry ${toString m}]" ]) elemType [
                {
                  inherit (def) file;
                  inherit value;
                }
              ]).mergedValue
            ) def.value
          ) defs
        );
      emptyValue.value = [ ];
      getSubOptions = prefix: elemType.getSubOptions (prefix ++ [ "*" ]);
      getSubModules = elemType.getSubModules;
      substSubModules = m: lazyListOf (elemType.substSubModules m);
      nestedTypes.elemType = elemType;
    };

  # A list of packages, or a function from a package set to one. The
  # function form (`p: [ p.openssl ]`) is called with the package set that
  # matches each platform, rather than taking separate host and target
  # lists, which are easy to mix up; a plain list is used as given.
  # Several definitions concatenate, whatever form each one has.
  inputs = types.coercedTo (lazyListOf types.package) (l: _: l) (
    types.functionTo (lazyListOf types.package)
  );

  # An environment value: a string, or anything that turns into one (a
  # path, a derivation such as another package's product, a number or a
  # boolean). Derivations reach instantiation by reference.
  envValue = types.oneOf [
    types.str
    types.path
    types.package
    types.int
    types.bool
  ];

  # Lazy, so that the variables' names are known without their values: a
  # value can be a product of the plan whose instantiation lists the
  # names. Not `types.attrsOf`, which evaluates every value to drop those
  # under `mkIf false`.
  envAttrs = types.lazyAttrsOf envValue;

  # An env value as the string a unit sees. Booleans as "1" and "" (as
  # derivation attributes are).
  envString =
    v:
    if builtins.isBool v then
      (if v then "1" else "")
    else if builtins.isInt v then
      toString v
    else
      v;

  # A test-run environment value: an env value, or a function of the
  # run's facts (`{ workspaceRoot, ... }`) that returns one. The facts are
  # known only per run (lib/test-runs.nix resolveTestEnv), so the function
  # is kept until then.
  testEnvValue = types.either envValue (types.functionTo envValue);
  testEnvAttrs = types.lazyAttrsOf testEnvValue;

  # An env value as the string a run sees, keeping a function a function.
  testEnvString = v: if lib.isFunction v then facts: envString (v facts) else envString v;

  testEnvNote = ''
    A value can also be a function of the run, `run: …`, with
    `run.workspaceRoot`: the absolute path of the workspace's root
    directory in the files the run sees (its source view, or the checkout
    for a test app with `checkout`). For example
    `INSTA_WORKSPACE_ROOT = run: run.workspaceRoot;`. More attributes may
    be added, so take them with `{ workspaceRoot, ... }`.
  '';

  # What `envAttrs` and `inputs` being lazy means for `lib.mkIf`, for the
  # texts of their options.
  envNote = ''
    The variables' names are read before their values, so `lib.mkIf`
    goes around the whole set (`env = lib.mkIf cond { FOO = "x"; }`): on
    one value (`env.FOO = lib.mkIf false "x"`) it does not remove the
    variable, and reading it is an error.
  '';
  inputsNote = ''
    The list's length is read before its elements, so `lib.mkIf` goes
    around the whole list or function: on one element it does not remove
    the element, and reading it is an error.
  '';

  mkEnv =
    description:
    mkOption {
      type = envAttrs;
      default = { };
      description = description + "\n\n" + envNote;
    };

  mkTestEnv =
    description:
    mkOption {
      type = testEnvAttrs;
      default = { };
      description = description + "\n\n" + testEnvNote + "\n" + envNote;
    };

  mkInputs =
    description:
    mkOption {
      type = inputs;
      default = [ ];
      example = lib.literalExpression "p: [ p.openssl ]";
      description = description + "\n\n" + inputsNote;
    };

  # The content of a Cargo config file: tables of booleans, integers,
  # strings and arrays (Cargo's config has no floats or dates). Tables
  # merge and arrays concatenate between definitions; a single value set
  # twice needs `lib.mkForce`.
  cargoConfig =
    let
      value =
        types.oneOf [
          types.bool
          types.int
          types.str
          (types.listOf value)
          (types.attrsOf value)
        ]
        // {
          description = "Cargo config value";
        };
    in
    types.attrsOf value;

  # A selection of a workspace's members: `true` (all), `false` (none), a
  # list of package names, or `{ exclude = [ … ]; }` (all but those). One
  # value, not merged: two definitions at one priority must agree, and in
  # layers (`layer`) the higher one's replaces the lower's, a list
  # included. Not `types.oneOf`, whose list member would concatenate a
  # layer's list with a lower layer's, and refuse a list over a boolean.
  selection = lib.mkOptionType {
    name = "selection";
    description = "boolean, list of package names, or { exclude = [ … ]; }";
    descriptionClass = "conjunction";
    check =
      v:
      builtins.isBool v
      || (builtins.isList v && lib.all builtins.isString v)
      || (
        builtins.isAttrs v
        && lib.attrNames v == [ "exclude" ]
        && builtins.isList v.exclude
        && lib.all builtins.isString v.exclude
      );
    merge = lib.mergeEqualOption;
  };

  # A stage or check definition. Kept as raw values
  # so `lib.mkForce null` can remove one.
  stages = types.attrsOf (types.nullOr types.raw);

  # Whether an option type keeps one definition's value, where several
  # definitions at one priority conflict, rather than combining them
  # (lists concatenate, attribute sets and modules merge). A function's
  # definitions merge as its results do.
  singleValued =
    t:
    if t.name == "nullOr" || t.name == "functionTo" then
      singleValued t.nestedTypes.elemType
    else if t.name == "either" then
      singleValued t.nestedTypes.left && singleValued t.nestedTypes.right
    else
      lib.elem t.name [
        "selection"
        "str"
        "nonEmptyStr"
        "singleLineStr"
        "bool"
        "enum"
        "int"
        "float"
        "path"
        "package"
        "raw"
        "testRunner"
      ];

  # The modules of a layer's sub-layers (the `target.<triple>` and
  # `variant.<v>` of package settings): one `{ rank; module; }` per
  # definition, `rank` being that of the `layer` that gave it, so that an
  # evaluation can add each module as a layer of its own, ranked between
  # that layer and the next (lib/package-settings.nix).
  subLayers = lib.mkOptionType {
    name = "subLayers";
    description = "module";
    descriptionClass = "noun";
    check = m: builtins.isAttrs m || builtins.isFunction m || builtins.isPath m || builtins.isString m;
    merge =
      loc:
      map (d: {
        rank = if d.value ? _breakbulkLayer then d.value._breakbulkLayer else 0;
        module = lib.setDefaultModuleLocation "${d.file}, via option ${lib.showOption loc}" (
          if d.value ? _breakbulkLayer then d.value.module else d.value
        );
      });
  };

  # A layer of settings over a module evaluation: `layer options rank value
  # module`. `rank` (-1 < rank < 1) orders the layers of one evaluation;
  # definitions outside any layer have rank 0.
  # The definitions `module` gives single-valued options (of `options`,
  # and inside their attribute sets and submodules: `env.FOO`,
  # `test.binaries.<key>.enable`) are moved up by `rank` in priority, so
  # that of two definitions at one priority the higher layer's wins
  # instead of conflicting. A fraction keeps the order of any two integer
  # priorities: `mkForce` and `mkDefault` still win and lose as written.
  # Not `mkOverride` around the whole module: a list at a lower priority
  # would then be dropped, not concatenated. The definitions of the other
  # options are ordered by `rank` (`mkOrder`), so lists concatenate in
  # layer order whatever order the modules come in; within one layer,
  # `lib.mkBefore` and `lib.mkAfter` order them. A `subLayers` option
  # keeps each module with `rank`. `value name v` rewrites each value the
  # layer gives option `name` (`a.b` when nested), under its mkIf,
  # mkMerge, mkOverride and mkOrder. A module's key gets the rank, so a
  # file imported by two layers counts in both.
  layer =
    options:
    let
      optionAt = path: lib.attrByPath path null options;
      # A group of options (`checks` of `checks.docs`), not an option.
      isGroup =
        path:
        let
          o = optionAt path;
        in
        builtins.isAttrs o && !lib.isOption o;
      isAttrsType = t: t.name == "attrsOf" || t.name == "lazyAttrsOf";
      # The layer function of the submodule an option's values are, or are
      # attribute sets of; each computed once for every layer of `options`.
      nestedOf =
        t:
        if t.name == "submodule" then
          layer (t.getSubOptions [ ])
        else if isAttrsType t then
          nestedOf t.nestedTypes.elemType
        else
          null;
      nested = lib.mapAttrsRecursiveCond (o: !lib.isOption o) (_: o: nestedOf o.type) options;
      default = lib.modules.defaultOverridePriority;
    in
    rank: value:
    let
      under = underProperties;
      wrap = prio: v: if prio == default then v else lib.mkOverride prio v;
      leaf =
        prio: f: v:
        let
          t = v._type or null;
        in
        if t == "if" then
          v // { content = leaf prio f v.content; }
        else if t == "merge" then
          v // { contents = map (leaf prio f) v.contents; }
        else if t == "override" then
          v
          // {
            priority = v.priority - rank;
            content = under f v.content;
          }
        else
          lib.mkOverride (prio - rank) (under f v);
      # Far above any order a module writes, so the rank decides first.
      orderOf = p: rank * 1.0e9 + p;
      ordered =
        f: v:
        let
          t = v._type or null;
        in
        if t == "if" || t == "override" then
          v // { content = ordered f v.content; }
        else if t == "merge" then
          v // { contents = map (ordered f) v.contents; }
        else if t == "order" then
          v
          // {
            priority = orderOf v.priority;
            content = under f v.content;
          }
        else
          lib.mkOrder (orderOf lib.modules.defaultOrderPriority) (f v);
      # A definition `v` of an option of type `t` at priority `prio` (an
      # `mkOverride` around a set of options, pushed down to each).
      # `sub`: nestedOf t.
      def =
        t: sub: prio: f: v:
        if singleValued t then
          leaf prio f v
        else if t.name == "subLayers" then
          wrap prio (
            under (m: {
              _breakbulkLayer = rank;
              module = f m;
            }) v
          )
        else if t.name == "submodule" then
          # Not ordered: a submodule's merge takes definitions without
          # an order, and its own options order theirs.
          wrap prio (under (x: inner t sub (f x)) v)
        else
          wrap prio (ordered (x: inner t sub (f x)) v);
      inner =
        t: sub: x:
        if t.name == "submodule" then
          # A function, which a submodule whose attribute-set definitions
          # are its config only (`types.submodule`) still takes as a module.
          { ... }: sub rank (_: y: y) x
        else if isAttrsType t && builtins.isAttrs x then
          lib.mapAttrs (_: def t.nestedTypes.elemType sub default (y: y)) x
        else
          x;
      # A module's `config`. An `mkOverride` around several options goes
      # down to each, as the module system pushes it down.
      config =
        prio: path: c:
        let
          t = c._type or null;
        in
        if t == "if" then
          c // { content = config prio path c.content; }
        else if t == "merge" then
          c // { contents = map (config prio path) c.contents; }
        else if t == "override" then
          config c.priority path c.content
        else
          lib.mapAttrs (
            n: v:
            let
              p = path ++ [ n ];
              o = optionAt p;
            in
            if isGroup p then
              config prio p v
            else if lib.isOption o then
              def o.type (lib.getAttrFromPath p nested) prio (value (lib.concatStringsSep "." p)) v
            else
              wrap prio v
          ) c;
    in
    mapModule {
      config = config default [ ];
      key = k: "${toString k}#layer-${toString rank}";
    };

  # `f` on each value under a definition's properties (mkIf, mkMerge,
  # mkOverride, mkOrder).
  underProperties =
    f: v:
    let
      t = v._type or null;
    in
    if t == "if" || t == "override" || t == "order" then
      v // { content = underProperties f v.content; }
    else if t == "merge" then
      v // { contents = map (underProperties f) v.contents; }
    else
      f v;

  # A module with `config` applied to its `config` (the whole of it, under
  # any properties) and to that of every module it imports, and `key` to
  # its key and theirs: what a file is keyed by too.
  mapModule =
    {
      config,
      key ? k: k,
    }:
    let
      reserved = [
        "_class"
        "_file"
        "key"
        "disabledModules"
        "freeformType"
      ];
      module =
        m:
        if builtins.isPath m || builtins.isString m then
          # Keyed as the module system keys a file, so that a file imported
          # twice is still imported once.
          {
            key = key (toString m);
            _file = m;
            imports = [ (module (import m)) ];
          }
        else if lib.isFunction m then
          lib.setFunctionArgs (args: module (m args)) (lib.functionArgs m)
        else if (m._type or null) == "if" || (m._type or null) == "override" then
          module { config = m; }
        else
          let
            explicit = m ? config || m ? options;
          in
          builtins.intersectAttrs (lib.genAttrs (
            reserved
            ++ lib.optionals explicit [
              "options"
              "meta"
            ]
          ) (_: null)) m
          // lib.optionalAttrs (m ? key) { key = key m.key; }
          // {
            imports = map module (m.require or [ ] ++ m.imports or [ ]);
            config = config (
              if explicit then
                m.config or { }
              else
                removeAttrs m (
                  reserved
                  ++ [
                    "require"
                    "imports"
                  ]
                )
            );
          };
    in
    module;

  # An internal option collecting warnings from a submodule.
  warningsOption = mkOption {
    type = types.listOf types.str;
    default = [ ];
    internal = true;
    visible = false;
    description = "Warnings from this part of the configuration.";
  };

  # An internal option collecting cross-option checks from a submodule, as
  # NixOS's `assertions`: mkRepository fails with every false one's message
  # before it returns anything.
  assertionsOption = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          assertion = mkOption { type = types.bool; };
          message = mkOption { type = types.str; };
        };
      }
    );
    default = [ ];
    internal = true;
    visible = false;
    description = "Checks from this part of the configuration.";
  };

  # " (set in `a.nix')" for an option, for messages that name where a value
  # came from; empty when only anonymous modules set it.
  setIn =
    opt:
    let
      files = lib.filter (f: f != "<unknown-file>") opt.files;
    in
    lib.optionalString (files != [ ])
      " (set in ${lib.concatMapStringsSep " and " (f: "`${toString f}'") files})";
}
