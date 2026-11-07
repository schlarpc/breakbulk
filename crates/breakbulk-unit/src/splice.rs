//! The wrapping table and splice expansion.
//!
//! A splice point in a compile's arguments stands for some directives of one
//! build-script run. At build time it expands to that run's values, wrapped
//! as Cargo wraps them (`add_native_deps` and `add_custom_flags` in Cargo's
//! `src/compiler/mod.rs`, tag `0.100.0`):
//!
//! | Kind | Arguments per value |
//! | --- | --- |
//! | `rustc-cfg` | `--cfg`, value |
//! | `rustc-check-cfg` | `--check-cfg`, value |
//! | `rustc-link-lib` | `-l`, value |
//! | `rustc-link-search` | `-L`, value |
//! | `rustc-link-arg*` | `-C`, `link-arg=`value |
//! | `rustc-env` | none: env var on the compile |
//!
//! Each splice expands on its own, in place ("Fields" in
//! `docs/implementation.md`, from spike A's wrapping table):
//!
//! - **`rustc-link-search`.** Cargo collects the `-L` paths of every run the
//!   unit links, then stable-sorts them so that paths inside the printing
//!   script's own `OUT_DIR` come before all others. The stub prints one
//!   sentinel of each class, so the trace shows one splice per class per run,
//!   where Cargo put it: `"in": "out"` expands to the run's paths inside its
//!   `out`, `"in": "other"` to its other paths, each in printed order. A
//!   literal `-L` from a `links` override stays where Cargo placed it.
//! - **`rustc-link-arg` and its forms.** Cargo keeps one list of link args per
//!   run in printed order, and passes those that apply to the unit. One splice
//!   per run carries the set of kinds that apply (`kinds`), and expands to the
//!   run's link args of those kinds in printed order.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::directives::BuildOutput;
use crate::spec::{RenderedArg, SearchIn, Splice, SpliceKind};

/// The arguments one directive value becomes, or `None` for `rustc-env`,
/// which becomes an env var. The planner checks sentinel placement against
/// this same function.
pub fn wrap(kind: SpliceKind, value: &str) -> Option<[String; 2]> {
    let (flag, arg) = match kind {
        SpliceKind::RustcCfg => ("--cfg", value.to_owned()),
        SpliceKind::RustcCheckCfg => ("--check-cfg", value.to_owned()),
        SpliceKind::RustcLinkLib => ("-l", value.to_owned()),
        SpliceKind::RustcLinkSearch => ("-L", value.to_owned()),
        SpliceKind::RustcEnv => return None,
        k => {
            debug_assert!(k.is_link_arg());
            ("-C", format!("link-arg={value}"))
        }
    };
    Some([flag.to_owned(), arg])
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpliceError(pub String);

impl fmt::Display for SpliceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SpliceError {}

macro_rules! bail {
    ($($arg:tt)*) => {
        return Err(SpliceError(format!($($arg)*)))
    };
}

/// A splice in messages: `rustc-cfg from R`, `rustc-link-search (in out) from
/// R`, `rustc-link-arg [rustc-link-arg, rustc-link-arg-bins] from R`.
pub fn describe<S: fmt::Display>(s: &Splice<S>) -> String {
    match (&s.search, &s.kinds) {
        (Some(SearchIn::Out), _) => format!("{} (in out) from {}", s.kind, s.splice),
        (Some(SearchIn::Other), _) => format!("{} (in other) from {}", s.kind, s.splice),
        (None, Some(kinds)) => format!(
            "{} [{}] from {}",
            s.kind,
            kinds
                .iter()
                .map(|k| k.to_string())
                .collect::<Vec<_>>()
                .join(", "),
            s.splice
        ),
        (None, None) => format!("{} from {}", s.kind, s.splice),
    }
}

/// Check the shape rules that expansion relies on: every splice has the
/// fields its kind needs, `rustc-env` is not among the arguments, and no
/// splice appears twice. The planner runs the same check on `plan.json`, with
/// unit ids in place of `flags` paths.
pub fn check_arg_splices<S: Ord + Clone + fmt::Display>(
    splices: &[(usize, &Splice<S>)],
) -> Result<(), SpliceError> {
    let mut seen = BTreeSet::new();
    for (_, s) in splices {
        if let Err(e) = s.check_shape() {
            bail!("splice {}: {e}", describe(s));
        }
        if s.kind == SpliceKind::RustcEnv {
            bail!(
                "splice {} is in the arguments; rustc-env belongs in envSplices",
                describe(s)
            );
        }
        if !seen.insert((s.splice.clone(), s.kind, s.search)) {
            bail!("splice {} appears twice", describe(s));
        }
    }
    Ok(())
}

/// Expand a compile's arguments.
///
/// `directives` returns the parsed output of the run whose `flags` directory
/// is given (`$flags/directives.json`).
pub fn expand_args<'a>(
    args: &[RenderedArg],
    directives: impl Fn(&str) -> Option<&'a BuildOutput>,
) -> Result<Vec<String>, SpliceError> {
    let splices: Vec<(usize, &Splice<String>)> = args
        .iter()
        .enumerate()
        .filter_map(|(i, a)| match a {
            RenderedArg::Splice(s) => Some((i, s)),
            RenderedArg::Literal(_) => None,
        })
        .collect();
    check_arg_splices(&splices)?;

    let mut out = Vec::new();
    let push = |out: &mut Vec<String>, kind: SpliceKind, value: &str| {
        out.extend(wrap(kind, value).expect("argument kinds always wrap"));
    };
    for arg in args {
        let s = match arg {
            RenderedArg::Literal(l) => {
                out.push(l.clone());
                continue;
            }
            RenderedArg::Splice(s) => s,
        };
        let d = directives(&s.splice)
            .ok_or_else(|| SpliceError(format!("no directives for splice {}", describe(s))))?;
        match s.kind {
            SpliceKind::RustcCfg => d.cfgs.iter().for_each(|v| push(&mut out, s.kind, v)),
            SpliceKind::RustcCheckCfg => {
                d.check_cfgs.iter().for_each(|v| push(&mut out, s.kind, v))
            }
            SpliceKind::RustcLinkLib => d
                .library_links
                .iter()
                .for_each(|v| push(&mut out, s.kind, v)),
            SpliceKind::RustcLinkSearch => {
                let inside = s.search == Some(SearchIn::Out);
                for p in d.library_paths.iter().filter(|p| p.in_out_dir == inside) {
                    push(&mut out, s.kind, &p.value);
                }
            }
            SpliceKind::RustcLinkArg => {
                let kinds = s.kinds.as_deref().unwrap_or_default();
                for a in &d.linker_args {
                    if kinds
                        .iter()
                        .any(|k| k.kind == a.kind && k.bin.as_deref() == a.bin.as_deref())
                    {
                        push(&mut out, a.kind, &a.value);
                    }
                }
            }
            _ => unreachable!("rejected by check_arg_splices"),
        }
    }
    Ok(out)
}

/// The dynamic-library path variable of the platform `breakbulk-unit` runs
/// on: Cargo's `dylib_path_envvar` (`cargo-util`, `paths.rs`).
pub const DYLIB_PATH_VAR: &str = if cfg!(windows) {
    "PATH"
} else if cfg!(target_os = "macos") {
    "DYLD_FALLBACK_LIBRARY_PATH"
} else {
    "LD_LIBRARY_PATH"
};

/// Expand dynamic-path splices into `env`: each run's search paths that lie
/// inside its own `out` (without their `native=`-style kind), in order, go
/// before the variable's recorded value. Cargo keeps only paths inside its
/// target directory (`filter_dynamic_search_path`); breakbulk keeps those
/// inside the printing run's `out`.
pub fn expand_dylib_path<'a>(
    env: &mut BTreeMap<String, String>,
    runs: &[String],
    directives: impl Fn(&str) -> Option<&'a BuildOutput>,
) -> Result<(), SpliceError> {
    if runs.is_empty() {
        return Ok(());
    }
    let mut paths: Vec<String> = Vec::new();
    for r in runs {
        let d = directives(r).ok_or_else(|| {
            SpliceError(format!(
                "no directives for the dynamic-path splice from {r}"
            ))
        })?;
        for p in d.library_paths.iter().filter(|p| p.in_out_dir) {
            let path = match p.value.split_once('=') {
                Some(("native" | "crate" | "dependency" | "framework" | "all", rest)) => rest,
                _ => p.value.as_str(),
            };
            if !paths.iter().any(|x| x == path) {
                paths.push(path.to_owned());
            }
        }
    }
    let sep = if cfg!(windows) { ";" } else { ":" };
    if let Some(old) = env.get(DYLIB_PATH_VAR).filter(|v| !v.is_empty()) {
        paths.push(old.clone());
    }
    if !paths.is_empty() {
        env.insert(DYLIB_PATH_VAR.into(), paths.join(sep));
    }
    Ok(())
}

/// Expand a compile's env: the recorded env, then each `rustc-env` splice in
/// order. Like Cargo's `add_custom_flags`, which runs after Cargo has set
/// every other variable, a script's value replaces a recorded one, and a later
/// value replaces an earlier one.
pub fn expand_env<'a>(
    env: &BTreeMap<String, String>,
    env_splices: &[Splice<String>],
    directives: impl Fn(&str) -> Option<&'a BuildOutput>,
) -> Result<BTreeMap<String, String>, SpliceError> {
    let mut out = env.clone();
    let mut seen = BTreeSet::new();
    for s in env_splices {
        if s.kind != SpliceKind::RustcEnv || s.check_shape().is_err() {
            bail!("env splice {} is not rustc-env", describe(s));
        }
        if !seen.insert(&s.splice) {
            bail!("env splice {} appears twice", describe(s));
        }
        let d = directives(&s.splice)
            .ok_or_else(|| SpliceError(format!("no directives for splice {}", describe(s))))?;
        for (k, v) in &d.env {
            out.insert(k.clone(), v.clone());
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests;
