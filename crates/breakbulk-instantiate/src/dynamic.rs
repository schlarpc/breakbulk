//! Dynamic-derivation mode, the part that needs no store.
//!
//! In IFD mode the Nix side substitutes every reference in `units.json` and
//! applies `derivation` to the result (`lib/instantiate.nix`). Dynamic mode
//! does the same here, in the builder of the outer derivation: it takes the
//! same [`UnitsJson`], the values of the input keys (with their string
//! context, as `builtins.getContext` gives it), and the output paths of the
//! derivations written so far, and produces each derivation exactly as
//! `derivation` would: the same `env`, `args`, input derivations and input
//! sources. Hashing and writing are left to the caller (`breakbulk-drv`,
//! which uses harmonia), so this crate keeps no store dependency.
//!
//! On top of the units and root stubs, each root gets a wrapper derivation,
//! because Nix requires a submitted output to be named
//! `<outer name>-<output name>` (spike B, finding 2). Its output is a
//! directory:
//!
//! - `root`: a symlink to the root unit's output, or for a test binary
//!   Cargo did not build to its stub's (which succeeds and logs why);
//! - `not-built`: for a root Cargo did not build (required features), the
//!   reason. A product root has no `root` then and does not depend on its
//!   stub, so products can leave it out at build time, as IFD mode does at
//!   evaluation time;
//! - `debug`: a symlink to the root unit's `debug` output (its debuginfo
//!   side files), when it has one;
//! - `breakbulk-root.json`: what the root is ([`RootInfo`]), and for a test
//!   binary what its test run and test app need ([`TestSpec`]), with real
//!   paths. The wrapper has every path in it as an input, so they are in its
//!   closure.
//!
//! Each predicted doctest (a library of the test plan) gets the same: the
//! doctest derivation IFD mode makes, with the package's test configuration
//! (runner, arguments, env) from `values.json`, and a wrapper
//! `<outer name>-<package>.doctest` whose `root` links its output, or whose
//! `not-built` says why the plan has none.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{
    CompileUnit, Piece, Plan, Platform, Reference, Resolve, RootKind, SrcRef, Text, Unit,
    to_canonical_json,
};
use serde::{Deserialize, Serialize};

use crate::output::{Drv, Part, RootOut, RootWhat, UnitsJson, Value};
use crate::{
    Error, Inputs, TOOL_SHELL, Tokens, err, keys, kind_str, token_prefix, unit_outputs,
    workspace_dir,
};

/// The key of the coreutils store path the wrappers use (`values.json`
/// only; IFD mode has no wrappers).
pub const COREUTILS_KEY: &str = "dynamic:coreutils";

/// `outer.json`: the outer derivation's name and its outputs.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Outer {
    /// The outer derivation's name, `<ws>-<triple>-<variant>[-test]`.
    pub name: String,
    /// Root name (`<package>/<kind>/<target>`) to its output name
    /// (`<…>.drv`). Must cover every root of the instantiation.
    pub outputs: BTreeMap<String, String>,
    /// The output for a derivation that depends on every output of every
    /// unit (`units.drv`): building it builds the whole plan, as check and
    /// clippy variants need (they have no roots). None: no such output.
    #[serde(default)]
    pub units: Option<String>,
    /// Package name to the output for its doctest (`<package>.doctest.drv`):
    /// the predicted doctests of a test plan. Must cover every doctest of
    /// the plan.
    #[serde(default)]
    pub doctests: BTreeMap<String, String>,
}

/// The attributes a doctest derivation gets from the package's test
/// configuration (`doctestConfig` in `lib/test-runs.nix`), each the value of
/// [`doctest_key`] in `values.json`.
pub const DOCTEST_CONFIG: [&str; 3] = [
    "BREAKBULK_TEST_RUNNER",
    "BREAKBULK_TEST_ARGS",
    "BREAKBULK_TEST_ENV",
];

/// The `values.json` key of one doctest configuration attribute.
pub fn doctest_key(package: &str, attr: &str) -> String {
    format!("doctest:{package}:{attr}")
}

/// `values.json`: every input key's value, without string context, and the
/// context separately.
pub type Values = BTreeMap<String, InputValue>;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InputValue {
    pub value: String,
    #[serde(default)]
    pub context: Vec<Context>,
}

/// One element of a string's context, as `builtins.getContext` describes it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum Context {
    /// `{ path = true; }`: a store path, an input source.
    Opaque { path: String },
    /// `{ outputs = [ … ]; }`: outputs of a derivation, an input derivation.
    Built { drv: String, outputs: Vec<String> },
}

/// One derivation as `derivation` would produce it, with paths filled in
/// and output paths still to compute. Input paths are full store paths.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    pub name: String,
    pub system: String,
    pub builder: String,
    pub args: Vec<String>,
    /// Every attribute except `args`, lists joined with spaces. Output
    /// variables are not included.
    pub env: BTreeMap<String, String>,
    /// In declaration order.
    pub outputs: Vec<String>,
    pub input_drvs: BTreeMap<String, BTreeSet<String>>,
    pub input_srcs: BTreeSet<String>,
}

/// A derivation the outer builder writes, in the order it must write them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    /// A unit id, `stub:<root>` or `wrapper:<root>`.
    pub key: String,
    pub drv: Drv,
    /// For wrappers: the output of the outer derivation to submit it as.
    pub submit_as: Option<String>,
}

/// What the outer builder writes, in topological order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicPlan {
    pub nodes: Vec<Node>,
}

/// `breakbulk-root.json` in a wrapper's output.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RootInfo {
    pub package: String,
    pub target: String,
    pub kind: breakbulk_format::RootKind,
    pub test: bool,
    /// The root unit, when the plan has the root.
    pub unit: Option<String>,
    /// Why the plan lacks it, otherwise.
    pub reason: Option<String>,
    /// A test binary the plan has: what its test run needs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_spec: Option<TestSpec>,
    /// A product root the plan has: the `flags` outputs of the
    /// target-platform runs it depends on (`RootOut::build_script_runs`),
    /// for the product's `buildScriptFiles` stage and check (#23). They are
    /// built before the root unit anyway.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub build_script_flags: Vec<String>,
}

/// What a test run needs from the plan (`runSpec` in `lib/test-runs.nix`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestSpec {
    /// The test unit's recorded env that a test process gets at run time:
    /// `CARGO`, `CARGO_MANIFEST_DIR`, `CARGO_MANIFEST_PATH`, `CARGO_PKG_*`,
    /// `CARGO_BIN_EXE_*` (`isRuntimeVar` in `lib/test-runs.nix`).
    pub env: BTreeMap<String, String>,
    /// The project's `[env]` variables Cargo set on the test unit (the
    /// plan's `configEnv`), which `cargo test` also sets on the test
    /// process; not the runtime variables above, not the host's
    /// dynamic-library variable, which Cargo sets itself.
    pub config_env: BTreeMap<String, String>,
    /// `flags` outputs of the runs whose `rustc-env` values the process gets.
    pub env_flags: Vec<String>,
    /// `flags` of every run of the unit's platform, for the dynamic-library
    /// path. Each run's `directives.json` says which of its search paths go
    /// on it (`LibraryPath::for_dylib_path` in breakbulk-unit).
    pub dylib_flags: Vec<String>,
    /// The package's directory relative to the repository root (the source
    /// view's root), for test apps run in a checkout; None when
    /// `CARGO_MANIFEST_DIR` is not in a source view.
    pub package_dir: Option<String>,
    /// What nextest's reuse-build mode reads to run this binary.
    pub nextest: Nextest,
}

/// nextest's `--binaries-metadata` and `--cargo-metadata` for one test
/// binary, for both delivery modes (IFD mode gets it in `units.json`'s
/// roots, `RootNextest`). Placeholders the test run replaces: `@BINARY@`
/// (the binary), `@TARGET@` (a scratch target directory), `@WS@` (a
/// scratch workspace root), and the string `"@LIBDIR@"` (the whole JSON
/// value of the target's sysroot library directory, which only the Nix
/// side knows).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Nextest {
    pub binary_id: String,
    pub cargo_metadata: serde_json::Value,
    pub binaries: serde_json::Value,
}

/// The recorded variables a test process gets at run time: the list in
/// `runtime-env.json`, which the Nix library reads too (`isRuntimeVar` in
/// `lib/test-runs.nix`), so both delivery modes give a test the same env.
#[derive(serde::Deserialize)]
struct RuntimeEnv {
    exact: Vec<String>,
    prefixes: Vec<String>,
}

fn is_runtime_var(k: &str) -> bool {
    static LIST: std::sync::OnceLock<RuntimeEnv> = std::sync::OnceLock::new();
    let l = LIST.get_or_init(|| {
        serde_json::from_str(include_str!("runtime-env.json")).expect("runtime-env.json")
    });
    l.exact.iter().any(|e| e == k) || l.prefixes.iter().any(|p| k.starts_with(p.as_str()))
}

fn text(t: &Text, tokens: &Tokens) -> Result<String, Error> {
    use breakbulk_format::Resolve;
    Ok(match t {
        Text::Literal(s) => s.clone(),
        Text::Concat(pieces) => {
            let mut out = String::new();
            for p in pieces {
                match p {
                    Piece::Literal(s) => out.push_str(s),
                    Piece::Ref(r) => out.push_str(&tokens.reference(r)?),
                }
            }
            out
        }
    })
}

/// The test spec of a test root's unit, rendered with tokens. `tokens` must
/// resolve the package's source as its test units do (`test_package`).
fn test_spec(tokens: &Tokens, plan: &Plan, unit: &str, root: &RootOut) -> Result<TestSpec, Error> {
    let Some(Unit::Compile(c)) = plan.units.get(unit) else {
        return err(format!("the test root unit {unit} is not a compile unit"));
    };
    let mut env = BTreeMap::new();
    let mut config_env = BTreeMap::new();
    for (k, v) in &c.env {
        let into = if is_runtime_var(k) {
            &mut env
        } else if plan.config_env.contains(k) && k != breakbulk_format::HOST_DYLIB_PATH_VAR {
            &mut config_env
        } else {
            continue;
        };
        into.insert(
            k.clone(),
            tokens.tokenize_store_paths(unit, &text(v, tokens)?)?,
        );
    }
    let env_flags = c
        .env_splices
        .iter()
        .map(|s| tokens.unit(&s.splice, "flags"))
        .collect();
    let runs: Vec<&String> = plan
        .units
        .iter()
        .filter(|(_, u)| matches!(u, Unit::Run(r) if r.platform == c.platform))
        .map(|(id, _)| id)
        .collect();
    let package_dir = match c.env.get("CARGO_MANIFEST_DIR") {
        Some(Text::Concat(pieces)) => pieces.iter().find_map(|p| match p {
            Piece::Ref(Reference::Src(s)) => Some(s.rel.clone()),
            _ => None,
        }),
        _ => None,
    };
    Ok(TestSpec {
        env,
        config_env,
        env_flags,
        dylib_flags: runs.iter().map(|id| tokens.unit(id, "flags")).collect(),
        package_dir,
        nextest: nextest(tokens, plan, c, root)?,
    })
}

/// [`Nextest`] for a test root, with its source view as `tokens` resolve
/// it (dynamic-derivation mode).
fn nextest(
    tokens: &Tokens,
    plan: &Plan,
    unit: &CompileUnit,
    root: &RootOut,
) -> Result<Nextest, Error> {
    // The root of the tested package's source view (its test view when it
    // has one), under which every path package is listed.
    let view_root = tokens.reference(&Reference::Src(SrcRef {
        src: unit.package.clone(),
        rel: String::new(),
    }))?;
    nextest_for(plan, unit, root.kind, &root.target, &view_root)
}

/// The placeholder for the test's source view root in IFD mode's
/// [`crate::output::RootNextest`], which the Nix side replaces.
pub const VIEW_PLACEHOLDER: &str = "@VIEW@";

/// [`Nextest`] for a test binary (`unit`, root `kind`/`target`) whose source
/// view root is `view_root`: nextest-metadata's `BinaryListSummary` and a
/// `cargo metadata` document, as nextest 0.9.146 reads them
/// (nextest-runner/src/list/test_list.rs `from_binary_list`,
/// src/test_command.rs, src/list/rust_build_meta.rs):
///
/// - the binary path is absolute and used as is (no remap), so the binary
///   stays in its own store path (`@BINARY@`);
/// - the test's cwd and `CARGO_MANIFEST_DIR` are the package's manifest
///   directory in the cargo metadata: the package directory of its source
///   view, as for libtest runs. The workspace root is that view's root;
///   other path packages of the plan are listed under it too (their
///   directories need not exist), so `package()` filtersets match them;
/// - nextest sets `CARGO_PKG_*` from the package entry, so the entry is
///   built from the test unit's recorded `CARGO_PKG_*` values;
/// - no base output directories, linked paths, build-script out dirs or
///   libdirs: nextest then adds nothing to the dynamic-library path, and
///   keeps the environment the run already set, so the process sees what a
///   libtest run sees;
/// - dependency edges are not synthesized: `deps()` and `rdeps()`
///   filtersets see none;
/// - nextest requires `<workspace root>/Cargo.toml` to exist and writes its
///   store under it, so the workspace root is a scratch directory made at
///   build time (`@WS@`).
pub fn nextest_for(
    plan: &Plan,
    unit: &CompileUnit,
    root_kind: RootKind,
    root_target: &str,
    view_root: &str,
) -> Result<Nextest, Error> {
    use serde_json::{Value as J, json};
    let pkg_id = &unit.package;
    let env_of = |u: &CompileUnit, k: &str| match u.env.get(k) {
        Some(Text::Literal(s)) => s.clone(),
        _ => String::new(),
    };
    let or_null = |v: String| if v.is_empty() { J::Null } else { J::String(v) };
    let view_root = view_root.to_owned();
    // One unit per path package: the test unit for the tested package, else
    // its first compile unit by id.
    let mut path_pkgs: BTreeMap<&str, &CompileUnit> = BTreeMap::new();
    for u in plan.units.values() {
        if let Unit::Compile(c) = u
            && c.package.starts_with("path+file://")
        {
            path_pkgs.entry(c.package.as_str()).or_insert(c);
        }
    }
    let mut packages = Vec::new();
    for (id, u) in &path_pkgs {
        let u = if *id == pkg_id.as_str() { unit } else { u };
        let e = |k: &str| env_of(u, k);
        let Some(dir) = workspace_dir(plan, id) else {
            return err(format!(
                "nextest: {id} is not a path package under the skeleton"
            ));
        };
        let dir = if dir.is_empty() {
            view_root.clone()
        } else {
            format!("{view_root}/{dir}")
        };
        let authors: Vec<String> = e("CARGO_PKG_AUTHORS")
            .split(':')
            .filter(|a| !a.is_empty())
            .map(str::to_owned)
            .collect();
        packages.push(json!({
            "id": id,
            "name": e("CARGO_PKG_NAME"),
            "version": e("CARGO_PKG_VERSION"),
            "authors": authors,
            "description": or_null(e("CARGO_PKG_DESCRIPTION")),
            "homepage": or_null(e("CARGO_PKG_HOMEPAGE")),
            "repository": or_null(e("CARGO_PKG_REPOSITORY")),
            "license": or_null(e("CARGO_PKG_LICENSE")),
            "license_file": or_null(e("CARGO_PKG_LICENSE_FILE")),
            "rust_version": or_null(e("CARGO_PKG_RUST_VERSION")),
            "readme": null,
            "documentation": null,
            "source": null,
            "dependencies": [],
            "targets": [],
            "features": {},
            "manifest_path": format!("{dir}/Cargo.toml"),
            "metadata": null,
            "publish": null,
            "categories": [],
            "keywords": [],
            "edition": "2021",
            "links": null,
            "default_run": null,
        }));
    }
    let ids: Vec<&str> = path_pkgs.keys().copied().collect();
    let nodes: Vec<J> = ids
        .iter()
        .map(|id| json!({ "id": id, "dependencies": [], "deps": [], "features": [] }))
        .collect();
    let cargo_metadata = json!({
        "version": 1,
        "packages": packages,
        "workspace_members": ids,
        "workspace_default_members": ids,
        "resolve": { "nodes": nodes, "root": null },
        "workspace_root": "@WS@",
        "target_directory": "@TARGET@",
        "metadata": null,
    });
    let kind = kind_str(root_kind);
    let pkg_name = env_of(unit, "CARGO_PKG_NAME");
    let binary_id = match root_kind {
        RootKind::Lib => pkg_name.clone(),
        RootKind::Test => format!("{pkg_name}::{root_target}"),
        _ => format!("{pkg_name}::{kind}/{root_target}"),
    };
    let platform = |triple: &str| json!({ "triple": triple, "target-features": "unknown" });
    let libdir = |triple: &str| {
        if triple == plan.target {
            J::String("@LIBDIR@".into())
        } else {
            json!({ "status": "unavailable", "reason": "breakbulk" })
        }
    };
    let targets: Vec<J> = if plan.target != plan.host {
        vec![json!({ "platform": platform(&plan.target), "libdir": libdir(&plan.target) })]
    } else {
        vec![]
    };
    let build_platform = if unit.platform == Platform::Host && plan.target != plan.host {
        "host"
    } else {
        "target"
    };
    let mut rust_binaries = serde_json::Map::new();
    rust_binaries.insert(
        binary_id.clone(),
        json!({
            "binary-id": binary_id,
            "binary-name": root_target,
            "package-id": pkg_id,
            "kind": kind,
            "binary-path": "@BINARY@",
            "build-platform": build_platform,
        }),
    );
    let binaries = json!({
        "rust-build-meta": {
            "target-directory": "@TARGET@",
            "build-directory": "@TARGET@",
            "base-output-directories": [],
            "non-test-binaries": {},
            "build-script-out-dirs": {},
            "build-script-info": {},
            "linked-paths": [],
            "platforms": {
                "host": { "platform": platform(&plan.host), "libdir": libdir(&plan.host) },
                "targets": targets,
            },
            "target-platforms": [platform(&plan.target)],
            "target-platform": null,
        },
        "rust-binaries": rust_binaries,
    });
    Ok(Nextest {
        binary_id,
        cargo_metadata,
        binaries,
    })
}

/// The wrapper of one root.
fn wrapper(
    inputs: &Inputs,
    prefix: &str,
    outer: &Outer,
    root_name: &str,
    root: &RootOut,
    output_name: &str,
) -> Result<Drv, Error> {
    let mut tokens = Tokens::new(inputs, prefix);
    let (target, unit, reason) = match &root.what {
        RootWhat::Unit { unit, output } => (tokens.unit(unit, output), Some(unit.clone()), None),
        // A test stub succeeds and logs why, so test runs and test binaries
        // can use it; a product stub fails, so the wrapper leaves it out.
        RootWhat::Stub { reason, .. } if root.test => (
            tokens.unit(&format!("stub:{root_name}"), "out"),
            None,
            Some(reason.clone()),
        ),
        RootWhat::Stub { reason, .. } => (String::new(), None, Some(reason.clone())),
    };
    let spec = match (&unit, root.test) {
        (Some(u), true) => {
            // Test units see their package's test view (`sourceScope`).
            if let Some(Unit::Compile(c)) = inputs.plan.units.get(u) {
                tokens.test_package = Some(c.package.clone());
            }
            Some(test_spec(&tokens, &inputs.plan, u, root)?)
        }
        _ => None,
    };
    let info = RootInfo {
        package: root.package.clone(),
        target: root.target.clone(),
        kind: root.kind,
        test: root.test,
        unit,
        reason: reason.clone(),
        test_spec: spec,
        build_script_flags: root
            .build_script_runs
            .iter()
            .map(|id| tokens.unit(id, "flags"))
            .collect(),
    };
    // The debuginfo side files (`debug`) of the unit, when it has that
    // output, and of the libraries below a product root that have one
    // (`.dwo` with `split-debuginfo=unpacked`), for the
    // product's `linked` stage: one path per line.
    let traits = &inputs.toolchains.target_traits;
    let debug = match &info.unit {
        Some(u) => {
            let own = matches!(inputs.plan.units.get(u), Some(Unit::Compile(c)) if c.has_debug_output(traits));
            own.then(|| u.clone())
                .into_iter()
                .chain(root.debug_units.iter().cloned())
                .map(|id| tokens.unit(&id, crate::DEBUG_OUTPUT) + "\n")
                .collect()
        }
        None => String::new(),
    };
    let json = to_canonical_json(&info).map_err(|e| Error(e.to_string()))?;
    small_drv(
        inputs,
        &tokens,
        outer,
        output_name,
        WRAPPER_SCRIPT,
        [
            ("root", target),
            ("debugRoot", debug),
            ("notBuilt", reason.unwrap_or_default()),
            ("rootJson", json),
        ],
    )
    .map_err(|e| Error(format!("root {root_name}: {e}")))
}

/// Every wrapper's builder: `root` and `not-built` when their attributes
/// are set, `breakbulk-root.json` when `rootJson` is, and `debug`, a
/// directory linking every file of the `debug` outputs `debugRoot` lists
/// (one per line), when it lists any.
const WRAPPER_SCRIPT: &str = r#"mkdir "$out" && { [ -z "$root" ] || ln -s "$root" "$out/root"; } && { [ -z "$debugRoot" ] || { mkdir "$out/debug" && printf '%s' "$debugRoot" | while read -r d; do for f in "$d"/*; do [ ! -e "$f" ] || [ -e "$out/debug/${f##*/}" ] || ln -s "$f" "$out/debug/" || exit 1; done; done; }; } && { [ -z "$notBuilt" ] || printf '%s\n' "$notBuilt" > "$out/not-built"; } && { [ -z "$rootJson" ] || printf '%s' "$rootJson" > "$out/breakbulk-root.json"; }"#;

/// The doctest of one predicted library: the plan's doctest derivation with
/// the package's test configuration (None when the plan has no doctest for
/// the package), and its wrapper.
fn doctest(
    inputs: &Inputs,
    prefix: &str,
    units: &UnitsJson,
    outer: &Outer,
    package: &str,
    output_name: &str,
) -> Result<(Option<Drv>, Drv), Error> {
    let tokens = Tokens::new(inputs, prefix);
    let (drv, root, not_built) = match units.doctests.get(&format!("d-{package}")) {
        Some(d) => {
            let mut d = d.clone();
            for a in DOCTEST_CONFIG {
                d.attrs.insert(
                    a.into(),
                    Value::Parts {
                        parts: vec![Part::Input {
                            input: doctest_key(package, a),
                            json: false,
                        }],
                    },
                );
            }
            let root = tokens.unit(&doctest_node(package), "out");
            (Some(d), root, String::new())
        }
        None => (
            None,
            String::new(),
            format!(
                "`{package}` has no doctests in this plan: Cargo did not run `rustdoc --test` \
                 for it (`cargo test --doc` covers only the selected workspace members)"
            ),
        ),
    };
    let w = small_drv(
        inputs,
        &tokens,
        outer,
        output_name,
        WRAPPER_SCRIPT,
        [
            ("root", root),
            ("debugRoot", String::new()),
            ("notBuilt", not_built),
            ("rootJson", String::new()),
        ],
    )
    .map_err(|e| Error(format!("doctest {package}: {e}")))?;
    Ok((drv, w))
}

/// The node key of a package's doctest derivation.
fn doctest_node(package: &str) -> String {
    format!("doctest:{package}")
}

/// A derivation the outer derivation submits: named
/// `<outer name>-<output name without .drv>`, as Nix requires; bash with
/// coreutils on `PATH` runs `script`; `attrs` are tokenized text.
fn small_drv<const N: usize>(
    inputs: &Inputs,
    tokens: &Tokens,
    outer: &Outer,
    output_name: &str,
    script: &str,
    attrs: [(&str, String); N],
) -> Result<Drv, Error> {
    let base = output_name.strip_suffix(".drv").ok_or_else(|| {
        Error(format!(
            "the output name {output_name} does not end in .drv"
        ))
    })?;
    let path = format!("{}/bin", tokens.input(COREUTILS_KEY.into()));
    let builder = tokens.input(keys::tool(TOOL_SHELL));
    let mut out = BTreeMap::new();
    out.insert(
        "name".into(),
        Value::String(format!("{}-{base}", outer.name)),
    );
    out.insert(
        "args".into(),
        Value::Strings(vec!["-c".into(), script.into()]),
    );
    out.insert(
        "system".into(),
        Value::String(inputs.toolchains.system.clone()),
    );
    out.insert("outputs".into(), Value::Strings(vec!["out".into()]));
    for (k, v) in [("builder", builder), ("PATH", path)]
        .into_iter()
        .chain(attrs)
    {
        out.insert(
            k.into(),
            Value::Parts {
                parts: tokens.split(&v)?,
            },
        );
    }
    Ok(Drv { attrs: out })
}

/// The derivation that depends on every output of every unit of the plan;
/// `$out/units` lists them.
fn all_units(
    inputs: &Inputs,
    prefix: &str,
    outer: &Outer,
    output_name: &str,
) -> Result<Drv, Error> {
    let tokens = Tokens::new(inputs, prefix);
    let mut list = String::new();
    for (id, unit) in &inputs.plan.units {
        for o in unit_outputs(unit, &inputs.toolchains.target_traits) {
            list.push_str(&tokens.unit(id, &o));
            list.push('\n');
        }
    }
    small_drv(
        inputs,
        &tokens,
        outer,
        output_name,
        r#"mkdir "$out" && printf '%s' "$units" > "$out/units""#,
        [("units", list)],
    )
}

/// The derivations to write, units first in dependency order, then each
/// root's stub (if any) and wrapper.
pub fn dynamic_plan(
    inputs: &Inputs,
    units: &UnitsJson,
    outer: &Outer,
) -> Result<DynamicPlan, Error> {
    let prefix = token_prefix(inputs);
    let mut drvs: BTreeMap<String, Drv> = units.units.clone();
    let mut wrappers = Vec::new();
    let missing: Vec<&String> = units
        .roots
        .keys()
        .filter(|r| !outer.outputs.contains_key(*r))
        .collect();
    if !missing.is_empty() {
        return err(format!(
            "outer.json names no output for the roots {missing:?}; the Nix side predicted \
             other roots than instantiation found"
        ));
    }
    let mut taken = BTreeMap::new();
    for (name, root) in &units.roots {
        let output = &outer.outputs[name];
        if let Some(other) = taken.insert(output.clone(), name.clone()) {
            return err(format!(
                "the roots {other} and {name} have the same output name {output}"
            ));
        }
        if let RootWhat::Stub { stub, .. } = &root.what
            && root.test
        {
            drvs.insert(format!("stub:{name}"), stub.clone());
        }
        let w = wrapper(inputs, &prefix, outer, name, root, output)?;
        wrappers.push((format!("wrapper:{name}"), w, output.clone()));
    }
    let unpredicted: Vec<&str> = units
        .doctests
        .keys()
        .filter_map(|id| id.strip_prefix("d-"))
        .filter(|p| !outer.doctests.contains_key(*p))
        .collect();
    if !unpredicted.is_empty() {
        return err(format!(
            "the plan has doctests of {unpredicted:?}, which outer.json does not name; the \
             Nix side predicted the doctests {:?}",
            outer.doctests.keys().collect::<Vec<_>>()
        ));
    }
    for (package, output) in &outer.doctests {
        if let Some(other) = taken.insert(output.clone(), format!("{package} (doctest)")) {
            return err(format!(
                "the root {other} and the doctest of {package} have the same output name {output}"
            ));
        }
        let (d, w) = doctest(inputs, &prefix, units, outer, package, output)?;
        if let Some(d) = d {
            drvs.insert(doctest_node(package), d);
        }
        wrappers.push((format!("wrapper:{package}.doctest"), w, output.clone()));
    }
    let mut order = Vec::new();
    let mut state: BTreeMap<String, bool> = BTreeMap::new();
    for key in drvs.keys() {
        visit(key, &drvs, &mut state, &mut order)?;
    }
    let mut nodes: Vec<Node> = order
        .into_iter()
        .map(|key| Node {
            drv: drvs[&key].clone(),
            key,
            submit_as: None,
        })
        .collect();
    if let Some(output) = &outer.units {
        if taken.contains_key(output) {
            return err(format!("the units output {output} is also a root's output"));
        }
        wrappers.push((
            "wrapper:*units".into(),
            all_units(inputs, &prefix, outer, output)?,
            output.clone(),
        ));
    }
    for (key, drv, output) in wrappers {
        nodes.push(Node {
            key,
            drv,
            submit_as: Some(output),
        });
    }
    Ok(DynamicPlan { nodes })
}

fn refs(d: &Drv) -> impl Iterator<Item = &String> {
    d.attrs.values().flat_map(|v| match v {
        Value::Parts { parts } => parts
            .iter()
            .filter_map(|p| match p {
                Part::Unit { unit, .. } => Some(unit),
                _ => None,
            })
            .collect::<Vec<_>>(),
        _ => Vec::new(),
    })
}

/// Depth-first post-order; `state` is false while a key is on the stack.
fn visit(
    key: &str,
    drvs: &BTreeMap<String, Drv>,
    state: &mut BTreeMap<String, bool>,
    order: &mut Vec<String>,
) -> Result<(), Error> {
    match state.get(key) {
        Some(true) => return Ok(()),
        Some(false) => return err(format!("the units form a cycle through {key}")),
        None => {}
    }
    let Some(d) = drvs.get(key) else {
        return err(format!("reference to unknown unit {key}"));
    };
    state.insert(key.to_owned(), false);
    let deps: BTreeSet<&String> = refs(d).collect();
    for dep in deps {
        visit(dep, drvs, state, order)?;
    }
    state.insert(key.to_owned(), true);
    order.push(key.to_owned());
    Ok(())
}

/// The paths of a written derivation: its `.drv` path, and per output its
/// output path (or placeholder, when deferred).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Written {
    pub drv_path: String,
    pub outputs: BTreeMap<String, String>,
}

/// The string context a substitution collects.
#[derive(Default)]
struct Ctx {
    drvs: BTreeMap<String, BTreeSet<String>>,
    srcs: BTreeSet<String>,
}

/// Substitute `parts` as `part` in `lib/instantiate.nix` does. A join's
/// empty items are left out, with their context, as `filter` drops them.
fn substitute(
    parts: &[Part],
    values: &Values,
    written: &BTreeMap<String, Written>,
    ctx: &mut Ctx,
) -> Result<String, Error> {
    let mut s = String::new();
    for p in parts {
        match p {
            Part::Literal(l) => s.push_str(l),
            Part::Unit { unit, output, weak } => {
                let Some(w) = written.get(unit) else {
                    return err(format!("{unit} is referenced before it is written"));
                };
                let Some(path) = w.outputs.get(output) else {
                    return err(format!("{unit} has no output {output}"));
                };
                s.push_str(path);
                if !weak {
                    ctx.drvs
                        .entry(w.drv_path.clone())
                        .or_default()
                        .insert(output.clone());
                }
            }
            Part::Input { input, json } => {
                let Some(v) = values.get(input) else {
                    return err(format!(
                        "units.json names the input `{input}`, which values.json lacks"
                    ));
                };
                if *json {
                    let q = serde_json::to_string(&v.value).map_err(|e| Error(e.to_string()))?;
                    s.push_str(&q[1..q.len() - 1]);
                } else {
                    s.push_str(&v.value);
                }
                for c in &v.context {
                    match c {
                        Context::Opaque { path } => {
                            ctx.srcs.insert(path.clone());
                        }
                        Context::Built { drv, outputs } => {
                            ctx.drvs
                                .entry(drv.clone())
                                .or_default()
                                .extend(outputs.iter().cloned());
                        }
                    }
                }
            }
            Part::Join { join, sep } => {
                let mut items = Vec::new();
                for item in join {
                    let mut c = Ctx::default();
                    let v = substitute(item, values, written, &mut c)?;
                    if !v.is_empty() {
                        items.push(v);
                        ctx.srcs.extend(c.srcs);
                        for (drv, outs) in c.drvs {
                            ctx.drvs.entry(drv).or_default().extend(outs);
                        }
                    }
                }
                s.push_str(&items.join(sep));
            }
        }
    }
    Ok(s)
}

/// Resolve one derivation as `derivation (drvAttrs d)` does in
/// `lib/instantiate.nix`: substitute every part, collect string context
/// into input derivations and sources, and move `BREAKBULK_UNIT` to
/// `passAsFile` when it is long.
pub fn resolve(
    d: &Drv,
    values: &Values,
    written: &BTreeMap<String, Written>,
    pass_as_file_above: usize,
) -> Result<Resolved, Error> {
    let mut input_drvs: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut input_srcs = BTreeSet::new();
    let mut env = BTreeMap::new();
    let mut args = Vec::new();
    let mut outputs = vec!["out".to_owned()];
    for (k, v) in &d.attrs {
        let s = match v {
            Value::String(s) => s.clone(),
            Value::Strings(l) => {
                match k.as_str() {
                    "args" => {
                        args = l.clone();
                        continue;
                    }
                    "outputs" => outputs = l.clone(),
                    _ => {}
                }
                l.join(" ")
            }
            Value::Parts { parts } => {
                let mut ctx = Ctx::default();
                let s = substitute(parts, values, written, &mut ctx)?;
                input_srcs.extend(ctx.srcs);
                for (drv, outs) in ctx.drvs {
                    input_drvs.entry(drv).or_default().extend(outs);
                }
                s
            }
        };
        if k == "args" {
            return err("`args` must be a list");
        }
        env.insert(k.clone(), s);
    }
    if env
        .get("BREAKBULK_UNIT")
        .is_some_and(|u| u.len() > pass_as_file_above)
    {
        env.insert("passAsFile".into(), "BREAKBULK_UNIT".into());
    }
    let take = |k: &str| {
        env.get(k)
            .cloned()
            .ok_or_else(|| Error(format!("the derivation has no `{k}`")))
    };
    Ok(Resolved {
        name: take("name")?,
        system: take("system")?,
        builder: take("builder")?,
        args,
        outputs,
        input_drvs,
        input_srcs,
        env,
    })
}
