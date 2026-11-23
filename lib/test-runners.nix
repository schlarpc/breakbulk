# Test runners (`packages.<name>.test.runner`; "Test runners" in
# docs/src/reference/presets.md): what starts a test or bench binary in its
# run. A test runner is a function from the run's facts to a shell snippet
# (bash) that runs the tests:
#
#   facts = {
#     pkgs;          # the package set of the machine that runs the test
#     package;       # the package name
#     kind;          # "test" or "bench": the plan the binary is from
#     binary = {
#       key;         # its key: `lib/<crate>`, `bin/<name>`, `<test>`, …
#       kind;        # its root kind: lib, bin, test, bench, example
#       name;        # its Cargo target's name
#     };
#     args;          # the run's `args`, a list of strings
#     platform;      # "target", or "host" for a binary built for the
#                    # build machine (a proc macro's unit tests)
#     triple;        # that platform's triple
#     hostTriple;    # the build machine's triple
#     targetTriple;  # the plan's target triple
#     launcher;      # null, or a program that starts the program given
#                    # after it, with its arguments, under the run's test
#                    # wrapper and the platform's target runner
#                    # (`targets.<t>.runner`)
#     withEnv;       # shell words that put the variables the shell cannot
#                    # export (`CARGO_BIN_EXE_<bin>` with a `-`) in a
#                    # command's environment: `${withEnv} <command>`
#     libDir;        # the sysroot's library directory of the platform
#                    # (already on the dynamic-library path), or null
#     pathPackages;  # a JSON file, read at build time: `packageId`, the
#                    # tested package's id, and `packages.<name> = { dir;
#                    # targets; dependencies; }` for every path package
#                    # the plan compiles, by name (crates/breakbulk-
#                    # instantiate/src/test_spec.rs `PathNode`)
#     workspaceDir;  # the Cargo workspace's directory in the repository
#                    # (a path), for the project's own configuration
#   };
#
# The snippet runs in a subshell of the run's shell, in the run's working
# directory, with the run's environment exported and `$binary` the test
# binary. Its output goes to the build log and `$log`, and its exit status
# is the run's; breakbulk's hints and `postRun` follow. `$TMPDIR` is the
# run's own. A runner that copies files to `$out` decides whether the run
# is reproducible (`nix build --rebuild`).
{ lib, util }:
let
  # A program's words, with the launcher before it when there is one.
  launch = facts: lib.optionalString (facts.launcher != null) "${lib.escapeShellArg facts.launcher} ";

  # nextest's reuse-build metadata for the run's binary, as nextest 0.9.146
  # reads them (nextest-runner/src/list/test_list.rs `from_binary_list`,
  # src/test_command.rs, src/list/rust_build_meta.rs, nextest-filtering
  # src/compile.rs). A jq program over the path-package graph (`$g`) and
  # the run's `breakbulk-root.json` (`$info`, for the tested package's
  # `CARGO_PKG_*`), with the binary, the scratch workspace (`$ws`, whose
  # `target` is the target directory) and the working directory (`$wd`)
  # as arguments. Only what the run can observe is in it:
  #
  # - the binary path is absolute and used as is, so the binary stays in
  #   its own store path;
  # - nextest runs the binary in its package's manifest directory and sets
  #   `CARGO_MANIFEST_DIR` to it, so the tested package's manifest is in
  #   the run's working directory. nextest sets `CARGO_PKG_*` from the
  #   package entry, so the entry is built from the test unit's recorded
  #   `CARGO_PKG_*` values;
  # - the other path packages are there for filtersets only: `package()`,
  #   `deps()` and `rdeps()` match package names, and `binary()` and
  #   `binary_id()` are checked against the targets (nextest-filtering
  #   `ParseContextCache::new`, which fails a run whose configuration names
  #   a binary it does not know). Nothing reads their manifest paths,
  #   versions or ids, so each is listed by name alone (its id is its
  #   name, its version `0.0.0`), with its manifest and target sources
  #   under the scratch workspace;
  # - dependency edges for `deps()` and `rdeps()`. A filterset is only
  #   evaluated for the run's own binary, so `deps(x)` asks only whether a
  #   package named `x` reaches the tested package, and `rdeps(x)` whether
  #   the tested package reaches one (guppy's `depends_on`: transitive, any
  #   dependency kind, and true from a package to itself). Each package
  #   that reaches the tested one gets a direct edge to it, and the tested
  #   package one to each package it reaches; edges between other packages
  #   are left out. guppy matches each resolve edge to a declared
  #   dependency by the dependency's library name and version requirement,
  #   so each edge is declared with `*` and no rename, under the library's
  #   own name;
  # - no base output directories, linked paths, build-script out dirs or
  #   libdirs but the sysroot's of the binary's own platform (`$libdir`):
  #   nextest then adds nothing to the dynamic-library path, and keeps the
  #   environment the run already set, so the process sees what a direct
  #   run sees;
  # - nextest requires `<workspace root>/Cargo.toml` to exist and writes its
  #   store under it, so the workspace root is a scratch directory.
  metadataJq = ''
    ($g[0]) as $g
    | ($info[0].testSpec.env) as $env
    | $env.CARGO_PKG_NAME as $self
    | ($g.packages // {}) as $P
    | def listed($n): if $n == $self then $g.packageId else $n end;
      def orNull: if . == null or . == "" then null else . end;
      def libName($id):
        ([$P[$id].targets[] | select(.kind | any(. == "bin" or . == "example" or . == "test" or . == "bench" or . == "custom-build") | not)][0].name // "")
        | gsub("-"; "_");
      def reach($edges; $from):
        {seen: {}, todo: [$from]}
        | until(.todo == [];
            .todo[0] as $x
            | .todo |= .[1:]
            | reduce ($edges[$x] // [])[] as $n (.;
                if .seen[$n] then . else .seen[$n] = true | .todo += [$n] end))
        | .seen | del(.[$from]) | keys;
      ($P | with_entries(.value = [.value.dependencies[] | select($P[.] != null)])) as $fwd
    | (reduce ($fwd | to_entries[]) as $e ({}; reduce $e.value[] as $to (.; .[$to] += [$e.key]))) as $rev
    | reach($fwd; $self) as $below
    | reach($rev; $self) as $above
    | def depsOf($id):
        if $id == $self then $below
        elif ($above | index($id)) != null then [$self]
        else [] end;
      def manifest($id):
        if $id == $self then $wd + "/Cargo.toml"
        elif $P[$id].dir == "" then $ws + "/Cargo.toml"
        else $ws + "/" + $P[$id].dir + "/Cargo.toml" end;
      ($P | keys) as $ids
    | {
        version: 1,
        packages: [
          $ids[] as $id
          | {
              id: listed($id),
              name: $id,
              version: "0.0.0",
              authors: [],
              description: null,
              homepage: null,
              repository: null,
              license: null,
              license_file: null,
              rust_version: null,
              readme: null,
              documentation: null,
              source: null,
              dependencies: [depsOf($id)[] | {
                name: ., source: null, req: "*", kind: null, optional: false,
                uses_default_features: true, features: [], target: null, rename: null,
                registry: null, path: null
              }],
              targets: [$P[$id].targets[] | {
                name, kind, crate_types: .crateTypes,
                src_path: ($ws + "/" + (.srcPath | ltrimstr("/")))
              }],
              features: {},
              manifest_path: manifest($id),
              metadata: null,
              publish: null,
              categories: [],
              keywords: [],
              edition: "2021",
              links: null,
              default_run: null
            }
          | if $id == $self then . + {
              version: $env.CARGO_PKG_VERSION,
              authors: [($env.CARGO_PKG_AUTHORS // "") | split(":")[] | select(. != "")],
              description: ($env.CARGO_PKG_DESCRIPTION | orNull),
              homepage: ($env.CARGO_PKG_HOMEPAGE | orNull),
              repository: ($env.CARGO_PKG_REPOSITORY | orNull),
              license: ($env.CARGO_PKG_LICENSE | orNull),
              license_file: ($env.CARGO_PKG_LICENSE_FILE | orNull),
              rust_version: ($env.CARGO_PKG_RUST_VERSION | orNull)
            } else . end
        ],
        workspace_members: [$ids[] | listed(.)],
        workspace_default_members: [$ids[] | listed(.)],
        resolve: {
          nodes: [$ids[] as $id | {
            id: listed($id),
            dependencies: [depsOf($id)[] | listed(.)],
            deps: [depsOf($id)[] | {name: libName(.), pkg: listed(.), dep_kinds: [{kind: null, target: null}]}],
            features: []
          }],
          root: null
        },
        workspace_root: $ws,
        target_directory: ($ws + "/target"),
        metadata: null
      } as $cargo
    | ($env.CARGO_PKG_NAME) as $pkg
    | (if $kind == "lib" then $pkg
       elif $kind == "test" then $pkg + "::" + $target
       else $pkg + "::" + $kind + "/" + $target end) as $id
    | def platform($t): {triple: $t, "target-features": "unknown"};
      def libdir($t):
        if $t == $triple and $libdir != "" then {status: "available", path: $libdir}
        else {status: "unavailable", reason: "breakbulk"} end;
      {
        "rust-build-meta": {
          "target-directory": ($ws + "/target"),
          "build-directory": ($ws + "/target"),
          "base-output-directories": [],
          "non-test-binaries": {},
          "build-script-out-dirs": {},
          "build-script-info": {},
          "linked-paths": [],
          platforms: {
            host: {platform: platform($host), libdir: libdir($host)},
            targets: (if $target_ != $host then [{platform: platform($target_), libdir: libdir($target_)}] else [] end)
          },
          "target-platforms": [platform($target_)],
          "target-platform": null
        },
        "rust-binaries": {
          ($id): {
            "binary-id": $id,
            "binary-name": $target,
            "package-id": $g.packageId,
            kind: $kind,
            "binary-path": $binary,
            "build-platform": (if $platform == "host" and $target_ != $host then "host" else "target" end)
          }
        }
      } as $binaries
    | {cargo: $cargo, binaries: $binaries}
  '';
in
{
  # The binary itself, as `cargo test` and `cargo bench` start it, with the
  # run's `args`. It speaks libtest's protocol: RUST_TEST_THREADS is the
  # build's cores unless the environment set it, and `#[ignore]` tests are
  # left out unless `args` has `--include-ignored` or `--ignored`.
  direct = facts: ''
    export RUST_TEST_THREADS=''${RUST_TEST_THREADS:-$NIX_BUILD_CORES}
    exec ${facts.withEnv} ${launch facts}"$binary" ${lib.escapeShellArgs facts.args}
  '';

  # cargo-nextest's reuse-build mode over the one binary, with the
  # project's nextest configuration (retries, timeouts, default filter,
  # test groups). The run's `args` go after `--`, which nextest emulates
  # (`--skip`, `--exact`, `--include-ignored`, …). nextest starts the
  # binary through the launcher, as Cargo's target runner
  # (`CARGO_TARGET_<TRIPLE>_RUNNER`, for listing as for each test): its own
  # wrapper scripts need the experimental `wrapper-scripts` feature, which
  # only the project's main configuration file can turn on (nextest
  # 0.9.146, nextest_version.rs). `test-threads` is the build's cores, in a
  # tool configuration, which ranks under the project's configuration and
  # `NEXTEST_TEST_THREADS`. nextest's store (JUnit reports) is
  # `$TMPDIR/nextest-ws/target/nextest`.
  #
  # `configFile`: the workspace's `.config/nextest.toml` when it exists,
  # unless given (`null`: none). `package`: cargo-nextest (default: the
  # test machine's).
  nextest =
    args@{
      profile ? "default",
      package ? null,
      ...
    }:
    let
      bad = lib.attrNames (
        removeAttrs args [
          "profile"
          "package"
          "configFile"
        ]
      );
    in
    if bad != [ ] then
      throw "breakbulk.lib.testRunners.nextest: unknown argument ${lib.concatStringsSep ", " bad}; it takes profile, configFile and package"
    else
      facts:
      let
        auto = facts.workspaceDir + "/.config/nextest.toml";
        configFile =
          if args ? configFile then
            args.configFile
          else if builtins.pathExists auto then
            auto
          else
            null;
        nextest = if package != null then package else facts.pkgs.cargo-nextest;
        jq = "${facts.pkgs.jq}/bin/jq";
        var = util.cargoTargetEnvVar facts.triple "RUNNER";
      in
      ''
        ws=$TMPDIR/nextest-ws
        mkdir -p "$ws/target"
        touch "$ws/Cargo.toml"
        ${lib.optionalString (facts.launcher != null) "export ${var}=${lib.escapeShellArg facts.launcher}"}
        ${jq} -n \
          --slurpfile g ${facts.pathPackages} \
          --slurpfile info "$info" \
          --arg binary "$binary" --arg ws "$ws" --arg wd "$PWD" \
          --arg kind ${lib.escapeShellArg facts.binary.kind} \
          --arg target ${lib.escapeShellArg facts.binary.name} \
          --arg platform ${lib.escapeShellArg facts.platform} \
          --arg triple ${lib.escapeShellArg facts.triple} \
          --arg host ${lib.escapeShellArg facts.hostTriple} \
          --arg target_ ${lib.escapeShellArg facts.targetTriple} \
          --arg libdir ${lib.escapeShellArg (if facts.libDir == null then "" else facts.libDir)} \
          ${lib.escapeShellArg metadataJq} > "$TMPDIR/nextest-metadata.json"
        ${jq} -c .cargo "$TMPDIR/nextest-metadata.json" > "$TMPDIR/cargo-metadata.json"
        ${jq} -c .binaries "$TMPDIR/nextest-metadata.json" > "$TMPDIR/binaries-metadata.json"
        printf '[profile.default]\ntest-threads = %s\n' "$NIX_BUILD_CORES" > "$TMPDIR/breakbulk-nextest.toml"
        cd "$TMPDIR"
        exec ${facts.withEnv} ${nextest}/bin/cargo-nextest nextest run \
          --binaries-metadata "$TMPDIR/binaries-metadata.json" \
          --cargo-metadata "$TMPDIR/cargo-metadata.json" \
          ${lib.optionalString (configFile != null) "--config-file ${configFile}"} \
          --profile ${lib.escapeShellArg profile} \
          --tool-config-file "breakbulk:$TMPDIR/breakbulk-nextest.toml" \
          --no-tests=warn --color never \
          ${lib.optionalString (facts.args != [ ]) "-- ${lib.escapeShellArgs facts.args}"}
      '';
}
