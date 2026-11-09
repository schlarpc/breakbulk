# The documentation site: docs/src through mdBook, with the module options
# page generated from `optionsCommonMark` (a repository's
# `optionsDoc.optionsCommonMark`) and the logo from docs/logo.
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
      ./src
      ./logo
    ];
  };
in
rec {
  site = pkgs.runCommand "breakbulk-docs-site" { nativeBuildInputs = [ pkgs.mdbook ]; } ''
    cp -r ${src} book
    chmod -R u+w book
    cp -r book/logo book/src/logo
    {
      echo '# Module options'
      echo
      echo 'Every option of `mkRepository`, generated from the module declarations.'
      echo
      cat ${optionsCommonMark}
    } > book/src/reference/options.md
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
