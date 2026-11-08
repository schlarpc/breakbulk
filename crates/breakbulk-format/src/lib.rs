//! The `plan.json` format: types, canonical serialization, validation, and
//! rendering of units into `BREAKBULK_UNIT`.
//!
//! The rendered unit type lives in `breakbulk-unit` (re-exported here as
//! [`rendered`]), so that `breakbulk-unit`, an input of every unit, does not
//! depend on this crate.

mod canonical;
pub mod deps;
mod doctest;
mod normalize;
mod plan;
mod render;
mod validate;
pub mod version;

pub use canonical::{CanonicalError, to_canonical_json};
pub use deps::{Graph, crate_deps, crate_deps_of};
pub use doctest::render_doctest;
pub use normalize::{normalize_arg, normalize_text, normalize_unit};
pub use plan::*;
pub use render::{
    Resolve, is_linking, link_packages, merge_layer_with, remap_bases, render_unit, render_unit_in,
    unit_env_value,
};
pub use validate::{
    ValidationError, ValidationOptions, contains_path, contains_sentinel, literal_store_paths,
    validate,
};

/// The environment contract's layer merging, shared with instantiation.
pub use breakbulk_unit::env::append as append_env_list;
/// The per-unit `BREAKBULK_UNIT` types, defined by `breakbulk-unit`.
pub use breakbulk_unit::spec as rendered;
/// The dynamic-library path variable of the machine units run on (the
/// planning host's, where every recorded process ran): Cargo's
/// `dylib_path_envvar`. A test process's own comes from the target's
/// traits and runner (`dylibPathOf` in `lib/test-runs.nix`).
pub use breakbulk_unit::splice::DYLIB_PATH_VAR as HOST_DYLIB_PATH_VAR;
/// The wrapping table, shared with the planner's sentinel checks.
pub use breakbulk_unit::splice::wrap;

#[derive(Debug)]
pub enum PlanError {
    Json(serde_json::Error),
    Version(u32),
}

impl std::fmt::Display for PlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlanError::Json(e) => write!(f, "invalid plan.json: {e}"),
            PlanError::Version(v) => {
                write!(
                    f,
                    "plan.json version {v} is not supported (expected {PLAN_VERSION})"
                )
            }
        }
    }
}

impl std::error::Error for PlanError {}

impl Plan {
    /// Parse `plan.json`. Accepts any formatting; checks the version.
    pub fn from_json(s: &str) -> Result<Plan, PlanError> {
        // Read the version first so an unknown version reports as such
        // rather than as a schema mismatch.
        #[derive(serde::Deserialize)]
        struct Header {
            version: u32,
        }
        let h: Header = serde_json::from_str(s).map_err(PlanError::Json)?;
        if h.version != PLAN_VERSION {
            return Err(PlanError::Version(h.version));
        }
        serde_json::from_str(s).map_err(PlanError::Json)
    }

    /// The canonical JSON of the plan's normal form: byte-identical for equal
    /// plans, whatever order they were built in.
    pub fn to_canonical_json(&self) -> String {
        let mut p = self.clone();
        p.normalize();
        to_canonical_json(&p).expect("plans contain no floats and always serialize")
    }
}

#[cfg(test)]
mod tests;
