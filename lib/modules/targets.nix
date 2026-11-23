# targets.<triple>: the toolchain spec of one target platform.
#
# A spec is data: the linker, C toolchain, rustflags, env and runner for a
# target's units. The host units (build scripts, proc macros and their
# dependencies) have the workspace's host spec (`workspaces.<ws>.host`),
# in every plan.
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
#  - `rustflags`, `linker`, the host's `linker` go to Cargo with `--config`
#    (rustflags under the key the project already uses: Cargo reads only
#    one rustflags key, so flags under the other one would make it ignore
#    the project's). On a same-triple target the planner rewrites host
#    units' linker to the host's.
#  - `cc`, `cxx`, `ar`, `cflags`, `cxxflags`, `bindgen.extraClangArgs`
#    become `CC_<triple>`, `CXX_<triple>`, `AR_<triple>`, `CFLAGS_<triple>`,
#    `CXXFLAGS_<triple>`, `BINDGEN_EXTRA_CLANG_ARGS_<triple>` in `env`
#    (`cEnv` in ./target-spec.nix).
#  - `env` is added to target units only; the host's `env` to host units only.
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
      `presets.linuxStatic` (musl); another Linux `-gnu` triple
      `presets.linux`, a `-musl` one `presets.linuxStatic`, a Windows
      `-gnu` or `-gnullvm` one `presets.windows`, `wasm32-wasip2`
      `presets.wasmComponent`, a UEFI triple `presets.uefi`, and a
      bare-metal triple that rustc links with lld `presets.bareMetal`. A triple
      whose preset needs arguments or a choice (`-msvc`, macOS,
      Android, wasm32 without WASI) fails at evaluation, naming the preset, unless
      the target sets a `preset`, a `linker`, or `preset = null`. Any
      other triple, and one with `preset = null`, uses an empty spec (the
      toolchain as Cargo finds it).
    '';
  };
}
