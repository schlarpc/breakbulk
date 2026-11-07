//! The plan invariants from "Plan format" in `docs/implementation.md`.
//!
//! [`validate`] checks invariants 2 and 3 and the shape rules that splice
//! expansion relies on. Invariant 1 (canonical form) holds by construction
//! for plans written with [`Plan::to_canonical_json`]. Invariant 4 (literal
//! store paths are declared inputs) needs the toolchain spec and source map,
//! so instantiation checks it, using [`literal_store_paths`].

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use breakbulk_unit::splice::check_arg_splices;

use crate::plan::{Arg, Plan, Reference, Unit, for_each_literal, for_each_reference};
use crate::{PLAN_VERSION, Splice, SpliceKind};

/// Paths no literal may contain, besides the plan's own `skeletonRoot`:
/// typically the planner's scratch directory, the vendor directory, the
/// sandbox build directory (`/build`) and `$HOME`.
#[derive(Clone, Debug, Default)]
pub struct ValidationOptions {
    pub forbidden_paths: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ValidationError {
    /// The unit concerned, if any.
    pub unit: Option<String>,
    pub message: String,
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.unit {
            Some(u) => write!(f, "unit {u}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for ValidationError {}

/// Whether `s` contains a sentinel token: `__bb` in any case, not followed by
/// an ASCII letter or digit. This covers `__bb_R_cfg`, `__BB_R_ENV`, `__bb=R`
/// and the `DEP_<LINKS>___BB` variable they produce.
pub fn contains_sentinel(s: &str) -> bool {
    let b = s.as_bytes();
    b.windows(4).enumerate().any(|(i, w)| {
        w.eq_ignore_ascii_case(b"__bb") && b.get(i + 4).is_none_or(|c| !c.is_ascii_alphanumeric())
    })
}

/// Characters that can continue a path name; a forbidden path only matches
/// where it is not part of a longer name.
fn is_path_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c >= 0x80 || matches!(c, b'.' | b'-' | b'_' | b'+' | b'~' | b'/')
}

/// Whether `literal` contains the absolute path `path`, or a path below it.
///
/// The match must start the literal, follow a delimiter (`=`, `:`, `,`,
/// whitespace, quotes, `@`, `;`) or follow a short flag with an attached value
/// (`-L/build/x`), and must end the literal or be followed by `/` or a
/// non-path character. So `/build` matches `/build`, `dependency=/build/x`
/// and `-L/build`, but not `/build.rs`, `/buildx` or `/nix/store/…/build`.
pub fn contains_path(literal: &str, path: &str) -> bool {
    let path = path.trim_end_matches('/');
    if path.is_empty() {
        return false;
    }
    let l = literal.as_bytes();
    let mut from = 0;
    while let Some(off) = literal[from..].find(path) {
        let i = from + off;
        let end = i + path.len();
        let start_ok = i == 0
            || !is_path_char(l[i - 1])
            || (i == 2 && l[0] == b'-' && l[1].is_ascii_alphabetic());
        let end_ok = end == l.len() || l[end] == b'/' || !is_path_char(l[end]);
        if start_ok && end_ok {
            return true;
        }
        from = i + 1;
        while !literal.is_char_boundary(from) {
            from += 1;
        }
    }
    false
}

/// Every store path named in a literal of the plan: `<store_dir>/<name>` up
/// to the next `/` or delimiter.
pub fn literal_store_paths(plan: &Plan, store_dir: &str) -> BTreeSet<String> {
    let prefix = format!("{}/", store_dir.trim_end_matches('/'));
    let mut out = BTreeSet::new();
    for unit in plan.units.values() {
        for_each_literal(unit, &mut |s, _| {
            let mut rest = s;
            while let Some(i) = rest.find(&prefix) {
                let after = &rest[i + prefix.len()..];
                let name_len = after
                    .find(|c: char| !(c.is_ascii_alphanumeric() || "+-._?=".contains(c)))
                    .unwrap_or(after.len());
                if name_len > 0 {
                    out.insert(format!("{prefix}{}", &after[..name_len]));
                }
                rest = &after[name_len..];
            }
        });
    }
    out
}

/// Check the plan. Returns every problem found, not just the first.
pub fn validate(plan: &Plan, opts: &ValidationOptions) -> Result<(), Vec<ValidationError>> {
    let mut errors = Vec::new();
    let mut err = |unit: Option<&str>, message: String| {
        errors.push(ValidationError {
            unit: unit.map(str::to_owned),
            message,
        })
    };

    if plan.version != PLAN_VERSION {
        err(None, format!("unsupported plan version {}", plan.version));
    }

    let mut forbidden: Vec<&str> = opts.forbidden_paths.iter().map(String::as_str).collect();
    forbidden.push(&plan.skeleton_root);

    // Doctests are checked as compile units without outputs; their
    // searchPathsOf splices are checked below.
    let doctests: Vec<(&String, Unit)> = plan
        .doctests
        .iter()
        .map(|(id, d)| (id, Unit::Compile(d.as_compile())))
        .collect();
    for (id, d) in &plan.doctests {
        for a in &d.args {
            if let Arg::SearchPaths(s) = a {
                for r in &s.search_paths_of {
                    if !matches!(plan.units.get(r), Some(Unit::Run(_))) {
                        err(
                            Some(id),
                            format!("searchPathsOf names {r}, which is not a run unit"),
                        );
                    }
                }
            }
        }
    }
    let units = plan
        .units
        .iter()
        .chain(doctests.iter().map(|(id, u)| (*id, u)));
    for (id, unit) in units {
        let id_ = Some(id.as_str());
        if let Unit::Compile(c) = unit
            && c.args.iter().any(|a| matches!(a, Arg::SearchPaths(_)))
        {
            err(id_, "a searchPathsOf splice outside a doctest".into());
        }

        // Invariant 3: literals.
        for_each_literal(unit, &mut |s, what| {
            for p in &forbidden {
                if contains_path(s, p) {
                    err(
                        id_,
                        format!("{} contains the forbidden path `{p}`: `{s}`", what()),
                    );
                }
            }
            if contains_sentinel(s) {
                err(id_, format!("{} contains a sentinel token: `{s}`", what()));
            }
        });

        // Invariant 2: references.
        for_each_reference(unit, &mut |r, what| {
            if let Err(m) = check_reference(plan, r) {
                err(id_, format!("{}: {m}", what()));
            }
        });

        match unit {
            Unit::Compile(c) => {
                let splices: Vec<(usize, &Splice)> = c
                    .args
                    .iter()
                    .enumerate()
                    .filter_map(|(i, a)| match a {
                        Arg::Splice(s) => Some((i, s)),
                        _ => None,
                    })
                    .collect();
                if let Err(e) = check_arg_splices(&splices) {
                    err(id_, e.0);
                }
                for (_, s) in &splices {
                    if let Err(m) = check_splice_target(plan, s) {
                        err(id_, m);
                    }
                }
                let mut seen = BTreeSet::new();
                for s in &c.env_splices {
                    if s.kind != SpliceKind::RustcEnv || s.check_shape().is_err() {
                        err(
                            id_,
                            format!("envSplices entry from {} has kind {}", s.splice, s.kind),
                        );
                    }
                    if !seen.insert(&s.splice) {
                        err(id_, format!("envSplices names {} twice", s.splice));
                    }
                    if let Err(m) = check_splice_target(plan, s) {
                        err(id_, m);
                    }
                }
                check_dylib_path(plan, &c.dylib_path_from, &mut |m| err(id_, m));
                for (output, files) in &c.outputs {
                    for f in files {
                        if f.is_empty() || f.contains('/') {
                            err(
                                id_,
                                format!("output `{output}` lists invalid file name `{f}`"),
                            );
                        }
                    }
                }
            }
            Unit::Run(r) => {
                match &r.script {
                    Reference::Out(o)
                        if matches!(plan.units.get(&o.out), Some(Unit::Compile(_))) => {}
                    other => err(
                        id_,
                        format!("script is not an output of a compile unit: {other:?}"),
                    ),
                }
                check_dylib_path(plan, &r.dylib_path_from, &mut |m| err(id_, m));
                for up in &r.metadata_from {
                    match plan.units.get(up) {
                        _ if up == id => err(id_, "metadataFrom names the run itself".into()),
                        Some(Unit::Run(u)) if u.links.is_some() => {}
                        Some(Unit::Run(_)) => err(
                            id_,
                            format!("metadataFrom names {up}, whose package declares no `links`"),
                        ),
                        Some(Unit::Compile(_)) => {
                            err(id_, format!("metadataFrom names compile unit {up}"))
                        }
                        None => err(id_, format!("metadataFrom names unknown unit {up}")),
                    }
                }
                if let Some(v) = &r.rust_version
                    && let Err(e) = breakbulk_unit::directives::msrv_allows_new_syntax(v)
                {
                    err(id_, e.0);
                }
            }
        }
    }

    let mut seen_roots = BTreeMap::new();
    for root in &plan.roots {
        match plan.units.get(&root.unit) {
            Some(Unit::Compile(_)) => {}
            _ => err(
                None,
                format!(
                    "root {}/{} names unit {}, which is not a compile unit in the plan",
                    root.package, root.target, root.unit
                ),
            ),
        }
        if let Some(prev) = seen_roots.insert(
            (&root.package, &root.target, root.kind, root.test),
            &root.unit,
        ) {
            err(
                None,
                format!(
                    "root {}/{} appears twice (units {prev} and {})",
                    root.package, root.target, root.unit
                ),
            );
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

fn check_reference(plan: &Plan, r: &Reference) -> Result<(), String> {
    let rel = match r {
        Reference::Src(s) => &s.rel,
        Reference::CrateSrc(s) => &s.rel,
        Reference::Out(o) => {
            return match plan.units.get(&o.out) {
                None => Err(format!("reference to unknown unit {}", o.out)),
                Some(Unit::Run(_)) => match (o.output.as_str(), &o.file) {
                    ("out", None) => Ok(()),
                    _ => Err(format!(
                        "reference to run unit {} must be output `out` without a file",
                        o.out
                    )),
                },
                Some(Unit::Compile(c)) => match (c.outputs.get(&o.output), &o.file) {
                    (None, _) => Err(format!("unit {} has no output `{}`", o.out, o.output)),
                    (Some(files), Some(f)) if !files.contains(f) => Err(format!(
                        "unit {} output `{}` has no file `{f}`",
                        o.out, o.output
                    )),
                    _ => Ok(()),
                },
            };
        }
    };
    if rel.starts_with('/') {
        return Err(format!("`rel` must be relative: `{rel}`"));
    }
    Ok(())
}

/// Dynamic-path splices name run units, each once.
fn check_dylib_path(plan: &Plan, runs: &[String], err: &mut dyn FnMut(String)) {
    let mut seen = BTreeSet::new();
    for r in runs {
        if !seen.insert(r) {
            err(format!("dylibPathFrom names {r} twice"));
        }
        if !matches!(plan.units.get(r), Some(Unit::Run(_))) {
            err(format!("dylibPathFrom names {r}, which is not a run unit"));
        }
    }
}

fn check_splice_target(plan: &Plan, s: &Splice) -> Result<(), String> {
    match plan.units.get(&s.splice) {
        Some(Unit::Run(r)) => {
            for bin in s.kinds.iter().flatten().filter_map(|k| k.bin.as_ref()) {
                if !r.targets.iter().any(|t| t.is_bin() && &t.name == bin) {
                    return Err(format!(
                        "splice {} names bin `{bin}`, which run {} has no bin target for",
                        s.kind, s.splice
                    ));
                }
            }
            Ok(())
        }
        Some(Unit::Compile(_)) => Err(format!("splice {} names compile unit {}", s.kind, s.splice)),
        None => Err(format!("splice {} names unknown unit {}", s.kind, s.splice)),
    }
}
