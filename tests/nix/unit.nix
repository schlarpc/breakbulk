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
  merged = lockfile.merge [
    a
    b
  ];
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
  };

  # Layered settings (lib/modules/types.nix `layer`): a base evaluation
  # extended with layers of ranks 0.25 and 0.5, as a variant's settings
  # on a target.
  bt = import ../../lib/modules/types.nix { inherit lib; };
  layered = layeredWith (_: v: v);
  # `value`: each layer's rewrite of its values (`layer`'s third argument).
  layeredWith =
    value: base: layers:
    let
      c = layeredConfig value base layers;
    in
    {
      inherit (c) profile flag features;
    };
  layeredConfig =
    value: base: layers:
    let
      e = lib.evalModules {
        modules = [
          (
            { ... }:
            {
              options = {
                profile = lib.mkOption {
                  type = lib.types.str;
                  default = "release";
                };
                flag = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                };
                features = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                # A group of options, as a variant's `docs.check`.
                docs.check = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
              };
            }
          )
          base
        ];
      };
    in
    (e.extendModules { modules = lib.imap1 (r: bt.layer e.options (r / 4.0) value) layers; }).config;
  layerFile = builtins.toFile "layer.nix" ''
    { lib, ... }: { profile = lib.mkForce "file"; features = [ "f" ]; }
  '';

  # The variants of the variants fixture's workspace, but `default`, with a
  # featurePowerset module of `args` and the workspace settings `extra`.
  powersetVariants =
    args: extra:
    removeAttrs
      (bb.mkRepository {
        inherit pkgs;
        root = ../fixtures/variants;
        modules = [
          {
            workspaces.main = {
              path = "ws";
              imports = [ (bb.variants.featurePowerset args) ];
            }
            // extra;
          }
        ];
      }).config.workspaces.main.variants
      [ "default" ];
  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  # Package settings layers (lib/package-settings.nix), lowest first, as
  # mkRepository gives them for one lockfile entry: a stand-in for
  # `memberDefaults`, then one for `packages.<name>`, on triple `t` in
  # variant `v`.
  packageSettings =
    layers:
    (bb.packageSettings.evaluate {
      layers = map (module: { inherit module; }) layers;
      defaults = bb.packageSettings.contextDefaults {
        ca = false;
        nextestConfig = null;
      };
      specialArgs.package = {
        name = "app";
        version = "0.43.1";
      };
    }).on
      {
        triple = "t";
        variant = "v";
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
      reference = {
        type = "branch";
        value = "fix/thing";
      };
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
    expected = [
      "app@0.1.0"
      "itoa@1.0.11"
      "priv@2.0.0"
      "serde@1.0.0"
      "serde@1.0.0"
    ];
  };
  testRemote = {
    expr = map (e: e.name) (lockfile.remoteEntries a);
    expected = [
      "itoa"
      "serde"
      "priv"
    ];
  };
  testLastQueryWins = {
    expr = (lockfile.parseSource "git+https://x/y?branch=a&rev=b#c").reference;
    expected = {
      type = "rev";
      value = "b";
    };
  };
  testRefIsBranch = {
    expr = (lockfile.parseSource "git+https://x/y?ref=a#c").reference;
    expected = {
      type = "branch";
      value = "a";
    };
  };

  # --- download URLs (cargo-util src/registry.rs) -------------------------
  testCratesIoUrl = {
    expr = fetch.crateUrl "https://static.crates.io/crates/{crate}/{crate}-{version}.crate" (
      find a "itoa"
    );
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
    expr =
      map
        (
          n:
          fetch.crateUrl "{prefix}" {
            name = n;
            version = "1";
            checksum = "";
          }
        )
        [
          "a"
          "ab"
          "abc"
        ];
    expected = [
      "1"
      "2"
      "3/a"
    ];
  };
  testNoMarkers = {
    expr = fetch.crateUrl "https://old.example/api/v1/crates" (find a "itoa");
    expected = "https://old.example/api/v1/crates/itoa/1.0.11/download";
  };
  testAltRegistryFetchUrl = {
    expr =
      (fetch.fetchRegistryTarball (find a "priv")).urls
        or [ (fetch.fetchRegistryTarball (find a "priv")).url ];
    expected = [
      "https://my.registry/dl/pr/iv/priv/2.0.0/1111111111111111111111111111111111111111111111111111111111111111"
    ];
  };
  # crates.io is the `registries.crates-io` entry: a mirror replaces its
  # `dl`, a fetcher its `fetch`, and its sparse index is the same registry.
  testCratesIoMirror = {
    expr =
      let
        f = bb.mkFetch pkgs {
          registries.crates-io = {
            dl = "https://mirror.example/{crate}/{version}";
            fetch = p: args: p.fetchurl (args // { name = "mirrored-${args.name}"; });
          };
        };
        sparse = lockfile.mkEntry {
          name = "itoa";
          version = "1.0.11";
          source = "sparse+https://index.crates.io/";
          inherit (find a "itoa") checksum;
        };
        t = f.fetchRegistryTarball sparse;
      in
      {
        inherit (t) name;
        urls = t.urls or [ t.url ];
        registry = (f.registryOf sparse).name;
      };
    expected = {
      name = "mirrored-itoa-1.0.11.tar.gz";
      urls = [ "https://mirror.example/itoa/1.0.11" ];
      registry = "crates-io";
    };
  };
  testUnknownRegistry = {
    expr = (bb.mkFetch pkgs { }).registryOf (find a "priv");
    expected = null;
  };
  testUnknownRegistryFetch = {
    expr =
      (builtins.tryEval ((bb.mkFetch pkgs { }).fetchRegistryTarball (find a "priv")).drvPath).success;
    expected = false;
  };

  # --- git settings: by source string, else by URL ---------------------------
  testGitKeyRule = {
    expr =
      let
        e = find a "serde";
        subdirWith = git: (bb.mkFetch pkgs { inherit git; }).crateSource e;
      in
      {
        both =
          (subdirWith {
            ${e.source}.subdirs.serde = "by-source";
            ${e.parsed.url}.subdirs.serde = "by-url";
          }).subdir;
        url = (subdirWith { ${e.parsed.url}.subdirs.serde = "./by-url/"; }).subdir;
        # The two entries are not merged: the source string's has no
        # subdir, so `a` is found in its tree.
        notMerged =
          let
            entries = lockfile.read ../fixtures/vendor-git-inherit/consumer/Cargo.lock;
            ea = find entries "a";
          in
          (
            (bb.mkFetch pkgs {
              git.${ea.source}.tree = ../fixtures/vendor-git-inherit/repo;
              git.${ea.parsed.url} = {
                tree = ../fixtures/vendor-git-inherit/repo;
                subdirs.a = "elsewhere";
              };
            }).crateSource
              ea
          ).subdir;
      };
    expected = {
      both = "by-source";
      url = "by-url";
      notMerged = "crates/a";
    };
  };

  # --- crateSources -----------------------------------------------------------
  testCrateSources = {
    expr =
      let
        f = bb.mkFetch pkgs {
          git."https://github.com/me/serde".subdirs.serde = "in/repo";
          crateSources = [
            (
              e:
              if e.name == "serde" then
                {
                  inherit (e.defaultSource) path;
                  subdir = "${e.defaultSource.subdir}/patched";
                }
              else
                null
            )
            (
              e:
              if e.name == "itoa" then
                {
                  path = ../fixtures/vendor-git-inherit/repo;
                  subdir = "./crates/a/";
                }
              else
                null
            )
            (e: if e.name == "itoa" then throw "a later function was called" else null)
          ];
        };
        s = n: f.crateSource (find a n);
      in
      {
        itoa = {
          inherit (s "itoa") subdir checksummed kind;
          path = lib.hasSuffix "-repo/crates/a" (s "itoa").path;
        };
        serde = (s "serde").subdir;
        # No function answers: the built-in fetcher's unpacked crate.
        priv = (s "priv").checksummed;
      };
    expected = {
      itoa = {
        subdir = "crates/a";
        checksummed = false;
        kind = "registry";
        path = true;
      };
      serde = "in/repo/patched";
      priv = true;
    };
  };
  testCrateSourcesBadResult = {
    expr =
      (builtins.tryEval
        ((bb.mkFetch pkgs { crateSources = [ (_: { dir = ./.; }) ]; }).crateSource (find a "itoa")).path
      ).success;
    expected = false;
  };

  # --- vendor config --------------------------------------------------------
  testVendorConfig = {
    expr =
      let
        h1 = util.shortHash "registry+https://github.com/rust-lang/crates.io-index";
        h2 = util.shortHash "sparse+https://my.registry/index/";
      in
      lib.all
        (
          s:
          lib.hasInfix (builtins.unsafeDiscardStringContext s) (
            builtins.unsafeDiscardStringContext vendor.config
          )
        )
        [
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
          fetch = bb.mkFetch pkgs {
            git."https://example.invalid/repo".tree = ../fixtures/vendor-git-inherit/repo;
          };
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
    expr = map util.normalizeRel [
      "a/./b/../c"
      "./x"
      "../a/../../b"
      ""
      "a/"
    ];
    expected = [
      "a/c"
      "x"
      "../../b"
      ""
      "a"
    ];
  };
  testRelativeTo = {
    expr = [
      (util.relativeTo "README.md" "crates/a")
      (util.relativeTo "crates/a/x" "crates/a")
      (util.relativeTo "crates/b" "crates/a")
    ];
    expected = [
      "../../README.md"
      "x"
      "../b"
    ];
  };
  testIsUnder = {
    expr = [
      (util.isUnder "" "a/b")
      (util.isUnder "" "../a")
      (util.isUnder "a" "a")
      (util.isUnder "a" "ab")
      (util.isUnder "a" "a/b")
    ];
    expected = [
      true
      false
      true
      false
      true
    ];
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
    expected = [
      "crates/edition2015"
      "crates/excluded"
      "crates/explicit-paths"
      "crates/proc"
    ];
  };
  testGlobDoubleStar = {
    expr = util.expandGlob ../fixtures/roots-layouts "**/util";
    expected = [ "shared/util" ];
  };

  # Package patterns as Cargo's `-p` and `--exclude` take them (the glob
  # crate's `Pattern`).
  testPackagePattern = {
    expr =
      let
        m = p: n: (util.packagePattern p).matches n;
      in
      [
        (m "core-*" "core-a")
        (m "core-*" "core")
        (m "*" "")
        (m "c?re" "core")
        (m "c?re" "cre")
        (m "[a-c]*" "build")
        (m "[a-c]*" "doc")
        (m "[!a-c]*" "doc")
        (m "[!a-c]*" "app")
        (m "[]x]" "]")
        (m "[!]]" "x")
        (m "x-[a-]" "x--")
        (m "**" "anything")
        (m "**/core" "core")
        (m "**/c*" "core")
        (m "*/core" "core")
        (m "Core" "core")
        (m "a]" "a]")
      ];
    expected = [
      true
      false
      true
      true
      false
      true
      false
      true
      false
      true
      true
      true
      true
      true
      true
      false
      false
      true
    ];
  };
  testPackagePatternErrors = {
    expr = map (p: (util.packagePattern p).error) [
      "core**"
      "**core"
      "a/***"
      "[ab"
      "[!]"
      "[]"
      "ok*"
    ];
    expected = [
      "near position 3: recursive wildcards must form a single path component"
      "near position 2: recursive wildcards must form a single path component"
      "near position 4: wildcards are either regular `*` or recursive `**`"
      "near position 0: invalid range pattern"
      "near position 0: invalid range pattern"
      "near position 0: invalid range pattern"
      null
    ];
  };
  testExcludeMembers = {
    expr =
      bb.manifest.excludeMembers
        [ "core-b" "app" "core-a" "helper" ]
        [
          "core-*"
          "helper"
          "nope"
          "zz*"
          "x**"
        ];
    expected = {
      selected = [ "app" ];
      errors = [
        "`nope` matches no member (app, core-a, core-b, helper)"
        "`zz*` matches no member (app, core-a, core-b, helper)"
        "`x**` is not a valid package pattern (near position 0: recursive wildcards must form a single path component)"
      ];
    };
  };
  # An entry matches when it matches any member, even one an earlier entry
  # already excludes (Cargo would report `core-*` as unmatched here).
  testExcludeMembersOverlap = {
    expr = bb.manifest.excludeMembers [ "core-a" "app" ] [ "core-a" "core-*" ];
    expected = {
      selected = [ "app" ];
      errors = [ ];
    };
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
            features = [
              "a"
              "b"
            ];
          };
          bin = [
            {
              name = "z";
              path = "src/z.rs";
            }
          ];
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
      "virtual-sub/inner"
    ];
  };
  testMemberPackages = {
    expr = bb.manifest.memberPackages { root = ../fixtures/workspace-members; };
    expected = {
      app = {
        name = "app";
        path = ".";
      };
      core-a = {
        name = "core-a";
        path = "crates/core-a";
      };
      core-b = {
        name = "core-b";
        path = "crates/core-b";
      };
      helper = {
        name = "helper";
        path = "libs/helper";
      };
      ws-util = {
        name = "ws-util";
        path = "crates/util";
      };
    };
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
      build = [
        "bin:bar:build"
        "bin:bin-dirs:build"
        "bin:foo:build"
      ];
      test = [
        "bin:bin-dirs:test"
        "bin:foo:test"
        "example:ex1:test"
        "example:ex2:build"
        "test:it:test"
        "test:sub:test"
      ];
      bench = [
        "bin:bar:bench"
        "bin:bin-dirs:bench"
        "bin:foo:bench"
        "bench:b:bench"
      ];
    };
  };

  # Test runs on another system (`testSystem`) import nixpkgs for it with
  # the user's overlays and config. Only `testPkgs` is forced.
  testTestPkgsKeepOverlays =
    let
      user = pkgs.extend (_: _: { bbMarker = "overlay"; });
      other =
        if pkgs.stdenv.buildPlatform.system == "aarch64-linux" then "x86_64-linux" else "aarch64-linux";
      args = {
        pkgs = user;
        inst = throw "unused";
        tools = { };
        target = "x";
        testSystem = other;
      };
      of = r: {
        marker = r.testPkgs.bbMarker or null;
        system = r.testPkgs.stdenv.hostPlatform.system;
      };
    in
    {
      expr = [
        (of (bb.testRuns.mkTestRuns args))
        (of (bb.dynamic.mkTestRuns args))
      ];
      expected = lib.genList (_: {
        marker = "overlay";
        system = other;
      }) 2;
    };

  # mkRepository's `root`: a path stays a path; a flake's `self` (or its
  # outPath) becomes the path of the same store location, without context;
  # anything else fails (tests/flake-self/run.sh checks real flakes).
  testRootPath =
    let
      store = builtins.path {
        path = ../fixtures/outside-reads/assets;
        name = "root-path-probe";
      };
      self = {
        outPath = store;
        sourceInfo = { };
      };
      fails = v: !(builtins.tryEval (bb.util.rootPath v)).success;
    in
    {
      expr = {
        path = bb.util.rootPath ./. == ./.;
        self = builtins.isPath (bb.util.rootPath self) && toString (bb.util.rootPath self) == store;
        outPath = bb.util.rootPath "${store}" == bb.util.rootPath self;
        readable = builtins.pathExists (bb.util.rootPath self + "/data.txt");
        notStore = fails "/home/someone/project";
        attrs = fails { foo = 1; };
        int = fails 3;
      };
      expected = {
        path = true;
        self = true;
        outPath = true;
        readable = true;
        notStore = true;
        attrs = true;
        int = true;
      };
    };

  # cargo-hack's per-package matrix (field-trial gap 10). Expected sets are
  # what `cargo hack check --workspace --feature-powerset` and
  # `--each-feature --print-command-list` (cargo-hack 0.6.45) print for the
  # variants fixture (cargo-hack 0.6.46 for app's `extra`): app has one
  # feature, `extra`, and no optional dependencies (no --all-features);
  # lib-a has default = [x], x, y and no optional dependencies (no
  # --all-features in the powerset; `default+x` is left out, since default
  # enables x).
  testPackageFeaturePowerset =
    let
      ps = args: powersetVariants ({ scope = "package"; } // args) { };
      check = {
        variant.mode = "check";
      };
      shape = lib.mapAttrs (
        _: v: {
          inherit (v) packages mode features;
          all = v.allFeatures;
          noDefault = v.noDefaultFeatures;
        }
      );
      lib-a = features: noDefault: all: {
        packages = [ "lib-a" ];
        mode = "check";
        inherit features noDefault all;
      };
      app = {
        "hack-app.no-default-features" = {
          packages = [ "app" ];
          mode = "check";
          features = [ ];
          noDefault = true;
          all = false;
        };
        "hack-app.extra" = {
          packages = [ "app" ];
          mode = "check";
          features = [ "extra" ];
          noDefault = true;
          all = false;
        };
      };
    in
    {
      expr = {
        powerset = shape (ps check);
        each = shape (ps (check // { eachFeature = true; }));
        depth1 = lib.attrNames (ps {
          depth = 1;
          packages = [ "lib-a" ];
        });
        excluded = lib.attrNames (ps {
          packages = [ "lib-a" ];
          excludeFeatures = [ "default" ];
          excludeNoDefaultFeatures = true;
        });
        # Any --exclude-features turns --all-features off (cargo-hack's
        # cli.rs).
        eachExcluded = lib.attrNames (ps {
          packages = [ "lib-a" ];
          eachFeature = true;
          excludeFeatures = [ "y" ];
        });
        sets = lib.attrNames (ps {
          packages = {
            exclude = [ "app" ];
          };
          excludeSets = [
            [
              "y"
              "x"
            ]
            [ "default" ]
          ];
        });
        # An optional dependency that is an implicit feature brings
        # --all-features back.
        optional = map (r: r.suffix) (
          bb.variants.packageRuns {
            features = {
              a = [ "dep:o" ];
            };
            optionalDeps = [ "z" ];
          }
        );
        unknown = fails (ps {
          packages = [ "nope" ];
        });
        withFeatures = fails (ps {
          features = [ "x" ];
        });
        eachDepth = fails (ps {
          eachFeature = true;
          depth = 2;
        });
      };
      expected = {
        powerset = app // {
          "hack-lib-a.no-default-features" = lib-a [ ] true false;
          "hack-lib-a.default" = lib-a [ "default" ] true false;
          "hack-lib-a.x" = lib-a [ "x" ] true false;
          "hack-lib-a.y" = lib-a [ "y" ] true false;
          "hack-lib-a.default+y" = lib-a [ "default" "y" ] true false;
          "hack-lib-a.x+y" = lib-a [ "x" "y" ] true false;
        };
        each = app // {
          "hack-lib-a.all-features" = lib-a [ ] false true;
          "hack-lib-a.no-default-features" = lib-a [ ] true false;
          "hack-lib-a.default" = lib-a [ "default" ] true false;
          "hack-lib-a.x" = lib-a [ "x" ] true false;
          "hack-lib-a.y" = lib-a [ "y" ] true false;
        };
        depth1 = [
          "hack-lib-a.default"
          "hack-lib-a.no-default-features"
          "hack-lib-a.x"
          "hack-lib-a.y"
        ];
        excluded = [
          "hack-lib-a.x"
          "hack-lib-a.x+y"
          "hack-lib-a.y"
        ];
        eachExcluded = [
          "hack-lib-a.default"
          "hack-lib-a.no-default-features"
          "hack-lib-a.x"
        ];
        sets = [
          "hack-lib-a.default+y"
          "hack-lib-a.no-default-features"
          "hack-lib-a.x"
          "hack-lib-a.y"
        ];
        optional = [
          ".all-features"
          ".no-default-features"
          ".a"
        ];
        unknown = true;
        withFeatures = true;
        eachDepth = true;
      };
    };

  # The workspace scope: one feature list for the whole workspace, each set
  # with --no-default-features.
  testWorkspaceFeaturePowerset =
    let
      ps = args: powersetVariants ({ scope = "workspace"; } // args) { };
      features = [
        "lib-a/x"
        "lib-a/y"
        "extra"
      ];
      names = args: lib.attrNames (ps ({ inherit features; } // args));
      fp = ps {
        features = [ "lib-a/y" ];
        packages = [ "lib-a" ];
        prefix = "fp";
      };
    in
    {
      expr = {
        all = names { };
        depth = names { depth = 1; };
        each = names {
          eachFeature = true;
          excludeNoDefaultFeatures = true;
        };
        excluded = names {
          excludeFeatures = [ "extra" ];
          excludeSets = [
            [
              "lib-a/y"
              "lib-a/x"
            ]
          ];
        };
        fp = lib.mapAttrs (_: v: { inherit (v) features noDefaultFeatures packages; }) fp;
        noFeatures = fails (ps { });
        allFeatures = fails (ps {
          inherit features;
          excludeAllFeatures = true;
        });
        badScope = fails (powersetVariants { scope = "crate"; } { });
      };
      expected = {
        all = [
          "features-extra"
          "features-lib-a_x"
          "features-lib-a_x+extra"
          "features-lib-a_x+lib-a_y"
          "features-lib-a_x+lib-a_y+extra"
          "features-lib-a_y"
          "features-lib-a_y+extra"
          "features-none"
        ];
        depth = [
          "features-extra"
          "features-lib-a_x"
          "features-lib-a_y"
          "features-none"
        ];
        each = [
          "features-extra"
          "features-lib-a_x"
          "features-lib-a_y"
        ];
        excluded = [
          "features-lib-a_x"
          "features-lib-a_y"
          "features-none"
        ];
        fp = {
          fp-none = {
            features = [ ];
            noDefaultFeatures = true;
            packages = [ "lib-a" ];
          };
          fp-lib-a_y = {
            features = [ "lib-a/y" ];
            noDefaultFeatures = true;
            packages = [ "lib-a" ];
          };
        };
        noFeatures = true;
        allFeatures = true;
        badScope = true;
      };
    };

  # Generated variants keep their test runs out of repo.checks unless
  # `variant` or another definition opts in; hand-written variants default
  # to in.
  testGeneratedVariantChecks =
    let
      checksOf = vs: lib.unique (lib.mapAttrsToList (_: v: v.checks) vs);
    in
    {
      expr = {
        package = checksOf (powersetVariants { scope = "package"; } { });
        packageOptIn = checksOf (
          powersetVariants {
            scope = "package";
            variant.checks = true;
          } { }
        );
        workspace = checksOf (
          powersetVariants {
            scope = "workspace";
            features = [
              "lib-a/x"
              "lib-a/y"
            ];
          } { }
        );
        workspaceOptIn = checksOf (
          powersetVariants {
            scope = "workspace";
            features = [ "lib-a/x" ];
          } { variants.features-none.checks = true; }
        );
        handWritten = (powersetVariants { scope = "package"; } { variants.mine = { }; }).mine.checks;
      };
      expected = {
        package = [ false ];
        packageOptIn = [ true ];
        workspace = [ false ];
        workspaceOptIn = [
          false
          true
        ];
        handWritten = true;
      };
    };

  # A package-scope run defines only what it needs, so the user's settings
  # of a generated variant apply to it: `noDefaultFeatures = true` in
  # `variant` reaches the --all-features run (whose default features are on
  # otherwise), a plain `features` elsewhere is added to the run's, and a
  # definition that contradicts the run is a conflict, not dropped.
  testFeaturePowersetUserSettings =
    let
      vs =
        extra:
        powersetVariants {
          scope = "package";
          packages = [ "lib-a" ];
          eachFeature = true;
          variant.noDefaultFeatures = true;
        } extra;
      honoured = vs { variants."hack-lib-a.all-features".features = [ "y" ]; };
      contradictedRun =
        (powersetVariants {
          scope = "package";
          packages = [ "lib-a" ];
          eachFeature = true;
        } { variants."hack-lib-a.x".noDefaultFeatures = false; })."hack-lib-a.x";
    in
    {
      expr = {
        all = {
          inherit (honoured."hack-lib-a.all-features") allFeatures noDefaultFeatures features;
        };
        x = {
          inherit (honoured."hack-lib-a.x") noDefaultFeatures features;
        };
        conflict = fails contradictedRun.noDefaultFeatures;
      };
      expected = {
        all = {
          allFeatures = true;
          noDefaultFeatures = true;
          features = [ "y" ];
        };
        x = {
          noDefaultFeatures = true;
          features = [ "x" ];
        };
        conflict = true;
      };
    };

  # Per-target variable names (breakbulk-plan's spec.rs `target_env_var`
  # gives the same for these).
  testTargetEnvNames = {
    expr = [
      (util.cargoTargetEnvVar "x86_64-unknown-linux-gnu" "RUNNER")
      (util.cargoTargetEnvVar "thumbv7em-none-eabihf.json" "LINKER")
      (util.tripleEnvSuffix "x86_64-pc-windows-msvc")
    ];
    expected = [
      "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER"
      "CARGO_TARGET_THUMBV7EM_NONE_EABIHF_JSON_LINKER"
      "x86_64_pc_windows_msvc"
    ];
  };

  # util.rustVersion: one parse (the capabilities it decides are
  # lib/toolchain-facts.nix's).
  testRustVersion = {
    expr =
      let
        rv = util.rustVersion;
      in
      [
        (rv.majorMinor "1.101.0-nightly")
        (rv.majorMinor "1.99.0")
        (rv.atLeast "1.101" "1.101.0-nightly")
        (rv.atLeast "1.101" "1.100.0")
        (rv.atLeast "1.95" "1.95.0")
        (rv.atLeast "1.95" "1.94.1")
      ];
    expected = [
      "1.101"
      "1.99"
      true
      false
      true
      false
    ];
  };

  # Check-group patterns: `*` within a segment, `**` across any number.
  testCheckGroupMatches = {
    expr = map (p: bb.checkGroups.matches (lib.head p) (lib.last p)) [
      [
        "*/fmt"
        "main/fmt"
      ]
      [
        "*/fmt"
        "main/x86_64-unknown-linux-gnu/fmt"
      ]
      [
        "*/*/variant-clippy/**"
        "main/x86_64-unknown-linux-gnu/variant-clippy/check"
      ]
      [
        "*/*/variant-clippy/**"
        "main/x86_64-unknown-linux-gnu/variant-clippy/app/build"
      ]
      [
        "*/*/variant-clippy/**"
        "main/x86_64-unknown-linux-gnu/app/build"
      ]
      [
        "**/test-*"
        "main/x86_64-unknown-linux-gnu/app/test-it"
      ]
      [
        "main/**"
        "main"
      ]
      [
        "ma?n/*-unknown-*/app/build"
        "main/x86_64-unknown-linux-gnu/app/build"
      ]
    ];
    expected = [
      true
      false
      true
      true
      false
      true
      true
      true
    ];
  };
  # A later layer's single value wins without mkForce; lists concatenate,
  # in layer order.
  testLayerPlain = {
    expr =
      layered
        {
          profile = "base";
          features = [ "b" ];
        }
        [
          {
            profile = "one";
            features = [ "1" ];
          }
          {
            profile = "two";
            flag = true;
          }
        ];
    expected = {
      profile = "two";
      flag = true;
      features = [
        "b"
        "1"
      ];
    };
  };
  # Priorities count across layers: mkForce below wins, mkDefault above
  # loses; among equal explicit priorities the later layer wins.
  testLayerPriorities = {
    expr = layered { profile = lib.mkForce "base"; } [
      { profile = "one"; }
      {
        flag = lib.mkDefault true;
        profile = lib.mkForce "two";
      }
    ];
    expected = {
      profile = "two";
      flag = true;
      features = [ ];
    };
  };
  # A nested option layers as a top-level one: the later layer wins.
  testLayerNested = {
    expr = map (l: (layeredConfig (_: v: v) { docs.check = false; } l).docs.check) [
      [ { docs.check = true; } ]
      [
        { docs.check = true; }
        { docs = lib.mkIf true { check = false; }; }
      ]
    ];
    expected = [
      true
      false
    ];
  };
  testLayerDefaultLoses = {
    expr = (layered { flag = false; } [ { flag = lib.mkDefault true; } ]).flag;
    expected = false;
  };

  # Lists concatenate across layers in layer order, sub-layers after the
  # layer they refine; `lib.mkForce [ ]` in a higher layer clears the
  # lower layers' entries, and `lib.mkForce` in a lower one keeps them
  # over a higher layer's plain list.
  testPackageSettingsLists = {
    expr =
      map
        (
          layers:
          let
            c = (packageSettings layers).config;
          in
          {
            inherit (c) extraSources;
            inherit (c.test) args;
          }
        )
        [
          [
            {
              extraSources = [ "md" ];
              target.t.extraSources = [ "md-t" ];
              test.args = [ "--md" ];
            }
            {
              extraSources = [ "pkg" ];
              variant.v.extraSources = [ "pkg-v" ];
              variant.v.target.t.extraSources = [ "pkg-v-t" ];
              test.args = lib.mkBefore [ "--pkg" ];
            }
          ]
          [
            {
              extraSources = [ "md" ];
              test.args = lib.mkForce [ "--md" ];
            }
            {
              extraSources = lib.mkForce [ ];
              test.args = [ "--pkg" ];
            }
          ]
        ];
    expected = [
      {
        extraSources = [
          "md"
          "md-t"
          "pkg"
          "pkg-v"
          "pkg-v-t"
        ];
        args = [
          "--md"
          "--pkg"
        ];
      }
      {
        extraSources = [ ];
        args = [ "--md" ];
      }
    ];
  };
  # Around a whole set, a priority is the module system's: `lib.mkForce`
  # on `env` replaces every lower-priority definition of `env`; on one
  # variable it forces that variable only. Single values inside sets and
  # run layers (`env.X`, `stages.<name>`, `test.binaries.<key>.enable`,
  # `test.doctest.enable`) take the higher layer's at equal priority.
  testPackageSettingsSets = {
    expr =
      let
        e = packageSettings [
          {
            env = {
              A = "md";
              B = "md";
            };
            forHost.env = {
              H = "md";
              F = lib.mkForce "md";
            };
            stages.sign.run = "md";
            checks.lowOnly.run = "md";
            test.binaries.lib.enable = false;
            test.doctest.enable = false;
          }
          {
            env = lib.mkForce { C = "pkg"; };
            forHost.env = {
              H = "pkg";
              F = "pkg";
            };
            stages.sign = null;
            test.binaries.lib.enable = true;
            test.doctest.enable = true;
          }
        ];
        c = e.config;
      in
      {
        inherit (c) env stages;
        forHost = c.forHost.env;
        checks = lib.attrNames c.checks;
        binary = (e.runs.test "lib").enable;
        doctest = e.runs.doctest.enable;
      };
    expected = {
      env.C = "pkg";
      forHost = {
        H = "pkg";
        F = "md";
      };
      stages.sign = null;
      checks = [ "lowOnly" ];
      binary = true;
      doctest = true;
    };
  };
  # Run settings: `test`, refined per run by `test.doctest` or `bench`,
  # then `test.binaries.<key>`, each just above the layer that gives it
  # and under that layer's `target` and `variant` layers. Lists
  # concatenate in that order; a more specific single value wins within
  # a layer, a higher layer's across layers. `preRun` has breakbulk's
  # entries, which a layer replaces or removes one by one; bench runs
  # start with `--test`.
  testPackageSettingsRuns = {
    expr =
      let
        e = packageSettings [
          {
            test.args = [ "--md" ];
            test.env.A = "md";
            test.wrapper = "md";
            test.binaries.k = {
              args = [ "--md-k" ];
              env.A = "md-k";
              wrapper = "md-k";
              enable = false;
            };
            test.doctest.args = [ "--md-doc" ];
            bench.enable = false;
            target.t.test.env.B = "md-t";
            target.t.test.binaries.k.env.B = "md-t-k";
          }
          {
            test.args = [ "--pkg" ];
            test.wrapper = "pkg";
            test.preRun.home = null;
            test.binaries.k.preRun.db = "start";
            bench.args = [ "--bench-pkg" ];
          }
        ];
        of = r: {
          inherit (r)
            args
            env
            wrapper
            enable
            ;
          preRun = lib.attrNames (lib.filterAttrs (_: v: v != null) r.preRun);
        };
      in
      {
        k = of (e.runs.test "k");
        other = of (e.runs.test "other");
        doctest = of e.runs.doctest;
        bench = of (e.runs.bench "k");
      };
    expected = {
      k = {
        args = [
          "--md"
          "--md-k"
          "--pkg"
        ];
        env = {
          A = "md-k";
          B = "md-t-k";
        };
        wrapper = "pkg";
        enable = false;
        preRun = [
          "db"
          "threads"
        ];
      };
      other = {
        args = [
          "--md"
          "--pkg"
        ];
        env = {
          A = "md";
          B = "md-t";
        };
        wrapper = "pkg";
        enable = true;
        preRun = [ "threads" ];
      };
      doctest = {
        args = [
          "--md"
          "--md-doc"
          "--pkg"
        ];
        env = {
          A = "md";
          B = "md-t";
        };
        wrapper = "pkg";
        enable = true;
        preRun = [ "threads" ];
      };
      bench = {
        args = [
          "--test"
          "--md"
          "--md-k"
          "--pkg"
          "--bench-pkg"
        ];
        env = {
          A = "md-k";
          B = "md-t-k";
        };
        wrapper = "pkg";
        enable = false;
        preRun = [
          "db"
          "threads"
        ];
      };
    };
  };
  # A run layer sets run settings only: under `test`, `runFiles` would be
  # accepted and do nothing.
  testPackageSettingsRunsOnly = {
    expr = fails ((packageSettings [ { test.binaries.k.runFiles = [ "x" ]; } ]).runs.test "k").runFiles;
    expected = true;
  };
  # A layer can be a module of the lockfile entry: a version condition,
  # by hand or with `whenVersion`, which takes any module.
  testPackageSettingsVersion = {
    expr =
      (packageSettings [
        (
          { package, ... }:
          lib.mkIf (bb.versionReq.matches ">=0.42" package.version) { env.NEW = "1"; }
        )
        (bb.whenVersion "<0.42" { env.OLD = "1"; })
        (bb.whenVersion "^0.43" ({ package, ... }: { env.VERSION = package.version; }))
      ]).config.env;
    expected = {
      NEW = "1";
      VERSION = "0.43.1";
    };
  };
  # The names of `env` are known without its values, which can be
  # products of the plan that reads the names; so are those of a curated
  # layer's `env` on a target without a package set (moved to the host
  # side).
  testPackageSettingsLazyEnv = {
    expr =
      let
        s = bb.packageSettings.evaluate {
          layers = [
            {
              hostOnly = true;
              module.env.CURATED = throw "a curated value was read";
            }
            {
              module = {
                env.PRODUCT = throw "a value was read";
                forHost.env.HOST = throw "a host value was read";
                target.t.env.TRIPLE = throw "a triple value was read";
              };
            }
          ];
        };
        c =
          (s.on {
            triple = "t";
            variant = "v";
          }).config;
      in
      {
        env = lib.attrNames c.env;
        forHost = lib.attrNames c.forHost.env;
      };
    expected = {
      env = [
        "PRODUCT"
        "TRIPLE"
      ];
      forHost = [
        "CURATED"
        "HOST"
      ];
    };
  };
  # Function modules (reading config), mkIf, mkMerge, an mkOverride
  # around several options, `config` and `imports`, and files.
  testLayerForms = {
    expr = map (l: layered { profile = "base"; } [ l ]) [
      (
        { config, ... }:
        {
          flag = lib.mkIf (config.profile == "base") true;
          features = [ config.profile ];
        }
      )
      {
        config = lib.mkMerge [
          (lib.mkIf false { profile = "no"; })
          { profile = "merged"; }
        ];
      }
      {
        config = lib.mkDefault {
          profile = "default";
          features = [ "d" ];
        };
      }
      { imports = [ layerFile ]; }
    ];
    expected = [
      {
        profile = "base";
        flag = true;
        features = [ "base" ];
      }
      {
        profile = "merged";
        flag = null;
        features = [ ];
      }
      {
        profile = "base";
        flag = null;
        features = [ "d" ];
      }
      {
        profile = "file";
        flag = null;
        features = [ "f" ];
      }
    ];
  };

  # A layer's rewrite reaches its values under mkIf, mkMerge, mkOverride
  # and mkOrder, and not the base's; `lib.mkBefore` orders within the
  # layer only.
  testLayerValues =
    let
      value = n: v: if n == "features" then lib.filter (f: f != "drop") v else v + "!";
      on = l: layeredWith value { features = [ "drop" ]; } [ l ];
    in
    {
      expr = map on [
        {
          profile = "one";
          features = [
            "drop"
            "keep"
          ];
        }
        {
          profile = lib.mkIf true (lib.mkForce "forced");
          features = lib.mkMerge [
            (lib.mkIf true [
              "drop"
              "if"
            ])
            (lib.mkBefore [ "before" ])
          ];
        }
        { features = lib.mkForce [ "drop" ]; }
      ];
      expected = [
        {
          profile = "one!";
          flag = null;
          features = [
            "drop"
            "keep"
          ];
        }
        {
          profile = "forced!";
          flag = null;
          features = [
            "drop"
            "before"
            "if"
          ];
        }
        {
          profile = "release";
          flag = null;
          features = [ ];
        }
      ];
    };

  # Cargo's `Workspace::collect_matching_features` for one member.
  testAcceptsFeature =
    let
      m = {
        package.name = "core";
        features.fast = [ ];
        dependencies = {
          serde = "1";
          json = {
            package = "serde_json";
            optional = true;
          };
        };
        target."cfg(windows)".dev-dependencies.winapi = "0.3";
      };
    in
    {
      expr = lib.filter (bb.acceptsFeature ({ name = "core"; } // bb.manifest.featureFacts m)) [
        "fast"
        "json"
        "core/fast"
        "core?/json"
        "serde/derive"
        "json?/std"
        "winapi/everything"
        "dep:json"
        "slow"
        "core/slow"
        "app/fast"
        "serde_json/std"
      ];
      expected = [
        "fast"
        "json"
        "core/fast"
        "core?/json"
        "serde/derive"
        "json?/std"
        "winapi/everything"
        "dep:json"
      ];
    };

  testCheckGroupPrefixes = {
    expr = bb.checkGroups.properPrefixes "a/b/c/d";
    expected = [
      "a"
      "a/b"
      "a/b/c"
    ];
  };
}
