# A flake-parts module wrapping mkRepository.
#
#   inputs.breakbulk.url = "…";
#   outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
#     imports = [ inputs.breakbulk.lib.flakeModule ];
#     systems = [ "x86_64-linux" ];
#     perSystem = { ... }: {
#       breakbulk.modules = [ ./nix/rust.nix ];  # breakbulk modules (workspaces, packages, …)
#     };
#   };
#
# `root` defaults to the flake's `self`: flake-parts passes it to every
# top-level module as a special argument (flake-parts lib.nix,
# `evalFlakeModule`: `specialArgs = { inherit self flake-parts-lib
# moduleLocation; inputs = …; }`), so this module reads it there.
#
# Per system it sets `breakbulk.repo` (the mkRepository result) and, unless
# turned off (`breakbulk.expose.<output> = false`), each of `checks`,
# `packages`, `apps` and `devShells` from `repo.flake` (lib/repository.nix,
# which names them for a flake without flake-parts too).
breakbulkLib:
{
  lib,
  flake-parts-lib,
  self,
  ...
}:
let
  inherit (lib) types mkOption;
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    let
      cfg = config.breakbulk;
      repo = cfg.repo;
    in
    {
      options.breakbulk = {
        root = mkOption {
          type = types.nullOr types.path;
          default = self;
          defaultText = lib.literalExpression "self";
          description = ''
            The repository root given to mkRepository: the flake's `self`
            (the default) or a path (`./.`). `null` turns breakbulk off.
          '';
        };
        modules = mkOption {
          type = types.listOf types.deferredModule;
          default = [ ];
          description = "breakbulk configuration modules (workspaces, targets, packages, …).";
        };
        pkgs = mkOption {
          type = types.raw;
          default = pkgs;
          defaultText = lib.literalExpression "pkgs";
          description = "The package set breakbulk builds with.";
        };
        repo = mkOption {
          type = types.raw;
          readOnly = true;
          description = "The mkRepository result.";
        };
        expose = {
          checks = mkOption {
            type = types.bool;
            default = true;
            description = "Add repo.checks to the flake's checks.";
          };
          packages = mkOption {
            type = types.bool;
            default = true;
            description = "Add every workspace's products on its default target (`workspaces.<ws>.defaultTarget`) to the flake's packages, and its default variant's docs there as `<ws>-docs`.";
          };
          apps = mkOption {
            type = types.bool;
            default = true;
            description = "Add repo.apps (every test app, named as its test run's check) to the flake's apps.";
          };
          devShells = mkOption {
            type = types.bool;
            default = true;
            description = "Add each workspace's dev shell to the flake's devShells.";
          };
        };
      };

      config = lib.mkIf (cfg.root != null) {
        breakbulk.repo = breakbulkLib.mkRepository {
          pkgs = cfg.pkgs;
          inherit (cfg) root modules;
        };
        checks = lib.mkIf cfg.expose.checks repo.flake.checks;
        packages = lib.mkIf cfg.expose.packages repo.flake.packages;
        apps = lib.mkIf cfg.expose.apps repo.flake.apps;
        devShells = lib.mkIf cfg.expose.devShells repo.flake.devShells;
      };
    }
  );
}
