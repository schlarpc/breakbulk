# The stage helpers reference page (docs/src/reference/stage-helpers.md),
# rendered from each helper's declaration (lib/stage-helpers: `mkHelper`'s
# `description`, `kind` and `options`).
#
#   import ./stage-helpers.nix { lib; helpers = breakbulk.stageHelpers; }
#     -> the page, a string
{
  lib,
  helpers,
}:
let
  inherit (lib) concatMapStrings concatStringsSep trim;

  # A labelled default or example: literalExpression or literalMD text.
  # Short values go on one line, as `[ "-Oz" ]`, not as the three lines
  # lib.generators.toPretty writes.
  value =
    label: v:
    let
      text = trim v.text;
      oneLine = concatStringsSep " " (map trim (lib.splitString "\n" text));
    in
    if v._type == "literalMD" then
      "*${label}:* ${text}"
    else if !(lib.hasInfix "\n" text) || lib.stringLength oneLine <= 60 then
      "*${label}:* `${oneLine}`"
    else
      "*${label}:*\n\n```nix\n${text}\n```";

  option =
    o:
    if o.description == null then
      throw "stage helper option `${o.name}` has no description"
    else
      ''

        #### `${o.name}`

        ${trim o.description}

        *Type:* ${o.type}

        ${if o ? default then value "Default" o.default else "*Default:* none; the option must be set"}
      ''
      + lib.optionalString (o ? example) ''

        ${value "Example" o.example}
      '';

  helper =
    name:
    let
      h = helpers.${name};
      opts = lib.filter (o: o.visible && !o.internal) (lib.optionAttrSetToDocList h.options);
    in
    ''

      ### `${name}`

      ${trim h.description}
    ''
    + (
      if opts == [ ] then
        ''

          It has no options.
        ''
      else
        concatMapStrings option opts
    );

  names = lib.attrNames (lib.filterAttrs (_: helpers.isHelper) helpers);
  ofKind = kind: lib.filter (n: helpers.${n}.kind == kind) names;
in
''
  <!-- Generated from lib/stage-helpers by `nix run .#update-docs-options`; edit the helper declarations there. -->

  # Stage helpers

  `breakbulk.stageHelpers` holds ready-made stages and checks. A helper
  is the `run` of a stage or check. Use it as it is, or call it with
  options first:

  ```nix
  packages.app.stages.rpath = {
    run = breakbulk.stageHelpers.patchelfRpath { libs = [ pkgs.vulkan-loader ]; };
  };
  packages.app.checks.selfContained.run = breakbulk.stageHelpers.noStorePaths;
  ```

  The options are module options. An unknown option fails at
  evaluation and lists the helper's options. A value of the wrong type
  fails at evaluation and names the option. A configured helper called
  with more options sets them over the earlier ones.

  The stage helpers that change binaries expect the flat link output,
  so run them before `install`; `deterministicZip` packs any tree and
  can follow it. What a stage or check function receives, `product`
  included, is in [Stage and check functions](stage-functions.md).

  ## Stages
''
+ concatMapStrings helper (ofKind "stage")
+ ''

  ## Checks

  Use these as `checks.<name>.run`.
''
+ concatMapStrings helper (ofKind "check")
