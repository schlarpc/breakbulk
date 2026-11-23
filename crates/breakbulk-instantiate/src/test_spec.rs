//! What a test binary's run needs from the plan ([`TestSpec`]), for both
//! delivery modes: it is written into the root wrapper's
//! `breakbulk-root.json` ([`crate::shape`]), which test runs and test apps
//! read at build time.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{
    CompileUnit, Piece, Plan, Platform, Reference, Resolve, RootKind, SrcRef, Text, Unit,
};
use serde::Serialize;

use crate::{Error, Inputs, Tokens, err, kind_str, workspace_dir};

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
    /// What nextest's reuse-build mode reads to run this binary.
    pub nextest: Nextest,
}

/// nextest's `--binaries-metadata` and `--cargo-metadata` for one test
/// binary. Placeholders the test run replaces: `@BINARY@`
/// (the binary), `@TARGET@` (a scratch target directory), `@WS@` (a
/// scratch workspace root), and the string `"@LIBDIR@"` (the whole JSON
/// value of the sysroot library directory of the binary's platform, which
/// only the Nix side knows).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Nextest {
    pub binary_id: String,
    pub cargo_metadata: serde_json::Value,
    pub binaries: serde_json::Value,
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

/// The test spec of a test root (`unit`, root `kind`/`target`), rendered
/// with tokens: the one function both delivery modes take it from (IFD
/// mode's `RootTestSpec` in `units.json`, dynamic mode's
/// `breakbulk-root.json`). `tokens` must resolve the package's source as
/// its test units do ([`test_tokens`]).
pub(crate) fn test_spec(
    tokens: &Tokens,
    plan: &Plan,
    unit: &str,
    kind: RootKind,
    target: &str,
) -> Result<TestSpec, Error> {
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
        nextest: nextest(tokens, plan, c, kind, target)?,
    })
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

/// [`Nextest`] for a test root, with its source view as `tokens` resolve
/// it.
fn nextest(
    tokens: &Tokens,
    plan: &Plan,
    unit: &CompileUnit,
    kind: RootKind,
    target: &str,
) -> Result<Nextest, Error> {
    // The root of the tested package's source view (its test view when it
    // has one), under which every path package is listed.
    let view_root = tokens.reference(&Reference::Src(SrcRef {
        src: unit.package.clone(),
        rel: String::new(),
    }))?;
    nextest_for(plan, unit, kind, target, &view_root)
}

/// [`Nextest`] for a test binary (`unit`, root `kind`/`target`) whose source
/// view root is `view_root`: nextest-metadata's `BinaryListSummary` and a
/// `cargo metadata` document, as nextest 0.9.146 reads them
/// (nextest-runner/src/list/test_list.rs `from_binary_list`,
/// src/test_command.rs, src/list/rust_build_meta.rs, nextest-filtering
/// src/compile.rs). Only what the run can observe is in it, so that the
/// run's derivation changes only with that:
///
/// - the binary path is absolute and used as is (no remap), so the binary
///   stays in its own store path (`@BINARY@`);
/// - the test's cwd and `CARGO_MANIFEST_DIR` are the tested package's
///   manifest directory in the cargo metadata: the package directory of its
///   source view, as for libtest runs. nextest sets `CARGO_PKG_*` from the
///   package entry, so the entry is built from the test unit's recorded
///   `CARGO_PKG_*` values;
/// - the other path packages of the plan are there for filtersets only:
///   `package()`, `deps()` and `rdeps()` match package names, and
///   `binary()` and `binary_id()` are checked against the targets. Nothing
///   reads their manifest paths, versions or ids, so each is listed by name
///   alone (its id is its name, its version `0.0.0`), with its manifest
///   under the scratch workspace root. Path packages outside the skeleton
///   are the standard library's, from `-Zbuild-std`: `cargo metadata`
///   resolves the workspace alone (cargo `ops/cargo_metadata.rs` has no
///   build-std resolve), so they are left out;
/// - each package lists its Cargo targets ([`Plan::path_packages`]): nextest
///   checks the names `binary()` and `binary_id()` filtersets use against
///   them (nextest-filtering `ParseContextCache::new`), and fails a run
///   whose configuration names a binary it does not know. Nothing reads
///   their source paths, which are under the scratch workspace root;
/// - dependency edges for `deps()` and `rdeps()`. A filterset is only
///   evaluated for the run's own binary, so `deps(x)` asks only whether a
///   package named `x` reaches the tested package, and `rdeps(x)` whether
///   the tested package reaches one (guppy's `depends_on`: transitive, any
///   dependency kind, and true from a package to itself, so neither set is
///   empty when `x` names a package). Each package that reaches the tested
///   one is given a direct edge to it, and the tested package one to each
///   package it reaches; edges between other packages are left out. guppy
///   matches each resolve edge to a declared dependency by the dependency's
///   library name and version requirement, so each edge is declared with
///   `*` and no rename, under the library's own name;
/// - no base output directories, linked paths, build-script out dirs or
///   libdirs: nextest then adds nothing to the dynamic-library path, and
///   keeps the environment the run already set, so the process sees what a
///   libtest run sees;
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
    let pkg_id = unit.package.as_str();
    let env_of = |u: &CompileUnit, k: &str| match u.env.get(k) {
        Some(Text::Literal(s)) => s.clone(),
        _ => String::new(),
    };
    let or_null = |v: String| if v.is_empty() { J::Null } else { J::String(v) };
    // One unit (for the package's name) and directory per path package
    // under the skeleton: the test unit for the tested package, else its
    // first compile unit by id.
    let mut path_pkgs: BTreeMap<&str, (&CompileUnit, &str)> = BTreeMap::new();
    for u in plan.units.values() {
        if let Unit::Compile(c) = u
            && let Some(dir) = workspace_dir(plan, &c.package)
        {
            path_pkgs.entry(c.package.as_str()).or_insert((c, dir));
        }
    }
    if !path_pkgs.contains_key(pkg_id) {
        return err(format!(
            "nextest: {pkg_id} is not a path package under the skeleton"
        ));
    }
    let name_of = |id: &str| {
        if id == pkg_id {
            env_of(unit, "CARGO_PKG_NAME")
        } else {
            path_pkgs
                .get(id)
                .map(|(u, _)| env_of(u, "CARGO_PKG_NAME"))
                .unwrap_or_default()
        }
    };
    // The id a package is listed under.
    let listed = |id: &str| {
        if id == pkg_id {
            id.to_owned()
        } else {
            name_of(id)
        }
    };
    let path_package = |id: &str| plan.path_packages.get(id);
    let lib_name = |id: &str| {
        path_package(id)
            .and_then(|p| p.targets.iter().find(|t| is_lib_target(&t.kind)))
            .map(|t| t.name.replace('-', "_"))
            .unwrap_or_default()
    };
    // The edges whose both ends are listed, forward and reversed.
    let mut forward: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    let mut reverse: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for id in path_pkgs.keys() {
        for d in path_package(id)
            .map(|p| &p.dependencies[..])
            .unwrap_or_default()
        {
            if let Some((&to, _)) = path_pkgs.get_key_value(d.package.as_str()) {
                forward.entry(id).or_default().push(to);
                reverse.entry(to).or_default().push(id);
            }
        }
    }
    fn reached<'a>(edges: &BTreeMap<&'a str, Vec<&'a str>>, from: &'a str) -> BTreeSet<&'a str> {
        let mut seen = BTreeSet::new();
        let mut todo = vec![from];
        while let Some(id) = todo.pop() {
            for &n in edges.get(id).map(|v| &v[..]).unwrap_or_default() {
                if seen.insert(n) {
                    todo.push(n);
                }
            }
        }
        seen.remove(from);
        seen
    }
    let below = reached(&forward, pkg_id);
    let above = reached(&reverse, pkg_id);
    let deps_of = |id: &str| -> Vec<&str> {
        if id == pkg_id {
            below.iter().copied().collect()
        } else if above.contains(id) {
            vec![pkg_id]
        } else {
            vec![]
        }
    };
    let mut packages = Vec::new();
    for (id, (_, dir)) in &path_pkgs {
        let manifest = |root: &str| {
            if dir.is_empty() {
                format!("{root}/Cargo.toml")
            } else {
                format!("{root}/{dir}/Cargo.toml")
            }
        };
        let targets: Vec<J> = path_package(id)
            .map(|p| &p.targets[..])
            .unwrap_or_default()
            .iter()
            .map(|t| {
                json!({
                    "name": t.name,
                    "kind": t.kind,
                    "crate_types": t.crate_types,
                    "src_path": format!("@WS@/{}", t.src_path.trim_start_matches('/')),
                })
            })
            .collect();
        let dependencies: Vec<J> = deps_of(id)
            .into_iter()
            .map(|d| {
                json!({
                    "name": name_of(d),
                    "source": null,
                    "req": "*",
                    "kind": null,
                    "optional": false,
                    "uses_default_features": true,
                    "features": [],
                    "target": null,
                    "rename": null,
                    "registry": null,
                    "path": null,
                })
            })
            .collect();
        let mut entry = json!({
            "id": listed(id),
            "name": name_of(id),
            "version": "0.0.0",
            "authors": [],
            "description": null,
            "homepage": null,
            "repository": null,
            "license": null,
            "license_file": null,
            "rust_version": null,
            "readme": null,
            "documentation": null,
            "source": null,
            "dependencies": dependencies,
            "targets": targets,
            "features": {},
            "manifest_path": manifest("@WS@"),
            "metadata": null,
            "publish": null,
            "categories": [],
            "keywords": [],
            "edition": "2021",
            "links": null,
            "default_run": null,
        });
        if *id == pkg_id {
            let e = |k: &str| env_of(unit, k);
            let authors: Vec<String> = e("CARGO_PKG_AUTHORS")
                .split(':')
                .filter(|a| !a.is_empty())
                .map(str::to_owned)
                .collect();
            let fields = json!({
                "version": e("CARGO_PKG_VERSION"),
                "authors": authors,
                "description": or_null(e("CARGO_PKG_DESCRIPTION")),
                "homepage": or_null(e("CARGO_PKG_HOMEPAGE")),
                "repository": or_null(e("CARGO_PKG_REPOSITORY")),
                "license": or_null(e("CARGO_PKG_LICENSE")),
                "license_file": or_null(e("CARGO_PKG_LICENSE_FILE")),
                "rust_version": or_null(e("CARGO_PKG_RUST_VERSION")),
                "manifest_path": manifest(view_root),
            });
            for (k, v) in fields.as_object().into_iter().flatten() {
                entry[k] = v.clone();
            }
        }
        packages.push(entry);
    }
    let ids: Vec<String> = path_pkgs.keys().map(|id| listed(id)).collect();
    let nodes: Vec<J> = path_pkgs
        .keys()
        .map(|id| {
            let deps = deps_of(id);
            json!({
                "id": listed(id),
                "dependencies": deps.iter().map(|d| listed(d)).collect::<Vec<_>>(),
                "deps": deps
                    .iter()
                    .map(|d| json!({
                        "name": lib_name(d),
                        "pkg": listed(d),
                        "dep_kinds": [{ "kind": null, "target": null }],
                    }))
                    .collect::<Vec<_>>(),
                "features": [],
            })
        })
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
    // The Nix side knows the sysroot library directory of the binary's
    // own platform only.
    let own = match unit.platform {
        Platform::Host => &plan.host,
        Platform::Target => &plan.target,
    };
    let libdir = |triple: &str| {
        if triple == own {
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

/// Whether a `cargo metadata` target kind list is a library's (its crate
/// types) rather than a bin, example, test, bench or build script.
fn is_lib_target(kind: &[String]) -> bool {
    !kind.iter().any(|k| {
        matches!(
            k.as_str(),
            "bin" | "example" | "test" | "bench" | "custom-build"
        )
    })
}
