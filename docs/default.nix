# The documentation site: docs/src through mdBook, and the generated
# pages, committed so a checkout, the flake input and GitHub have them
# too: the module options pages (docs/src/reference/options/), from
# `optionsCommonMark` (a repository's `optionsDoc.optionsCommonMark`,
# split by options-pages.py), and the stage helpers page
# (docs/src/reference/stage-helpers.md), from the helpers' declarations
# (stage-helpers.nix).
#
#   site            the built site (packages.<system>.docs-site)
#   links           a check that every internal link and fragment resolves
#   optionsPages    the options pages as the modules generate them
#   stageHelpersPage  the stage helpers page as the helpers generate it
#   optionsFresh    a check that the committed pages are the generated ones
#   updateOptions   a script writing the generated pages into a checkout
#                   (nix run .#update-docs-options)
{
  pkgs,
  optionsCommonMark,
  stageHelpers,
}:
let
  inherit (pkgs) lib;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./book.toml
      ./theme.css
      ./src
      ./logo
    ];
  };
  optionsDir = "docs/src/reference/options";
  helpersFile = "docs/src/reference/stage-helpers.md";
in
rec {
  site = pkgs.runCommand "breakbulk-docs-site" { nativeBuildInputs = [ pkgs.mdbook ]; } ''
    cp -r ${src} book
    chmod -R u+w book
    cp -r book/logo book/src/logo
    mdbook build book --dest-dir $out
  '';

  optionsPages = pkgs.runCommand "breakbulk-options-pages" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./options-pages.py} ${optionsCommonMark} $out
    # A store path would change with every evaluation of a dependency.
    if grep -rn '${builtins.storeDir}/' $out; then
      echo "the options pages name store paths (above); make them repository-relative" >&2
      exit 1
    fi
  '';

  stageHelpersPage =
    let
      page = pkgs.writeText "stage-helpers.md" (
        import ./stage-helpers.nix {
          inherit lib;
          helpers = stageHelpers;
        }
      );
    in
    pkgs.runCommand "breakbulk-stage-helpers-page" { } ''
      if grep -nE '${builtins.storeDir}/[0-9a-z]{32}-' ${page}; then
        echo "the stage helpers page names store paths (above); use literalExpression for such defaults and examples" >&2
        exit 1
      fi
      cp ${page} $out
    '';

  optionsFresh = pkgs.runCommand "docs-options-fresh" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    status=0
    if ! diff -ru ${./src/reference/options} ${optionsPages}; then
      echo "${optionsDir} is not what the modules generate; run: nix run .#update-docs-options" >&2
      status=1
    fi
    if ! diff -u ${./src/reference/stage-helpers.md} ${stageHelpersPage}; then
      echo "${helpersFile} is not what the stage helpers generate; run: nix run .#update-docs-options" >&2
      status=1
    fi
    [ $status = 0 ]
    touch $out
  '';

  updateOptions = pkgs.writeShellScript "update-docs-options" ''
    set -euo pipefail
    if [ ! -f flake.nix ] || [ ! -d ${optionsDir} ]; then
      echo "update-docs-options: run it from the root of a breakbulk checkout" >&2
      exit 1
    fi
    rm -f ${optionsDir}/*.md
    cp ${optionsPages}/*.md ${optionsDir}/
    chmod u+w ${optionsDir}/*.md
    echo "wrote ${optionsDir}"
    cp ${stageHelpersPage} ${helpersFile}
    chmod u+w ${helpersFile}
    echo "wrote ${helpersFile}"
  '';

  links = pkgs.runCommand "docs-site-links" { nativeBuildInputs = [ pkgs.lychee ]; } ''
    # lychee builds its HTTP client even with --offline, and that needs CAs.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    # 404.html links with the deployed base path (site-url), which only
    # resolves on the server.
    lychee --offline --no-progress --include-fragments --root-dir ${site} \
      --exclude-path '404\.html$' '${site}/**/*.html'
    touch $out
  '';
}
