//! The shape of a root, the same in both delivery modes. Because Nix
//! requires an output a dynamic derivation submits to be named
//! `<outer name>-<output name>` (spike B, finding 2), each root is a small
//! wrapper derivation, and IFD mode describes the same wrapper in
//! `units.json`, so that everything after a root (test runs, test apps,
//! doctests, products, `buildScriptPaths`) has one implementation, which
//! reads the root at build time. Its output is a directory:
//!
//! - `root`: a symlink to the root unit's output, or for a test binary
//!   Cargo did not build to its stub's (which succeeds and logs why);
//! - `not-built`: for a root Cargo did not build (required features), the
//!   reason. A product root has no `root` then and does not depend on its
//!   stub, so products leave it out at build time;
//! - `debug`: a symlink to the root unit's `debug` output (its debuginfo
//!   side files), when it has one;
//! - `breakbulk-root.json`: what the root is ([`RootInfo`]), and for a test
//!   binary what its test run and test app need ([`TestSpec`]), with real
//!   paths. The wrapper has every path in it as an input, so they are in its
//!   closure.
//!
//! Each predicted doctest (a library of the test plan) gets the same: the
//! plan's doctest derivation with the package's test configuration
//! (runner, arguments, env) as input values, and a wrapper
//! `<outer name>-<package>.doctest` whose `root` links its output, or whose
//! `not-built` says why the plan has none. A doc plan's docs derivation
//! gets a wrapper `<outer name>-docs` whose `root` links its output. Two
//! more name every unit's outputs (`units.drv`) and every build-script
//! run's `flags` (`runs.drv`).

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::rendered::package_name_version;
use breakbulk_format::{Unit, to_canonical_json};
use serde::{Deserialize, Serialize};

use crate::output::{Drv, Part, RootOut, RootWhat, UnitsJson, Value};
use crate::test_spec::{TestSpec, test_spec, test_tokens};
use crate::{Error, Inputs, TOOL_SHELL, Tokens, err, keys, token_prefix, unit_outputs};

/// The key of the coreutils store path the wrappers use.
pub const COREUTILS_KEY: &str = "wrapper:coreutils";

/// `outer.json`: the name the wrappers are named after (in dynamic mode the
/// outer derivation's, which submits them as its outputs) and the output
/// name of each.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Outer {
    /// `<ws>-<triple>-<variant>[-test]`: a wrapper of output `<o>.drv` is
    /// named `<name>-<o>`.
    pub name: String,
    /// Root name (`<package>/<kind>/<target>`) to its output name
    /// (`<…>.drv`). Must cover every root of the instantiation.
    pub outputs: BTreeMap<String, String>,
    /// The output for a derivation that depends on every output of every
    /// unit (`units.drv`): building it builds the whole plan, as check and
    /// clippy variants need (they have no roots). None: no such output.
    #[serde(default)]
    pub units: Option<String>,
    /// The output for a derivation that depends on the `flags` output of
    /// every build-script run of the plan, on both platforms (`runs.drv`):
    /// what the plan's `buildScriptPaths` check reads, without building
    /// the rest of the plan. None: no such output.
    #[serde(default)]
    pub runs: Option<String>,
    /// Package name to the output for its doctest (`<package>.doctest.drv`):
    /// the predicted doctests of a test plan. Must cover every doctest of
    /// the plan.
    #[serde(default)]
    pub doctests: BTreeMap<String, String>,
    /// Doc plans: the output for the docs derivation's wrapper
    /// (`docs.drv`), whose `root` links the docs derivation's output.
    #[serde(default)]
    pub docs: Option<String>,
    /// Packages (by name) whose units this outer derivation does not write,
    /// nor their roots and doctests, nor the docs: another outer derivation
    /// of the same plan writes them, with settings this one must not take
    /// (settings that use this one's products). A unit of another package
    /// that depends on one of them is an error.
    #[serde(default)]
    pub leave: BTreeSet<String>,
    /// The packages whose roots and doctests this outer derivation
    /// submits; None: every package's. It still writes every unit they
    /// depend on: it cannot read another outer derivation's.
    #[serde(default)]
    pub submit: Option<BTreeSet<String>>,
}

impl Outer {
    /// Whether this outer derivation submits the roots and doctest of
    /// package `name`.
    fn submits(&self, name: &str) -> bool {
        !self.leave.contains(name) && self.submit.as_ref().is_none_or(|s| s.contains(name))
    }
}

/// The attributes a doctest derivation gets from the package's test
/// configuration (`doctestConfig` in `lib/test-runs.nix`), each the value of
/// [`doctest_key`] in `values.json`.
pub const DOCTEST_CONFIG: [&str; 4] = [
    "BREAKBULK_TEST_RUNNERS",
    "BREAKBULK_TEST_ARGS",
    "BREAKBULK_TEST_ENV",
    "BREAKBULK_TEST_POST_RUN",
];

/// The `values.json` key of one doctest configuration attribute.
pub fn doctest_key(package: &str, attr: &str) -> String {
    format!("doctest:{package}:{attr}")
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

/// The wrapper of one root.
fn wrapper(
    inputs: &Inputs,
    prefix: &str,
    outer: &Outer,
    root_name: &str,
    root: &RootOut,
    output_name: &str,
) -> Result<Drv, Error> {
    let tokens = match &root.what {
        RootWhat::Unit { unit, .. } if root.test => test_tokens(inputs, prefix, unit),
        _ => Tokens::new(inputs, prefix),
    };
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
        (Some(u), true) => Some(test_spec(&tokens, &inputs.plan, u)?),
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
    let debuginfo = &inputs.plan.target_debuginfo;
    let debug = match &info.unit {
        Some(u) => {
            let own = matches!(inputs.plan.units.get(u), Some(Unit::Compile(c)) if c.has_debug_output(debuginfo));
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
                 for it (`cargo test` doc-tests only the selected workspace members)"
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

/// The node key of a doc plan's docs derivation.
const DOCS_NODE: &str = "docs";

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
    left: &BTreeSet<String>,
) -> Result<Drv, Error> {
    let tokens = Tokens::new(inputs, prefix);
    let mut list = String::new();
    for (id, unit) in &inputs.plan.units {
        if left.contains(id) {
            continue;
        }
        for o in unit_outputs(unit, &inputs.plan.target_debuginfo) {
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

/// The derivation that depends on the `flags` output of every build-script
/// run of the plan; `$out/runs` lists them. Not `$out/units`: that one
/// builds every compile of the plan too.
fn all_runs(
    inputs: &Inputs,
    prefix: &str,
    outer: &Outer,
    output_name: &str,
    left: &BTreeSet<String>,
) -> Result<Drv, Error> {
    let tokens = Tokens::new(inputs, prefix);
    let mut list = String::new();
    for (id, unit) in &inputs.plan.units {
        if let Unit::Run(_) = unit
            && !left.contains(id)
        {
            list.push_str(&tokens.unit(id, "flags"));
            list.push('\n');
        }
    }
    small_drv(
        inputs,
        &tokens,
        outer,
        output_name,
        r#"mkdir "$out" && printf '%s' "$runs" > "$out/runs""#,
        [("runs", list)],
    )
}

/// The ids of the units of the packages outer.json leaves to another outer
/// derivation.
pub(crate) fn left_units(inputs: &Inputs, outer: &Outer) -> BTreeSet<String> {
    if outer.leave.is_empty() {
        return BTreeSet::new();
    }
    inputs
        .plan
        .units
        .iter()
        .filter(|(_, u)| {
            package_name_version(u.package()).is_some_and(|(n, _)| outer.leave.contains(n))
        })
        .map(|(id, _)| id.clone())
        .collect()
}

/// What a root's shape adds to the units of one outer derivation: the
/// derivations the wrappers name besides units (`nodes`: test stubs
/// `stub:<root>`, doctests `doctest:<package>`, the docs `docs`), and the
/// wrappers, in the order to write them, each with its node key and the
/// output it is submitted as.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Shape {
    pub nodes: BTreeMap<String, Drv>,
    pub wrappers: Vec<(String, Drv, String)>,
}

/// Every root's, doctest's and the docs' wrapper for `outer`, and the
/// `units.drv` and `runs.drv` wrappers.
pub fn shape(inputs: &Inputs, units: &UnitsJson, outer: &Outer) -> Result<Shape, Error> {
    let prefix = token_prefix(inputs);
    let left = left_units(inputs, outer);
    let mut nodes: BTreeMap<String, Drv> = BTreeMap::new();
    let mut wrappers = Vec::new();
    let roots: BTreeMap<&String, &RootOut> = units
        .roots
        .iter()
        .filter(|(_, r)| outer.submits(&r.package))
        .collect();
    let missing: Vec<&String> = roots
        .keys()
        .filter(|r| !outer.outputs.contains_key(**r))
        .copied()
        .collect();
    if !missing.is_empty() {
        return err(format!(
            "outer.json names no output for the roots {missing:?}; the Nix side predicted \
             other roots than instantiation found"
        ));
    }
    let mut taken = BTreeMap::new();
    for (name, root) in roots {
        let output = &outer.outputs[name];
        if let Some(other) = taken.insert(output.clone(), name.clone()) {
            return err(format!(
                "the roots {other} and {name} have the same output name {output}"
            ));
        }
        if let RootWhat::Stub { stub, .. } = &root.what
            && root.test
        {
            nodes.insert(format!("stub:{name}"), stub.clone());
        }
        let w = wrapper(inputs, &prefix, outer, name, root, output)?;
        wrappers.push((format!("wrapper:{name}"), w, output.clone()));
    }
    let unpredicted: Vec<&str> = units
        .doctests
        .keys()
        .filter_map(|id| id.strip_prefix("d-"))
        .filter(|p| outer.submits(p) && !outer.doctests.contains_key(*p))
        .collect();
    if !unpredicted.is_empty() {
        return err(format!(
            "the plan has doctests of {unpredicted:?}, which outer.json does not name; the \
             Nix side predicted the doctests {:?}. This is a bug in breakbulk's doctest \
             prediction; list the packages in the workspace's `roots.doctests` option to \
             work around it",
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
            nodes.insert(doctest_node(package), d);
        }
        wrappers.push((format!("wrapper:{package}.doctest"), w, output.clone()));
    }
    // The docs read every package's rustdoc output: with packages left,
    // the other outer derivation writes them.
    let docs = if outer.leave.is_empty() {
        &units.docs
    } else {
        &None
    };
    match (docs, &outer.docs) {
        (None, None) => {}
        (Some(d), Some(output)) => {
            if let Some(other) = taken.insert(output.clone(), "the docs".into()) {
                return err(format!(
                    "the root {other} and the docs have the same output name {output}"
                ));
            }
            nodes.insert(DOCS_NODE.into(), d.clone());
            let tokens = Tokens::new(inputs, &prefix);
            let w = small_drv(
                inputs,
                &tokens,
                outer,
                output,
                WRAPPER_SCRIPT,
                [
                    ("root", tokens.unit(DOCS_NODE, "out")),
                    ("debugRoot", String::new()),
                    ("notBuilt", String::new()),
                    ("rootJson", String::new()),
                ],
            )
            .map_err(|e| Error(format!("docs: {e}")))?;
            wrappers.push((format!("wrapper:{DOCS_NODE}"), w, output.clone()));
        }
        (Some(_), None) => {
            return err("the plan has docs, but outer.json names no output for them");
        }
        (None, Some(output)) => {
            return err(format!(
                "outer.json names the docs output {output}, but the plan is no doc plan"
            ));
        }
    }
    if let Some(output) = &outer.units {
        if taken.contains_key(output) {
            return err(format!("the units output {output} is also a root's output"));
        }
        wrappers.push((
            "wrapper:*units".into(),
            all_units(inputs, &prefix, outer, output, &left)?,
            output.clone(),
        ));
    }
    if let Some(output) = &outer.runs {
        if taken.contains_key(output) || outer.units.as_ref() == Some(output) {
            return err(format!(
                "the runs output {output} is also a root's or the units output"
            ));
        }
        wrappers.push((
            "wrapper:*runs".into(),
            all_runs(inputs, &prefix, outer, output, &left)?,
            output.clone(),
        ));
    }
    Ok(Shape { nodes, wrappers })
}
