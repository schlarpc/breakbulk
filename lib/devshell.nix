# The dev shell of one workspace ("Dev shell" in
# docs/src/explanation/internals/nix-library.md):
# local Cargo set up as the planner runs it.
#
#  - CARGO_BUILD_TARGET=<the `rustcTarget` of `devShell.target`> (the
#    target is by default the native
#    triple when the workspace targets it, else its only target; null
#    exports none, so the project's own `build.target` applies): the
#    planner always passes --target, and without it local Cargo applies
#    rustflags to build scripts, computes different `-C metadata` and puts
#    outputs elsewhere.
#  - That target's toolchain spec as Cargo env config, as the
#    planner chooses it (`cargo-env.json` from lib/plan.nix mkCargoEnv,
#    which reads only Cargo config files and rustc, so the shell opens
#    while a manifest is broken): CARGO_TARGET_<TRIPLE>_LINKER, and the spec's
#    rustflags as CARGO_TARGET_<TRIPLE>_RUSTFLAGS or CARGO_BUILD_RUSTFLAGS,
#    whichever key the planner's `--config` used. Cargo appends these lists
#    to the project's own, as it appends `--config` lists. The shell
#    depends on that derivation and its hook exports the variables when
#    the shell starts (`nix develop`, `nix print-dev-env`), so evaluating
#    the shell imports nothing from a derivation: in dynamic-derivation
#    mode `nix flake check` evaluates it without building the planner.
#    The spec's tool paths are inputs of the shell, since the file names
#    them without their context.
#  - CARGO_PROFILE_<P>_TRIM_PATHS=all when the planner turns Cargo's
#    trim-paths on, for each profile P of the default variant's build and
#    test plans (Cargo 1.101 and
#    later, as the variant's sourcePaths says), so local `-C metadata` matches the plan's. It comes from
#    the same `cargo-env.json`, by the planner's own file-reading rule, so
#    the shell opens with a broken manifest on every Cargo version
#    (a manifest that is not valid TOML is a warning).
#  - The union of the workspace's packages' inputs on the native platform,
#    through nixpkgs' own setup hooks (what the env captures record per
#    package). One shell cannot scope env per unit, and a union is only
#    valid within one platform: a cross target's own `inputs` (libraries
#    for that platform) are left out, its `nativeInputs` and `env` are
#    not. Package env is merged the same way: packages in Cargo.lock
#    order, then the target's `env`, the last value winning. A variable
#    two of them set differently is a warning that names each value and
#    `devShell.env`.
#  - `devShell.env`, over all of the above: a value replaces, null
#    removes (and with it the shell's dependency on the value's
#    derivation). There is no ranking between packages, as a conflict
#    between them concerns only the shell, and `devShell.env` settles it.
#    The conflict warnings and cargo-env.json's own warnings are printed
#    when the shell starts: a variable the planner's env sets is not a
#    conflict, and that env is known only then.
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
{ lib, util }:
{
  pkgs,
  name,
  nativeTriple,
  toolchain,
  # The triple the shell is set up for (`devShell.target`), or null.
  target ? nativeTriple,
  # What Cargo is given as `--target` for it (lib/target-traits.nix
  # rustcTargetArg).
  rustcTarget ? target,
  # The workspace's packages that have settings, in Cargo.lock order:
  # [ { id = "<name>@<version>"; override; } ], `override` being the
  # package's settings (repository.nix `settingsOf`) for `target` (or the
  # native triple).
  packages ? [ ],
  # targets.<target>.env, already strings.
  targetEnv ? { },
  # devShell.env: env values, or null to remove.
  shellEnv ? { },
  # The planner's `cargo-env.json` for `target`, a path with its
  # derivation's context: { env; warnings; }
  # (crates/breakbulk-plan/src/spec.rs `CargoEnv`), the trim-paths
  # variable included. Null: none.
  cargoEnvFile ? null,
  # The store paths (strings with context) that cargo-env.json's values
  # name: the spec's linkers and rustflags.
  cargoEnvInputs ? [ ],
}:
let
  bt = import ./modules/types.nix { inherit lib; };
  inherit (bt) envString;

  overrides = map (p: p.override) packages;
  # Everything the native build needs: host-side and target-side inputs
  # are the same package sets on a native build. A cross target's own
  # inputs are libraries for another platform, so they are left out.
  native = target == null || target == nativeTriple;
  nativeInputs = lib.unique (
    lib.concatMap (
      o:
      lib.concatMap (side: side.nativeInputs pkgs.buildPackages) [
        o
        o.forHost
        o.forTarget
      ]
    ) overrides
  );
  inputs = lib.unique (
    lib.concatMap (
      o: o.inputs pkgs ++ o.forHost.inputs pkgs ++ lib.optionals native (o.forTarget.inputs pkgs)
    ) overrides
  );

  # A shell sets each variable once: lists are joined into the value.
  envOf =
    o:
    lib.mapAttrs (bt.envFlat o.envSeparators) (
      bt.envLayers [
        o.env
        o.forHost.env
        o.forTarget.env
      ]
    );
  # Lowest first.
  sources =
    map (p: {
      label = p.id;
      env = envOf p.override;
    }) packages
    ++ [
      {
        label = "the env of target `${toString target}`";
        env = targetEnv;
      }
    ];
  packageEnv = lib.foldl' (a: s: a // s.env) { } sources;

  # How the planner runs Cargo for `target`, as far as evaluation knows
  # it; cargo-env.json's variables come when the shell starts.
  planEnv = lib.optionalAttrs (target != null) {
    CARGO_BUILD_TARGET = rustcTarget;
  };

  # { <var> = [ { label; value; } … ]; } for the variables that sources
  # set to different values and that neither `planEnv` nor `devShell.env`
  # replaces. The hook drops those cargo-env.json sets.
  conflicts =
    lib.filterAttrs
      (
        var: setters:
        !(planEnv ? ${var} || shellEnv ? ${var}) && lib.length (lib.unique (map (s: s.value) setters)) > 1
      )
      (
        lib.zipAttrs (
          map (
            s:
            lib.mapAttrs (_: value: {
              inherit (s) label;
              inherit value;
            }) s.env
          ) sources
        )
      );
  # Without the context: a warning message cannot carry one.
  show = v: util.devirtualizeAndDiscard (builtins.toJSON v);
  conflictWarning =
    var: setters:
    let
      last = lib.last setters;
    in
    "${var} is set to different values: ${
      lib.concatMapStringsSep ", " (s: "${s.label} = ${show s.value}") setters
    }. The shell uses ${show last.value} from ${last.label}: the last value, with packages in Cargo.lock order and the target's env after them. To choose a value, set `workspaces.${name}.devShell.env.${var}`.";

  ownEnv = lib.filterAttrs (_: v: v != null) (
    packageEnv // planEnv // lib.mapAttrs (_: v: if v == null then null else envString v) shellEnv
  );

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
  prefix = "breakbulk: the dev shell of workspace `${name}`: ";

  # cargo-env.json as shell lines, made when the shell's inputs are built:
  # `__bb_set <var> <value>` per variable, `__bb_note <warning>` per
  # warning. Not jq in the hook: the hook runs in the user's shell, and
  # the conversion is the same every time.
  cargoEnvScript =
    pkgs.buildPackages.runCommand "breakbulk-${name}-cargo-env.sh"
      {
        nativeBuildInputs = [ pkgs.buildPackages.jq ];
      }
      ''
        jq -r '(.env // {} | to_entries[] | "__bb_set \(.key | @sh) \(.value | @sh)"),
          (.warnings // [] | .[] | "__bb_note \(. | @sh)")' ${cargoEnvFile} > $out
      '';
in
pkgs.mkShell {
  name = "breakbulk-${name}";
  packages = pkgsList;
  nativeBuildInputs = nativeInputs;
  buildInputs = inputs;
  strictDeps = true;
  env = ownEnv;
  breakbulkOwnEnv = lib.concatStringsSep " " (lib.attrNames ownEnv);
  # The tool paths cargo-env.json names, built with the shell.
  breakbulkCargoEnvInputs = cargoEnvInputs;
  shellHook = ''
    __breakbulk_warn() { echo "breakbulk: $*" >&2; }
    __bb_own=" $breakbulkOwnEnv "
    __bb_planned=" "
    ${lib.optionalString (cargoEnvFile != null) ''
      # The planner's env (cargo-env.json), under devShell.env.
      __bb_set() {
        case " ${lib.concatStringsSep " " (lib.attrNames shellEnv)} " in *" $1 "*) return 0 ;; esac
        export "$1=$2"
        __bb_own+="$1 "
        __bb_planned+="$1 "
      }
      __bb_note() { echo ${lib.escapeShellArg prefix}"$1" >&2; }
      . ${cargoEnvScript}
      unset -f __bb_set __bb_note
    ''}
    ${lib.concatStrings (
      lib.mapAttrsToList (var: setters: ''
        case "$__bb_planned" in *" ${var} "*) ;; *) echo ${
          lib.escapeShellArg (prefix + conflictWarning var setters)
        } >&2 ;; esac
      '') conflicts
    )}
    for __bb_v in "''${!CARGO_@}" ${lib.concatStringsSep " " watched}; do
      # Exported variables only (the planner's Cargo would inherit
      # nothing else either).
      case "$(declare -p "$__bb_v" 2>/dev/null)" in "declare -x"*) ;; *) continue ;; esac
      case "$__bb_own" in *" $__bb_v "*) continue ;; esac
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
    unset __bb_v __bb_f __bb_own __bb_planned
    unset -f __breakbulk_warn
  '';
}
