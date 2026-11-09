# packages.<name>: per-package overrides. They reach only that package's
# units, so a build stamp or a large SDK never changes another unit.
{
  lib,
  config,
  options,
  ...
}:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  versionReq = import ./version-req.nix { inherit lib; };
  settings = (import ./package-settings.nix { inherit lib; }).settings;

  package =
    {
      name,
      options,
      config,
      ...
    }:
    {
      imports = [ settings ];
      options = {
        version = mkOption {
          type = types.nullOr bt.versionReq;
          default = null;
          example = ">=0.42, <0.50";
          description = ''
            A version requirement in Cargo's syntax (`1.2`, `^1.2`, `~1.2`,
            `=1.2.3`, `>=1, <2`, `*`). The override applies to the
            package's locked versions that match. `null` matches every
            version. The attribute name may also carry the requirement:
            `packages."aws-lc-sys@>=0.42"`.
          '';
        };

        pipelining = bt.notImplemented 14 (mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Opt this package in or out of the pipelined split.";
        });

        warnings = bt.warningsOption;
      };

      config.warnings =
        bt.unimplementedWarnings "packages.${lib.strings.escapeNixIdentifier name}" options {
          "14" = [ [ "pipelining" ] ];
        };
    };
in
{
  options.packages = mkOption {
    type = types.attrsOf (types.submodule package);
    default = { };
    example = lib.literalExpression ''
      {
        openssl-sys = { nativeInputs = p: [ p.pkg-config ]; inputs = p: [ p.openssl ]; };
        app.env.GIT_REV = self.rev or "dirty";
        "libsqlite3-sys".env.LIBSQLITE3_SYS_USE_PKG_CONFIG = "1";  # opt in to the system SQLite
      }
    '';
    description = ''
      Per-package overrides, by package name (or `name@<version
      requirement>`). They apply in every workspace whose lockfile has a
      matching package, and only to that package's units. An override that
      matches nothing in any lockfile is an evaluation warning.
    '';
  };

  config.warnings = lib.concatMap (p: p.warnings) (lib.attrValues config.packages);

  # The requirement in a `name@<requirement>` key, which no option type sees.
  config.assertions = lib.concatMap (
    k:
    let
      m = builtins.match "([^@]+)@(.+)" k;
      req = builtins.elemAt m 1;
      # The files that define this key.
      files = map (d: d.file) (lib.filter (d: d.value ? ${k}) options.packages.definitionsWithLocations);
    in
    lib.optional (m != null) {
      assertion = versionReq.isReq req;
      message = "breakbulk: packages.${lib.strings.escapeNixIdentifier k}${bt.setIn { inherit files; }}: `${req}` is not a Cargo version requirement";
    }
  ) (lib.attrNames config.packages);
}
