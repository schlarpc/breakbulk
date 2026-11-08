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
pub mod trim_paths;

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
///
/// With the toolchain's capabilities, it also exports
/// `CARGO_PROFILE_<P>_TRIM_PATHS=all` when the planner would turn
/// trim-paths on for `opts.profile`, by the same file-reading rule
/// ([`trim_paths::decide`]; decision 135): the variable, like the planner's
/// `--config`, overrides the project's setting.
pub fn cargo_env(opts: &trace::Options) -> Result<spec::CargoEnv, Error> {
    let mut env = spec::prepare_for(opts)?
        .map(|p| p.cargo_env())
        .unwrap_or_default();
    if let Some(caps) = &opts.capabilities {
        let declared = trim_paths::declared(&trace::workspace_dir(opts));
        env.warnings.extend(declared.warnings.iter().cloned());
        if trim_paths::decide(opts.trim_paths, caps.trim_paths, &declared)? {
            env.env.insert(trim_paths_var(&opts.profile), "all".into());
        }
    }
    Ok(env)
}

/// `CARGO_PROFILE_<P>_TRIM_PATHS`: the profile name uppercased, `-` as `_`.
pub fn trim_paths_var(profile: &str) -> String {
    format!(
        "CARGO_PROFILE_{}_TRIM_PATHS",
        profile.to_ascii_uppercase().replace('-', "_")
    )
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
    // Cargo's trim-paths ("trim-paths" in docs/implementation.md, decision
    // 121): turned on with `--config` unless the project's files declare it
    // (or `--trim-paths` says otherwise), when the toolchain has it (its
    // capabilities). One trace either way.
    let capabilities = trace::capabilities(opts)?;
    let declared = trim_paths::declared(&trace::workspace_dir(&traced));
    for w in &declared.warnings {
        eprintln!("breakbulk-plan: warning: {w}");
    }
    let on = trim_paths::decide(opts.trim_paths, capabilities.trim_paths, &declared)?;
    if opts.trim_paths == trim_paths::Mode::Auto && !declared.places.is_empty() {
        eprintln!(
            "breakbulk-plan: the project declares trim-paths ({}); leaving it to the project",
            declared.places.join(", ")
        );
    }
    let (traced, t) = if on {
        let o = trace::with_trim_paths(&traced);
        match trace::run(&o) {
            Ok(t) => (o, t),
            // A nightly from before the setting was stable.
            Err(e) if e.0.contains("trim-paths") && opts.trim_paths == trim_paths::Mode::Auto => {
                eprintln!(
                    "breakbulk-plan: warning: Cargo rejected trim-paths; using breakbulk's own \
                     path remapping:\n{e}"
                );
                let t = trace::run(&traced)?;
                (traced, t)
            }
            Err(e) => return Err(e),
        }
    } else {
        let t = trace::run(&traced)?;
        (traced, t)
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
    let mut cargo_env = prepared.as_ref().map(|p| p.cargo_env()).unwrap_or_default();
    if opts.trim_paths_default {
        cargo_env
            .env
            .insert(trim_paths_var(&opts.profile), "all".into());
    }
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
