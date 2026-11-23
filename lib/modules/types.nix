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

  # A separator of an env list: one character, as breakbulk-unit takes it.
  # A checked `str`, so that `layer` ranks it as the single value it is.
  envSeparator = types.addCheck types.str (s: lib.stringLength s == 1);

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

  # One variable of an env layer: a value, which replaces the value of the
  # layers below (the env capture's included), or a list of values, which
  # are appended to it, joined with the variable's separator
  # (`envSeparatorOf`). The definitions of all layers fold in layer order
  # (`envOver`), so lists concatenate and a later string starts again;
  # `lib.mkForce` keeps only its own definitions. The merged value is a
  # value, a list, or `{ _type = "breakbulkEnv"; replace; append; }` (a
  # value with lists after it). List elements are checked when they are
  # read, so that a list's length is known before its elements are.
  envEntryOf =
    item:
    lib.mkOptionType {
      name = "envEntry";
      description = "${
        types.optionDescriptionPhrase (class: class == "noun" || class == "composite") item
      } (replaces) or list of them (appends)";
      descriptionClass = "composite";
      check = v: builtins.isList v || item.check v;
      merge = loc: defs: lib.foldl' (acc: d: envOver acc d.value) null defs;
    };

  # `v` (one layer's definition) over `acc` (the layers below, or null).
  envOver =
    acc: v:
    if !(builtins.isList v) then
      v
    else if acc == null then
      v
    else if builtins.isList acc then
      acc ++ v
    else if acc._type or null == "breakbulkEnv" then
      acc // { append = acc.append ++ v; }
    else
      {
        _type = "breakbulkEnv";
        replace = acc;
        append = v;
      };

  # Env attribute sets, lowest layer first, as one (`env` then
  # `forHost.env`): each variable's values fold as an option's definitions
  # do. A variable only one layer sets is left unevaluated.
  envLayers =
    layers:
    lib.zipAttrsWith (_: vs: if lib.length vs == 1 then lib.head vs else lib.foldl' envOver null vs) (
      lib.filter (l: l != { }) layers
    );

  # `f` applied to every value of a merged env entry, whatever its form.
  envMapValues =
    f: v:
    if builtins.isList v then
      map f v
    else if v._type or null == "breakbulkEnv" then
      v
      // {
        replace = f v.replace;
        append = map f v.append;
      }
    else
      f v;

  # The separator lists of `name` are joined with: `separators.<name>` (a
  # setting's `envSeparators`), else the built-in table's
  # (crates/breakbulk-unit/src/env-separators.json, which breakbulk-unit
  # reads too: `:` for search paths, a space for flag lists; the
  # `_FOR_BUILD` and `_FOR_TARGET` forms as their base names), else `:`.
  builtinEnvSeparators = lib.importJSON ../../crates/breakbulk-unit/src/env-separators.json;
  envSeparatorOf =
    separators: name:
    let
      base = lib.removeSuffix "_FOR_TARGET" (lib.removeSuffix "_FOR_BUILD" name);
    in
    separators.${name} or builtinEnvSeparators.${base} or ":";

  # The non-empty values of a list joined with `sep`, each as the string a
  # unit sees.
  envJoin =
    sep: vs: lib.concatStringsSep sep (lib.filter (x: x != "") (map (x: "${envString x}") vs));

  # A merged env entry as instantiate takes it: a value (replaces), or
  # `{ append; sep; }` (appends). A value with lists after it is one value.
  envSpec =
    separators: name: v:
    let
      sep = envSeparatorOf separators name;
    in
    if builtins.isList v then
      {
        append = envJoin sep v;
        inherit sep;
      }
    else if v._type or null == "breakbulkEnv" then
      envJoin sep ([ v.replace ] ++ v.append)
    else
      envString v;

  # An env attribute set as instantiate takes it.
  envSpecs = separators: lib.mapAttrs (envSpec separators);

  # A merged env entry as one string, for a consumer that cannot append
  # (the dev shell): the lists joined.
  envFlat =
    separators: name: v:
    let
      s = envSpec separators name v;
    in
    if builtins.isAttrs s && !(lib.isDerivation s) then s.append else s;

  # Lazy, so that the variables' names are known without their values: a
  # value can be a product of the plan whose instantiation lists the
  # names. Not `types.attrsOf`, which evaluates every value to drop those
  # under `mkIf false`.
  envAttrs = types.lazyAttrsOf (envEntryOf envValue);

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
  # run's facts (`{ workspaceRoot, ... }`) that returns one; a variable
  # takes one, or a list of them. The facts are known only per run
  # (lib/test-runs.nix resolveTestEnv), so a function is kept until then.
  testEnvValue = types.either envValue (types.functionTo envValue);
  testEnvAttrs = types.lazyAttrsOf (envEntryOf testEnvValue);

  # A merged test-run env entry with each value as the string a run sees,
  # keeping a function a function.
  testEnvString = envMapValues (
    v: if lib.isFunction v then facts: envString (v facts) else envString v
  );

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
    A string (or path, package, number, boolean) replaces the
    variable's value from the layers below, the env capture's included; a
    list of them is appended to it, joined with the variable's separator
    (`envSeparators`; by default `:` for search paths and unknown names, a
    space for flag lists such as `NIX_CFLAGS_COMPILE`; see
    [the table](../unit-builder.md#list-variables)). Lists from every
    layer concatenate; `lib.mkForce` keeps only its own definition.

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

  # A submodule whose definitions may also be `null`, which stands for
  # `{ enable = false; }`, so that fields merge across definitions as in
  # any submodule and `null` (or `lib.mkForce null`) still removes the
  # entry. Not `types.nullOr`: there a `null` and a set at one priority
  # conflict, so a plain `null` could not remove what a preset defines.
  # `nullAs` is read by `layer` below. The module system rebuilds a
  # submodule type from its modules (`substSubModules`), so that is
  # wrapped too.
  nullableSubmodule =
    sub:
    sub
    // {
      description = "null or ${sub.description}";
      check = x: x == null || sub.check x;
      merge =
        loc: defs: sub.merge loc (map (d: if d.value == null then d // { value = nullAs; } else d) defs);
      substSubModules = m: nullableSubmodule (sub.substSubModules m);
      inherit nullAs;
    };
  nullAs = {
    enable = false;
  };

  # `after` and `before` of a stage: a stage name, a list of them, or
  # null. One value, which a higher layer replaces (`singleValued`).
  stageRefs = lib.mkOptionType {
    name = "stageRefs";
    description = "null, stage name or list of stage names";
    descriptionClass = "conjunction";
    check = v: v == null || builtins.isString v || (builtins.isList v && lib.all builtins.isString v);
    merge = lib.mergeEqualOption;
  };

  enableOption = what: {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the ${what} exists. A definition `null` sets it to false.";
    };
  };
  caOption = what: {
    ca = mkOption {
      type = types.bool;
      default = true;
      description = ''
        false: the ${what}'s derivation stays input-addressed when the
        repository's `ca` is on, and its `run` may return something that
        is not a derivation (which cannot be made content-addressed).
      '';
    };
  };

  # A post-link stage (lib/stages.nix). Its fields merge across
  # definitions: a preset's stage with the user's `after`.
  stage = nullableSubmodule (
    types.submodule {
      options =
        enableOption "stage"
        // caOption "stage"
        // {
          after = mkOption {
            type = stageRefs;
            default = null;
            description = "The stage or stages this one runs after.";
          };
          before = mkOption {
            type = stageRefs;
            default = null;
            description = "The stage or stages this one runs before.";
          };
          run = mkOption {
            type = types.raw;
            description = "`{ input, product, target, pkgs }: <derivation>`: the stage's output from its input, the previous stage's.";
          };
        };
    }
  );
  stages = types.attrsOf stage;

  # A check on a product (lib/stages.nix).
  check = nullableSubmodule (
    types.submodule {
      options =
        enableOption "check"
        // caOption "check"
        // {
          on = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "The stage whose output the check reads (`linked` for the raw link output); null: the product.";
          };
          run = mkOption {
            type = types.raw;
            description = "`{ input, product, target, pkgs }: <derivation>`, which fails when the check does.";
          };
        };
    }
  );
  checks = types.attrsOf check;

  # `linkerKinds` of a target spec and of a workspace's host
  # (lib/presets/linker.nix `builtinKinds`, the table they start from).
  linkerKindsOption = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          on = mkOption {
            type = types.raw;
            description = "`traits: bool`: whether the kind links for a target with these [traits](../../explanation/internals/toolchains.md#target-traits).";
          };
          what = mkOption {
            type = types.str;
            default = "some";
            description = "The targets `on` accepts, as messages name them (`\"Linux\"`).";
          };
          bitcode = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the linker reads rustc's LLVM bitcode, as `crossLanguageLto` (`-C linker-plugin-lto`) needs.";
          };
          incompatible = mkOption {
            type = types.raw;
            default = _: null;
            defaultText = lib.literalExpression "_: null";
            description = ''
              `ctx: null or message`: why the kind cannot link in this
              context, which is an evaluation error naming the kind.
              `ctx` is `{ triple; traits; lto; staticNonPie; zig; ndk; }`
              (`staticNonPie`: the link makes non-PIE static glibc
              executables; `zig`: linuxPortable's `zig cc`, or null;
              `ndk`: presets.android's NDK clang and `--target`, or
              null).
            '';
          };
          build = mkOption {
            type = types.raw;
            description = ''
              `args: path`: the linker. `args` is `{ pkgs; packageSet;
              llvm; lld; zig; ndk; triple; traits; }`: mkRepository's
              `pkgs`, the package set whose C toolchain drives the link,
              nixpkgs' LLVM packages of rustc's major release (the
              toolchain's facts), an `lld` package a preset passes, or
              null, linuxPortable's `zig cc`, and presets.android's
              `{ clang; target; }`. A C compiler driver
              with a flag is `breakbulk.presets.ccDriverLinker {
              packageSet; flag; }`.
            '';
          };
          lld = mkOption {
            type = types.nullOr types.raw;
            default = null;
            description = ''
              `args: { name; version; patches; }`, the LLD the kind links
              with, for the macOS SDK's linker requirements (`args`:
              `{ rustc; llvm; }`), or null for a kind that is not an
              Apple linker.
            '';
          };
        };
      }
    );
    default = { };
    example = lib.literalExpression ''
      {
        wild = {
          on = traits: traits.isLinux;
          what = "Linux";
          build = { packageSet, ... }: breakbulk.presets.ccDriverLinker {
            inherit packageSet;
            cc = (packageSet.stdenvAdapters.useWildLinker packageSet.stdenv).cc;
            flag = "-fuse-ld=wild";
          };
        };
      }
    '';
    description = ''
      The linker kinds `linkerKind` may name: breakbulk's own
      (`breakbulk.presetHelpers.builtinKinds`: `cc`, `lld`, `mold`,
      `clang-lld`, `zig`, `lld-link`, `wasm-ld`, `wasm-component-ld`,
      `mingw-lld`, `rust-lld`, `ld64.lld`, `ld.lld`), whose fields are set with
      `lib.mkDefault`, and any added here or by a preset. A kind is
      chosen only by name; the default kind for a target is
      breakbulk's rule (`breakbulk.presetHelpers.linkerKind`).
    '';
  };

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
        "stageRefs"
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
          { ... }: sub rank (_: y: y) (if x == null && t ? nullAs then t.nullAs else x)
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

  # A target runner (`targets.<t>.runner`, `workspaces.<ws>.host.runner`):
  # null, false, a program, a list of a program and its first arguments, or
  # a record (`runnerNote`). The program types are tried in this order: a
  # store-path string stays a string (`types.package` would make it a
  # derivation).
  runnerProgram = types.oneOf [
    types.str
    types.path
    types.package
  ];
  runner = types.nullOr (
    types.oneOf [
      (types.enum [ false ])
      runnerProgram
      (types.nonEmptyListOf runnerProgram)
      (types.submodule {
        options = {
          program = mkOption {
            type = runnerProgram;
            description = "The runner program.";
          };
          args = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Arguments before the test binary.";
          };
          dylibPath = mkOption {
            type = types.nullOr (
              types.submodule {
                options = {
                  var = mkOption {
                    type = types.str;
                    description = "The variable.";
                  };
                  sep = mkOption {
                    type = types.str;
                    description = "The separator of its entries.";
                  };
                };
              }
            );
            default = null;
            description = ''
              The variable the test process reads shared-library
              directories from under this runner, and its separator.
              `null`: the target's (its traits' `dylibPathVar` and
              `dylibPathSep`).
            '';
          };
        };
      })
    ]
  );
  runnerNote = ''
    The value is one of:

    - `null`: the binary runs directly.
    - a program: invoked as `<runner> <binary> <args…>`, as Cargo invokes
      `target.<triple>.runner`, with the run's working directory,
      environment and `$TMPDIR`. It keeps any state it needs (a wine
      prefix, a browser profile) under `$TMPDIR`.
    - a list of the program and its first arguments (Cargo's array form).
    - `{ program; args ? [ ]; dylibPath ? null; }`: the program, its first
      arguments, and `{ var; sep; }`, the variable the test process reads
      shared-library directories from under this runner, when it is not
      the target's: wine reads `WINEPATH` (`;`-separated), not the
      Unix `PATH` (`breakbulk.runners.wine` gives this).
    - `false`: nothing here runs the target's programs (a preset's value
      when it finds no runner). A test run fails, naming the options that
      give one, and `canRunTests` defaults to false.

    `breakbulk.runners` has runners for wine, qemu-user, wasmtime,
    wasm-bindgen-test-runner and the build machine's ELF loader.
  '';

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
