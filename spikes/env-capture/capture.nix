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
, strictDeps ? true
}:
stdenv.mkDerivation {
  name = "breakbulk-env-${name}";
  nativeBuildInputs = nativeInputs;
  buildInputs = inputs;
  # As buildRustPackage does, and as cross stdenvs default to. Without it,
  # setup.sh puts every input's bin/ on PATH and runs every env hook for
  # every dependency offset (setup.sh: activatePackage, _addToEnv), so a
  # library's tools leak onto PATH and flags are added twice.
  inherit strictDeps;
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
