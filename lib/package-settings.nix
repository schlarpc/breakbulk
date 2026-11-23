# Package settings, evaluated: the layers of one package's settings
# (modules of lib/modules/package-settings.nix) merged by the module
# system, as variant layers are (`layer` in lib/modules/types.nix).
#
#   s = packageSettings.evaluate {
#     layers = [ { module = …; hostOnly = false; } … ];  # lowest first
#     defaults = packageSettings.contextDefaults { ca; };
#     specialArgs = { package = <lockfile entry>; … };
#   };
#   e = s.on { triple; variant; }
#   e.config                     the settings in the plans of `variant`
#                                on `triple` (`.options`: the evaluated
#                                options)
#   e.runs.test <key>            the run settings (`config.test`, test
#   e.runs.doctest               env values as strings or functions of
#   e.runs.bench <key>           the run) of one test binary's run, the
#                                doctest run, one bench binary's run
#   e.runEvals.<…>               the same, as evaluations
#   s.config, s.options, s.runs  without any `target` or `variant` layer
#   s.layerVariants              the names each layer's `variant` gives
#
# Each layer gets a rank: the layers in order, each followed by its own
# `target.<triple>` layer, then its `variant.<variant>` layer, then that
# one's `target.<triple>`. Single values of a higher rank win at equal
# priority; lists concatenate in rank order.
#
# Run settings are layers too: a run's settings are `test`'s, with the
# modules of `test.doctest` or `bench` (the run's kind), then of
# `test.binaries.<key>`, each ranked just above the layer that gave it
# and below that layer's `target` and `variant` layers. So within one
# layer the more specific setting wins, and across layers the higher
# layer's, as for `target` and `variant`.
{
  lib,
  # breakbulk.stageHelpers, for the `test.stages` default.
  helpers ? null,
}:
let
  bt = import ./modules/types.nix { inherit lib; };
  inherit (import ./modules/package-settings.nix { inherit lib; })
    settings
    runOptionNames
    doctestRefused
    ;

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

  # A module of run settings (`test.binaries.<key>`, `test.doctest`,
  # `bench`) as a module of package settings, setting them under `test`.
  # `what` names it in the error for an option that is not a run setting.
  # Only the run settings: under `test`, `runFiles` would be accepted and
  # do nothing.
  underTest =
    what:
    bt.mapModule {
      config = bt.underProperties (
        c:
        let
          bad = lib.attrNames (removeAttrs c runOptionNames);
        in
        if bad != [ ] then
          throw "breakbulk: ${what} sets ${lib.concatMapStringsSep ", " (n: "`${n}`") bad}, which ${
            if lib.length bad == 1 then "is not a run setting" else "are not run settings"
          }; the run settings are ${lib.concatMapStringsSep ", " (n: "`${n}`") runOptionNames}"
        else
          { test = c; }
      );
    };

  # Bench runs start with `--test` (libtest's and Criterion's test mode):
  # before every layer's arguments, so that `lib.mkForce` anywhere
  # replaces it.
  benchDefaults = {
    _file = ./package-settings.nix;
    test.args = lib.mkOrder 0 [ "--test" ];
  };

  # The run settings of evaluation `ev`, whose layers have the rooms
  # `rooms` (`{ rank; room; }`: the room between a layer and the next
  # thing ranked above it, a quarter of which each sub-layer level takes).
  runsOf =
    ev: rooms:
    let
      roomOf =
        rank:
        (lib.findFirst (r: r.rank == rank) (throw "breakbulk: no layer of rank ${toString rank}") rooms)
        .room;
      # The modules under `path` (a list of `{ rank; module; }`), each
      # ranked `f` of its layer's room above that layer.
      at =
        path: f:
        map (t: {
          rank = t.rank + f * roomOf t.rank;
          inherit (t) module;
        }) (lib.attrByPath path [ ] ev.config);
      resolve =
        what: subs: extra:
        if subs == [ ] && extra == [ ] then
          ev
        else
          ev.extendModules {
            modules = extra ++ map (t: layerOf t.rank (_: v: v) (underTest what t.module)) subs;
          };
      binary = key: at [ "test" "binaries" key ] 0.5;
      evals = {
        test = key: resolve "`test.binaries.${key}`" (binary key) [ ];
        doctest = resolve "`test.doctest`" (at [ "test" "doctest" ] 0.25) [ ];
        bench =
          key:
          resolve "`bench` or `test.binaries.${key}`" (at [ "bench" ] 0.25 ++ binary key) [
            benchDefaults
          ];
      };
      configOf =
        e:
        let
          t = e.config.test;
        in
        t
        // {
          env = lib.mapAttrs (_: bt.testEnvString) t.env;
          inherit (e.config) envSeparators;
        };
    in
    {
      runEvals = evals;
      runs = {
        test = key: configOf (evals.test key);
        doctest = configOf evals.doctest;
        bench = key: configOf (evals.bench key);
      };
    };
in
{
  inherit settings doctestRefused;

  # Defaults that come from outside the settings: `test.stages` follows
  # `ca`.
  contextDefaults =
    { ca }:
    {
      _file = ./package-settings.nix;
      test.stages = lib.optionalAttrs ca {
        strip = lib.mkOptionDefault {
          run = helpers.strip { buildId = false; };
        };
      };
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
      baseRooms = lib.genList (i: {
        rank = rankOf i;
        room = 1.0 / (4 * n);
      }) n;
      withRuns = ev: rooms: ev // runsOf ev rooms;
      on =
        {
          triple,
          variant,
        }:
        let
          # Each level of sub-layers between a layer and the next, a quarter
          # of the room the level above has: `target` first, then `variant`.
          # Not one evaluation of every module: a layer's sub-layers are
          # known only from its evaluated `target` and `variant` (a layer can
          # be a function of `package`), so each level extends the one above.
          walk =
            room: ev: parents: rooms:
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
              { inherit ev rooms; }
            else
              walk (room / 4)
                (ev.extendModules {
                  modules = map (t: layerOf t.rank (_: v: v) t.module) subs;
                })
                (map (t: t.rank) subs)
                (
                  rooms
                  ++ map (t: {
                    inherit (t) rank;
                    room = room / 4;
                  }) subs
                );
          r =
            if n == 0 then
              {
                ev = base;
                rooms = [ ];
              }
            else
              walk (1.0 / (4 * n)) base (lib.genList rankOf n) baseRooms;
        in
        withRuns r.ev r.rooms;
    in
    {
      inherit (base) config options;
      inherit on;
      inherit (runsOf base baseRooms) runs runEvals;
      # The variants each layer's `variant.<v>` names, in the order of
      # `layers`.
      layerVariants = lib.genList (
        i: lib.attrNames (lib.filterAttrs (_: lib.any (t: t.rank == rankOf i)) base.config.variant)
      ) n;
    };
}
