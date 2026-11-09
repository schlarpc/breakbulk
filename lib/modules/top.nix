# Repository-wide options: delivery mode, source strictness, fetching,
# and the curated defaults for -sys crates (lib/sys-defaults.nix).
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  settings = (import ./package-settings.nix { inherit lib; }).settings;
  curated = import ../sys-defaults.nix { inherit lib; };
in
{
  config.sysDefaults.packages = lib.mkIf config.sysDefaults.enable (
    lib.mapAttrs (_: v: lib.mkDefault (if builtins.isFunction v then v else _: v)) curated
  );

  options = {
    mode = mkOption {
      type = types.enum [
        "auto"
        "ifd"
        "dynamic"
      ];
      default = "auto";
      description = ''
        How unit derivations reach Nix. `ifd`: breakbulk-instantiate writes
        units.json, which Nix imports (import-from-derivation). `dynamic`:
        an outer derivation writes the unit derivations through Nix's
        `builder-rpc-v0` interface and products reach them with
        `builtins.outputOf` (needs Nix 2.36 or later with the
        `dynamic-derivations` and `ca-derivations` experimental features).
        `auto` picks `dynamic` when the evaluator has `builtins.outputOf`
        and is Nix 2.36 or later, and `ifd` otherwise. A daemon or builder
        older than the evaluator fails with Nix's own "missing system
        features" error naming `builder-rpc-v0`; set `ifd` then. Unit
        derivations are identical in both modes; products are not (they are
        resolved at build time in `dynamic`), so teams that mix Nix versions
        should pin the mode.

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
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Content-address post-link stages, checks and test runs, so that an
        unchanged input does not re-run them. Needs Nix's `ca-derivations`
        experimental feature in the evaluator and the daemon. `null` turns
        it on exactly when the evaluator has `dynamic-derivations` (which
        needs `ca-derivations` too), and off otherwise: Nix code cannot
        tell whether `ca-derivations` is on, and without it a
        content-addressed derivation is an error that cannot be caught.
      '';
    };

    strictSources = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Fail a build-script run that succeeds while declaring a
        `rerun-if-changed` path missing from its sandbox. When false, such
        paths are warnings that name the option to add them to.
        `packages.<name>.strictSources` overrides it per package.
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

    sysDefaults.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Define breakbulk's curated settings for common `-sys` crates
        (seeded from nixpkgs' `defaultCrateOverrides`) in
        `sysDefaults.packages`.
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
        replaces it. They are: ${lib.concatMapStringsSep ", " (n: "`${n}`") (lib.attrNames curated)}.
      '';
    };

    warnings = bt.warningsOption;
    assertions = bt.assertionsOption;
  };
}
