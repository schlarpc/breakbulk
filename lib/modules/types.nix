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

  mkInputs =
    description:
    mkOption {
      type = inputs;
      default = [ ];
      example = lib.literalExpression "p: [ p.openssl ]";
      description = description + "\n\n" + inputsNote;
    };

  # A package selection by what it leaves out: `{ exclude = [ … ]; }`,
  # the workspace's members but those (lib/manifest.nix excludeMembers).
  excludeSelection = types.submodule {
    options.exclude = mkOption {
      type = types.listOf types.str;
      description = ''
        Members to leave out, as `cargo … --workspace --exclude`: package
        names, or glob patterns (`*`, `?`, `[…]`, `[!…]`).
      '';
    };
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

  # A list of packages, or the exclude form.
  packageList = types.either (types.listOf types.str) excludeSelection;

  # A stage or check definition. Kept as raw values
  # so `lib.mkForce null` can remove one.
  stages = types.attrsOf (types.nullOr types.raw);

  # The GitHub issue that tracks issue number `n`.
  issueUrl = n: "https://github.com/schlarpc/breakbulk/issues/${toString n}";

  # Mark an option as declared ahead of its implementation. `issue` is the
  # number of the issue that tracks it.
  notImplemented =
    issue: opt:
    opt
    // {
      description = (opt.description or "") + "\n\nNot implemented yet ([#${toString issue}](${issueUrl issue})): setting it only gives an evaluation warning.";
    };

  # The paths (lists of attribute names) of options in `paths` that some
  # module set, as opposed to their defaults. Defaults have priority 1500
  # (mkOptionDefault); anything set with a plain definition, mkDefault
  # (1000) or mkForce is a definition.
  setPaths =
    options: paths:
    lib.filter (
      p:
      let
        o = lib.getAttrFromPath p options;
      in
      o.highestPrio < 1500
    ) paths;

  # Whether an option type keeps one definition's value, where several
  # definitions at one priority conflict, rather than combining them
  # (lists concatenate, attribute sets and modules merge).
  singleValued =
    t:
    if t.name == "nullOr" then
      singleValued t.nestedTypes.elemType
    else if t.name == "either" then
      singleValued t.nestedTypes.left && singleValued t.nestedTypes.right
    else
      lib.elem t.name [
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
      ];

  # Layer `rank` (1, 2, …) of settings that refine a module evaluation
  # (`extendModules`): `module` with the definitions of the single-valued
  # options it sets (`isSingle`, by option name) moved up by `rank / 4` in
  # priority, so that among definitions of equal priority the
  # higher-ranked layer's wins instead of conflicting. A fraction keeps
  # the order of any two integer priorities: `mkForce` and `mkDefault`
  # still win and lose as written. Not `mkOverride` around the whole
  # module: a list at a lower priority would then be dropped, not
  # concatenated.
  layer =
    rank: isSingle:
    let
      shift = rank / 4.0;
      leaf =
        prio: v:
        let
          t = v._type or null;
        in
        if t == "if" then
          v // { content = leaf prio v.content; }
        else if t == "merge" then
          v // { contents = map (leaf prio) v.contents; }
        else if t == "override" then
          v // { priority = v.priority - shift; }
        else
          lib.mkOverride (prio - shift) v;
      # A module's `config`. An `mkOverride` around several options goes
      # down to each, as the module system pushes it down.
      config =
        prio: c:
        let
          t = c._type or null;
        in
        if t == "if" then
          c // { content = config prio c.content; }
        else if t == "merge" then
          c // { contents = map (config prio) c.contents; }
        else if t == "override" then
          config c.priority c.content
        else
          lib.mapAttrs (
            n: v:
            if isSingle n then
              leaf prio v
            else if prio == lib.modules.defaultOverridePriority then
              v
            else
              lib.mkOverride prio v
          ) c;
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
          # Keyed as the module system keys a file, so that a file also
          # imported elsewhere is still imported once.
          {
            key = toString m;
            _file = m;
            imports = [ (module (import m)) ];
          }
        else if lib.isFunction m then
          lib.setFunctionArgs (args: module (m args)) (lib.functionArgs m)
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
          // {
            imports = map module (m.require or [ ] ++ m.imports or [ ]);
            config = config lib.modules.defaultOverridePriority (
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
    lib.optionalString (files != [ ]) " (set in ${lib.concatMapStringsSep " and " (f: "`${toString f}'") files})";

  # Warnings for options of a submodule that are set but not implemented:
  # `prefix` names the submodule instance (e.g. `targets.wasm32-unknown-unknown`).
  unimplementedWarnings =
    prefix: options: byIssue:
    lib.concatLists (
      lib.mapAttrsToList (
        issue: paths:
        map (
          p: "breakbulk: `${prefix}.${lib.concatStringsSep "." p}` is set but not implemented yet (${issueUrl issue}); it has no effect."
        ) (setPaths options paths)
      ) byIssue
    );
}
