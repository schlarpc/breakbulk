//! Types for `plan.json`, as described under "Plan format" in
//! `docs/implementation.md`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

pub use breakbulk_unit::spec::{CrateInfo, PackageTarget, Platform, SpliceKind};

/// The only plan format version this crate reads and writes.
pub const PLAN_VERSION: u32 = 1;

/// A unit's key: `c-<hash>` for compile units (Cargo's `-C metadata`),
/// `r-<pkg>-<hash>` for build-script runs (from `OUT_DIR`).
pub type UnitId = String;

/// A splice point in `plan.json`: names a run unit.
pub type Splice = breakbulk_unit::spec::Splice<UnitId>;

/// One `plan.json`: every unit of one (workspace, target, variant, plan kind).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Plan {
    pub version: u32,
    pub kind: PlanKind,
    /// `cargo -V` version.
    pub cargo: String,
    /// `rustc -vV` release line.
    pub rustc: String,
    pub host: String,
    pub target: String,
    pub variant: Variant,
    /// The canonical absolute skeleton path planning ran at.
    pub skeleton_root: String,
    /// Whether Cargo's `trim-paths` was in effect.
    pub trim_paths: bool,
    pub units: BTreeMap<UnitId, Unit>,
    /// The plan's products. Sorted.
    pub roots: Vec<Root>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlanKind {
    Build,
    Test,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Variant {
    pub profile: String,
    pub features: BTreeSet<String>,
    pub mode: VariantMode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VariantMode {
    Build,
    Check,
    Clippy,
    Coverage,
}

/// A path the planner rewrote: resolved to a store path at instantiation.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reference {
    /// `<skeleton>/<rel>` inside a workspace package.
    Src(SrcRef),
    /// `<vendor dir>/<source>/<crate>/<rel>`.
    CrateSrc(CrateSrcRef),
    /// An output of another unit in the plan.
    Out(OutRef),
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SrcRef {
    /// The workspace package.
    pub src: String,
    /// Relative path inside it; empty for the package directory.
    pub rel: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CrateSrcRef {
    /// The package id.
    pub crate_src: String,
    pub rel: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutRef {
    pub out: UnitId,
    /// `rmeta`, `rlib` or `bin` for a compile unit (a key of its `outputs`);
    /// `out` for a run unit.
    pub output: String,
    /// A file inside the output; listed in the compile unit's `outputs`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

/// One part of a concatenated argument.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Piece {
    Literal(String),
    Ref(Reference),
}

/// A string value: a literal, or literals and references concatenated.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Text {
    Literal(String),
    Concat(Vec<Piece>),
}

/// One argument segment.
///
/// A string is a literal argument. An array is one argument made by
/// concatenating literals and references. A splice object expands at build
/// time to zero or more arguments.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Arg {
    Literal(String),
    Concat(Vec<Piece>),
    Splice(Splice),
}

impl From<Text> for Arg {
    fn from(t: Text) -> Arg {
        match t {
            Text::Literal(s) => Arg::Literal(s),
            Text::Concat(p) => Arg::Concat(p),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Unit {
    Compile(CompileUnit),
    Run(RunUnit),
}

impl Unit {
    pub fn package(&self) -> &str {
        match self {
            Unit::Compile(c) => &c.package,
            Unit::Run(r) => &r.package,
        }
    }
}

/// A rustc (or wrapper) invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CompileUnit {
    pub package: String,
    #[serde(rename = "crate")]
    pub krate: CrateInfo,
    pub platform: Platform,
    /// The program and wrapper chain, e.g. `[clippy-driver, rustc]`.
    pub program: Vec<Text>,
    pub args: Vec<Arg>,
    pub env: BTreeMap<String, Text>,
    /// Runs whose `rustc-env` values are added to `env`, in order; a later
    /// run's value wins.
    pub env_splices: Vec<Splice>,
    pub cwd: Reference,
    /// Output name to file names.
    pub outputs: BTreeMap<String, BTreeSet<String>>,
}

/// A build-script run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RunUnit {
    pub package: String,
    pub platform: Platform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<String>,
    /// The build-script executable: an `out` reference to its compile unit.
    pub script: Reference,
    pub env: BTreeMap<String, Text>,
    /// The working directory Cargo gave the script (the package directory).
    pub cwd: Reference,
    /// Upstream runs whose `DEP_<links>_*` metadata this run receives.
    pub metadata_from: BTreeSet<UnitId>,
    /// The package's `rust-version`, for Cargo's `cargo::` syntax check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<String>,
    /// The package's targets, for Cargo's `rustc-link-arg-*` validations.
    /// Sorted.
    pub targets: Vec<PackageTarget>,
    /// Cargo's `nightly_features_allowed` for the planning toolchain.
    pub nightly_features_allowed: bool,
}

/// A product of the plan.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Root {
    pub package: String,
    /// The Cargo target name.
    pub target: String,
    pub kind: RootKind,
    pub unit: UnitId,
    pub test: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RootKind {
    Bin,
    Cdylib,
    Dylib,
    Staticlib,
    Example,
    Test,
    Bench,
}

impl Reference {
    /// The unit this reference names, for `out` references.
    pub fn unit(&self) -> Option<&str> {
        match self {
            Reference::Out(o) => Some(&o.out),
            _ => None,
        }
    }
}

/// Visit every literal string of a unit that becomes part of a command, an
/// env value or an env name, with a description of where it is.
pub(crate) fn for_each_literal(unit: &Unit, f: &mut dyn FnMut(&str, &dyn Fn() -> String)) {
    fn text(t: &Text, what: &dyn Fn() -> String, f: &mut dyn FnMut(&str, &dyn Fn() -> String)) {
        match t {
            Text::Literal(s) => f(s, what),
            Text::Concat(pieces) => pieces.iter().for_each(|p| {
                if let Piece::Literal(s) = p {
                    f(s, what)
                }
            }),
        }
    }
    let env = |env: &BTreeMap<String, Text>, f: &mut dyn FnMut(&str, &dyn Fn() -> String)| {
        for (k, v) in env {
            f(k, &|| format!("env name `{k}`"));
            text(v, &|| format!("env `{k}`"), f);
        }
    };
    match unit {
        Unit::Compile(c) => {
            for (i, p) in c.program.iter().enumerate() {
                text(p, &|| format!("program[{i}]"), f);
            }
            for (i, a) in c.args.iter().enumerate() {
                match a {
                    Arg::Literal(s) => f(s, &|| format!("args[{i}]")),
                    Arg::Concat(p) => text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f),
                    Arg::Splice(_) => {}
                }
            }
            env(&c.env, f);
        }
        Unit::Run(r) => env(&r.env, f),
    }
}

/// Visit every reference of a unit.
pub(crate) fn for_each_reference(unit: &Unit, f: &mut dyn FnMut(&Reference, &dyn Fn() -> String)) {
    fn text(
        t: &Text,
        what: &dyn Fn() -> String,
        f: &mut dyn FnMut(&Reference, &dyn Fn() -> String),
    ) {
        if let Text::Concat(pieces) = t {
            for p in pieces {
                if let Piece::Ref(r) = p {
                    f(r, what)
                }
            }
        }
    }
    let env = |env: &BTreeMap<String, Text>, f: &mut dyn FnMut(&Reference, &dyn Fn() -> String)| {
        for (k, v) in env {
            text(v, &|| format!("env `{k}`"), f);
        }
    };
    match unit {
        Unit::Compile(c) => {
            for (i, p) in c.program.iter().enumerate() {
                text(p, &|| format!("program[{i}]"), f);
            }
            for (i, a) in c.args.iter().enumerate() {
                if let Arg::Concat(p) = a {
                    text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f);
                }
            }
            env(&c.env, f);
            f(&c.cwd, &|| "cwd".into());
        }
        Unit::Run(r) => {
            env(&r.env, f);
            f(&r.script, &|| "script".into());
            f(&r.cwd, &|| "cwd".into());
        }
    }
}
