# Native libraries reach the link steps of the packages that link them,
# over ./fixture: `foo-sys` prints only `rustc-link-lib=foo`, and
# `packages.foo-sys.inputs` names a small C shared library built here from
# ./foo.c. Wired into the flake's checks as
# `native-link-*`.
#
#   nix build -f tests/native-link runs
#
#   runs           app's bin (another package than foo-sys) links and runs
#                  with an empty environment: the linker found libfoo through
#                  foo-sys's capture and recorded an rpath to it. app's unit
#                  test, mid's unit test harness and mid's doctest link and
#                  pass too. Host units get no target capture.
#   invalidation   changing foo-sys's input (the library, built with another
#                  answer) changes foo-sys's own units and those of the
#                  packages that depend on it (as any change to foo-sys's
#                  units does, by input addressing), and nothing of `other`,
#                  which does not link it.
{
  pkgs ? import (
    let
      n = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
    in
    fetchTarball {
      url = "https://github.com/${n.owner}/${n.repo}/archive/${n.rev}.tar.gz";
      sha256 = n.narHash;
    }
  ) { },
  breakbulk ? import ../../lib { inherit (pkgs) lib; },
}:
let
  inherit (pkgs) lib;
  tools = breakbulk.mkTools pkgs;
  native = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  # libfoo.so, whose foo_answer() returns `answer`.
  libfoo =
    answer:
    pkgs.runCommandCC "libfoo-${toString answer}" { } ''
      mkdir -p $out/lib
      $CC -shared -fPIC -DANSWER=${toString answer} -o $out/lib/libfoo.so ${./foo.c}
    '';

  mkRepo =
    lib':
    breakbulk.mkRepository {
      inherit pkgs tools;
      root = ./fixture;
      modules = [
        {
          workspaces.main = {
            variants.default.profile = "dev";
            # native-link-runs reads the runs' output.
            memberDefaults.test.keepLog = true;
          };
          packages.foo-sys.inputs = [ lib' ];
        }
      ];
    };
  repo = mkRepo (libfoo 42);
  changedRepo = mkRepo (libfoo 43);
  ws = repo.workspaces.main;
  instOf = r: r.workspaces.main.instances.${native}.default;

  # Unit .drv path -> derivation name, for both plan kinds, plus doctests.
  drvNames =
    r:
    let
      i = instOf r;
    in
    lib.listToAttrs (
      map (u: lib.nameValuePair (builtins.unsafeDiscardStringContext u.drvPath) u.name) (
        lib.attrValues i.units.build ++ lib.attrValues i.units.test ++ lib.attrValues i.doctests
      )
    );
  changed =
    before: after:
    let
      b = drvNames before;
    in
    lib.sort lib.lessThan (
      lib.unique (lib.attrValues (lib.filterAttrs (d: _: !(b ? ${d})) (drvNames after)))
    );

  # The rendered units, by derivation name.
  rendered =
    r:
    let
      i = instOf r;
    in
    lib.listToAttrs (
      map (
        u:
        lib.nameValuePair u.name (
          builtins.fromJSON (builtins.unsafeDiscardStringContext u.drvAttrs.BREAKBULK_UNIT)
        )
      ) (
        lib.filter (u: u.drvAttrs ? BREAKBULK_UNIT) (
          lib.attrValues i.units.build ++ lib.attrValues i.units.test
        )
      )
    );
in
{
  inherit repo;

  runs =
    let
      units = rendered repo;
      linkCaps = n: units.${n}.linkCaptures or [ ];
      app = ws.packages.app;
      t = ws.testRuns;
    in
    # The bin links foo-sys through mid: it gets foo-sys's capture. mid's
    # library compile does not link; foo-sys's own units have the capture
    # as layer 2 already; build scripts are host units.
    assert lib.assertMsg (
      lib.length (linkCaps "app-0.1.0-bin") == 1
    ) "native-link: app's bin has link captures ${builtins.toJSON (linkCaps "app-0.1.0-bin")}";
    assert lib.assertMsg (
      linkCaps "mid-0.1.0-lib" == [ ] && linkCaps "foo-sys-0.1.0-lib" == [ ] && linkCaps "other-0.1.0-bin" == [ ]
    ) "native-link: a unit that does not link, or links nothing of foo-sys, got link captures";
    assert lib.assertMsg (lib.all (n: linkCaps n == [ ]) (
      lib.filter (lib.hasInfix "build-script") (lib.attrNames units)
    )) "native-link: a build-script compile got a link capture";
    pkgs.runCommand "native-link-runs"
      {
        nativeBuildInputs = [ pkgs.binutils ];
        inherit app;
        appTest = t.app."bin/app";
        midTest = t.mid."lib/mid";
        midDoctest = ws.target.${native}.doctests.mid;
        foo = libfoo 42;
      }
      ''
        bin=$app/bin/app
        env -i "$bin" | tee out
        grep -qx 'the answer is 42' out
        readelf -d "$bin" | grep -E 'R(UN)?PATH' | tee rpath
        grep -q "$foo/lib" rpath
        grep -q 'test tests::links_and_runs ... ok' $appTest/log
        grep -q 'running 0 tests' $midTest/log
        grep -q 'test result: ok. 1 passed' $midDoctest/log
        mkdir -p $out
        cp out rpath $out/
      '';

  invalidation =
    let
      got = changed repo changedRepo;
      # foo-sys's units, and its dependents' (whose inputs, foo-sys's
      # outputs, changed); never `other`'s.
      want = [
        "app-0.1.0-bin"
        "app-0.1.0-test"
        "foo-sys-0.1.0-build-run"
        "foo-sys-0.1.0-build-script"
        "foo-sys-0.1.0-doctest"
        "foo-sys-0.1.0-lib"
        "foo-sys-0.1.0-test"
        "mid-0.1.0-doctest"
        "mid-0.1.0-lib"
        "mid-0.1.0-test"
      ];
    in
    assert lib.assertMsg (got == want)
      "native-link: changing foo-sys's input changed ${builtins.toJSON got}, expected ${builtins.toJSON want}";
    pkgs.runCommand "native-link-invalidation" { } ''
      mkdir -p $out
      echo ${lib.escapeShellArg (builtins.toJSON got)} > $out/changed
    '';
}
