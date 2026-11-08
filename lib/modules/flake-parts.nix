# A flake-parts module wrapping mkRepository.
#
#   inputs.breakbulk.url = "…";
#   outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
#     imports = [ inputs.breakbulk.flakeModule ];
#     systems = [ "x86_64-linux" ];
#     perSystem = { ... }: {
#       breakbulk = {
#         root = ./.;
#         modules = [ ./nix/rust.nix ];     # breakbulk modules (workspaces, packages, …)
#       };
#     };
#   };
#
# Per system it sets `breakbulk.repo` (the mkRepository result) and, unless
# turned off, adds:
#  - checks."<ws>/<triple>/<pkg>/<name>": repo.checks;
#  - packages."<pkg>" for each native product of the default variant
#    ("<ws>-<pkg>" when two workspaces have a package of that name);
#  - devShells."<ws>" for each workspace, and devShells.default when there
#    is exactly one.
breakbulkLib:
{ lib, flake-parts-lib, ... }:
let
  inherit (lib) types mkOption;
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    let
      cfg = config.breakbulk;
      repo = cfg.repo;
      wsNames = lib.attrNames repo.workspaces;
      allPkgs = lib.concatMap (ws: map (p: { inherit ws p; }) (lib.attrNames repo.workspaces.${ws}.packages)) wsNames;
      counts = lib.groupBy (x: x.p) allPkgs;
      pkgName = x: if lib.length counts.${x.p} > 1 then "${x.ws}-${x.p}" else x.p;
    in
    {
      options.breakbulk = {
        root = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            The repository root given to mkRepository: a path (`./.`) or
            the flake's `self`. breakbulk does nothing while it is null.
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
        exposeChecks = mkOption {
          type = types.bool;
          default = true;
          description = "Add repo.checks to the flake's checks.";
        };
        exposePackages = mkOption {
          type = types.bool;
          default = true;
          description = "Add the native products of every workspace to the flake's packages.";
        };
        exposeDevShells = mkOption {
          type = types.bool;
          default = true;
          description = "Add each workspace's dev shell to the flake's devShells.";
        };
      };

      config = lib.mkIf (cfg.root != null) {
        breakbulk.repo = breakbulkLib.mkRepository {
          pkgs = cfg.pkgs;
          inherit (cfg) root modules;
        };
        checks = lib.mkIf cfg.exposeChecks repo.checks;
        packages = lib.mkIf cfg.exposePackages (
          lib.listToAttrs (map (x: lib.nameValuePair (pkgName x) repo.workspaces.${x.ws}.packages.${x.p}) allPkgs)
        );
        devShells = lib.mkIf cfg.exposeDevShells (
          lib.genAttrs wsNames (ws: repo.workspaces.${ws}.devShell)
          // lib.optionalAttrs (lib.length wsNames == 1) {
            default = repo.workspaces.${lib.head wsNames}.devShell;
          }
        );
      };
    }
  );
}
