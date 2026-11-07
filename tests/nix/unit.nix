# Pure evaluation tests (lib.debug.runTests). Each test is
# { expr; expected; }; any failure throws at evaluation time.
{
  pkgs,
  bb,
  runTests,
}:
let
  inherit (pkgs) lib;
  inherit (bb) util lockfile;

  lockA = ''
    version = 4

    [[package]]
    name = "app"
    version = "0.1.0"
    dependencies = ["itoa", "serde 1.0.0 (git+https://github.com/me/serde?branch=fix%2Fthing#abc)"]

    [[package]]
    name = "itoa"
    version = "1.0.11"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "49f1f14873335454500d59611f1cf4a4b0f786f9ac11f4312a78e4cf2566695b"

    [[package]]
    name = "serde"
    version = "1.0.0"
    source = "git+https://github.com/me/serde?branch=fix%2Fthing#abcdef0123456789abcdef0123456789abcdef01"

    [[package]]
    name = "priv"
    version = "2.0.0"
    source = "sparse+https://my.registry/index/"
    checksum = "1111111111111111111111111111111111111111111111111111111111111111"
  '';

  lockB = ''
    version = 3

    [[package]]
    name = "itoa"
    version = "1.0.11"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "49f1f14873335454500d59611f1cf4a4b0f786f9ac11f4312a78e4cf2566695b"

    [[package]]
    name = "serde"
    version = "1.0.0"
    source = "git+https://github.com/me/serde?rev=v1#0000000000000000000000000000000000000001"
  '';

  # Lockfile v1 kept checksums in [metadata].
  lockV1 = ''
    [[package]]
    name = "a"
    version = "0.1.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [metadata]
    "checksum a 0.1.0 (registry+https://github.com/rust-lang/crates.io-index)" = "aaaa"
  '';

  a = lockfile.fromLockText lockA;
  b = lockfile.fromLockText lockB;
  merged = lockfile.merge [ a b ];
  find = es: n: lib.findFirst (e: e.name == n) null es;

  fetch = bb.mkFetch pkgs {
    registries.my = {
      index = "sparse+https://my.registry/index/";
      dl = "https://my.registry/dl/{prefix}/{crate}/{version}/{sha256-checksum}";
    };
    registries.old = {
      index = "https://old.example/index";
      dl = "https://old.example/api/v1/crates";
    };
  };

  vendor = bb.mkVendor pkgs {
    inherit fetch;
    entries = lib.filter (e: e.parsed.kind == "registry") a;
    registries.my.index = "sparse+https://my.registry/index/";
  };
in
runTests "lib-unit" {
  # --- lockfile ----------------------------------------------------------
  testRegistryParse = {
    expr = (find a "itoa").parsed;
    expected = {
      kind = "registry";
      url = "https://github.com/rust-lang/crates.io-index";
      source = "registry+https://github.com/rust-lang/crates.io-index";
      id = "registry+https://github.com/rust-lang/crates.io-index";
      isCratesIo = true;
    };
  };
  testSparseKeepsPrefix = {
    expr = (find a "priv").parsed.url;
    expected = "sparse+https://my.registry/index/";
  };
  testGitParse = {
    expr = builtins.removeAttrs (find a "serde").parsed [ "source" ];
    expected = {
      kind = "git";
      url = "https://github.com/me/serde";
      # query values are percent-decoded, as `url::Url::query_pairs` does
      reference = { type = "branch"; value = "fix/thing"; };
      precise = "abcdef0123456789abcdef0123456789abcdef01";
      id = "https://github.com/me/serde?branch=fix%2Fthing";
    };
  };
  testPathPackage = {
    expr = (find a "app").parsed.kind;
    expected = "path";
  };
  testPkgId = {
    expr = (find a "itoa").id;
    expected = "registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.11";
  };
  testV1Checksum = {
    expr = (builtins.head (lockfile.fromLockText lockV1)).checksum;
    expected = "aaaa";
  };
  # itoa is shared; the two serde revisions stay apart; app (path) is kept
  # as an entry but is not remote.
  testMerge = {
    expr = lib.sort (x: y: x < y) (map (e: "${e.name}@${e.version}") (builtins.attrValues merged));
    expected = [ "app@0.1.0" "itoa@1.0.11" "priv@2.0.0" "serde@1.0.0" "serde@1.0.0" ];
  };
  testRemote = {
    expr = map (e: e.name) (lockfile.remoteEntries a);
    expected = [ "itoa" "serde" "priv" ];
  };
  testLastQueryWins = {
    expr = (lockfile.parseSource "git+https://x/y?branch=a&rev=b#c").reference;
    expected = { type = "rev"; value = "b"; };
  };
  testRefIsBranch = {
    expr = (lockfile.parseSource "git+https://x/y?ref=a#c").reference;
    expected = { type = "branch"; value = "a"; };
  };

  # --- download URLs (cargo-util src/registry.rs) -------------------------
  testCratesIoUrl = {
    expr = fetch.crateUrl "https://static.crates.io/crates/{crate}/{crate}-{version}.crate" (find a "itoa");
    expected = "https://static.crates.io/crates/itoa/itoa-1.0.11.crate";
  };
  testTemplateMarkers = {
    expr = fetch.crateUrl "x/{prefix}/{lowerprefix}/{crate}/{version}/{sha256-checksum}" {
      name = "AbCd";
      version = "1";
      checksum = "c";
    };
    expected = "x/Ab/Cd/ab/cd/AbCd/1/c";
  };
  testShortPrefixes = {
    expr = map (n: fetch.crateUrl "{prefix}" { name = n; version = "1"; checksum = ""; }) [ "a" "ab" "abc" ];
    expected = [ "1" "2" "3/a" ];
  };
  testNoMarkers = {
    expr = fetch.crateUrl "https://old.example/api/v1/crates" (find a "itoa");
    expected = "https://old.example/api/v1/crates/itoa/1.0.11/download";
  };
  testAltRegistryFetchUrl = {
    expr = (fetch.fetchRegistryTarball (find a "priv")).urls or [ (fetch.fetchRegistryTarball (find a "priv")).url ];
    expected = [ "https://my.registry/dl/pr/iv/priv/2.0.0/1111111111111111111111111111111111111111111111111111111111111111" ];
  };

  # --- vendor config --------------------------------------------------------
  testVendorConfig = {
    expr =
      let
        h1 = util.shortHash "registry+https://github.com/rust-lang/crates.io-index";
        h2 = util.shortHash "sparse+https://my.registry/index/";
      in
      lib.all (s: lib.hasInfix (builtins.unsafeDiscardStringContext s) (builtins.unsafeDiscardStringContext vendor.config)) [
        "[source.crates-io]\nreplace-with = \"breakbulk-${h1}\""
        "[source.\"my\"]\nregistry = \"sparse+https://my.registry/index/\"\nreplace-with = \"breakbulk-${h2}\""
        "[source.\"breakbulk-${h1}\"]\ndirectory = \"${vendor.dir}/${h1}\""
      ];
    expected = true;
  };
  testVendorGitSection = {
    expr =
      let
        entries = lockfile.read ../fixtures/vendor-git-inherit/consumer/Cargo.lock;
        v = bb.mkVendor pkgs {
          fetch = bb.mkFetch pkgs { gitTrees."https://example.invalid/repo" = ../fixtures/vendor-git-inherit/repo; };
          inherit entries;
        };
        h = util.shortHash "https://example.invalid/repo?branch=main";
      in
      {
        section = lib.hasInfix ''
          [source."https://example.invalid/repo?branch=main"]
          git = "https://example.invalid/repo"
          branch = "main"
          replace-with = "breakbulk-${h}"
        '' (builtins.unsafeDiscardStringContext v.config);
        crates = builtins.attrNames v.crates;
      };
    expected = {
      section = true;
      crates = [
        "${util.shortHash "https://example.invalid/repo?branch=main"}/a-0.3.1"
        "${util.shortHash "https://example.invalid/repo?branch=main"}/b-0.3.1"
      ];
    };
  };

  # --- path helpers -----------------------------------------------------------
  testNormalize = {
    expr = map util.normalizeRel [ "a/./b/../c" "./x" "../a/../../b" "" "a/" ];
    expected = [ "a/c" "x" "../../b" "" "a" ];
  };
  testRelativeTo = {
    expr = [
      (util.relativeTo "README.md" "crates/a")
      (util.relativeTo "crates/a/x" "crates/a")
      (util.relativeTo "crates/b" "crates/a")
    ];
    expected = [ "../../README.md" "x" "../b" ];
  };
  testIsUnder = {
    expr = [
      (util.isUnder "" "a/b")
      (util.isUnder "" "../a")
      (util.isUnder "a" "a")
      (util.isUnder "a" "ab")
      (util.isUnder "a" "a/b")
    ];
    expected = [ true false true false true ];
  };
  testPercentDecode = {
    expr = util.percentDecode "a%2Fb%2541+c";
    expected = "a/b%41 c";
  };
  testGlob = {
    expr = util.expandGlob ../fixtures/roots-layouts "crates/*";
    expected = [
      "crates/autobins-off"
      "crates/bin-dirs"
      "crates/edition2015"
      "crates/excluded"
      "crates/explicit-paths"
      "crates/normalized"
      "crates/not-a-dir"
      "crates/proc"
    ];
  };
  testGlobClass = {
    expr = util.expandGlob ../fixtures/roots-layouts "crates/[ep]*";
    expected = [ "crates/edition2015" "crates/excluded" "crates/explicit-paths" "crates/proc" ];
  };
  testGlobDoubleStar = {
    expr = util.expandGlob ../fixtures/roots-layouts "**/util";
    expected = [ "shared/util" ];
  };

  # --- TOML writer --------------------------------------------------------------
  testTomlRoundTrip = {
    expr =
      let
        v = {
          package = {
            name = "x";
            "weird key" = "quote \" and \\ and \n";
            n = 3;
            f = 1.5;
            b = false;
          };
          dependencies.y = {
            version = "1";
            features = [ "a" "b" ];
          };
          bin = [ { name = "z"; path = "src/z.rs"; } ];
        };
      in
      builtins.fromTOML (util.toTOML v) == v;
    expected = true;
  };

  # --- workspace membership -------------------------------------------------------
  testMembers = {
    expr = (bb.manifest.workspace { root = ../fixtures/roots-layouts; }).members;
    expected = [
      "crates/autobins-off"
      "crates/bin-dirs"
      "crates/edition2015"
      "crates/explicit-paths"
      "crates/normalized"
      "crates/proc"
      "shared/util"
      "virtual-sub"
    ];
  };

  # --- plan roots -------------------------------------------------------------------
  testPlanRoots = {
    expr =
      let
        r = (bb.roots.workspaceRoots { root = ../fixtures/roots-layouts; }).bin-dirs.roots;
        names = rs: map (x: "${x.kind}:${x.name}:${x.mode}") rs;
      in
      {
        build = names r.build;
        test = names r.test;
        bench = names r.bench;
      };
    expected = {
      build = [ "bin:bar:build" "bin:bin-dirs:build" "bin:foo:build" ];
      test = [
        "bin:bin-dirs:test"
        "bin:foo:test"
        "example:ex1:test"
        "example:ex2:build"
        "test:it:test"
        "test:sub:test"
      ];
      bench = [ "bin:bar:bench" "bin:bin-dirs:bench" "bin:foo:bench" "bench:b:bench" ];
    };
  };
}
