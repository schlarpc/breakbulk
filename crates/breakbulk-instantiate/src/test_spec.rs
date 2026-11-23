//! What a test binary's run needs from the plan ([`TestSpec`]), for both
//! delivery modes: it is written into the root wrapper's
//! `breakbulk-root.json` ([`crate::shape`]), which test runs and test apps
//! read at build time.

use std::collections::BTreeMap;

use breakbulk_format::rendered::package_name_version;
use breakbulk_format::{PathTarget, Piece, Plan, Reference, Text, Unit};
use serde::Serialize;

use crate::{Error, Inputs, Tokens, err, workspace_dir};

/// What a test run needs from the plan, for both delivery modes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestSpec {
    /// The test unit's recorded env that a test process gets at run time:
    /// `CARGO`, `CARGO_MANIFEST_DIR`, `CARGO_MANIFEST_PATH`, `CARGO_PKG_*`,
    /// `CARGO_BIN_EXE_*` (`runtime-env.json`).
    pub env: BTreeMap<String, String>,
    /// The project's `[env]` variables Cargo set on the test unit (the
    /// plan's `configEnv`), which `cargo test` also sets on the test
    /// process; not the runtime variables above, not the host's
    /// dynamic-library variable, which Cargo sets itself.
    pub config_env: BTreeMap<String, String>,
    /// `flags` outputs of the runs whose `rustc-env` values the process gets.
    pub env_flags: Vec<String>,
    /// `flags` of the runs of the unit's platform that it depends on
    /// (`deps::units_below`, the bins it names in `CARGO_BIN_EXE_<name>`
    /// included), for the dynamic-library path. Not every run of the plan,
    /// as Cargo's shared `target/<profile>` gives: a library the test was
    /// linked against was found through its own closure's runs. Each run's
    /// `directives.json` says which of its search paths go on it
    /// (`LibraryPath::for_dylib_path` in breakbulk-unit).
    pub dylib_flags: Vec<String>,
    /// The package's directory relative to the repository root (the source
    /// view's root), for test apps run in a checkout; None when
    /// `CARGO_MANIFEST_DIR` is not in a source view. Also for the hints of
    /// a failed run (`breakbulk-hints`).
    pub package_dir: Option<String>,
    /// The package's test-only paths, relative to the repository root, for
    /// those hints: as a rendered unit's `view.testOnly`, without store
    /// paths, which a content-addressed run must not depend on.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub test_only: Vec<String>,
    /// As a rendered unit's `view.junk`, for those hints.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub junk: Vec<String>,
    /// As a rendered unit's `view.custom`, for those hints.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub custom: bool,
    /// The tested package's id.
    pub package_id: String,
    /// Every path package the plan compiles ([`Plan::path_packages`]), by
    /// name: what a test runner that reads the package graph needs
    /// (`breakbulk.lib.testRunners.nextest` builds `cargo metadata` from
    /// it). By name, not id: an id has the version, so another package's
    /// version bump would change every test binary's wrapper, and so
    /// re-run every test without content addressing. A test run reads it
    /// only through such a runner.
    pub path_packages: BTreeMap<String, PathNode>,
}

/// One path package in [`TestSpec::path_packages`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PathNode {
    /// Its directory relative to the skeleton root.
    pub dir: String,
    /// Its Cargo targets, as `cargo metadata` lists them, with their
    /// source paths relative to the skeleton root.
    pub targets: Vec<PathTarget>,
    /// The names of the path packages it depends on (any kind).
    pub dependencies: Vec<String>,
}

/// The recorded variables a test process gets at run time: the list in
/// `runtime-env.json` (its `description` says why each is there).
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

/// The test spec of a test root unit, rendered with tokens, for its
/// wrapper's `breakbulk-root.json`. `tokens` must resolve the package's
/// source as its test units do ([`test_tokens`]).
pub(crate) fn test_spec(tokens: &Tokens, plan: &Plan, unit: &str) -> Result<TestSpec, Error> {
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
    let runs = breakbulk_format::deps::runs_of(
        plan,
        breakbulk_format::deps::units_below(plan, &unit.to_owned()),
        c.platform,
    );
    let package_dir = match c.env.get("CARGO_MANIFEST_DIR") {
        Some(Text::Concat(pieces)) => pieces.iter().find_map(|p| match p {
            Piece::Ref(Reference::Src(s)) => Some(s.rel.clone()),
            _ => None,
        }),
        _ => None,
    };
    let dir = workspace_dir(plan, &c.package);
    Ok(TestSpec {
        env,
        config_env,
        env_flags,
        dylib_flags: runs.iter().map(|id| tokens.unit(id, "flags")).collect(),
        package_dir,
        test_only: dir.map(|d| tokens.test_only(d)).unwrap_or_default(),
        junk: dir.map(|d| tokens.junk(d)).unwrap_or_default(),
        custom: dir.is_some_and(|d| tokens.inputs.sources.custom.contains(d)),
        package_id: c.package.clone(),
        path_packages: path_packages(plan),
    })
}

/// [`TestSpec::path_packages`]: the plan's path packages under the
/// skeleton (the standard library's under `-Zbuild-std` are outside it,
/// and `cargo metadata` resolves the workspace alone), by name.
pub(crate) fn path_packages(plan: &Plan) -> BTreeMap<String, PathNode> {
    let name = |id: &str| package_name_version(id).map(|(n, _)| n.to_owned());
    plan.path_packages
        .iter()
        .filter_map(|(id, p)| {
            let dir = workspace_dir(plan, id)?;
            Some((
                name(id)?,
                PathNode {
                    dir: dir.to_owned(),
                    targets: p.targets.clone(),
                    dependencies: p
                        .dependencies
                        .iter()
                        .filter_map(|d| name(&d.package))
                        .collect(),
                },
            ))
        })
        .collect()
}

/// Tokens for a test root's spec: its package's source resolves to the
/// package's test view (`sourceScope`), as for its test units.
pub(crate) fn test_tokens<'a>(inputs: &'a Inputs, prefix: &'a str, unit: &str) -> Tokens<'a> {
    let mut tokens = Tokens::new(inputs, prefix);
    if let Some(Unit::Compile(c)) = inputs.plan.units.get(unit) {
        tokens.test_package = Some(c.package.clone());
    }
    tokens
}
