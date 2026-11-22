# Repository-wide options: delivery mode, source strictness, fetching,
# and the curated defaults for -sys crates (lib/sys-defaults.nix) and for
# the dependents of crates (lib/sys-defaults-dependents.nix).
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  settings = (import ./package-settings.nix { inherit lib; }).settings;
  curated = import ../sys-defaults.nix { inherit lib; };
  curatedDependents = import ../sys-defaults-dependents.nix { inherit lib; };
  gates = import ../nix-features.nix { inherit lib; };
in
{
  config.sysDefaults =
    let
      define = lib.mapAttrs (_: v: lib.mkDefault (if builtins.isFunction v then v else _: v));
    in
    {
      packages = define curated;
      dependents = define curatedDependents;
    };

  options = {
    mode = mkOption {
      type = types.enum [
        "ifd"
        "dynamic"
      ];
      default = gates.defaultMode;
      defaultText = lib.literalMD ''
        `"dynamic"` when the evaluator has dynamic derivations (Nix's
        `outputOf` builtin) and is Nix 2.36 or later, else `"ifd"`
      '';
      description = ''
        How unit derivations reach Nix. `ifd`: breakbulk-instantiate writes
        units.json, which Nix imports (import-from-derivation). `dynamic`:
        an outer derivation writes the unit derivations through Nix's
        `builder-rpc-v0` interface and products reach them with Nix's
        `outputOf` builtin (needs Nix 2.36 or later with the
        `dynamic-derivations` and `ca-derivations` experimental features).
        The default is the evaluator's: `dynamic` where it can, `ifd`
        elsewhere. A daemon or builder older than the evaluator fails with
        Nix's own "missing system features" error naming `builder-rpc-v0`;
        set `ifd` then. Unit derivations are identical in both modes;
        products are not (they are resolved at build time in `dynamic`), so
        teams that mix Nix versions should pin the mode.
        [`repo.nixFeatures`](../outputs.md#nixfeatures) lists the Nix
        features the evaluation may use.

        In `ifd`, evaluating another system's outputs builds its plans, which
        needs a builder for that system: `nix flake check --all-systems` and
        `nix flake show --all-systems` fail on a Linux machine for darwin
        outputs ("Required system"). Plain `nix flake check` and `nix flake
        show` evaluate only the current system and are unaffected, and
        `dynamic` evaluates every system without builders. With `ifd`, list
        only the systems you can build on (the common `nix-systems/default`
        includes darwin).
      '';
    };

    ca = mkOption {
      type = types.bool;
      default = config.mode == "dynamic";
      defaultText = lib.literalExpression ''mode == "dynamic"'';
      description = ''
        Content-address post-link stages, checks and test runs, so that an
        unchanged input does not re-run them. Needs Nix's `ca-derivations`
        experimental feature in the evaluator and the daemon. The default
        follows `mode`: `dynamic` needs `ca-derivations` anyway, while Nix
        code cannot tell whether it is on otherwise, and without it a
        content-addressed derivation is an error that cannot be caught.
      '';
    };

    registries = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            index = mkOption {
              type = types.str;
              example = "sparse+https://my-registry.example/index/";
              description = ''
                The registry's index URL as it appears in `Cargo.lock`
                (with or without the `registry+` prefix; sparse registries
                keep `sparse+`).
              '';
            };
            dl = mkOption {
              type = types.str;
              example = "https://my-registry.example/api/v1/crates/{crate}/{version}/download";
              description = ''
                Download URL template, as in the registry's `config.json`
                (`{crate}`, `{version}`, `{prefix}`, `{lowerprefix}`,
                `{sha256-checksum}`). `Cargo.lock` records only the index,
                and reading `config.json` would need a fetch during
                evaluation.
              '';
            };
          };
        }
      );
      default = { };
      description = "Alternative registries, by name.";
    };

    gitHashes = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        "git+https://github.com/me/serde?rev=abc#abc0123" = "sha256-…";
      };
      description = ''
        NAR hashes of git sources, keyed by the full `Cargo.lock` source
        string. Optional: with a hash, the fetch is fixed-output and a
        binary cache can serve it; without one, every fresh machine clones
        the source during evaluation. The hash is that of the fetched tree
        (`builtins.fetchGit`'s `narHash`), not crane's `outputHashes`.
      '';
    };

    gitTrees = mkOption {
      type = types.attrsOf types.path;
      default = { };
      description = ''
        Use a local tree instead of fetching a git source. Keyed by the
        `Cargo.lock` source string or by URL.
      '';
    };

    gitSubdirs = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      example = {
        "https://github.com/me/repo" = {
          mycrate = "crates/mycrate";
        };
      };
      description = ''
        Where a crate lives inside a git source, keyed by source string or
        URL, then by crate name. Skips the walk over the tree's
        `Cargo.toml` files.
      '';
    };

    gitSubmodules = mkOption {
      type = types.attrsOf types.bool;
      default = { };
      description = ''
        Per git URL: whether to fetch submodules. Cargo checks out
        submodules of git dependencies, so the default is true.
      '';
    };

    sysDefaults.packages = mkOption {
      type = types.attrsOf (types.nullOr (types.functionTo (types.submodule settings)));
      default = { };
      # The result has the options of `packages.<name>`, documented there.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          libsqlite3-sys = null;  # no curated inputs
          aws-lc-sys = { version, ... }: { inputs = p: [ p.aws-lc ]; };
        }
      '';
      description = ''
        Default settings for a package, by crate name: a function of the
        package's lockfile entry (`{ name, version, ... }`) that returns
        settings with the options of `packages.<name>`. They are the
        lowest layer; `packages.<name>` settings add to them (lists
        concatenate, env attributes merge).

        They name nixpkgs libraries, so they apply only where a package
        set exists: host units always (the build machine's), target units
        only when `targets.<triple>.packageSet` exists (or the target is
        the native one). On other targets (msvc, wasm32-unknown-unknown)
        those crates build their bundled copies.

        The curated entries are defined at `mkDefault` priority, so a
        plain definition replaces one: `null` turns it off, a function
        replaces it, and `sysDefaults.packages = lib.mkForce { }` drops
        them all. They are: ${lib.concatMapStringsSep ", " (n: "`${n}`") (lib.attrNames curated)}.
      '';
    };

    sysDefaults.dependents = mkOption {
      type = types.attrsOf (types.nullOr (types.functionTo (types.submodule settings)));
      default = { };
      # The result has the options of `packages.<name>`, documented there.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          insta = null;  # no INSTA_* variables in test runs
          my-fixtures = _: { test.env.FIXTURES = run: "''${run.workspaceRoot}/fixtures"; };
        }
      '';
      description = ''
        Default settings for the workspace members that depend on a
        crate, by the crate's name: a function of the crate's lockfile
        entry (`{ name, version, ... }`) that returns settings with the
        options of `packages.<name>`. They apply to every path package of
        a workspace whose `Cargo.lock` has the crate among its
        dependencies of any kind (dev-dependencies too), directly or
        through other crates. They are a layer over `sysDefaults.packages`
        and under `memberDefaults`
        ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)).

        The curated entries are defined at `mkDefault` priority, so a
        plain definition replaces one: `null` turns it off, a function
        replaces it, and `sysDefaults.dependents = lib.mkForce { }` drops
        them all. They are: ${lib.concatMapStringsSep ", " (n: "`${n}`") (lib.attrNames curatedDependents)}.
        `insta` sets `INSTA_WORKSPACE_ROOT` to the workspace root of the
        run's files and `INSTA_UPDATE = "no"`, in test runs and doctests
        (see [Run snapshot tests](../../how-to/snapshot-tests.md)).
      '';
    };

    checkGroups = mkOption {
      type = types.attrsOf (types.listOf (types.either types.str types.package));
      default = { };
      example = lib.literalExpression ''
        {
          clippy = [ "*/*/variant-clippy/**" ];
          fmt = [ "*/fmt" ];
          release = [ "host/*/variant-release/**" self.packages.x86_64-linux.docs ];
        }
      '';
      description = ''
        Named groups of checks, each an aggregate check in `repo.checks`
        (and the flake's `checks`) that builds what it holds as one
        installable. Each item is a glob over check names, where `*`
        matches within one `/`-separated segment and `**` any number of
        segments, or a derivation to include as is. A pattern that
        matches no check is an error, as is a name that is already a
        check, a prefix group (every proper prefix of a check name is
        one) or `all`.
      '';
    };

    warnings = bt.warningsOption;
    assertions = bt.assertionsOption;
  };
}
