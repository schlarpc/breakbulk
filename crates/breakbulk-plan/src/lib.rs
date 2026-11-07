//! `breakbulk-plan`: runs the user's cargo over the planning skeleton with
//! `breakbulk-shim` as its rustc wrapper, rustdoc and build-script stub, and
//! turns the records into `plan.json` ("Trace planner" in
//! `docs/implementation.md`).
//!
//! - [`trace`] runs cargo (and `cargo metadata`) and collects the records.
//! - [`graph`] turns records into units: identity, edges, sentinels, env.
//! - [`rewrite`] turns recorded paths into references.
//! - [`sentinel`] parses sentinel shapes.

pub mod graph;
pub mod records;
pub mod rewrite;
pub mod sentinel;
pub mod trace;

use std::fmt;

use breakbulk_format::{Plan, ValidationOptions, validate};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

#[macro_export]
#[doc(hidden)]
macro_rules! bail {
    ($($arg:tt)*) => {
        return Err($crate::Error(format!($($arg)*)))
    };
}

/// Trace, build the plan, and validate it.
pub fn plan(opts: &trace::Options) -> Result<Plan, Error> {
    let t = trace::run(opts)?;
    let ctx = t.context(opts);
    let b = graph::Builder::new(&ctx, &t.metadata, &t.records)?;
    let plan = b.plan()?;
    let mut forbidden = opts.forbidden.clone();
    forbidden.push(opts.scratch.clone());
    validate(
        &plan,
        &ValidationOptions {
            forbidden_paths: forbidden,
        },
    )
    .map_err(|errs| {
        Error(format!(
            "the traced plan is invalid (Cargo {}):\n{}",
            ctx.cargo_version,
            errs.iter()
                .map(|e| format!("  {e}"))
                .collect::<Vec<_>>()
                .join("\n")
        ))
    })?;
    Ok(plan)
}
