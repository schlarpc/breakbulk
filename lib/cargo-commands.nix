# The Cargo command each plan of a variant traces ("Invocation" in
# docs/src/explanation/internals/planner.md): one row per plan kind, one
# argv per variant mode. Everything that differs between the plans of one
# variant is a field of its row; mkWorkspace maps over the rows, and the
# planner gets the argv (`--cargo-arg`) with the kind and mode as labels.
#
#   cargoCommands.plans {
#     mode;                      # "build" or "check"
#     profile; testProfile;      # the variant's
#     select; testSelect; benchSelect;   # -p lists ([ ]: --workspace)
#     bench;                     # whether the variant has a bench plan
#     docsNoDeps;                # `cargo doc --no-deps`
#   }
#   => { <kind> = { argv; profile; packages; wrappers; }; }
#
# for the kinds the variant plans. `wrappers`: whether the plan runs the
# variant's rustc wrappers and gets its wrapper env.
{ lib }:
let
  # Each row: `argv.<mode>`, a function of the variant's settings, or
  # absent when the kind has no form in that mode; `profile` and
  # `packages`, functions of the settings; `wrappers`; `when`, whether the
  # variant plans the kind at all.
  rows = {
    build = {
      argv = {
        build = _: [ "build" ];
        check = _: [ "check" ];
      };
    };
    # Plain `cargo test`, not `cargo test --no-run` and then `cargo test
    # --doc`: `--no-run` stops before the doctests, and `--doc` doc-tests
    # other libraries than `cargo test` does (also those with `doctest =
    # false`), whose dependencies' build-script runs then reach every
    # doctest's `-L` list. Cargo starts each test binary through the
    # planner's runner, which does nothing, and then asks rustdoc for the
    # doctests. The check form selects what `cargo test` builds, not
    # `--all-targets`, which adds the benches, so that check and build
    # variants of a workspace have the same units: `--tests` is the
    # targets `cargo test` tests (`Target::tested`), `--examples` the
    # examples it builds. Not `--lib --bins` too: `--lib` fails when no
    # selected package has a library, and `cargo test` builds the plain
    # library and bins only as what the tests depend on.
    test = {
      argv = {
        build = _: [ "test" ];
        check = _: [
          "check"
          "--tests"
          "--examples"
        ];
      };
      # `cargo check` has one profile, as `cargo clippy` does.
      profile = s: if s.mode == "build" then s.testProfile else s.profile;
      packages = s: s.testSelect;
    };
    bench = {
      argv.build = _: [
        "bench"
        "--no-run"
      ];
      packages = s: s.benchSelect;
      when = s: s.bench;
    };
    # `cargo doc` in every mode: rustdoc reads check-mode units, which a
    # check variant's plans share. No wrappers: the units rustdoc reads are
    # then a plain check variant's, and docs are nothing a lint or a
    # verifier can fail.
    doc = {
      argv = rec {
        build = s: [ "doc" ] ++ lib.optional s.docsNoDeps "--no-deps";
        check = build;
      };
      wrappers = false;
    };
  };

  plans =
    s:
    lib.mapAttrs
      (_: r: {
        argv = r.argv.${s.mode} s;
        profile = (r.profile or (s: s.profile)) s;
        packages = (r.packages or (s: s.select)) s;
        wrappers = r.wrappers or true;
      })
      (
        lib.filterAttrs (
          kind: r:
          (r.when or (_: true)) s
          && (r.argv ? ${s.mode} || throw "breakbulk: a ${s.mode} variant has no `${kind}` plan")
        ) rows
      );
in
{
  inherit rows plans;
  # Every plan kind, for outputs keyed by kind.
  kinds = lib.attrNames rows;
}
