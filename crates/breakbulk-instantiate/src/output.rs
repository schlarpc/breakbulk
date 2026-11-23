//! `units.json`, the output of IFD mode.
//!
//! Every string attribute is either a plain string or `{"parts": [...]}`: a
//! concatenation of literal strings and references, which the Nix side
//! resolves:
//!
//! - `{"unit": <id>, "output": <name>}`: the output path of another unit
//!   derivation, `units.<id>.<name>`;
//! - `{"unit": <id>, "output": <name>, "weak": true}`: the same path without
//!   its string context, so it is not an input of the derivation. Used for
//!   the `flags` of runs a unit reaches through its dependencies' manifests
//!   (`breakbulk_format::deps`), which Nix puts in the sandbox through the
//!   dependencies' references;
//! - `{"input": <key>}`: the evaluation-time value with that key (a source
//!   view, crate source, tool, env capture or env value), with its string
//!   context;
//! - `{"input": <key>, "json": true}`: the same, escaped as the inside of a
//!   JSON string, for values placed into `BREAKBULK_UNIT`. Nix's `toJSON`
//!   escapes strings exactly as `serde_json` does (tested in this crate);
//! - `{"join": [[<part>, ...], ...], "sep": <sep>}`: each item resolved, the
//!   empty ones left out, and the rest joined with `sep`: a list-like
//!   variable (`PATH`, `NIX_CFLAGS_COMPILE`, ...) set by several env layers
//!   (`breakbulk_unit::env::merge_layer`), whose values only the Nix side
//!   knows.
//!
//! The file therefore contains no store paths: it is a function of the plan
//! and of the keys of the inputs only, and `builtins.fromJSON` accepts it
//! (it refuses strings with context, and `readFile` gives a file's
//! references as context).

use std::collections::BTreeMap;

use breakbulk_format::{Platform, RootKind};
use serde::Serialize;

/// The version of the `units.json` format.
pub const UNITS_VERSION: u32 = 4;

/// `BREAKBULK_UNIT` values longer than this many bytes, after the Nix side
/// has substituted every reference, are passed with `passAsFile`. Linux
/// limits one environment string to 128 KiB (`MAX_ARG_STRLEN`), and all of
/// them together to a quarter of the stack limit.
pub const PASS_AS_FILE_ABOVE: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UnitsJson {
    pub version: u32,
    /// See [`PASS_AS_FILE_ABOVE`]. The Nix side applies it, because only it
    /// knows the substituted length.
    pub pass_as_file_above: usize,
    /// Unit id to its derivation.
    pub units: BTreeMap<String, Drv>,
    /// Root name to root.
    pub roots: BTreeMap<String, RootOut>,
    /// Test plans: the plan's doctest id (`d-<package>`) to its doctest
    /// derivation (`kind: doctest`, output `out`), without the
    /// package's test configuration; the root shape's `doctest:<package>`
    /// node has it ([`crate::shape`]).
    #[serde(skip_serializing)]
    pub doctests: BTreeMap<String, Drv>,
    /// Doc plans: the docs derivation (`kind: docs`, output `out`),
    /// the root shape's `docs` node.
    #[serde(skip_serializing)]
    pub docs: Option<Drv>,
    /// With `--outer`: the derivations the wrappers name besides units, by
    /// node key (`stub:<root>`, `doctest:<package>`, `docs`), which a part
    /// names as it names a unit ([`crate::shape::Shape`]).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub nodes: BTreeMap<String, Drv>,
    /// With `--outer`: each wrapper by the output name outer.json gives it
    /// (`<package>.<kind>.<target>.drv`, `<package>.doctest.drv`,
    /// `units.drv`, `runs.drv`, `docs.drv`).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub wrappers: BTreeMap<String, Drv>,
}

/// The attributes of one derivation, passed to `derivation` after
/// resolving. `BREAKBULK_UNIT` is the only attribute that may be moved to
/// `passAsFile`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Drv {
    pub attrs: BTreeMap<String, Value>,
}

/// An attribute value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Value {
    String(String),
    Strings(Vec<String>),
    Parts { parts: Vec<Part> },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Part {
    Literal(String),
    Unit {
        unit: String,
        output: String,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        weak: bool,
    },
    Input {
        input: String,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        json: bool,
    },
    Join {
        join: Vec<Vec<Part>>,
        sep: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RootOut {
    /// The package name.
    pub package: String,
    pub target: String,
    pub kind: RootKind,
    pub test: bool,
    /// The platform of the root unit (a stub: the predicted one), which
    /// picks a test binary's runner, system and libraries.
    pub platform: Platform,
    /// What the root's wrapper links. Everything after a root reads it
    /// from the wrapper at build time; IFD mode keeps the unit's name
    /// (`rootUnits` in `lib/instantiate.nix`) for tests and debugging.
    #[serde(flatten)]
    pub what: RootWhat,
    /// For a product root the plan has: the target-platform runs it depends
    /// on (`deps::target_runs_below`), whose copies of Cargo's `<profile>`
    /// may hold files their scripts placed next to the binaries, for the
    /// product's `buildScriptFiles` stage and check (#23), through the
    /// wrapper. Sorted.
    #[serde(skip_serializing)]
    pub build_script_runs: Vec<String>,
    /// For a product root the plan has: the units below it that write
    /// per-object debuginfo side files (`deps::debug_units_below`), whose
    /// `debug` outputs hold the libraries' `.dwo` files, which
    /// the root's binary names, for the product's `linked` stage, through
    /// the wrapper's `debug`. Sorted.
    #[serde(skip_serializing)]
    pub debug_units: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum RootWhat {
    /// The plan has it: this output of this unit.
    Unit { unit: String, output: String },
    /// The plan lacks it: a stub derivation. A product stub fails with
    /// `reason`; a test stub succeeds and logs it.
    Stub { reason: String, stub: Drv },
}
