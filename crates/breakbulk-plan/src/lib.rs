//! `breakbulk-plan`: runs the user's cargo over the planning skeleton with
//! `breakbulk-shim` as its rustc wrapper, rustdoc and build-script stub, and
//! turns the records into `plan.json` ("Trace planner" in
//! `docs/implementation.md`).
//!
//! - [`trace`] runs cargo (and `cargo metadata`) and collects the records.
//! - [`graph`] turns records into units: identity, edges, sentinels, env.
//! - [`rewrite`] turns recorded paths into references.
//! - [`sentinel`] parses sentinel shapes.
//! - [`spec`] passes the toolchain spec's rustflags and linkers to Cargo,
//!   confirms they arrived, and rewrites same-triple host linkers.

pub mod build_std;
pub mod golden;
pub mod graph;
pub mod records;
pub mod rewrite;
pub mod sentinel;
pub mod spec;
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
    plan_with_cargo_env(opts).map(|(p, _)| p)
}

/// The toolchain spec as Cargo environment configuration for the dev shell,
/// without tracing: it reads only the project's Cargo config files and asks
/// rustc (`-vV`, `--print cfg`), and never runs Cargo, so it works while
/// the manifests are broken (decision 81). The same value as
/// [`plan_with_cargo_env`]'s.
pub fn cargo_env(opts: &trace::Options) -> Result<spec::CargoEnv, Error> {
    Ok(spec::prepare_for(opts)?
        .map(|p| p.cargo_env())
        .unwrap_or_default())
}

/// [`plan`], plus the toolchain spec as Cargo environment configuration for
/// the dev shell ([`spec::Prepared::cargo_env`]; empty without a spec).
pub fn plan_with_cargo_env(opts: &trace::Options) -> Result<(Plan, spec::CargoEnv), Error> {
    let prepared = spec::prepare_for(opts)?;
    let mut traced = opts.clone();
    if let Some(p) = &prepared {
        traced.configs.push(p.config.display().to_string());
    }
    if let Some(v) = trace::std_vendor(&traced)? {
        traced.configs.push(v.config.clone());
        traced.std_vendor = Some(v);
    }
    let capabilities = trace::capabilities(opts)?;
    let first = trace::run(&traced)?;
    // Cargo's trim-paths ("trim-paths" in docs/implementation.md): when the
    // project has not turned it on and Cargo has it (the toolchain's
    // capabilities), trace again with it on.
    let (traced, t) = if !graph::trace_trims_paths(&first.records) && capabilities.trim_paths {
        let o = trace::with_trim_paths(&traced);
        match trace::run(&o) {
            Ok(t) => (o, t),
            // A nightly from before the setting was stable.
            Err(e) if e.0.contains("trim-paths") => {
                eprintln!(
                    "breakbulk-plan: warning: Cargo {} rejected trim-paths; using breakbulk's own \
                     path remapping:\n{e}",
                    first.cargo_version
                );
                (traced, first)
            }
            Err(e) => return Err(e),
        }
    } else {
        (traced, first)
    };
    let opts = &traced;
    if !graph::trace_trims_paths(&t.records) {
        trace::check_location(opts, &t.metadata)?;
    }
    let ctx = t.context(opts)?;
    let b = graph::Builder::new(&ctx, &t.metadata, &t.records)?;
    let mut plan = b.plan()?;
    if let Some(p) = &prepared {
        p.apply(&mut plan)?;
    }
    let cargo_env = prepared.as_ref().map(|p| p.cargo_env()).unwrap_or_default();
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
    Ok((plan, cargo_env))
}
