//! The wrapping table and splice expansion.
//!
//! A splice point in a compile's arguments stands for one kind of directive
//! from one build-script run. At build time it expands to that run's values,
//! wrapped as Cargo wraps them (`add_native_deps` and `add_custom_flags` in
//! Cargo's `src/compiler/mod.rs`, tag `0.100.0`):
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
//! Two kinds cannot expand independently at each splice point, because Cargo
//! does not emit them run by run, kind by kind:
//!
//! - **`rustc-link-search`.** Cargo collects the `-L` paths of every run the
//!   unit links, then stable-sorts them so that paths inside the printing
//!   script's own `OUT_DIR` come before all others. Sentinel paths are all
//!   inside `OUT_DIR`, so the trace shows one splice per run in `to_link`
//!   order. Expansion emits each run's inside paths at its splice, and every
//!   run's outside paths, in splice order, after the last link-search splice.
//! - **`rustc-link-arg` and its forms.** Cargo keeps one list of link args per
//!   run in printed order, and passes those that apply to the unit. The trace
//!   shows one splice per kind that applies, in the order the stub printed
//!   them. Expansion emits, at the first of a run's link-arg splices, every
//!   link arg of that run whose kind has a splice in this unit, in printed
//!   order; the run's other link-arg splices expand to nothing.
//!
//! Both rules need the splices concerned to be adjacent, as Cargo emits them;
//! expansion fails otherwise.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::directives::BuildOutput;
use crate::spec::{RenderedArg, Splice, SpliceKind};

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

fn describe(s: &Splice<String>) -> String {
    match &s.bin {
        Some(bin) => format!("{} (bin `{bin}`) from {}", s.kind, s.splice),
        None => format!("{} from {}", s.kind, s.splice),
    }
}

/// Check the shape rules that expansion relies on. The planner runs the same
/// check on `plan.json`, with unit ids in place of `flags` paths.
pub fn check_arg_splices<S: Ord + Clone + fmt::Display>(
    splices: &[(usize, &Splice<S>)],
) -> Result<(), SpliceError> {
    let describe = |s: &Splice<S>| match &s.bin {
        Some(bin) => format!("{} (bin `{bin}`) from {}", s.kind, s.splice),
        None => format!("{} from {}", s.kind, s.splice),
    };
    let mut seen = BTreeSet::new();
    for (_, s) in splices {
        if s.kind == SpliceKind::RustcEnv {
            bail!(
                "splice {} is in the arguments; rustc-env belongs in envSplices",
                describe(s)
            );
        }
        if (s.kind == SpliceKind::RustcLinkArgBin) != s.bin.is_some() {
            bail!(
                "splice {}: `bin` must be given for rustc-link-arg-bin and only for it",
                describe(s)
            );
        }
        if !seen.insert((s.splice.clone(), s.kind, s.bin.clone())) {
            bail!("splice {} appears twice", describe(s));
        }
    }
    // Link-search splices, across all runs, must be adjacent.
    let search: Vec<usize> = splices
        .iter()
        .filter(|(_, s)| s.kind == SpliceKind::RustcLinkSearch)
        .map(|(i, _)| *i)
        .collect();
    if search.windows(2).any(|w| w[1] != w[0] + 1) {
        bail!("rustc-link-search splices are not adjacent in the arguments");
    }
    // Each run's link-arg splices must be adjacent.
    let mut link_args: BTreeMap<&S, Vec<usize>> = BTreeMap::new();
    for (i, s) in splices {
        if s.kind.is_link_arg() {
            link_args.entry(&s.splice).or_default().push(*i);
        }
    }
    for (run, positions) in link_args {
        if positions.windows(2).any(|w| w[1] != w[0] + 1) {
            bail!("rustc-link-arg splices from {run} are not adjacent in the arguments");
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

    let lookup = |s: &Splice<String>| {
        directives(&s.splice)
            .ok_or_else(|| SpliceError(format!("no directives for splice {}", describe(s))))
    };
    let last_search = splices
        .iter()
        .rev()
        .find(|(_, s)| s.kind == SpliceKind::RustcLinkSearch)
        .map(|(i, _)| *i);
    // For each run, the link-arg kinds this unit receives.
    let mut link_kinds: BTreeMap<&str, BTreeSet<(SpliceKind, Option<&str>)>> = BTreeMap::new();
    for (_, s) in &splices {
        if s.kind.is_link_arg() {
            link_kinds
                .entry(&s.splice)
                .or_default()
                .insert((s.kind, s.bin.as_deref()));
        }
    }

    let mut out = Vec::new();
    let push = |out: &mut Vec<String>, kind: SpliceKind, value: &str| {
        out.extend(wrap(kind, value).expect("argument kinds always wrap"));
    };
    for (i, arg) in args.iter().enumerate() {
        let s = match arg {
            RenderedArg::Literal(l) => {
                out.push(l.clone());
                continue;
            }
            RenderedArg::Splice(s) => s,
        };
        let d = lookup(s)?;
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
                for p in d.library_paths.iter().filter(|p| p.in_out_dir) {
                    push(&mut out, s.kind, &p.value);
                }
                if Some(i) == last_search {
                    for (_, t) in splices
                        .iter()
                        .filter(|(_, t)| t.kind == SpliceKind::RustcLinkSearch)
                    {
                        for p in lookup(t)?.library_paths.iter().filter(|p| !p.in_out_dir) {
                            push(&mut out, s.kind, &p.value);
                        }
                    }
                }
            }
            SpliceKind::RustcEnv => unreachable!("rejected by check_arg_splices"),
            _ => {
                let Some(kinds) = link_kinds.remove(s.splice.as_str()) else {
                    // A later splice of a run already expanded.
                    continue;
                };
                for a in &d.linker_args {
                    if kinds.contains(&(a.kind, a.bin.as_deref())) {
                        push(&mut out, a.kind, &a.value);
                    }
                }
            }
        }
    }
    Ok(out)
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
        if s.kind != SpliceKind::RustcEnv || s.bin.is_some() {
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
