# captureEnv: run a real stdenv with the given inputs and record the
# environment its setup hooks produce as $out/env.json.
#
#   stdenv        the stdenv of the platform whose units will use the capture
#                 (pkgs.stdenv for host units, pkgsCross.<x>.stdenv for target)
#   nativeInputs  tools that run on the build machine  -> nativeBuildInputs
#   inputs        libraries for the stdenv's host platform -> buildInputs
#   survey        also write $out/survey/* (spike diagnostics)
{ buildPackages }:
{ stdenv
, name ? "base"
, nativeInputs ? [ ]
, inputs ? [ ]
, survey ? false
}:
stdenv.mkDerivation {
  name = "breakbulk-env-${name}";
  nativeBuildInputs = nativeInputs;
  buildInputs = inputs;
  # setup.sh would otherwise add "-rpath $out/lib" (of this capture) to
  # NIX_LDFLAGS (setup.sh: _addRpathPrefix).
  NIX_NO_SELF_RPATH = 1;
  # Our own builder: record env, source setup, record env, diff.
  args = [ "-e" ./capture.sh ];
  jq = "${buildPackages.jq}/bin/jq";
  envTool = "${buildPackages.coreutils}/bin/env";
  captureSurvey = if survey then "1" else "";
  preferLocalBuild = true;
  allowSubstitutes = false;
}
