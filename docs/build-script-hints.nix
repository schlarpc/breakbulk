# The build-script failure hints reference page
# (docs/src/reference/build-script-hints.md), rendered from the curated
# table (lib/build-script-hints.json, `sysDefaults.buildScriptHints`'s
# entries), which build-script runs read.
#
#   import ./build-script-hints.nix { lib; table = lib.importJSON …; }
#     -> the page, a string
{
  lib,
  table,
}:
let
  inherit (lib) concatMapStrings concatMapStringsSep concatStringsSep;

  # A code span that may hold backticks; `|` escaped for a table cell.
  code =
    t:
    let
      s = builtins.replaceStrings [ "|" ] [ "\\|" ] t;
    in
    if lib.hasInfix "`" s then "`` ${s} ``" else "`${s}`";
  codes = concatMapStringsSep ", " code;

  fingerprint =
    f:
    concatStringsSep "; " (
      lib.optional (f.vars or [ ] != [ ]) "declares ${codes f.vars}"
      ++ lib.optional (f.lines or [ ] != [ ]) "prints ${codes f.lines}"
    );

  recognizerRows = concatMapStrings (
    name:
    let
      r = table.recognizers.${name};
    in
    concatMapStrings (e: ''
      | `${name}` | ${fingerprint (r.fingerprint or { })} | ${code e.pattern} | ${code e.hint} |
    '') r.errors
  ) (lib.attrNames table.recognizers);

  coverRows = concatMapStrings (
    name:
    let
      c = table.recognizers.${name}.covers or [ ];
    in
    lib.optionalString (c != [ ]) ''
      | `${name}` | ${codes c} |
    ''
  ) (lib.attrNames table.recognizers);

  toolRows = concatMapStrings (t: ''
    | ${code t} | `${table.tools.${t}}` |
  '') (lib.attrNames table.tools);
in
''
  <!-- Generated from lib/build-script-hints.json by docs/build-script-hints.nix;
       run `nix run .#update-docs-options` after changing either. -->

  # Build-script failure hints

  The curated entries of
  [`sysDefaults.buildScriptHints`](options/repository.md#sysdefaultsbuildscripthints):
  what a failed build-script run's output is searched for, to add hints
  after it ([Failure hints](unit-builder.md#failure-hints)). Patterns: `*`
  matches any text and `{}` any non-empty text, which a hint names as
  `{0}`; variable patterns also match after a `HOST_` or `TARGET_` prefix.
  In a hint, `{opt}` is the package's option prefix (`packages.<name>`).

  ## Crates

  A hint is added when the script printed the crate's error and the crate
  left its fingerprint (either part is enough). The first error pattern a
  line matches decides its hint.

  | Crate | Fingerprint | Error | Hint |
  | --- | --- | --- | --- |
  ${recognizerRows}
  After a crate's failure is recognized, the unset variables it declares
  are counted rather than listed:

  | Crate | Variables |
  | --- | --- |
  ${coverRows}
  ## Tools not found

  A line that says a program was not found (it contains one of
  ${codes table.notFound}) and names one of these tools gets
  ${code table.toolHint}. The tool must be quoted, end a path, or come
  before a `:`, as in ``failed to spawn `cmake` `` or
  `sh: 1: nasm: not found`.

  | Program | Package |
  | --- | --- |
  ${toolRows}
  ## Downloads

  A line that shows the script downloading gets ${code table.networkHint}.
  It does when, lowercased, it contains one of ${codes table.network}, or
  names one of ${codes table.downloaders} as a word outside a `cargo:`
  directive.
''
