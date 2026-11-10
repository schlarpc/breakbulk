# The settings of one package's units: the options of `packages.<name>`
# other than its matching (`version`). Also the shape of
# `workspaces.<ws>.memberDefaults` and of `sysDefaults.packages.<name>`'s
# result.
{ lib }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };

  # Which units are on which side.
  sides = "[sides](../../explanation/configuration.md#host-and-target-sides)";

  side = name: {
    env = bt.mkEnv "Environment for this package's ${name} units only (${sides}).";
    nativeInputs = bt.mkInputs "Build-machine tools for this package's ${name} units only (${sides}).";
    inputs = bt.mkInputs "Libraries for this package's ${name} units only (${sides}).";
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

  # Every setting but the per-triple layer, which has these same options.
  common = {
    key = "breakbulk/modules/package-settings.nix#common";
    _file = ./package-settings.nix;
    options = {
      env = bt.mkEnv ''
        Environment for every unit of this package, on both ${sides}
        (compiles and build-script runs). Values may be derivations,
        including another workspace's products; they are passed by
        reference.
      '';
      nativeInputs = bt.mkInputs ''
        Tools that run on the build machine (`pkg-config`, `cmake`,
        `protoc`), for this package's units on both ${sides}. A function of
        the build platform's package set, or a list.
      '';
      inputs = bt.mkInputs ''
        Libraries for the platform being built (`openssl`), for this
        package's units on both ${sides}. A function of a package set
        (`p: [ p.openssl ]`), called with the build machine's set for host
        units and with the target's set for target units; or a list used
        as given. Their library search paths (`NIX_LDFLAGS`, not compiler
        flags or `PATH`) also reach the link steps of the packages that
        link this one (bins, tests, cdylibs, doctests of dependents), on
        the same platform, so a `-sys` crate may print `rustc-link-lib`
        without a search path; binaries get an rpath to the library.
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

      forHost = side "host";
      forTarget = side "target";

      stages = mkOption {
        type = bt.stages;
        default = { };
        description = "Post-link stages for this package's products, as `targets.<triple>.stages` (`after = \"install\"` for wrappers and packaging).";
      };
      checks = mkOption {
        type = bt.stages;
        default = { };
        example = lib.literalExpression "{ noSourceReferences = null; }";
        description = ''
          Checks on this package's products, as `targets.<triple>.checks`.
          They are added to the target's checks and to the default checks
          (`noSourceReferences`, `buildScriptFiles`). `null` removes a check
          from this package only.
        '';
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
            Repository paths (paths, or strings relative to the
            repository root) that only this package's test units see: its
            test harnesses (`--test` compiles), doctests and test runs,
            whose working directory is the package directory of their
            view. A path outside the package is added to the test view. A
            path inside the package is also removed from the view of its
            other units (the library, bins, build script, examples).
            Either way, editing it re-runs only this package's tests. The
            package's `tests/` directory is in this scope too
            (`scopeTestsDir`).
          '';
        };
        scopeTestsDir = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Whether the package's `tests/` directory is test-only, as if
            listed in `sourceScope`: Cargo builds the files in it only as
            integration tests, so a fixture edit there re-runs only this
            package's tests. Set it to `false` when non-test code reads
            from `tests/` at compile time (`include_str!("../tests/…")`, a
            build script that generates tests from fixtures); such a
            library fails with a hint naming this option. `null`: `true`.
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
            in `tests.<pkg>.<binary>` for debugging. `null`: off.
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
            groups). Each binary is still its own test run. `null`:
            `libtest`.
          '';
        };
        nextest = {
          profile = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "ci";
            description = "nextest profile for this package's test runs (`null`: `default`).";
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
    };
  };
in
{
  inherit common;

  # Keyed, so the module system imports it once wherever it is used.
  settings = {
    key = "breakbulk/modules/package-settings.nix#settings";
    _file = ./package-settings.nix;
    imports = [ common ];
    options.target = mkOption {
      type = types.attrsOf (types.submodule common);
      default = { };
      # The same options as the package level, documented there.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          x86_64-pc-windows-msvc.forTarget.env.FFMPEG_DIR = ffmpegWin;
          x86_64-pc-windows-msvc.stages.sign = { after = "install"; run = sign; };
        }
      '';
      description = ''
        Settings for this package on one target triple, with every option
        of the package level (`env`, `forHost`, `forTarget`, `stages`,
        `test`, …). They apply to the plans for that triple, on top of the
        package-level settings of the same definition: `env` still means
        both ${sides} (the build-script compile of a plan for this triple
        included), `forTarget.env` the target side only.
      '';
    };
  };
}
