# Every option a Rust hint or error message names exists in the module
# tree, so renaming or removing an option cannot leave a hint naming
# nothing. The messages are read from the crates' sources:
#
#   `{opt}.<path>`               packages.<name>.<path> (`{opt}` is
#                                `option_prefix`, breakbulk-hints)
#   Widen::<V> => "<path>"       packages.<name>.<path> (`Widen::option`)
#   `workspaces.<ws>.<path>`     workspaces.<name>.<path>, `<triple>` and
#                                other placeholders as `<name>`
#   workspace's `roots…`         workspaces.<name>.roots…
#
# and compared with the option names of the generated reference
# (`optionsDoc`). A message that names an option some other way is not
# seen; write it in one of these forms.
{
  pkgs,
  bb,
}:
let
  inherit (pkgs) lib;

  options =
    lib.attrNames
      (bb.mkRepository {
        inherit pkgs;
        root = ../fixtures/walking-skeleton;
      }).optionsDoc.optionsNix;

  rustFiles = lib.filter (lib.hasSuffix ".rs") (lib.filesystem.listFilesRecursive ../../crates);

  # The first capture group of every match of `re` in `s`.
  matches = re: s: map lib.head (lib.filter builtins.isList (builtins.split re s));

  # Placeholders as the reference writes them.
  normalize =
    p:
    builtins.replaceStrings [ "<ws>" "<triple>" "<pkg>" "<v>" ] [ "<name>" "<name>" "<name>" "<name>" ]
      p;

  refsOf =
    file:
    let
      s = builtins.readFile file;
      at = path: {
        inherit path;
        file = lib.removePrefix (toString ../../. + "/") (toString file);
      };
      package = p: at "packages.<name>.${lib.removeSuffix "." p}";
    in
    map package (matches "\\{opt}\\.([A-Za-z][A-Za-z0-9_.]*)" s)
    ++ map package (matches "Widen::[A-Za-z]+ => \"([^\"]+)\"" s)
    ++ map (p: at (normalize "workspaces.${p}")) (
      matches "`workspaces\\.(<[a-z]+>\\.[A-Za-z0-9_.<>]*[A-Za-z0-9_>])" s
    )
    ++ map (p: at "workspaces.<name>.${p}") (matches "workspace's `(roots(\\.[a-z]+)?)`" s);

  refs = lib.concatMap refsOf rustFiles;
  # An option, or a submodule holding options (`roots`).
  exists = p: lib.elem p options || lib.any (lib.hasPrefix "${p}.") options;
  missing = lib.filter (r: !(exists r.path)) refs;
  report = lib.concatStringsSep "\n" (lib.unique (map (r: "${r.file}: ${r.path}") missing));
in
# A change to the message forms that finds (almost) nothing would pass
# silently; the sources name dozens today.
assert lib.assertMsg (lib.length refs > 30)
  "hint-options: only ${toString (lib.length refs)} option references found in the crates; were the message forms changed?";
pkgs.runCommand "hint-options"
  {
    inherit report;
    passthru = { inherit refs; };
  }
  ''
    if [ -n "$report" ]; then
      echo "hints name options that do not exist:" >&2
      echo "$report" >&2
      exit 1
    fi
    touch $out
  ''
