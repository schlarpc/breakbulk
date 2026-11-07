//! Rendering a plan's doctest into the `BREAKBULK_UNIT` of a doctest
//! derivation (`breakbulk-unit doctest`, see `breakbulk_unit::doctest`).

use breakbulk_unit::doctest::{DoctestKind, RenderedDoctest};
use breakbulk_unit::env::merge_layer;
use breakbulk_unit::spec::{RenderedArg, RenderedCompile};

use crate::normalize::{normalize_arg, normalize_text};
use crate::plan::{Arg, Plan, Reference, Text, Unit};
use std::collections::BTreeSet;

use crate::deps::doctest_deps;
use crate::render::{Resolve, env, flags, splice, text};

/// Render doctest `id` (`d-<package>`) of `plan`. The doctest is rendered as
/// a linking compile unit with no outputs and no remapping (rustdoc keeps
/// nothing it writes); its `searchPathsOf` splice becomes the list of runs'
/// `flags` outputs and its position in the arguments.
///
/// # Panics
///
/// If `id` is not a doctest of `plan`.
pub fn render_doctest<R: Resolve>(
    plan: &Plan,
    id: &str,
    r: &R,
) -> Result<RenderedDoctest, R::Error> {
    let mut d = plan
        .doctests
        .get(id)
        .unwrap_or_else(|| panic!("{id} is not a doctest of the plan"))
        .clone();
    d.program = std::mem::take(&mut d.program)
        .into_iter()
        .map(normalize_text)
        .collect();
    d.args = std::mem::take(&mut d.args)
        .into_iter()
        .map(normalize_arg)
        .collect();
    for v in d.env.values_mut() {
        *v = normalize_text(std::mem::replace(v, Text::Literal(String::new())));
    }
    d.krate.types.sort();
    d.krate.types.dedup();

    let at = d
        .args
        .iter()
        .position(|a| matches!(a, Arg::SearchPaths(_)))
        .unwrap_or(d.args.len());
    let mut runs: Vec<String> = d
        .args
        .iter()
        .filter_map(|a| match a {
            Arg::SearchPaths(s) => Some(s.search_paths_of.iter().cloned()),
            _ => None,
        })
        .flatten()
        .collect();
    runs.sort();
    runs.dedup();

    let c = d.as_compile();
    let id = id.to_owned();
    let unit = Unit::Compile(c.clone());
    let overlay = r.env_overlay(&id, &unit)?;
    let env_capture = r.env_capture(&id, &unit)?;
    let mut env = env(&c.env, r)?;
    merge_layer(&mut env, overlay);
    // A doctest reads no manifests: every run it splices is an input.
    let strong = BTreeSet::new();
    let compile = RenderedCompile {
        package: c.package.clone(),
        krate: c.krate.clone(),
        platform: c.platform,
        program: c
            .program
            .iter()
            .map(|t| text(t, r))
            .collect::<Result<_, _>>()?,
        args: c
            .args
            .iter()
            .map(|a| {
                Ok(match a {
                    Arg::Literal(s) => RenderedArg::Literal(s.clone()),
                    Arg::Concat(p) => RenderedArg::Literal(text(&Text::Concat(p.clone()), r)?),
                    Arg::Splice(s) => RenderedArg::Splice(splice(s, r, &strong)?),
                    Arg::SearchPaths(_) => unreachable!("as_compile drops searchPathsOf"),
                })
            })
            .collect::<Result<_, _>>()?,
        env,
        env_splices: c
            .env_splices
            .iter()
            .map(|s| splice(s, r, &strong))
            .collect::<Result<_, _>>()?,
        dylib_path_from: c
            .dylib_path_from
            .iter()
            .map(|u| flags(u, r, &strong))
            .collect::<Result<_, _>>()?,
        cwd: r.reference(&c.cwd)?,
        outputs: Default::default(),
        deps: doctest_deps(plan, &c)
            .into_iter()
            .map(|o| r.reference(&Reference::Out(o)))
            .collect::<Result<_, _>>()?,
        dep_manifests: Vec::new(),
        link_manifest_crates: false,
        manifest_crates: Vec::new(),
        remap: Vec::new(),
        remap_scope: None,
        env_capture,
        // rustdoc compiles no C; the doctest adds no C flags.
        seed: None,
    };
    Ok(RenderedDoctest {
        kind: DoctestKind::Doctest,
        compile,
        search_paths_of: runs.iter().map(|u| r.flags(u)).collect::<Result<_, _>>()?,
        search_paths_at: at,
    })
}
