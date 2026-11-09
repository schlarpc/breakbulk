# The documentation site: docs/src through mdBook, with the module options
# pages generated from `optionsCommonMark` (a repository's
# `optionsDoc.optionsCommonMark`, split by options-pages.py) and the logo
# from docs/logo.
#
#   site    the built site (packages.<system>.docs-site)
#   links   a check that every internal link and fragment resolves
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
      ./options-pages.py
      ./theme.css
      ./src
      ./logo
    ];
  };
in
rec {
  site = pkgs.runCommand "breakbulk-docs-site" { nativeBuildInputs = [ pkgs.mdbook pkgs.python3 ]; } ''
    cp -r ${src} book
    chmod -R u+w book
    cp -r book/logo book/src/logo
    python3 book/options-pages.py ${optionsCommonMark} book/src
    mdbook build book --dest-dir $out
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
