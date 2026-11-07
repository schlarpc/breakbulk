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
//! - `root`: a symlink to the root unit's output (or the stub's);
//! - `debug`: a symlink to the root unit's `debug` output (its debuginfo
//!   side files), when it has one;
//! - `breakbulk-root.json`: what the root is ([`RootInfo`]), and for a test
//!   binary what its test run needs ([`TestSpec`]), with real paths. The
//!   wrapper has every path in it as an input, so they are in its closure.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{Piece, Plan, Text, Unit, to_canonical_json};
use serde::{Deserialize, Serialize};

use crate::output::{Drv, Part, RootOut, RootWhat, UnitsJson, Value};
use crate::{Error, Inputs, TOOL_SHELL, Tokens, err, keys, token_prefix, unit_outputs};

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
    /// process; not the runtime variables above, not `LD_LIBRARY_PATH`.
    pub config_env: BTreeMap<String, String>,
    /// `flags` outputs of the runs whose `rustc-env` values the process gets.
    pub env_flags: Vec<String>,
    /// `flags` of every run of the unit's platform, for the dynamic-library
    /// path. Each run's `directives.json` says which of its search paths go
    /// on it (`LibraryPath::for_dylib_path` in breakbulk-unit).
    pub dylib_flags: Vec<String>,
}

fn is_runtime_var(k: &str) -> bool {
    k == "CARGO"
        || k == "CARGO_MANIFEST_DIR"
        || k == "CARGO_MANIFEST_PATH"
        || k.starts_with("CARGO_PKG_")
        || k.starts_with("CARGO_BIN_EXE_")
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

/// The test spec of a test root's unit, rendered with tokens.
fn test_spec(tokens: &Tokens, plan: &Plan, unit: &str) -> Result<TestSpec, Error> {
    let Some(Unit::Compile(c)) = plan.units.get(unit) else {
        return err(format!("the test root unit {unit} is not a compile unit"));
    };
    let mut env = BTreeMap::new();
    let mut config_env = BTreeMap::new();
    for (k, v) in &c.env {
        let into = if is_runtime_var(k) {
            &mut env
        } else if plan.config_env.contains(k) && k != "LD_LIBRARY_PATH" {
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
    Ok(TestSpec {
        env,
        config_env,
        env_flags,
        dylib_flags: runs.iter().map(|id| tokens.unit(id, "flags")).collect(),
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
    let tokens = Tokens::new(inputs, prefix);
    let (target, unit, reason) = match &root.what {
        RootWhat::Unit { unit, output } => (tokens.unit(unit, output), Some(unit.clone()), None),
        RootWhat::Stub { reason, .. } => (
            tokens.unit(&format!("stub:{root_name}"), "out"),
            None,
            Some(reason.clone()),
        ),
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
        reason,
        test_spec: spec,
    };
    // The unit's debuginfo side files (`debug`), for the product's `linked`
    // stage, when the unit has that output.
    let debug = match &info.unit {
        Some(u) if matches!(inputs.plan.units.get(u), Some(Unit::Compile(c)) if c.has_debug_output()) => {
            tokens.unit(u, crate::DEBUG_OUTPUT)
        }
        _ => String::new(),
    };
    let json = to_canonical_json(&info).map_err(|e| Error(e.to_string()))?;
    small_drv(
        inputs,
        &tokens,
        outer,
        output_name,
        r#"mkdir "$out" && ln -s "$root" "$out/root" && { [ -z "$debugRoot" ] || ln -s "$debugRoot" "$out/debug"; } && printf '%s' "$rootJson" > "$out/breakbulk-root.json""#,
        [("root", target), ("debugRoot", debug), ("rootJson", json)],
    )
    .map_err(|e| Error(format!("root {root_name}: {e}")))
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
        for o in unit_outputs(unit) {
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
        if let RootWhat::Stub { stub, .. } = &root.what {
            drvs.insert(format!("stub:{name}"), stub.clone());
        }
        let w = wrapper(inputs, &prefix, outer, name, root, output)?;
        wrappers.push((format!("wrapper:{name}"), w, output.clone()));
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
