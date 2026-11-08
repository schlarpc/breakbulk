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

use breakbulk_format::RootKind;
use serde::Serialize;

/// The version of the `units.json` format.
pub const UNITS_VERSION: u32 = 2;

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
    /// derivation (`breakbulk-unit doctest`, output `out`).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub doctests: BTreeMap<String, Drv>,
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
    #[serde(flatten)]
    pub what: RootWhat,
    /// For a test binary the plan has: what nextest's reuse-build mode reads
    /// to run it, for IFD mode's test runs (`nextestSpec` in
    /// `lib/test-runs.nix`), from the same function as dynamic-derivation
    /// mode's `TestSpec`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nextest: Option<RootNextest>,
    /// For a product root the plan has: the target-platform runs it depends
    /// on (`deps::target_runs_below`), whose copies of Cargo's `<profile>`
    /// may hold files their scripts placed next to the binaries, for the
    /// product's `buildScriptFiles` stage and check (#23). Sorted.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub build_script_runs: Vec<String>,
    /// For a product root the plan has: the units below it with a `debug`
    /// output (`deps::debug_units_below`): libraries' `.dwo` files, which
    /// the root's binary names, for the product's `linked` stage (decision
    /// 126). Sorted.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub debug_units: Vec<String>,
}

/// [`crate::dynamic::Nextest`] as compact JSON text with placeholders the
/// Nix side fills in at evaluation time: `@VIEW@` (the root of the test's
/// source view) and `"@LIBDIR@"` (the whole JSON value of the target's
/// sysroot library directory); `@BINARY@`, `@TARGET@` and `@WS@` the test
/// run fills in at build time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RootNextest {
    pub binary_id: String,
    pub cargo_metadata: String,
    pub binaries: String,
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
