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
  inherit (import ./package-settings.nix { inherit lib; }) settingsModule;
in
{
  options.packages = mkOption {
    type = types.attrsOf settingsModule;
    default = { };
    example = lib.literalExpression ''
      {
        openssl-sys = { nativeInputs = p: [ p.pkg-config ]; inputs = p: [ p.openssl ]; };
        app.env.GIT_REV = self.rev or "dirty";
        "libsqlite3-sys".env.LIBSQLITE3_SYS_USE_PKG_CONFIG = "1";  # opt in to the system SQLite
        aws-lc-sys = breakbulk.whenVersion ">=0.42" { env.AWS_LC_SYS_PREBUILT_NASM = "1"; };
      }
    '';
    description = ''
      Per-package overrides, by crate name. They apply in every workspace
      whose lockfile has a package of that name, and only to that
      package's units. Each is a module of the options below, evaluated
      for each locked package of the name, with that package's lockfile
      entry (`{ name, version, source ? null, ... }`) as its `package`
      argument: `{ package, ... }: lib.mkIf (breakbulk.versionReq.matches
      ">=0.42" package.version) { … }` applies to the matching versions
      only, as does `breakbulk.whenVersion ">=0.42" { … }`. A name that no
      lockfile has is an evaluation warning.
    '';
  };

  # Crate names have no `@`: a key with one is a version condition, which
  # goes in the module instead.
  config.assertions = map (
    k:
    let
      files = map (d: d.file) (lib.filter (d: d.value ? ${k}) options.packages.definitionsWithLocations);
    in
    {
      assertion = false;
      message = "breakbulk: packages.${lib.strings.escapeNixIdentifier k}${bt.setIn { inherit files; }}: a key is a crate name; for some versions only, use `packages.${lib.strings.escapeNixIdentifier (lib.head (lib.splitString "@" k))} = breakbulk.whenVersion \"${lib.last (lib.splitString "@" k)}\" { … }`";
    }
  ) (lib.filter (lib.hasInfix "@") (lib.attrNames config.packages));
}
