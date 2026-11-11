# The documentation site: docs/src through mdBook, and the module options
# pages (docs/src/reference/options/), generated from `optionsCommonMark`
# (a repository's `optionsDoc.optionsCommonMark`, split by options-pages.py)
# and committed so a checkout, the flake input and GitHub have them too.
#
#   site            the built site (packages.<system>.docs-site)
#   links           a check that every internal link and fragment resolves
#   optionsPages    the options pages as the modules generate them
#   optionsFresh    a check that the committed pages are optionsPages
#   updateOptions   a script writing optionsPages into a checkout
#                   (nix run .#update-docs-options)
{
  pkgs,
  optionsCommonMark,
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

  optionsFresh = pkgs.runCommand "docs-options-fresh" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    if ! diff -ru ${./src/reference/options} ${optionsPages}; then
      echo "${optionsDir} is not what the modules generate; run: nix run .#update-docs-options" >&2
      exit 1
    fi
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
