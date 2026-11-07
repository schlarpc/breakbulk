# The dev shell of one workspace ("Dev shell" in docs/implementation.md):
# local Cargo set up as the planner runs it.
#
#  - CARGO_BUILD_TARGET=<native triple> (unless setTarget = false): the
#    planner always passes --target, and without it local Cargo applies
#    rustflags to build scripts, computes different `-C metadata` and puts
#    outputs elsewhere.
#  - The native target's toolchain spec as Cargo env config, as the
#    planner chose it (`cargo-env.json` next to the build plan of the
#    default variant): CARGO_TARGET_<TRIPLE>_LINKER, and the spec's
#    rustflags as CARGO_TARGET_<TRIPLE>_RUSTFLAGS or CARGO_BUILD_RUSTFLAGS,
#    whichever key the planner's `--config` used. Cargo appends these lists
#    to the project's own, as it appends `--config` lists.
#  - The union of the workspace's packages' inputs on the native platform,
#    through nixpkgs' own setup hooks (what the env captures record per
#    package). One shell cannot scope env per unit, and a union is only
#    valid within one platform; package env is merged the same way, and a
#    variable two packages set differently is a warning.
#  - A warning, when the shell starts, for each variable in the user's
#    environment that changes what Cargo builds but that the planner never
#    sees: CARGO_* (except those that only affect output location, the
#    terminal, the network and credentials) and RUSTFLAGS, RUSTDOCFLAGS,
#    RUSTC, RUSTDOC, RUSTC_WRAPPER, RUSTC_WORKSPACE_WRAPPER; and for a Cargo
#    config file in $CARGO_HOME (default ~/.cargo), which the planner does
#    not read either.
#
# Limits: binaries go to target/<triple>/…; an input missing from the
# configuration can work locally (from the union, or from the user's
# system) and fail in Nix; and for same-triple presets local Cargo cannot
# keep target env away from build scripts.
{ lib }:
{
  pkgs,
  name,
  nativeTriple,
  toolchain,
  setTarget ? true,
  # Merged per-package overrides (repository.nix's `overrideFor`) of the
  # workspace's packages.
  overrides ? [ ],
  # targets.<native>.env, already strings.
  targetEnv ? { },
  # The planner's `cargo-env.json` for the native target: { env; warnings; }
  # (crates/breakbulk-plan/src/spec.rs `CargoEnv`).
  cargoEnv ? { },
}:
let
  envString = (import ./modules/types.nix { inherit lib; }).envString;

  # Everything the native build needs: host-side and target-side inputs
  # are the same package sets on a native build.
  nativeInputs = lib.unique (
    lib.concatMap (o: o.nativeInputs pkgs.buildPackages ++ o.host.nativeInputs pkgs.buildPackages ++ (o.target.${nativeTriple}.nativeInputs or (_: [ ])) pkgs.buildPackages) overrides
  );
  inputs = lib.unique (
    lib.concatMap (o: o.inputs pkgs ++ o.host.inputs pkgs ++ (o.target.${nativeTriple}.inputs or (_: [ ])) pkgs) overrides
  );

  envOf = o: lib.mapAttrs (_: envString) (o.env // o.host.env // (o.target.${nativeTriple}.env or { }));
  envs = map envOf overrides ++ [ targetEnv ];
  conflicts = lib.filterAttrs (_: vs: lib.length (lib.unique vs) > 1) (lib.zipAttrs envs);
  packageEnv = lib.foldl' (a: b: a // b) { } envs;

  ownEnv =
    packageEnv
    // (cargoEnv.env or { })
    // lib.optionalAttrs setTarget {
      CARGO_BUILD_TARGET = nativeTriple;
    };

  # Variables that change what Cargo builds but never reach the planner.
  watched = [
    "RUSTFLAGS"
    "RUSTDOCFLAGS"
    "RUSTC"
    "RUSTDOC"
    "RUSTC_WRAPPER"
    "RUSTC_WORKSPACE_WRAPPER"
  ];
  # CARGO_* variables that do not change what is built.
  harmless = [
    "CARGO_HOME"
    "CARGO_TARGET_DIR"
    "CARGO_BUILD_TARGET_DIR"
    "CARGO_BUILD_BUILD_DIR"
    "CARGO_BUILD_JOBS"
    "CARGO_TERM_*"
    "CARGO_HTTP_*"
    "CARGO_NET_*"
    "CARGO_REGISTRY_TOKEN"
    "CARGO_REGISTRIES_*_TOKEN"
    "CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS"
    "CARGO_LOG"
    "CARGO_CACHE_*"
  ];
  pkgsList = lib.unique [
    toolchain.cargo
    toolchain.rustc
  ];
in
lib.foldr (w: lib.warn "breakbulk: the dev shell of workspace `${name}`: ${w}") (
lib.warnIf (conflicts != { })
  "breakbulk: the dev shell of workspace `${name}` merges package env that differs between packages: ${lib.concatStringsSep ", " (lib.attrNames conflicts)}; the shell has the last value"
  (
    pkgs.mkShell {
      name = "breakbulk-${name}";
      packages = pkgsList;
      nativeBuildInputs = nativeInputs;
      buildInputs = inputs;
      strictDeps = true;
      env = ownEnv;
      breakbulkOwnEnv = lib.concatStringsSep " " (lib.attrNames ownEnv);
      shellHook = ''
        __breakbulk_warn() { echo "breakbulk: $*" >&2; }
        for __bb_v in "''${!CARGO_@}" ${lib.concatStringsSep " " watched}; do
          # Exported variables only (the planner's Cargo would inherit
          # nothing else either).
          case "$(declare -p "$__bb_v" 2>/dev/null)" in "declare -x"*) ;; *) continue ;; esac
          case " $breakbulkOwnEnv " in *" $__bb_v "*) continue ;; esac
          case "$__bb_v" in
            ${lib.concatStringsSep " | " harmless}) ;;
            CARGO_* | ${lib.concatStringsSep " | " watched})
              __breakbulk_warn "$__bb_v is set in your environment. breakbulk's planner does not see it, so Nix builds will differ from local cargo; move the setting into the project's .cargo/config.toml." ;;
          esac
        done
        for __bb_f in "''${CARGO_HOME:-$HOME/.cargo}"/config.toml "''${CARGO_HOME:-$HOME/.cargo}"/config; do
          if [ -f "$__bb_f" ]; then
            __breakbulk_warn "$__bb_f exists. breakbulk's planner reads only the project's own Cargo config; settings there that change the build do not reach Nix builds."
          fi
        done
        unset __bb_v __bb_f
        unset -f __breakbulk_warn
      '';
    }
  )
) (cargoEnv.warnings or [ ])
