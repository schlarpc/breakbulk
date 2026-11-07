# Repository-wide options: delivery mode, source strictness, fetching.
{ lib, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
in
{
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
        needs `ca-derivations` too), and off otherwise (decision 52).
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
        (`builtins.fetchGit`'s `narHash`), not crane's `outputHashes`
        (decision 14).
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
        Apply breakbulk's curated overrides for common `-sys` crates
        (seeded from nixpkgs' `defaultCrateOverrides`). Your own
        `packages.<name>` values merge with them: lists concatenate, env
        attributes merge, and `lib.mkForce` replaces a default.
      '';
    };

    warnings = bt.warningsOption;
  };
}
