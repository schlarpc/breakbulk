# Checks for the evaluation-time Nix library. Wired into the flake's
# `checks.<system>`; each attribute is a derivation.
#
#   lib-unit                 pure evaluation assertions (lockfile parsing,
#                            path helpers, globbing, TOML writer, URLs,
#                            vendor config)
#   target-traits, target-traits-rustc   lib/target-traits.nix (see
#                            ./target-traits.nix)
#   llvm-versions            lib/llvm-versions.nix against `rustc -vV`
#   roots-metadata-fixtures  predicted targets == `cargo metadata` for fixtures
#   roots-metadata-crates-io the same for real crates.io crates (IFD)
#   roots-plans              predicted build/test/bench roots == what real
#                            `cargo build`, `cargo test --no-run` and
#                            `cargo bench --no-run` compile
#   skeleton                 `cargo metadata` over the skeleton == over the
#                            real tree
#   source-views             file lists of source views
#   vendor-collision         crates.io + git crates (network at evaluation
#                            for git), offline `cargo build` against the
#                            vendor directory with unchanged `-C metadata`
#   vendor-git-inherit       git crates using workspace inheritance, offline
{
  pkgs,
  breakbulk,
}:
let
  inherit (pkgs) lib;
  bb = breakbulk;
  fixtures = ../fixtures;
  cargo = pkgs.cargo;
  rustc = pkgs.rustc;
  jq = pkgs.jq;

  # --- helpers -------------------------------------------------------------

  runTests =
    name: tests:
    let
      failures = lib.debug.runTests tests;
    in
    if failures == [ ] then
      pkgs.runCommand name { } "touch $out"
    else
      throw "${name}: ${builtins.toJSON failures}";

  doctestable = t: t.kind == "lib" && lib.any (c: lib.elem c [ "lib" "rlib" "proc-macro" ]) t.crateTypes;

  # The prediction, in the shape of tests/nix/metadata-shape.jq.
  predictedShape =
    wsRoots:
    {
      members = lib.sort (a: b: a < b) (lib.attrNames wsRoots);
      packages = lib.mapAttrs (
        _: p:
        map (t: {
          kind = if t.kind == "lib" then t.crateTypes else [ t.kind ];
          crate_types = if t.kind == "lib" || t.kind == "example" then t.crateTypes else [ "bin" ];
          inherit (t) name test;
          src_path = bb.util.joinRel p.dir t.path;
          doctest = t.doctest && doctestable t;
          required_features = t.requiredFeatures;
        }) p.targets
      ) wsRoots;
    };

  # One comparison: `root` is a store path (string) or Nix path holding the
  # workspace; `wsDir` its workspace directory.
  metadataCase =
    {
      name,
      root,
      wsDir ? "",
    }:
    let
      predicted = bb.roots.workspaceRoots { inherit root wsDir; };
    in
    {
      inherit name;
      root = "${root}";
      inherit wsDir;
      expected = builtins.toJSON (predictedShape predicted);
    };

  compareMetadata =
    checkName: cases:
    pkgs.runCommand checkName
      {
        nativeBuildInputs = [
          cargo
          rustc
          jq
        ];
        casesJson = builtins.toJSON cases;
        passAsFile = [ "casesJson" ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        fail=0
        n=$(jq length "$casesJsonPath")
        for i in $(seq 0 $((n - 1))); do
          name=$(jq -r ".[$i].name" "$casesJsonPath")
          root=$(jq -r ".[$i].root" "$casesJsonPath")
          ws=$(jq -r ".[$i].wsDir" "$casesJsonPath")
          manifest="$root''${ws:+/$ws}/Cargo.toml"
          cargo metadata --no-deps --offline --format-version 1 --manifest-path "$manifest" \
            | jq -S --arg root "$root" -f ${./metadata-shape.jq} > got.json
          jq -r ".[$i].expected" "$casesJsonPath" \
            | jq -S '.packages |= map_values(sort_by(.kind, .name))' > want.json
          if diff -u want.json got.json > diff.txt; then
            echo "ok: $name"
          else
            echo "MISMATCH: $name (- predicted, + cargo metadata)"
            cat diff.txt
            fail=1
          fi
        done
        [ $fail = 0 ]
        touch $out
      '';

  # --- crates.io corpus ----------------------------------------------------

  fetch = bb.mkFetch pkgs { };

  corpus = [
    # src/bin/*.rs next to a lib
    { name = "cargo-binutils"; version = "0.3.6"; checksum = "ec9a0e2ad2c6ec1516256bf9d0f07841a55265f2167e5d1c88ed1f99c73900da"; }
    # [[bin]] with path src/bin/<name>/main.rs and required-features
    { name = "sccache"; version = "0.7.7"; checksum = "578f230c68caf909e056db3be748acfe19cd7e5bc5b985a27e4e63b826b9777c"; }
    # autotests = false with an explicit [[test]] path
    { name = "regex"; version = "1.10.4"; checksum = "c117dbdfde9c8308975b6a18d71f3f385c89461f7b3fb054288ecf2a2058ba4c"; }
    # many [[example]] tables with required-features
    { name = "clap"; version = "4.4.18"; checksum = "1e578d6ec4194633722ccf9544794b71b1385c3c027efe0c55db226fc880865c"; }
    # [[test]] and [[bench]] tables, harness = false
    { name = "syn"; version = "2.0.48"; checksum = "0f3531638e407dfc0814761abb7c00a5b54992b849452a0646b7f65c9f770f3f"; }
    # src/bin/*/main.rs (wasm-bindgen-test-runner)
    { name = "wasm-bindgen-cli"; version = "0.2.92"; checksum = "08f61e21873f51e3059a8c7c3eef81ede7513d161cfc60751c7b2ffa6ed28270"; }
    { name = "mdbook"; version = "0.4.37"; checksum = "0c33564061c3c640bed5ace7d6a2a1b65f2c64257d1ac930c15e94ed0fb561d3"; }
    { name = "criterion"; version = "0.5.1"; checksum = "f2b12d017a929603d80db1831cd3a24082f8137ce19c69e6447f54f5fc8d692f"; }
    # edition 2015
    { name = "rand"; version = "0.4.6"; checksum = "552840b97013b1a26992c11eac34bdd778e464601a4c2054b5f0bff7c6761293"; }
    { name = "lazy_static"; version = "1.4.0"; checksum = "e2abad23fbc42b3700f2f279844dc832adb2b2eb069b2df918f455c4e18cc646"; }
    # [[bin]] path = "main.rs" at the package root
    { name = "bindgen-cli"; version = "0.69.4"; checksum = "5d31479f44d2c9eed368e5f945cb4846d2c8313bd91feb16b6ae937a80b7ae01"; }
    # published with normalized, fully explicit targets (auto* = false)
    { name = "ripgrep"; version = "14.1.1"; checksum = "f77b8032dc584527975f34aa5a897d0ef5a785573fda778771a614ff9da501d9"; }
    { name = "tokio"; version = "1.36.0"; checksum = "61285f6515fa018fb2d1e46eb21223fff441ee8db5d0f1435e8ab4f5cdb80931"; }
  ];

  corpusEntry =
    c:
    bb.lockfile.mkEntry {
      inherit (c) name version checksum;
      source = "registry+${bb.lockfile.cratesIoIndex}";
    };

  # A crate's original manifest (Cargo.toml.orig) is usable on its own when
  # it neither inherits from nor declares a workspace, and has no path
  # dependencies; then discovery runs on the author's manifest instead of
  # the normalized one.
  origUsable =
    src:
    let
      p = "${src}/Cargo.toml.orig";
      m = builtins.fromTOML (builtins.readFile p);
      inheritsOrPath = v: builtins.isAttrs v && (v.workspace or false || v ? path);
    in
    builtins.pathExists p
    && !(m ? workspace)
    && !(lib.any inheritsOrPath (builtins.attrValues (m.package or { })))
    && !(lib.any (t: lib.any inheritsOrPath (builtins.attrValues t)) (bb.manifest.dependencyTables m))
    && !(m ? patch);

  withOrig =
    src: name:
    pkgs.runCommand "${name}-orig" { } ''
      cp -r ${src} $out
      chmod -R u+w $out
      mv $out/Cargo.toml.orig $out/Cargo.toml
    '';

  corpusCases = lib.concatMap (
    c:
    let
      src = fetch.unpackRegistryCrate (corpusEntry c);
      id = "${c.name}-${c.version}";
    in
    [
      (metadataCase {
        name = "${id} (published Cargo.toml)";
        root = "${src}";
      })
    ]
    ++ lib.optional (origUsable src) (metadataCase {
      name = "${id} (Cargo.toml.orig)";
      root = "${withOrig src id}";
    })
  ) corpus;

  # --- plan roots against real Cargo ---------------------------------------

  rootsLayouts = fixtures + "/roots-layouts";

  planExpectation =
    root:
    let
      ws = bb.roots.workspaceRoots { inherit root; };
      entries =
        plan:
        lib.concatLists (
          lib.mapAttrsToList (
            _: p:
            map (r: {
              key = "${p.dir}|${r.kind}|${r.name}|${if r.mode == "build" then "build" else "test"}";
              optional = r.requiredFeatures != null;
            }) p.roots.${plan}
          ) ws
        );
    in
    {
      build = entries "build";
      test = entries "test";
      bench = entries "bench";
    };

  rootsPlans = pkgs.runCommandCC "roots-plans" {
    nativeBuildInputs = [ cargo rustc jq ];
    expectedJson = builtins.toJSON (planExpectation rootsLayouts);
    passAsFile = [ "expectedJson" ];
  } ''
    export CARGO_HOME=$TMPDIR/cargo-home
    cp -r ${rootsLayouts} ws
    chmod -R u+w ws
    cd ws
    root=$(pwd)
    # Roots of a plan from Cargo's JSON messages: test-mode units, plus
    # (cargo build) every unit, or (cargo test) examples built in build mode.
    collect() {
      jq -r --arg root "$root/" --arg plan "$1" '
        select(.reason == "compiler-artifact")
        | (.manifest_path | ltrimstr($root) | sub("/?Cargo.toml$"; "")) as $dir
        | (.target.kind) as $k
        | (if ($k | index("example")) then "example"
           elif ($k | index("test")) then "test"
           elif ($k | index("bench")) then "bench"
           elif ($k | index("custom-build")) then "custom-build"
           elif ($k | index("bin")) then "bin"
           else "lib" end) as $kind
        | (if .profile.test then "test" else "build" end) as $mode
        | select($kind != "custom-build")
        | select($plan == "build" or $mode == "test" or ($plan == "test" and $kind == "example"))
        | "\($dir)|\($kind)|\(.target.name)|\($mode)"'
    }
    cargo build --workspace --offline --message-format=json -q | collect build | sort -u > got-build
    cargo test --workspace --no-run --offline --message-format=json -q | collect test | sort -u > got-test
    cargo bench --workspace --no-run --offline --message-format=json -q | collect bench | sort -u > got-bench
    fail=0
    for plan in build test bench; do
      jq -r ".$plan[] | .key" "$expectedJsonPath" | sort -u > want-$plan
      jq -r ".$plan[] | select(.optional | not) | .key" "$expectedJsonPath" | sort -u > want-required-$plan
      # Cargo may skip roots whose required-features are off; nothing else.
      if ! comm -13 want-$plan got-$plan | diff /dev/null - ; then
        echo "$plan: Cargo built roots that were not predicted"; fail=1
      fi
      if ! comm -23 want-required-$plan got-$plan | diff /dev/null - ; then
        echo "$plan: predicted roots without required-features that Cargo did not build"; fail=1
      fi
      echo "== $plan"; cat got-$plan
    done
    [ $fail = 0 ]
    touch $out
  '';

  # --- skeleton --------------------------------------------------------------

  skeletonCheck =
    let
      sk = bb.mkSkeleton pkgs { root = rootsLayouts; };
    in
    pkgs.runCommand "skeleton"
      {
        nativeBuildInputs = [ cargo rustc jq ];
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cargo metadata --no-deps --offline --format-version 1 --manifest-path ${rootsLayouts}/Cargo.toml \
          | jq -S --arg root ${rootsLayouts} -f ${./metadata-shape.jq} > real.json
        cargo metadata --no-deps --offline --format-version 1 --manifest-path ${sk}/Cargo.toml \
          | jq -S --arg root ${sk} -f ${./metadata-shape.jq} > skeleton.json
        diff -u real.json skeleton.json
        # Only names: every file in the skeleton is a manifest, config or
        # lockfile, or empty.
        find ${sk} -type f ! -name Cargo.toml ! -name Cargo.lock ! -name config.toml -size +0 | diff /dev/null -
        # README files that set CARGO_PKG_README are present (empty).
        test -f ${sk}/README.md
        test -f ${sk}/crates/bin-dirs/README.md
        # Files that are not target candidates are absent.
        test ! -e ${sk}/crates/bin-dirs/src/bin/notes.txt
        test ! -e ${sk}/crates/bin-dirs/tests/common/mod.rs
        # Non-members that are not path dependencies are absent.
        test ! -e ${sk}/crates/excluded
        test ! -e ${sk}/virtual-sub/nested
        touch $out
      '';

  # --- source views ----------------------------------------------------------

  sourceViewsCheck =
    let
      views = bb.sourceViews.workspaceViews {
        root = rootsLayouts;
        extraSources.bin-dirs = [ "shared/bin" ];
      };
    in
    pkgs.runCommand "source-views" { } ''
      v=${views.virtual-sub.src}
      test -f $v/virtual-sub/src/main.rs
      test -f $v/virtual-sub/nested/Cargo.toml    # non-member package dir kept
      test ! -e $v/virtual-sub/inner              # nested member excluded
      test ! -e $v/crates                         # other packages excluded
      b=${views.bin-dirs.src}
      test -f $b/crates/bin-dirs/src/bin/notes.txt
      test -f $b/shared/bin/main.rs               # extraSources, same layout
      test ! -e $b/shared/util
      test "$(cd $b && find . -name Cargo.toml)" = "./crates/bin-dirs/Cargo.toml"
      touch $out
    '';

  # --- vendoring -------------------------------------------------------------

  vendorBuild =
    {
      name,
      src,
      fetchArgs ? { },
      expectOutput,
      expectedMetadata ? null,
    }:
    let
      f = bb.mkFetch pkgs fetchArgs;
      entries = bb.lockfile.read (src + "/Cargo.lock");
      vendor = bb.mkVendor pkgs {
        fetch = f;
        inherit entries;
      };
    in
    pkgs.runCommandCC name
      {
        nativeBuildInputs = [ cargo rustc ];
        passthru = { inherit vendor; };
      }
      ''
        export CARGO_HOME=$TMPDIR/cargo-home
        cp -r ${src} ws
        chmod -R u+w ws
        cd ws
        cargo build --offline --frozen -v --config ${vendor.configFile} 2> build.log || { cat build.log; exit 1; }
        out_line=$(./target/debug/${name})
        echo "$out_line"
        test "$out_line" = ${lib.escapeShellArg expectOutput}
        ${lib.optionalString (expectedMetadata != null) ''
          grep -oE -- "--crate-name [^ ]+ |-C metadata=[0-9a-f]+" build.log | paste -d' ' - - | sort > got-metadata
          diff -u ${expectedMetadata} got-metadata
        ''}
        mkdir -p $out
        cp build.log $out/
      '';
in
{
  lib-unit = import ./unit.nix { inherit pkgs bb runTests; };

  inherit (import ./target-traits.nix { inherit pkgs bb runTests; }) target-traits target-traits-rustc;

  # #37 (assumption L4): every row of lib/llvm-versions.nix against the
  # LLVM major that `rustc -vV` names, for the first and last release of
  # each row at the pinned rust-overlay (rustc component only), plus the
  # current beta and nightly up to `verifiedThrough`.
  llvm-versions =
    let
      rs = pkgs.rust-bin;
      toolchains = [
        rs.stable."1.90.0".rustc
        rs.stable."1.91.0".rustc
        rs.stable."1.94.1".rustc
        rs.stable."1.95.0".rustc
        rs.stable."1.98.1".rustc
        rs.stable."1.99.0".rustc
        rs.stable."1.99.1".rustc
        rs.beta.latest.rustc
        rs.nightly.latest.rustc
      ];
      expected = map (t: {
        inherit (t) version;
        llvm = bb.llvmVersions.lookup t.version;
      }) toolchains;
      missing = lib.filter (e: e.llvm == null) expected;
    in
    assert lib.assertMsg (missing == [ ])
      "llvm-versions: not in the table (extend it, or `verifiedThrough`): ${toString (map (e: e.version) missing)}";
    pkgs.runCommand "llvm-versions" { } ''
      set -eu
      ${lib.concatMapStrings (t: ''
        got=$(${t}/bin/rustc -vV | sed -n 's/^LLVM version: \([0-9][0-9]*\)\..*/\1/p')
        echo "${t.version}: table ${toString (bb.llvmVersions.lookup t.version)}, rustc -vV $got"
        [ "$got" = ${toString (bb.llvmVersions.lookup t.version)} ] || { echo "llvm-versions: ${t.version} mismatch" >&2; exit 1; }
      '') toolchains}
      touch $out
    '';

  roots-metadata-fixtures = compareMetadata "roots-metadata-fixtures" [
    (metadataCase {
      name = "roots-layouts";
      root = rootsLayouts;
    })
    (metadataCase {
      name = "vendor-git-inherit/repo";
      root = fixtures + "/vendor-git-inherit/repo";
    })
  ];

  roots-metadata-crates-io = compareMetadata "roots-metadata-crates-io" corpusCases;

  roots-plans = rootsPlans;

  skeleton = skeletonCheck;

  source-views = sourceViewsCheck;

  vendor-collision = vendorBuild {
    name = "vendor-collision";
    src = fixtures + "/vendor-collision";
    # One git source pinned by NAR hash (substitutable), one without.
    fetchArgs.gitHashes."git+https://github.com/dtolnay/itoa?tag=1.0.11#8f392032fadf15b5e6b9b7b6add21875575d67af" =
      "sha256-5mLf4B3zTZwv3wKgdixL/QJuTuouPlpm01rMFAZ8D6Y=";
    expectOutput = "ok 42";
    expectedMetadata = fixtures + "/vendor-collision/expected-metadata.txt";
  };

  vendor-git-inherit = vendorBuild {
    name = "consumer";
    src = fixtures + "/vendor-git-inherit/consumer";
    fetchArgs.gitTrees."https://example.invalid/repo" = fixtures + "/vendor-git-inherit/repo";
    # What Cargo reports for these crates in a real checkout (crates/a is
    # two levels below the workspace root).
    expectOutput = "../../README.md ../../LICENSE 42";
  };
}
