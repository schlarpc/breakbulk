# targets.<triple>: the toolchain spec of one target platform.
#
# A spec is data: the linker, C toolchain, rustflags, env and runner for a
# target's units, plus the host spec (`host.*`) for the host units (build
# scripts, proc macros and their dependencies) of plans for this target.
# Presets (lib/presets) fill it in; any field can be overridden. The
# options are declared in ./target-spec.nix.
#
# Specs are resolved per (workspace, target): `targets.<t>`
# holds the repository-wide definitions, `workspaces.<ws>.targets.<t>` a
# workspace's own, and lib/repository.nix evaluates both together with
# the workspace's toolchain, so a preset gets that workspace's rustc.
# Both options are therefore modules here (deferred), not evaluated specs.
#
# How the fields reach units (lib/repository.nix, breakbulk-plan's spec.rs):
#  - `rustflags`, `linker`, `host.linker` go to Cargo with `--config`
#    (rustflags under the key the project already uses: Cargo reads only
#    one rustflags key, so flags under the other one would make it ignore
#    the project's). On a same-triple target the planner rewrites host
#    units' linker to `host.linker`.
#  - `cc`, `cxx`, `ar`, `cflags`, `bindgen.extraClangArgs` become
#    `CC_<triple>`, `CXX_<triple>`, `AR_<triple>`, `CFLAGS_<triple>` and
#    `CXXFLAGS_<triple>`, `BINDGEN_EXTRA_CLANG_ARGS_<triple>` in `env`.
#  - `env` is added to target units only; `host.env` to host units only.
#    Neither goes through Cargo's `[env]`.
#  - `packageSet` gives the target's env capture and the package set that
#    `packages.<name>.inputs` functions are called with.
{
  lib,
  ...
}:
let
  inherit (lib) types mkOption;
in
{
  options.targets = mkOption {
    type = types.attrsOf (types.deferredModuleWith { staticModules = [ ./target-spec.nix ]; });
    default = { };
    description = ''
      Toolchain specs per target triple, for every workspace that builds
      the triple (`workspaces.<ws>.targets`). Each workspace's spec is
      these definitions together with its own
      `workspaces.<ws>.targets.<triple>`, evaluated with that workspace's
      toolchain, so a preset uses each workspace's rustc. A triple whose
      preset needs no arguments gets it without an entry here, and with
      entries that set other fields: the native triple, when the `pkgs`
      given to mkRepository is Linux, gets `presets.linux` (glibc) or
      `presets.linuxStatic` (musl), and a UEFI triple `presets.uefi`.
      Any other triple with no entry here or in the workspace uses an
      empty spec (the toolchain as Cargo finds it).
    '';
  };
}
