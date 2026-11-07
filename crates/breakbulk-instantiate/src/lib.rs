//! `breakbulk-instantiate`: turns `plan.json` into unit derivations.
//!
//! IFD mode (`--emit json`) writes `units.json` (see [`output`]): each unit's
//! complete derivation attributes, with every reference to another unit or
//! to an evaluation-time input left as a named reference for the Nix side
//! (`lib/instantiate.nix`) to substitute. Rendering itself is
//! [`breakbulk_format::render_unit`], driven by a resolver that emits
//! placeholder tokens; the rendered canonical JSON is then split at the
//! tokens. So the unit text Nix assembles is byte for byte what rendering
//! with the real paths gives, which is what dynamic-derivation mode will do.

pub mod inputs;
pub mod output;

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;

use breakbulk_format::rendered::{derivation_output, package_name_version};
use breakbulk_format::{
    Arg, CompileUnit, Graph, Plan, Platform, Reference, Resolve, Root, RootKind, RunUnit, Unit,
    UnitId, ValidationOptions, merge_layer_with, render_doctest, render_unit_in, to_canonical_json,
    unit_env_value, validate,
};

use inputs::{Overrides, PackageOverride, PredictedRoot, PredictedRoots, Sources, Toolchains};
use output::{Drv, PASS_AS_FILE_ABOVE, Part, RootOut, RootWhat, UNITS_VERSION, UnitsJson, Value};

/// The tool that is every unit's builder.
pub const TOOL_UNIT: &str = "breakbulk-unit";
/// The tool that is every root stub's builder: a bash executable.
pub const TOOL_SHELL: &str = "shell";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

fn err<T>(msg: impl Into<String>) -> Result<T, Error> {
    Err(Error(msg.into()))
}

/// Everything instantiation reads.
#[derive(Clone, Debug)]
pub struct Inputs {
    pub plan: Plan,
    pub sources: Sources,
    pub toolchains: Toolchains,
    pub overrides: Overrides,
    /// `None`: take the plan's roots as they are.
    pub roots: Option<PredictedRoots>,
}

/// A reference a token stands for.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Ref {
    /// `weak`: the path without its string context, for an output the unit
    /// reaches through its dependencies' manifests.
    Unit {
        unit: String,
        output: String,
        weak: bool,
    },
    Input {
        key: String,
        json: bool,
    },
    /// A list-like variable's layers, joined with `sep` after the Nix side
    /// has substituted them, leaving empty ones out (as
    /// `breakbulk_unit::env::append` does). Each item is text with tokens.
    Join {
        sep: char,
        items: Vec<String>,
    },
}

/// Input keys, shared with `lib/instantiate.nix`.
pub mod keys {
    use breakbulk_format::Platform;

    pub fn platform(p: Platform) -> &'static str {
        match p {
            Platform::Host => "host",
            Platform::Target => "target",
        }
    }
    /// A workspace package's source view, by directory.
    pub fn src(dir: &str) -> String {
        format!("src:{dir}")
    }
    /// A fetched crate's source, by package id.
    pub fn crate_src(id: &str) -> String {
        format!("crate:{id}")
    }
    pub fn tool(name: &str) -> String {
        format!("tool:{name}")
    }
    /// The base env capture of a platform.
    pub fn capture(p: Platform) -> String {
        format!("capture:{}", platform(p))
    }
    /// A toolchain spec env value.
    pub fn env(p: Platform, var: &str) -> String {
        format!("env:{}:{var}", platform(p))
    }
    /// A package override's env capture.
    pub fn override_capture(pkg: &str, p: Platform) -> String {
        format!("override:{pkg}:capture:{}", platform(p))
    }
    /// A package override's env value.
    pub fn override_env(pkg: &str, p: Platform, var: &str) -> String {
        format!("override:{pkg}:env:{}:{var}", platform(p))
    }
}

/// The resolver: every path becomes a token naming a [`Ref`].
struct Tokens<'a> {
    inputs: &'a Inputs,
    prefix: &'a str,
    refs: RefCell<Vec<Ref>>,
    index: RefCell<HashMap<Ref, usize>>,
}

impl<'a> Tokens<'a> {
    fn new(inputs: &'a Inputs, prefix: &'a str) -> Self {
        Tokens {
            inputs,
            prefix,
            refs: RefCell::default(),
            index: RefCell::default(),
        }
    }

    fn token(&self, r: Ref) -> String {
        let mut index = self.index.borrow_mut();
        let n = *index.entry(r.clone()).or_insert_with(|| {
            let mut refs = self.refs.borrow_mut();
            refs.push(r);
            refs.len() - 1
        });
        format!("{}{n}@", self.prefix)
    }

    fn input(&self, key: String) -> String {
        self.token(Ref::Input { key, json: false })
    }

    fn json_input(&self, key: String) -> String {
        self.token(Ref::Input { key, json: true })
    }

    fn unit(&self, unit: &str, output: &str) -> String {
        self.token(Ref::Unit {
            unit: unit.to_owned(),
            output: output.to_owned(),
            weak: false,
        })
    }

    /// The override that applies to a package, and its key.
    fn package_override(&self, id: &str) -> Option<(String, &'a PackageOverride)> {
        let packages = &self.inputs.overrides.packages;
        let (name, version) = package_name_version(id)?;
        [format!("{name}@{version}"), name.to_owned()]
            .into_iter()
            .find_map(|k| packages.get(&k).map(|o| (k, o)))
    }

    /// Split `text` at this resolver's tokens.
    fn split(&self, text: &str) -> Result<Vec<Part>, Error> {
        let mut parts = Vec::new();
        let mut rest = text;
        while let Some(i) = rest.find(self.prefix) {
            if i > 0 {
                parts.push(Part::Literal(rest[..i].to_owned()));
            }
            let after = &rest[i + self.prefix.len()..];
            let end = after
                .find('@')
                .ok_or_else(|| Error(format!("unterminated token in {text}")))?;
            let n: usize = after[..end]
                .parse()
                .map_err(|_| Error(format!("malformed token in {text}")))?;
            let r = self.refs.borrow().get(n).cloned();
            parts.push(match r {
                Some(Ref::Unit { unit, output, weak }) => Part::Unit { unit, output, weak },
                Some(Ref::Input { key, json }) => Part::Input { input: key, json },
                Some(Ref::Join { sep, items }) => Part::Join {
                    join: items
                        .iter()
                        .map(|i| self.split(i))
                        .collect::<Result<_, _>>()?,
                    sep: sep.to_string(),
                },
                None => return err(format!("unknown token {n} in {text}")),
            });
            rest = &after[end + 1..];
        }
        if !rest.is_empty() {
            parts.push(Part::Literal(rest.to_owned()));
        }
        Ok(parts)
    }

    /// Replace every literal store path in `text` with a token for the tool
    /// it lies in (invariant 4 of the plan format).
    fn tokenize_store_paths(&self, unit: &str, text: &str) -> Result<String, Error> {
        let store = format!(
            "{}/",
            self.inputs.toolchains.store_dir.trim_end_matches('/')
        );
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(i) = rest.find(&store) {
            out.push_str(&rest[..i]);
            let at = &rest[i..];
            let tool = self
                .inputs
                .toolchains
                .tools
                .iter()
                .filter(|(_, path)| {
                    let path = path.trim_end_matches('/');
                    at.starts_with(path)
                        && at[path.len()..]
                            .chars()
                            .next()
                            .is_none_or(|c| !is_store_name_char(c))
                })
                .max_by_key(|(_, path)| path.trim_end_matches('/').len());
            let Some((name, path)) = tool else {
                let len = store.len()
                    + at[store.len()..]
                        .find(|c: char| !is_store_name_char(c))
                        .unwrap_or(at.len() - store.len());
                return err(format!(
                    "unit {unit}: the store path {} is not a declared toolchain input \
                     (declared: {})",
                    &at[..len],
                    self.inputs
                        .toolchains
                        .tools
                        .iter()
                        .map(|(n, p)| format!("{n} = {p}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            };
            out.push_str(&self.input(keys::tool(name)));
            rest = &at[path.trim_end_matches('/').len()..];
        }
        out.push_str(rest);
        Ok(out)
    }
}

fn is_store_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || "+-._?=".contains(c)
}

/// The directory, relative to the repository root, of a path package of
/// the plan: its id is `path+file://<skeletonRoot>/<dir>#…`.
pub fn workspace_dir<'p>(plan: &Plan, id: &'p str) -> Option<&'p str> {
    let url = id.strip_prefix("path+file://")?;
    let path = url.split(['#', '?']).next()?;
    let root = plan.skeleton_root.trim_end_matches('/');
    let rel = path.strip_prefix(root)?;
    if rel.is_empty() {
        Some("")
    } else {
        rel.strip_prefix('/').map(|r| r.trim_end_matches('/'))
    }
}

impl Resolve for Tokens<'_> {
    type Error = Error;

    fn reference(&self, r: &Reference) -> Result<String, Error> {
        let (base, rel) = match r {
            Reference::Src(s) => {
                let plan = &self.inputs.plan;
                let Some(dir) = workspace_dir(plan, &s.src) else {
                    return err(format!(
                        "{} is not a path package under the skeleton root {}",
                        s.src, plan.skeleton_root
                    ));
                };
                if !self.inputs.sources.workspace.contains(dir) {
                    return err(format!(
                        "no source view for the package {} (directory `{dir}`)",
                        s.src
                    ));
                }
                (self.input(keys::src(dir)), s.rel.as_str())
            }
            Reference::CrateSrc(s) => {
                if !self.inputs.sources.crates.contains(&s.crate_src) {
                    return err(format!("no fetched source for {}", s.crate_src));
                }
                (self.input(keys::crate_src(&s.crate_src)), s.rel.as_str())
            }
            Reference::Out(o) => {
                let output = match self.inputs.plan.units.get(&o.out) {
                    Some(Unit::Run(_)) => "out",
                    Some(Unit::Compile(_)) => derivation_output(&o.output),
                    None => return err(format!("reference to unknown unit {}", o.out)),
                };
                (self.unit(&o.out, output), o.file.as_deref().unwrap_or(""))
            }
        };
        Ok(if rel.is_empty() {
            base
        } else {
            format!("{base}/{rel}")
        })
    }

    fn flags(&self, run: &UnitId) -> Result<String, Error> {
        Ok(self.unit(run, "flags"))
    }

    fn weak_flags(&self, run: &UnitId) -> Result<String, Error> {
        Ok(self.token(Ref::Unit {
            unit: run.clone(),
            output: "flags".into(),
            weak: true,
        }))
    }

    fn remap_name(&self, base: &Reference) -> Result<String, Error> {
        Ok(match base {
            // Source views are rooted at the repository root, so this keeps
            // each path as it is relative to the repository root.
            Reference::Src(_) => ".".into(),
            Reference::CrateSrc(s) => match package_name_version(&s.crate_src) {
                Some((name, version)) => format!("{name}-{version}"),
                None => return err(format!("cannot name the crate source {}", s.crate_src)),
            },
            Reference::Out(o) => format!("/breakbulk/build/{}", o.out),
        })
    }

    fn remap_scope(&self, _id: &UnitId, unit: &CompileUnit) -> Option<String> {
        // Test harnesses remap every scope; so does everything without a
        // shipped scope (no `splitDebug`) or on rustc before 1.95.
        let scope = self.inputs.toolchains.shipped_remap_scope.as_deref()?;
        if !has_remap_scope(&self.inputs.plan.rustc) || is_test_compile(unit) {
            return None;
        }
        // Coverage instruments target units only (the spec's rustflags), so
        // host units keep the build variant's scope and stay shared with it.
        Some(match unit.platform {
            Platform::Target => scope.to_owned(),
            Platform::Host => scope
                .split(',')
                .filter(|s| *s != "coverage")
                .collect::<Vec<_>>()
                .join(","),
        })
    }

    fn env_capture(&self, _id: &UnitId, unit: &Unit) -> Result<Option<String>, Error> {
        let p = platform(unit);
        if let Some((key, o)) = self.package_override(unit.package())
            && o.platform(p).env_capture
        {
            return Ok(Some(self.input(keys::override_capture(&key, p))));
        }
        Ok(self
            .inputs
            .toolchains
            .platform(p)
            .env_capture
            .then(|| self.input(keys::capture(p))))
    }

    fn env_overlay(&self, _id: &UnitId, unit: &Unit) -> Result<BTreeMap<String, String>, Error> {
        let p = platform(unit);
        let mut env: BTreeMap<String, String> = self
            .inputs
            .toolchains
            .platform(p)
            .env
            .iter()
            .map(|v| (v.clone(), self.json_input(keys::env(p, v))))
            .collect();
        if let Some((key, o)) = self.package_override(unit.package()) {
            let layer = o
                .platform(p)
                .env
                .iter()
                .map(|v| (v.clone(), self.json_input(keys::override_env(&key, p, v))))
                .collect();
            merge_layer_with(self, &mut env, layer)?;
        }
        Ok(env)
    }

    fn strict_sources(&self, _id: &UnitId, run: &RunUnit) -> bool {
        self.package_override(&run.package)
            .and_then(|(_, o)| o.strict_sources)
            .unwrap_or(self.inputs.overrides.strict_sources)
    }

    /// Values from the Nix side are tokens whose emptiness is unknown here,
    /// so a side with a token is joined by the Nix side ([`Ref::Join`]).
    /// Literal store paths in a side are tokenized first: the join's items
    /// never reach [`Tokens::tokenize_store_paths`] through the unit text.
    fn append_list(&self, sep: char, earlier: &str, later: &str) -> Result<String, Error> {
        if !earlier.contains(self.prefix) && !later.contains(self.prefix) {
            return Ok(breakbulk_format::append_env_list(sep, earlier, later));
        }
        let items = [earlier, later]
            .into_iter()
            .map(|t| self.tokenize_store_paths("(env layer)", t))
            .collect::<Result<_, _>>()?;
        Ok(self.token(Ref::Join { sep, items }))
    }
}

/// Whether rustc takes `--remap-path-scope`: stable since 1.95. `rustc` is
/// the plan's `rustc -vV` release line (`1.99.0 (… )`, `1.101.0-nightly …`).
pub fn has_remap_scope(rustc: &str) -> bool {
    let mut parts = rustc
        .split(|c: char| !c.is_ascii_digit())
        .filter(|p| !p.is_empty())
        .map(|p| p.parse::<u64>().unwrap_or(0));
    match (parts.next(), parts.next()) {
        (Some(major), Some(minor)) => (major, minor) >= (1, 95),
        _ => false,
    }
}

fn platform(unit: &Unit) -> Platform {
    match unit {
        Unit::Compile(c) => c.platform,
        Unit::Run(r) => r.platform,
    }
}

/// A token prefix that occurs nowhere in the inputs, so that every
/// occurrence in rendered text is a token. `@bb0:` in practice.
fn token_prefix(inputs: &Inputs) -> String {
    let mut hay = inputs.plan.to_canonical_json();
    for s in inputs
        .sources
        .workspace
        .iter()
        .chain(&inputs.sources.crates)
        .chain(inputs.toolchains.tools.keys())
        .chain(inputs.toolchains.tools.values())
        .chain(inputs.toolchains.host.env.iter())
        .chain(inputs.toolchains.target.env.iter())
        .chain(inputs.overrides.packages.keys())
        .chain(
            inputs
                .overrides
                .packages
                .values()
                .flat_map(|o| o.host.env.iter().chain(&o.target.env)),
        )
    {
        hay.push('\n');
        hay.push_str(s);
    }
    (0u64..)
        .map(|k| format!("@bb{k}"))
        .find(|p| !hay.contains(p.as_str()))
        .map(|p| format!("{p}:"))
        .expect("some prefix is unused")
}

/// A valid store path name: Nix allows `[A-Za-z0-9+-._?=]`, not starting
/// with `.`, at most 211 characters.
fn store_name(s: &str) -> String {
    let mut n: String = s
        .chars()
        .map(|c| if is_store_name_char(c) { c } else { '_' })
        .collect();
    while n.starts_with('.') {
        n.replace_range(..1, "_");
    }
    n.truncate(211);
    n
}

fn is_test_compile(c: &CompileUnit) -> bool {
    c.args
        .iter()
        .any(|a| matches!(a, Arg::Literal(s) if s == "--test"))
}

/// `<package>-<version>-<kind>`: `ring-0.17.14-lib`, `ring-0.17.14-build-script`,
/// `ring-0.17.14-build-run`, `app-0.1.0-bin`; a bin or test whose crate is
/// not named after the package adds the crate name (`app-0.1.0-bin-admin_cli`).
pub fn unit_name(id: &str, unit: &Unit) -> String {
    let (pkg, version) = package_name_version(unit.package()).unwrap_or((id, "0"));
    let kind = match unit {
        Unit::Run(_) => "build-run".to_owned(),
        Unit::Compile(c) => {
            let krate = &c.krate.name;
            let kind = if krate.starts_with("build_script_") {
                "build-script"
            } else if is_test_compile(c) {
                "test"
            } else if c.krate.types.iter().any(|t| t == "bin") {
                "bin"
            } else {
                "lib"
            };
            if matches!(kind, "bin" | "test") && *krate != pkg.replace('-', "_") {
                format!("{kind}-{krate}")
            } else {
                kind.to_owned()
            }
        }
    };
    store_name(&format!("{pkg}-{version}-{kind}"))
}

/// A unit derivation's outputs.
pub fn unit_outputs(unit: &Unit) -> Vec<String> {
    match unit {
        Unit::Compile(c) => c
            .outputs
            .keys()
            .map(|o| derivation_output(o).to_owned())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect(),
        Unit::Run(_) => vec!["flags".into(), "out".into()],
    }
}

fn instantiate_unit(
    inputs: &Inputs,
    graph: &Graph,
    prefix: &str,
    id: &UnitId,
) -> Result<Drv, Error> {
    let unit = &inputs.plan.units[id];
    let tokens = Tokens::new(inputs, prefix);
    let rendered =
        render_unit_in(graph, id, &tokens).map_err(|e| Error(format!("unit {id}: {e}")))?;
    let text = unit_env_value(&rendered).map_err(|e| Error(format!("unit {id}: {e}")))?;
    let text = tokens.tokenize_store_paths(id, &text)?;
    let builder = tokens.input(keys::tool(TOOL_UNIT));
    let mut attrs = BTreeMap::new();
    attrs.insert("name".into(), Value::String(unit_name(id, unit)));
    attrs.insert(
        "builder".into(),
        Value::Parts {
            parts: tokens.split(&builder)?,
        },
    );
    attrs.insert("args".into(), Value::Strings(vec!["unit".into()]));
    attrs.insert(
        "system".into(),
        Value::String(inputs.toolchains.system.clone()),
    );
    attrs.insert("outputs".into(), Value::Strings(unit_outputs(unit)));
    attrs.insert(
        "BREAKBULK_UNIT".into(),
        Value::Parts {
            parts: tokens.split(&text)?,
        },
    );
    Ok(Drv { attrs })
}

/// A doctest's derivation: `breakbulk-unit doctest` over the rendered
/// doctest, named `<package>-<version>-doctest`, with the one output `out`
/// (the log).
fn instantiate_doctest(inputs: &Inputs, prefix: &str, id: &str) -> Result<Drv, Error> {
    let d = &inputs.plan.doctests[id];
    let tokens = Tokens::new(inputs, prefix);
    let rendered = render_doctest(&inputs.plan, id, &tokens)
        .map_err(|e| Error(format!("doctest {id}: {e}")))?;
    let text = to_canonical_json(&rendered).map_err(|e| Error(format!("doctest {id}: {e}")))?;
    let text = tokens.tokenize_store_paths(id, &text)?;
    let builder = tokens.input(keys::tool(TOOL_UNIT));
    let (pkg, version) = package_name_version(&d.package).unwrap_or((id, "0"));
    let mut attrs = BTreeMap::new();
    attrs.insert(
        "name".into(),
        Value::String(store_name(&format!("{pkg}-{version}-doctest"))),
    );
    attrs.insert(
        "builder".into(),
        Value::Parts {
            parts: tokens.split(&builder)?,
        },
    );
    attrs.insert("args".into(), Value::Strings(vec!["doctest".into()]));
    attrs.insert(
        "system".into(),
        Value::String(inputs.toolchains.system.clone()),
    );
    attrs.insert("outputs".into(), Value::Strings(vec!["out".into()]));
    attrs.insert(
        "BREAKBULK_UNIT".into(),
        Value::Parts {
            parts: tokens.split(&text)?,
        },
    );
    Ok(Drv { attrs })
}

/// How a root is matched between the plan and the prediction.
type RootKey = (String, RootKind, String, bool);

fn kind_str(k: RootKind) -> String {
    match serde_json::to_value(k) {
        Ok(serde_json::Value::String(s)) => s,
        _ => unreachable!("root kinds serialize as strings"),
    }
}

/// A root's name: `<package>/<kind>/<target>`, with `-test` added to the kind
/// of test roots other than test targets (`app/bin-test/app`).
pub fn root_name(package: &str, kind: RootKind, target: &str, test: bool) -> String {
    let mut k = kind_str(kind);
    if test && kind != RootKind::Test {
        k.push_str("-test");
    }
    format!("{package}/{k}/{target}")
}

fn describe_key((package, kind, target, test): &RootKey) -> String {
    root_name(package, *kind, target, *test)
}

fn plan_root_key(r: &Root) -> RootKey {
    let package = package_name_version(&r.package)
        .map_or(r.package.as_str(), |(n, _)| n)
        .to_owned();
    (package, r.kind, r.target.clone(), r.test)
}

fn root_output(plan: &Plan, r: &Root) -> Result<String, Error> {
    let Some(unit) = plan.units.get(&r.unit) else {
        return err(format!("root {} names unknown unit {}", r.target, r.unit));
    };
    let outs = unit_outputs(unit);
    outs.iter()
        .find(|o| *o == "out")
        .or(outs.first())
        .cloned()
        .ok_or_else(|| Error(format!("root unit {} has no outputs", r.unit)))
}

fn stub(inputs: &Inputs, prefix: &str, p: &PredictedRoot, variant: &str) -> Result<RootOut, Error> {
    let why = match &p.required_features {
        Some(f) if !f.is_empty() => format!("required features `[{}]` not enabled", f.join(", ")),
        _ => "Cargo did not select it".into(),
    };
    let reason = if p.test {
        format!(
            "`{}` was skipped: not built by Cargo in variant `{variant}`: {why}",
            p.target
        )
    } else {
        format!(
            "`{}` was not built by Cargo in variant `{variant}`: {why}",
            p.target
        )
    };
    let script = if p.test {
        r#"printf 'skipped: %s\n' "$message"; printf '%s\n' "$message" > "$out""#
    } else {
        r#"printf 'error: %s\n' "$message" >&2; exit 1"#
    };
    let tokens = Tokens::new(inputs, prefix);
    let builder = tokens.input(keys::tool(TOOL_SHELL));
    let mut attrs = BTreeMap::new();
    attrs.insert(
        "name".into(),
        Value::String(store_name(&format!(
            "{}-{}-{}-{}",
            p.package,
            kind_str(p.kind),
            p.target,
            if p.test { "skipped" } else { "not-built" }
        ))),
    );
    attrs.insert(
        "builder".into(),
        Value::Parts {
            parts: tokens.split(&builder)?,
        },
    );
    attrs.insert(
        "args".into(),
        Value::Strings(vec!["-c".into(), script.into()]),
    );
    attrs.insert(
        "system".into(),
        Value::String(inputs.toolchains.system.clone()),
    );
    attrs.insert("outputs".into(), Value::Strings(vec!["out".into()]));
    attrs.insert("message".into(), Value::String(reason.clone()));
    Ok(RootOut {
        package: p.package.clone(),
        target: p.target.clone(),
        kind: p.kind,
        test: p.test,
        what: RootWhat::Stub {
            reason,
            stub: Drv { attrs },
        },
    })
}

fn instantiate_roots(inputs: &Inputs, prefix: &str) -> Result<BTreeMap<String, RootOut>, Error> {
    let plan = &inputs.plan;
    let mut planned: BTreeMap<RootKey, &Root> = BTreeMap::new();
    for r in &plan.roots {
        if planned.insert(plan_root_key(r), r).is_some() {
            return err(format!(
                "the plan has the root {} twice",
                describe_key(&plan_root_key(r))
            ));
        }
    }
    let from_plan = |key: &RootKey, r: &Root| -> Result<RootOut, Error> {
        Ok(RootOut {
            package: key.0.clone(),
            target: key.2.clone(),
            kind: key.1,
            test: key.3,
            what: RootWhat::Unit {
                unit: r.unit.clone(),
                output: root_output(plan, r)?,
            },
        })
    };
    let mut out = BTreeMap::new();
    let Some(predicted) = &inputs.roots else {
        for (key, r) in &planned {
            out.insert(describe_key(key), from_plan(key, r)?);
        }
        return Ok(out);
    };
    let mut want: BTreeMap<RootKey, &PredictedRoot> = BTreeMap::new();
    for p in &predicted.roots {
        let key = (p.package.clone(), p.kind, p.target.clone(), p.test);
        if want.insert(key.clone(), p).is_some() {
            return err(format!(
                "the root {} is predicted twice",
                describe_key(&key)
            ));
        }
    }
    let unpredicted: Vec<&RootKey> = planned.keys().filter(|k| !want.contains_key(*k)).collect();
    if !unpredicted.is_empty() {
        let list = |keys: &mut dyn Iterator<Item = &RootKey>| {
            keys.map(describe_key).collect::<Vec<_>>().join(", ")
        };
        return err(format!(
            "the plan has roots that were not predicted: {}. This is a bug in breakbulk's \
             target discovery; set the `roots` option to work around it.\n  \
             plan roots:      {}\n  predicted roots: {}",
            list(&mut unpredicted.into_iter()),
            list(&mut planned.keys()),
            list(&mut want.keys()),
        ));
    }
    for (key, p) in &want {
        let root = match planned.get(key) {
            Some(r) => from_plan(key, r)?,
            None => stub(inputs, prefix, p, &predicted.variant)?,
        };
        out.insert(describe_key(key), root);
    }
    Ok(out)
}

/// Check the plan and the inputs before rendering anything.
fn check(inputs: &Inputs) -> Result<(), Error> {
    validate(&inputs.plan, &ValidationOptions::default()).map_err(|errs| {
        Error(
            errs.iter()
                .map(|e| e.to_string())
                .collect::<Vec<_>>()
                .join("\n"),
        )
    })?;
    for t in [TOOL_UNIT, TOOL_SHELL] {
        if !inputs.toolchains.tools.contains_key(t) {
            return err(format!("toolchains.json: the tool `{t}` is missing"));
        }
    }
    Ok(())
}

/// IFD mode: the content of `units.json`.
pub fn instantiate(inputs: &Inputs) -> Result<UnitsJson, Error> {
    check(inputs)?;
    let prefix = token_prefix(inputs);
    let graph = Graph::new(&inputs.plan);
    let mut units = BTreeMap::new();
    let mut errors = Vec::new();
    for id in inputs.plan.units.keys() {
        match instantiate_unit(inputs, &graph, &prefix, id) {
            Ok(d) => {
                units.insert(id.clone(), d);
            }
            Err(e) => errors.push(e.0),
        }
    }
    let mut doctests = BTreeMap::new();
    for id in inputs.plan.doctests.keys() {
        match instantiate_doctest(inputs, &prefix, id) {
            Ok(d) => {
                doctests.insert(id.clone(), d);
            }
            Err(e) => errors.push(e.0),
        }
    }
    if !errors.is_empty() {
        return err(errors.join("\n"));
    }
    Ok(UnitsJson {
        version: UNITS_VERSION,
        pass_as_file_above: PASS_AS_FILE_ABOVE,
        units,
        roots: instantiate_roots(inputs, &prefix)?,
        doctests,
    })
}

/// `units.json` as canonical JSON.
pub fn to_json(units: &UnitsJson) -> String {
    to_canonical_json(units).expect("units.json has no floats")
}

#[cfg(test)]
mod tests;
