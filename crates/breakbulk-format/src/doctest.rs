//! Rendering a plan's doctest unit into the `BREAKBULK_UNIT` of a doctest
//! derivation (`kind: doctest`, which `breakbulk-doctest` builds).

use std::collections::BTreeSet;

use breakbulk_unit::spec::{RenderedDoctest, RenderedUnit};

use crate::deps::{doctest_deps, runs_of, units_below_unit};
use crate::docs::rustdoc_command;
use crate::normalize::normalize_unit;
use crate::plan::{Arg, Plan, Platform, SearchPathsSplice, Unit, UnitKind};
use crate::render::{Resolve, link_packages};

/// Render doctest unit `id` (`d-<package>`) of `plan`. The doctest is
/// rendered as a linking compile unit with no outputs and no remapping
/// (rustdoc keeps nothing it writes), with one `searchPathsOf` splice
/// where the first was.
///
/// The traced `-L` list and dynamic-library path name every run of the
/// invocation (Cargo's whole-build `native_dirs`). Rendered, they keep only
/// the runs in the doctest's own closure ([`closure_runs`]), so a run the
/// library does not depend on is not an input.
///
/// # Panics
///
/// If `id` is not a doctest unit of `plan`.
pub fn render_doctest<R: Resolve>(plan: &Plan, id: &str, r: &R) -> Result<RenderedUnit, R::Error> {
    let mut d = plan
        .units
        .get(id)
        .filter(|u| u.kind() == UnitKind::Doctest)
        .unwrap_or_else(|| panic!("{id} is not a doctest of the plan"))
        .clone();
    normalize_unit(&mut d);

    let at = d.args.iter().position(|a| matches!(a, Arg::SearchPaths(_)));
    let (search_runs, dylib_runs) = closure_runs(plan, &d);
    let mut runs: Vec<String> = Vec::new();
    let mut literals: Vec<String> = Vec::new();
    for a in &d.args {
        if let Arg::SearchPaths(s) = a {
            runs.extend(
                s.search_paths_of
                    .iter()
                    .filter(|u| search_runs.contains(*u))
                    .cloned(),
            );
            literals.extend(s.literals.iter().cloned());
        }
    }
    runs.sort();
    runs.dedup();
    literals.sort();
    literals.dedup();
    d.dylib_path_from.retain(|u| dylib_runs.contains(u));
    d.args.retain(|a| !matches!(a, Arg::SearchPaths(_)));
    if let Some(at) = at {
        d.args.insert(
            at,
            Arg::SearchPaths(SearchPathsSplice {
                search_paths_of: runs,
                literals,
            }),
        );
    }

    let id = id.to_owned();
    let deps = doctest_deps(plan, &d);
    let link_captures = r.link_captures(&id, &d, &link_packages(plan, &d, &deps))?;
    Ok(RenderedUnit::Doctest(RenderedDoctest {
        command: rustdoc_command(&id, &d, r, deps, link_captures, true)?,
        test: r.doctest_config(&id, &d)?,
    }))
}

/// The runs a doctest depends on: those of its platform, for its `-L`
/// list, and the host's, for its dynamic-library path (the proc macros
/// rustdoc loads). Cargo links a unit against the search paths of its
/// closure's build scripts only (`add_native_deps`, over
/// `build_scripts.to_link`), so the closure finds every library the
/// examples link. The traced `dylibPathFrom` and `searchPathsOf` name every
/// run of the invocation, so they are not followed.
pub fn closure_runs(plan: &Plan, d: &Unit) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut c = d.clone();
    c.dylib_path_from.clear();
    c.args.retain(|a| !matches!(a, Arg::SearchPaths(_)));
    let below = units_below_unit(plan, &c);
    (
        runs_of(plan, below.clone(), d.platform),
        runs_of(plan, below, Platform::Host),
    )
}
