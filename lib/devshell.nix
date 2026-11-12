# The dev shell of one workspace ("Dev shell" in
# docs/src/explanation/internals/nix-library.md):
# local Cargo set up as the planner runs it.
#
#  - CARGO_BUILD_TARGET=<target> (`devShell.target`: by default the native
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
#    to the project's own, as it appends `--config` lists.
#  - CARGO_PROFILE_<P>_TRIM_PATHS=all when the planner turns Cargo's
#    trim-paths on, for each profile P of the default variant's build and
#    test plans (Cargo 1.101 and
#    later, unless the project declares trim-paths or cargoTrimPaths says
#    otherwise), so local `-C metadata` matches the plan's. It comes from
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
  # The triple the shell is set up for (`devShell.target`), or null.
  target ? nativeTriple,
  # The workspace's packages that have settings, in Cargo.lock order:
  # [ { id = "<name>@<version>"; override; } ], `override` being
  # repository.nix's `overrideFor`, already merged for `target` (or the
  # native triple).
  packages ? [ ],
  # targets.<target>.env, already strings.
  targetEnv ? { },
  # devShell.env: env values, or null to remove.
  shellEnv ? { },
  # The planner's `cargo-env.json` for `target`: { env; warnings; }
  # (crates/breakbulk-plan/src/spec.rs `CargoEnv`), the trim-paths
  # variable included.
  cargoEnv ? { },
}:
let
  envString = (import ./modules/types.nix { inherit lib; }).envString;

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

  envOf = o: lib.mapAttrs (_: envString) (o.env // o.forHost.env // o.forTarget.env);
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

  # How the planner runs Cargo for `target`.
  planEnv =
    (cargoEnv.env or { })
    // lib.optionalAttrs (target != null) {
      CARGO_BUILD_TARGET = target;
    };

  # { <var> = [ { label; value; } … ]; } for the variables that sources
  # set to different values and that neither `planEnv` nor `devShell.env`
  # replaces.
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
  show = v: builtins.unsafeDiscardStringContext (builtins.toJSON v);
  conflictWarning =
    var: setters:
    let
      last = lib.last setters;
    in
    "${var} is set to different values: ${
      lib.concatMapStringsSep ", " (s: "${s.label} = ${show s.value}") setters
    }. The shell uses ${show last.value} from ${last.label}: the last value, with packages in Cargo.lock order and the target's env after them. To choose a value, set `workspaces.${name}.devShell.env.${var}`.";

  ownEnv = lib.filterAttrs (_: v: v != null) (
    packageEnv
    // planEnv
    // lib.mapAttrs (_: v: if v == null then null else envString v) shellEnv
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
  warnings = map (w: "breakbulk: the dev shell of workspace `${name}`: ${w}") (
    (cargoEnv.warnings or [ ]) ++ lib.mapAttrsToList conflictWarning conflicts
  );
in
lib.foldr lib.warn
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
      # The messages that evaluating the shell prints, for reading them
      # without parsing the evaluator's stderr.
      passthru = { inherit warnings; };
    }
  )
  warnings
