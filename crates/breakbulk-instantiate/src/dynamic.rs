//! Dynamic-derivation mode, the part that needs no store.
//!
//! In IFD mode the Nix side substitutes every reference in `units.json` and
//! applies `derivation` to the result (`lib/instantiate.nix`). Dynamic mode
//! does the same here, in the builder of the outer derivation: it takes the
//! same [`UnitsJson`] and root shape ([`crate::shape`]), the values of the
//! input keys (with their string context, as `builtins.getContext` gives
//! it), and the output paths of the derivations written so far, and
//! produces each derivation exactly as `derivation` would: the same `env`,
//! `args`, input derivations and input sources. Hashing and writing are
//! left to the caller (`breakbulk-drv`, which uses harmonia), so this crate
//! keeps no store dependency.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;

use crate::output::{Drv, Part, UnitsJson, Value};
use crate::shape::{Outer, left_units, shape};
use crate::{Error, Inputs, err};

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

/// The derivations to write, units, stubs, doctests and docs first in
/// dependency order, then the wrappers.
pub fn dynamic_plan(
    inputs: &Inputs,
    units: &UnitsJson,
    outer: &Outer,
) -> Result<DynamicPlan, Error> {
    let left = left_units(inputs, outer);
    let mut drvs: BTreeMap<String, Drv> = units
        .units
        .iter()
        .filter(|(id, _)| !left.contains(*id))
        .map(|(id, d)| (id.clone(), d.clone()))
        .collect();
    for (id, d) in &drvs {
        if let Some(dep) = refs(d).find(|r| left.contains(*r)) {
            return err(format!(
                "the unit {id} depends on {dep}, whose package outer.json leaves to another \
                 outer derivation; every package that depends on a package left must be left \
                 too"
            ));
        }
    }
    let s = shape(inputs, units, outer)?;
    drvs.extend(s.nodes);
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
    for (key, drv, output) in s.wrappers {
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
        }
    }
    Ok(s)
}

/// Resolve one derivation as `derivation (drvAttrs d)` does in
/// `lib/instantiate.nix`: substitute every part, collect string context
/// into input derivations and sources, and give a unit `passAsFile`: empty,
/// or `BREAKBULK_UNIT` when that is long.
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
    if let Some(u) = env.get("BREAKBULK_UNIT") {
        let pass = if u.len() > pass_as_file_above {
            "BREAKBULK_UNIT"
        } else {
            ""
        };
        env.insert("passAsFile".into(), pass.into());
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
