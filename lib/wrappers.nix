# Ready-made test wrappers (`packages.<name>.test.wrapper`; "Test
# wrappers" in docs/src/reference/presets.md). Each is a function from
# its options to a function from a package set to the program, which a
# test run calls with the package set of the machine that runs it.
#
#   packages.deno.test.wrapper = breakbulk.lib.wrappers.cargoTargetLayout { };
#
# A wrapper is started as `<wrapper> <binary> <args…>` in the package
# directory, with BREAKBULK_SOURCE_ROOT and BREAKBULK_NEXT set (lib/test-runs.nix
# `launchWords`).
{ lib, util }:
{
  # The binary where Cargo puts it, for tests that find the repository from
  # their own path (`std::env::current_exe()`, walking up to `target`): a
  # fresh directory in $TMPDIR holding a symbolic link per entry of the
  # source view's root, and `target/<profile>/deps/` holding the binary,
  # which then starts from there; the working directory stays the package
  # directory. A copy (or a hard link, when the file system allows one),
  # not a symbolic link: `current_exe()` resolves symbolic links. The
  # directory is removed when the binary exits, so the wrapper waits for
  # it instead of replacing its own process, and passes INT and TERM on
  # to it.
  cargoTargetLayout =
    {
      profile ? "debug",
    }:
    pkgs:
    pkgs.writeShellScript "breakbulk-cargo-target-layout" ''
      set -euo pipefail
      bin=$1
      shift
      if [ -z "''${BREAKBULK_SOURCE_ROOT:-}" ]; then
        echo "cargoTargetLayout: BREAKBULK_SOURCE_ROOT is not set" >&2
        exit 1
      fi
      PATH=${lib.makeBinPath [ pkgs.coreutils ]}''${PATH:+:$PATH}
      ${util.forwardSignalsScript "${pkgs.coreutils}/bin/env"}
      repo=$(mktemp -d "''${TMPDIR:-/tmp}/breakbulk-repo.XXXXXX")
      trap 'rm -rf "$repo"' EXIT
      for e in "$BREAKBULK_SOURCE_ROOT"/* "$BREAKBULK_SOURCE_ROOT"/.[!.]* "$BREAKBULK_SOURCE_ROOT"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ "''${e##*/}" = target ] || ln -s "$e" "$repo/"
      done
      deps=$repo/target/${profile}/deps
      mkdir -p "$deps"
      ln "$bin" "$deps/" 2> /dev/null || cp "$bin" "$deps/"
      __bb_run "$BREAKBULK_NEXT" "$deps/''${bin##*/}" "$@"
    '';
}
