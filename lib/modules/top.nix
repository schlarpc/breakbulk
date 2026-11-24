# Repository-wide options: delivery mode, source strictness, fetching,
# and the curated defaults for -sys crates (lib/sys-defaults.nix), for
# the dependents of crates (lib/sys-defaults-dependents.nix) and for the
# hints of failed build scripts (lib/build-script-hints.json).
{ lib, config, ... }:
let
  inherit (lib) types mkOption;
  bt = import ./types.nix { inherit lib; };
  inherit (import ./package-settings.nix { inherit lib; }) settingsModule;
  curated = import ../sys-defaults.nix { inherit lib; };
  curatedDependents = import ../sys-defaults-dependents.nix { inherit lib; };
  curatedHints = lib.importJSON ../build-script-hints.json;
  gates = import ../nix-features.nix { inherit lib; };
  registryDefaults = import ../registries.nix;
in
{
  config.registries = lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault)) registryDefaults;

  config.sysDefaults = {
    packages = lib.mapAttrs (_: lib.mkDefault) curated;
    dependents = lib.mapAttrs (
      _: v: lib.mkDefault (if builtins.isFunction v then v else _: v)
    ) curatedDependents;
    buildScriptHints = lib.mapAttrs (
      _: v: if builtins.isAttrs v then lib.mapAttrs (_: lib.mkDefault) v else lib.mkDefault v
    ) curatedHints;
  };

  options = {
    mode = mkOption {
      type = types.enum [
        "ifd"
        "dynamic"
      ];
      default = gates.defaultMode;
      defaultText = lib.literalMD ''
        `"dynamic"` when the evaluator has dynamic derivations (Nix's
        `outputOf` builtin) and is Nix 2.36 or later, else `"ifd"`
      '';
      description = ''
        How unit derivations reach Nix. `ifd`: breakbulk-instantiate writes
        units.json, which Nix imports (import-from-derivation). `dynamic`:
        an outer derivation writes the unit derivations through Nix's
        `builder-rpc-v0` interface and products reach them with Nix's
        `outputOf` builtin (needs Nix 2.36 or later with the
        `dynamic-derivations` and `ca-derivations` experimental features).
        The default is the evaluator's: `dynamic` where it can, `ifd`
        elsewhere. A daemon or builder older than the evaluator fails with
        Nix's own "missing system features" error naming `builder-rpc-v0`;
        set `ifd` then. Unit derivations are identical in both modes;
        products are not (they are resolved at build time in `dynamic`), so
        teams that mix Nix versions should pin the mode.
        [`repo.nixFeatures`](../outputs.md#nixfeatures) lists the Nix
        features the evaluation may use.

        In `ifd`, evaluating another system's outputs builds its plans, which
        needs a builder for that system: `nix flake check --all-systems` and
        `nix flake show --all-systems` fail on a Linux machine for darwin
        outputs ("Required system"). Plain `nix flake check` and `nix flake
        show` evaluate only the current system and are unaffected, and
        `dynamic` evaluates every system without builders. With `ifd`, list
        only the systems you can build on (the common `nix-systems/default`
        includes darwin).
      '';
    };

    ca = mkOption {
      type = types.bool;
      default = config.mode == "dynamic";
      defaultText = lib.literalExpression ''mode == "dynamic"'';
      description = ''
        Content-address post-link stages, checks and test runs, so that an
        unchanged input does not re-run them. Needs Nix's `ca-derivations`
        experimental feature in the evaluator and the daemon. The default
        follows `mode`: `dynamic` needs `ca-derivations` anyway, while Nix
        code cannot tell whether it is on otherwise, and without it a
        content-addressed derivation is an error that cannot be caught.
      '';
    };

    registries = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            index = mkOption {
              type = types.str;
              example = "sparse+https://my-registry.example/index/";
              description = ''
                The registry's index URL as it appears in `Cargo.lock`
                (with or without the `registry+` prefix; sparse registries
                keep `sparse+`). It says which lockfile entries the
                registry serves; crates.io's sparse index
                (`sparse+https://index.crates.io/`) counts as its git one.
              '';
            };
            dl = mkOption {
              type = types.str;
              example = "https://my-registry.example/api/v1/crates/{crate}/{version}/download";
              description = ''
                Download URL template, as in the registry's `config.json`
                (`{crate}`, `{version}`, `{prefix}`, `{lowerprefix}`,
                `{sha256-checksum}`). `Cargo.lock` records only the index,
                and reading `config.json` would need a fetch during
                evaluation. A mirror is a different `dl`.
              '';
            };
            fetch = mkOption {
              type = types.functionTo (types.functionTo types.package);
              default = p: p.fetchurl;
              defaultText = lib.literalExpression "pkgs: pkgs.fetchurl";
              example = lib.literalExpression ''
                pkgs: args: pkgs.fetchurl (args // {
                  netrcImpureEnvVars = [ "MY_REGISTRY_TOKEN" ];
                  netrcPhase = '''
                    echo "machine my-registry.example password $MY_REGISTRY_TOKEN" > netrc
                  ''';
                })
              '';
              description = ''
                How to download one crate: a function of the build
                machine's package set that returns a fetcher with
                `fetchurl`'s interface. The fetcher is called with `name`,
                `url` (from `dl`) and `sha256` (the lockfile's checksum)
                and returns the `.crate` file as a fixed-output
                derivation. Change it to authenticate.

                breakbulk does not handle secrets. A credential reaches
                the fetch only through an environment variable that the
                fetch names as impure, which Nix reads from the daemon's
                environment or its `impure-env` setting, or through a
                netrc file the daemon reads (see
                [Fetch from a mirror or a private registry](../../how-to/registries.md)).
              '';
            };
          };
        }
      );
      default = { };
      defaultText = lib.literalExpression ''
        {
          crates-io = {
            index = "${registryDefaults.crates-io.index}";
            dl = "${registryDefaults.crates-io.dl}";
          };
        }
      '';
      example = lib.literalExpression ''
        {
          crates-io.dl = "https://crates-mirror.example/{crate}/{crate}-{version}.crate";
          my = {
            index = "sparse+https://my-registry.example/index/";
            dl = "https://my-registry.example/api/v1/crates/{crate}/{version}/download";
          };
        }
      '';
      description = ''
        The registries crates are downloaded from, by name. A lockfile
        entry from a registry not listed here is an error. `crates-io` is
        defined field by field at `mkDefault` priority, so a definition of
        one of its fields replaces just that field: a mirror of crates.io
        sets `crates-io.dl`. The name labels the registry in the Cargo
        configuration that replaces it with its vendor directory.
      '';
    };

    git = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            hash = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "sha256-5mLf4B3zTZwv3wKgdixL/QJuTuouPlpm01rMFAZ8D6Y=";
              description = ''
                The NAR hash of the fetched tree (`builtins.fetchGit`'s
                `narHash`, not crane's `outputHashes`). Optional: with a
                hash, the fetch is fixed-output and a binary cache can
                serve it; without one, every fresh machine clones the
                source during evaluation.
              '';
            };
            tree = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = lib.literalExpression "inputs.my-fork";
              description = ''
                A tree to use instead of fetching: a local checkout, a
                fetched tree such as a flake input, or a test fixture.
                Crates are found in it as in a fetched one.
              '';
            };
            subdirs = mkOption {
              type = types.attrsOf types.str;
              default = { };
              example = {
                mycrate = "crates/mycrate";
              };
              description = ''
                Where a crate lives inside the tree, by crate name. Skips
                the walk over the tree's `Cargo.toml` files.
              '';
            };
            submodules = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether to fetch submodules. Cargo checks out the
                submodules of git dependencies.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          "https://github.com/me/repo".subdirs.mycrate = "crates/mycrate";
          "git+https://github.com/me/serde?rev=abc#abc0123".hash = "sha256-…";
        }
      '';
      description = ''
        Settings for git sources, keyed by the full `Cargo.lock` source
        string (`git+<url>?<reference>#<revision>`) or by the URL alone.
        A source uses the entry under its source string if there is one,
        else the one under its URL; the two are not merged. A source
        string names one locked revision, as a hash needs; a URL covers
        every revision locked from it. See
        [Use git dependencies](../../how-to/git-dependencies.md).
      '';
    };

    crateSources = mkOption {
      type = types.listOf (types.functionTo types.raw);
      default = [ ];
      example = lib.literalExpression ''
        [
          # A pre-vendored directory, as `cargo vendor` writes it.
          (entry:
            let dir = ./vendor + "/''${entry.name}-''${entry.version}"; in
            if builtins.pathExists dir then { path = dir; } else null)
          # A patched crate.
          (entry:
            if entry.name == "itoa" then {
              path = pkgs.applyPatches {
                name = "itoa-patched";
                src = entry.defaultSource.path;
                patches = [ ./itoa.patch ];
              };
              inherit (entry.defaultSource) subdir;
            } else null)
        ]
      '';
      description = ''
        Functions that supply the source of a registry or git dependency
        instead of fetching it. Each is called with the lockfile entry and
        returns `null` to pass, or `{ path; subdir ? ""; }`: the crate is
        the directory `subdir` of the tree `path` (a path, a derivation or
        a fetched tree). They are tried in order and the first non-null
        answer wins; the built-in fetchers (`registries`, `git`) come
        last.

        The entry has `name`, `version`, `source` (the `Cargo.lock` source
        string), `checksum` (null for git), `parsed.kind` (`"registry"` or
        `"git"`), `parsed.url`, and `defaultSource`: the
        `{ path; subdir; }` the built-in fetchers give, fetched only if
        used. Cargo checks a registry crate against the lockfile's
        checksum, which breakbulk gives a supplied crate whatever its
        contents, so a patched crate needs no new lockfile. See
        [Supply or patch a crate's source](../../how-to/crate-sources.md).
      '';
    };

    sysDefaults.packages = mkOption {
      type = types.attrsOf (types.nullOr settingsModule);
      default = { };
      # The options of `packages.<name>`, documented there.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          libsqlite3-sys = null;  # no curated inputs
          aws-lc-sys = breakbulk.whenVersion ">=0.42" { inputs = p: [ p.aws-lc ]; };
        }
      '';
      description = ''
        Default settings for a package, by crate name: a module with the
        options of `packages.<name>`, whose `package` argument is the
        package's lockfile entry (`{ name, version, ... }`). They are the
        lowest layer
        ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)):
        lists concatenate with those of `packages.<name>`, env attributes
        merge, and a single value there wins over one here.

        They name nixpkgs libraries, so they apply only where a package
        set exists: host units always (the build machine's), target units
        only when `targets.<triple>.packageSet` exists (or the target is
        the native one). On other targets (msvc, wasm32-unknown-unknown)
        those crates build their bundled copies.

        The curated entries are defined at `mkDefault` priority, so a
        plain definition replaces one: `null` turns it off, a module
        replaces it, and `sysDefaults.packages = lib.mkForce { }` drops
        them all. They are: ${lib.concatMapStringsSep ", " (n: "`${n}`") (lib.attrNames curated)}.
      '';
    };

    sysDefaults.dependents = mkOption {
      type = types.attrsOf (types.nullOr (types.functionTo settingsModule));
      default = { };
      # The result has the options of `packages.<name>`, documented there.
      visible = "shallow";
      example = lib.literalExpression ''
        {
          insta = null;  # no INSTA_* variables in test runs
          my-fixtures = _: { test.env.FIXTURES = run: "''${run.workspaceRoot}/fixtures"; };
        }
      '';
      description = ''
        Default settings for the packages that depend on a crate, by the
        crate's name: a function of the crate's lockfile entry (`{ name,
        version, direct, buildDependency, ... }`) that returns a module
        with the options of `packages.<name>` (whose `package` argument is
        the dependent's lockfile entry). They apply to every package of a
        workspace's `Cargo.lock`, from the registry, git or a path, that
        has the crate among its dependencies of any kind
        (dev-dependencies too), directly or through other crates. Two
        arguments narrow that: `direct` is `true` when the dependent's
        `Cargo.lock` entry names the crate itself, and `buildDependency`
        when the crate's library code runs in a path package's build
        script: its own `Cargo.toml` names the crate under
        `[build-dependencies]` (or a `[target.<cfg>.build-dependencies]`
        table, renamed with `package` too), or names a path package there
        that has the crate in its `[dependencies]`, directly or through
        more path packages (a local crate that wraps `bindgen`). It is
        always `false` for a registry or git package, and does not follow
        a registry or git crate's dependencies: their manifests are not
        read at evaluation. The manifests are read only by a function that
        uses the argument. They are a layer
        over `sysDefaults.packages` and under `memberDefaults`
        ([layer order](../../explanation/configuration.md#shared-settings-and-layer-order)).

        The curated entries are defined at `mkDefault` priority, so a
        plain definition replaces one: `null` turns it off, a function
        replaces it, and `sysDefaults.dependents = lib.mkForce { }` drops
        them all. They are: ${lib.concatMapStringsSep ", " (n: "`${n}`") (lib.attrNames curatedDependents)}.
        `insta` sets `INSTA_WORKSPACE_ROOT` to the workspace root of the
        run's files and `INSTA_UPDATE = "no"`, in test runs and doctests
        (see [Run snapshot tests](../../how-to/snapshot-tests.md)).
        `autocfg`, `bindgen`, `cxx-build`, `glib-build-tools`, `lalrpop`,
        `slint-build`, `tauri-build`, `vergen` and `vergen-lib` print
        `rerun-if-changed` directives from their library code, which
        source prediction cannot read: for a package that build-depends
        on one, they set
        [`predictSources.buildScriptRuns`](packages.md#packagesnamepredictsourcesbuildscriptruns)
        to `false`. `cmake` gives each package that depends on it
        directly a
        [`buildScript.outDirRemove`](packages.md#packagesnamebuildscriptoutdirremove)
        rule that deletes CMake's `CMakeFiles` beside its
        `CMakeCache.txt`.
      '';
    };

    sysDefaults.buildScriptHints = mkOption {
      type = types.submodule {
        options = {
          recognizers = mkOption {
            type = types.attrsOf (
              types.nullOr (
                types.submodule {
                  options = {
                    about = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "What the entry recognizes, for its readers; not used.";
                    };
                    fingerprint.vars = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Variable patterns: the crate ran when the script declared a matching `rerun-if-env-changed` variable.";
                    };
                    fingerprint.lines = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Line patterns: the crate ran when the script printed a matching line.";
                    };
                    errors = mkOption {
                      type = types.listOf (
                        types.submodule {
                          options = {
                            pattern = mkOption {
                              type = types.str;
                              description = "A line pattern; `{}` captures text the hint names as `{0}`.";
                            };
                            hint = mkOption {
                              type = types.str;
                              description = "The hint; `{opt}` is the package's option prefix (`packages.<name>`).";
                            };
                          };
                        }
                      );
                      default = [ ];
                      description = "Error lines and their hints; the first pattern a line matches decides its hint.";
                    };
                    covers = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = "Variable patterns of the variables the crate declares and normally leaves unset: counted, not listed, after its failure.";
                    };
                  };
                }
              )
            );
            default = { };
            description = "Failures of common crates, by the crate name the hints name.";
          };
          notFound = mkOption {
            type = types.listOf types.str;
            description = "Text of a line that says a program was not found.";
          };
          tools = mkOption {
            type = types.attrsOf (types.nullOr types.str);
            default = { };
            description = "Programs build scripts run, by the name they run, and the attribute of the package set that provides each.";
          };
          toolHint = mkOption {
            type = types.str;
            description = "The hint for a tool not found: `{tool}`, `{attr}` and `{opt}` name the tool, its attribute and the package's option prefix.";
          };
          network = mkOption {
            type = types.listOf types.str;
            description = "Lowercase text of a line that shows a build script downloading or failing to reach the network.";
          };
          downloaders = mkOption {
            type = types.listOf types.str;
            description = "Programs whose name, as a word outside a `cargo:` directive, shows a download.";
          };
          networkHint = mkOption {
            type = types.str;
            description = "The hint for a download; `{opt}` is the package's option prefix.";
          };
        };
      };
      default = { };
      description = ''
        What a failed build-script run is searched for, to add hints
        after its output: failures of common crates when a tool or
        library is missing from the sandbox (`recognizers`), a program
        not found that a known package provides (`notFound`, `tools`),
        and a download (`network`, `downloaders`). The hints never
        change the result. Patterns: `*` matches any text and `{}` any
        non-empty text, which a hint names as `{0}`; variable patterns
        also match after a `HOST_` or `TARGET_` prefix.

        The table reaches every build-script run as one file, read only
        after a failure: changing it rebuilds build-script runs, not
        compiles. The curated entries are defined at `mkDefault`
        priority, so a plain definition replaces one: a recognizer or
        tool set to `null` is turned off, and a list or hint replaces
        the curated one. They are listed in
        [Build-script failure hints](../build-script-hints.md).
      '';
    };

    wasmBindgen.hashes = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            hash = mkOption {
              type = types.str;
              description = "The hash of `fetchCrate { pname = \"wasm-bindgen-cli\"; version; }`.";
            };
            cargoHash = mkOption {
              type = types.str;
              description = "The hash of its vendored dependencies (`buildRustPackage`'s `cargoHash`).";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          "0.2.123" = { hash = "sha256-…"; cargoHash = "sha256-…"; };
        }
      '';
      description = ''
        wasm-bindgen-cli versions to build from crates.io, by version,
        merged over breakbulk's table (`lib/wasm-bindgen-hashes.nix`),
        for a workspace whose locked `wasm-bindgen` is in neither that
        table nor nixpkgs
        ([`workspaces.<ws>.tools.wasmBindgen`](workspaces.md#workspacesnametoolswasmbindgen)).
      '';
    };

    checks = mkOption {
      type = types.attrsOf types.package;
      default = { };
      example = lib.literalExpression ''
        {
          "lint/deny" = pkgs.runCommand "deny" { } "cargo-deny … && touch $out";
        }
      '';
      description = ''
        Your own checks, each a named leaf of `repo.checks` (and the
        flake's `checks`), beside breakbulk's: a name may hold `/`, and
        then makes groups as breakbulk's names do (`lint/deny` is in the
        group `lint`, [check groups](../outputs.md#checks)), and
        `checkGroups` patterns match it. A name that is already one of
        breakbulk's checks is an error.
      '';
    };

    checkGroups = mkOption {
      type = types.attrsOf (types.listOf (types.either types.str types.package));
      default = { };
      example = lib.literalExpression ''
        {
          clippy = [ "*/*/variant-clippy/**" ];
          fmt = [ "*/fmt" ];
          release = [ "host/*/variant-release/**" self.packages.x86_64-linux.docs ];
        }
      '';
      description = ''
        Named groups of checks, each an aggregate check in `repo.checks`
        (and the flake's `checks`) that builds what it holds as one
        installable. Each item is a glob over check names, where `*`
        matches within one `/`-separated segment and `**` any number of
        segments, or a derivation to include as is. A pattern that
        matches no check is an error, as is a name that is already a
        check, a prefix group (every proper prefix of a check name is
        one) or `all`.
      '';
    };

    warnings = bt.warningsOption;
    assertions = bt.assertionsOption;
  };
}
