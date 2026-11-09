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

  targetOverride =
    { ... }:
    {
      options = {
        env = bt.mkEnv "Environment for this package's units on this target (target units only).";
        nativeInputs = bt.mkInputs "Build-machine tools for this package's units on this target (target units only).";
        inputs = bt.mkInputs "Libraries for this package's units on this target (target units only).";
        stages = mkOption {
          type = bt.stages;
          default = { };
          description = "Post-link stages for this package's products on this target, as `targets.<triple>.stages` (`after = \"install\"` for wrappers and packaging).";
        };
        checks = mkOption {
          type = bt.stages;
          default = { };
          description = "Checks on this package's products on this target.";
        };
      };
    };

  testBinary = {
    options = {
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "libtest arguments for this test binary.";
      };
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this binary's test run is part of `repo.checks` (it is built either way).";
      };
    };
  };

  package =
    {
      name,
      options,
      config,
      ...
    }:
    {
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

        env = bt.mkEnv ''
          Environment for every unit of this package (compiles and build
          script runs, host and target). Values may be derivations,
          including another workspace's products; they are passed by
          reference.
        '';
        nativeInputs = bt.mkInputs ''
          Tools that run on the build machine (`pkg-config`, `cmake`,
          `protoc`). A function of the build platform's package set, or a
          list.
        '';
        inputs = bt.mkInputs ''
          Libraries for the platform being built (`openssl`). A function of
          a package set (`p: [ p.openssl ]`), called with the build
          machine's set for host units and with the target's set for
          target units; or a list used as given. Their library search
          paths (`NIX_LDFLAGS`, not compiler flags or `PATH`) also reach
          the link steps of the packages that link this one (bins, tests,
          cdylibs, doctests of dependents), on the same platform, so a
          `-sys` crate may print `rustc-link-lib` without a search path;
          binaries get an rpath to the library.
        '';
        extraSources = mkOption {
          type = types.listOf (types.either types.path types.str);
          default = [ ];
          example = [
            "wit"
            "../shared/assets"
          ];
          description = ''
            Files and directories outside the package directory that its
            units read (`include_str!("../../wit/x.wit")`, a sibling assets
            directory, patches), at their original relative paths. Strings
            are relative to the repository root.
          '';
        };

        host = {
          env = bt.mkEnv "Environment for this package's host units only (build scripts, proc macros, build dependencies).";
          nativeInputs = bt.mkInputs "Tools for this package's host units only.";
          inputs = bt.mkInputs "Libraries for this package's host units only.";
        };

        target = mkOption {
          type = types.attrsOf (types.submodule targetOverride);
          default = { };
          description = "Settings for this package's target units on one target triple.";
        };

        stages = mkOption {
          type = bt.stages;
          default = { };
          description = "Post-link stages for this package's products, on every target, as `targets.<triple>.stages` (`after = \"install\"` for wrappers and packaging).";
        };
        checks = mkOption {
          type = bt.stages;
          default = { };
          description = "Checks on this package's products, on every target.";
        };

        test = {
          env = bt.mkEnv "Environment for this package's test runs.";
          path = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "Packages added to `PATH` in this package's test runs.";
          };
          sourceScope = mkOption {
            type = types.listOf (types.either types.path types.str);
            default = [ ];
            example = [ "testdata" ];
            description = ''
              Extra repository paths (paths, or strings relative to the
              repository root) in the source view of this package's test
              units: its test harnesses (`--test` compiles), doctests and
              test runs, whose working directory is the package directory
              of that view. Other units keep the package's normal view, so
              editing these paths re-runs only this package's tests.
            '';
          };
          runFiles = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            example = [ "tests/fixtures" ];
            description = ''
              Narrow what this package's test runs see: their working
              directory (and runtime `CARGO_MANIFEST_DIR`) is a view holding
              only these paths, relative to the package directory, at their
              usual places; `[ ]` gives an empty directory. Editing any other
              file of the package then leaves the test run's own inputs
              unchanged, so with content addressing (`ca`) a byte-identical
              test binary is not re-run. A test that reads a file not listed
              fails. `null`: the package's whole source view (or its
              `test.sourceScope` view), as `cargo test` sees it. Test apps
              keep the whole view.
            '';
          };
          stripForRun = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Run a copy of each test binary with its debug info (and build
              ID) stripped, content-addressed when `ca` is on. Workspace
              libraries keep real source paths in their debug info, so an
              edit to any file of such a library (a README) changes the bytes
              of every test binary that links it; the stripped copy does not
              change, and the test is not re-run. Backtraces still name
              functions, but not files and lines. The unstripped binary stays
              in `tests.<pkg>.<binary>` for debugging. `null`: the
              workspace's `test.stripForRun`.
            '';
          };
          args = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [
              "--skip"
              "net::"
            ];
            description = "libtest arguments for every test binary of this package.";
          };
          includeIgnored = mkOption {
            type = types.bool;
            default = false;
            description = "Also run `#[ignore]` tests.";
          };
          binaries = mkOption {
            type = types.attrsOf (types.submodule testBinary);
            default = { };
            description = "Per test binary settings.";
          };
          runner = mkOption {
            type = types.nullOr (
              types.enum [
                "libtest"
                "nextest"
              ]
            );
            default = null;
            example = "nextest";
            description = ''
              How this package's test binaries run: `libtest` (the binary
              itself, as `cargo test` runs it) or `nextest` (cargo-nextest's
              reuse-build mode over the one binary, with the project's
              nextest configuration: retries, timeouts, default filter, test
              groups). Each binary is still its own test run. `null`: the
              workspace's `test.runner`, else `libtest`.
            '';
          };
          nextest = {
            profile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "ci";
              description = "nextest profile for this package's test runs (`null`: the workspace's `test.nextest.profile`, else `default`).";
            };
            configFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = lib.literalExpression "./.config/nextest.toml";
              description = ''
                nextest configuration file. `null`: the repository's
                `.config/nextest.toml` when it exists, else nextest's
                defaults.
              '';
            };
            package = mkOption {
              type = types.nullOr types.package;
              default = null;
              description = "cargo-nextest to run with (`null`: the test platform's `cargo-nextest`).";
            };
          };
        };

        strictSources = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = "Override the repository's `strictSources` for this package's build scripts.";
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
