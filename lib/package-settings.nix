# Package settings, evaluated: the layers of one package's settings
# (modules of lib/modules/package-settings.nix) merged by the module
# system, as variant layers are (`layer` in lib/modules/types.nix).
#
#   s = packageSettings.evaluate {
#     layers = [ { module = …; hostOnly = false; } … ];  # lowest first
#     defaults = packageSettings.contextDefaults { ca; nextestConfig; };
#     specialArgs = { package = <lockfile entry>; … };
#   };
#   (s.on { triple; variant; }).config   the settings in the plans of
#                                `variant` on `triple` (`.options`: the
#                                evaluated options)
#   s.config, s.options          without any `target` or `variant` layer
#   s.layerVariants              the names each layer's `variant` gives
#
# Each layer gets a rank: the layers in order, each followed by its own
# `target.<triple>` layer, then its `variant.<variant>` layer, then that
# one's `target.<triple>`. Single values of a higher rank win at equal
# priority; lists concatenate in rank order.
{ lib }:
let
  bt = import ./modules/types.nix { inherit lib; };
  inherit (import ./modules/package-settings.nix { inherit lib; }) settings;

  layerOf = bt.layer (lib.evalModules { modules = [ settings ]; }).options;

  # A curated layer on a target without a package set: what it sets for
  # both sides (`env`, `inputs`, `nativeInputs`) goes to the host side
  # only, and what it sets for the target side is left out. Curated
  # settings name nixpkgs libraries, which only the build machine has
  # there.
  hostOnly = bt.mapModule {
    config = bt.underProperties (
      c:
      let
        both = lib.filterAttrs (
          n: _:
          lib.elem n [
            "env"
            "inputs"
            "nativeInputs"
          ]
        ) c;
        sub = lib.mapAttrs (_: bt.underProperties hostOnly);
      in
      removeAttrs c [
        "env"
        "inputs"
        "nativeInputs"
        "forHost"
        "forTarget"
        "target"
        "variant"
      ]
      // {
        forHost = lib.mkMerge ([ both ] ++ lib.optional (c ? forHost) c.forHost);
      }
      // lib.optionalAttrs (c ? target) { target = bt.underProperties sub c.target; }
      // lib.optionalAttrs (c ? variant) { variant = bt.underProperties sub c.variant; }
    );
  };
in
{
  inherit settings;

  # The settings of a test binary that `test.binaries` does not list.
  binaryDefaults =
    (lib.evalModules {
      modules = [
        settings
        { test.binaries.none = { }; }
      ];
    }).config.test.binaries.none;

  # Defaults that come from outside the settings: `test.stripForRun`
  # follows `ca`, `test.nextest.configFile` is the workspace's own
  # (lib/test-runs.nix nextestDefaultConfig).
  contextDefaults =
    { ca, nextestConfig }:
    {
      test.stripForRun = lib.mkOptionDefault ca;
      test.nextest.configFile = lib.mkOptionDefault nextestConfig;
    };

  evaluate =
    {
      layers,
      defaults ? { },
      specialArgs ? { },
    }:
    let
      n = lib.length layers;
      rankOf = i: i * 1.0 / n;
      base = lib.evalModules {
        modules = [
          settings
          defaults
        ]
        ++ lib.imap0 (
          i: l: layerOf (rankOf i) (_: v: v) (if l.hostOnly or false then hostOnly l.module else l.module)
        ) layers;
        inherit specialArgs;
      };
      # Each level of sub-layers between a layer and the next, a quarter
      # of the room the level above has: `target` first, then `variant`.
      on =
        { triple, variant }:
        let
          go =
            room: ev: parents:
            let
              of =
                kind: key: offset:
                map (t: {
                  rank = t.rank + offset * room;
                  inherit (t) module;
                }) (lib.filter (t: lib.elem t.rank parents) (ev.config.${kind}.${key} or [ ]));
              subs = of "target" triple 1 ++ of "variant" variant 2;
            in
            if subs == [ ] then
              ev
            else
              go (room / 4) (ev.extendModules {
                modules = map (t: layerOf t.rank (_: v: v) t.module) subs;
              }) (map (t: t.rank) subs);
        in
        go (1.0 / (4 * n)) base (lib.genList rankOf n);
    in
    {
      inherit (base) config options;
      inherit on;
      # The variants each layer's `variant.<v>` names, in the order of
      # `layers`.
      layerVariants = lib.genList (
        i: lib.attrNames (lib.filterAttrs (_: lib.any (t: t.rank == rankOf i)) base.config.variant)
      ) n;
    };
}
