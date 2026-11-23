//! Rendering a doc plan's `doc` units into the `BREAKBULK_UNIT` of its
//! docs derivation (`kind: docs`, which `breakbulk-docs` builds), and
//! the command part rustdoc units (docs and doctests) share.

use std::collections::BTreeSet;

use breakbulk_unit::spec::{Hints, RenderedArg, RenderedCompile, RenderedDocs, RenderedUnit};

use crate::deps::doc_deps;
use crate::normalize::normalize_unit;
use crate::plan::{Arg, OutRef, Plan, Reference, Text, Unit, UnitId, doc_order};
use crate::render::{Resolve, env, flags, search_paths, splice, text};

/// Render every doc unit of `plan`, in [`doc_order`]. Each is rendered as
/// a compile unit with no outputs and no remapping: rustdoc writes into
/// the one output the derivation gives every command.
///
/// # Panics
///
/// If the doc units' `after` edges form a cycle (validated).
pub fn render_docs<R: Resolve>(plan: &Plan, r: &R) -> Result<RenderedUnit, R::Error> {
    let order = doc_order(plan).unwrap_or_else(|e| panic!("{e} (validated)"));
    let commands = order
        .iter()
        .map(|id| {
            let mut d = plan.units[id].clone();
            normalize_unit(&mut d);
            let deps = doc_deps(plan, &d);
            rustdoc_command(id, &d, r, deps, Vec::new(), false)
        })
        .collect::<Result<_, _>>()?;
    Ok(RenderedUnit::Docs(RenderedDocs { commands }))
}

/// A rustdoc unit (a doc or a doctest, normalized) as a rendered compile
/// with no outputs and no remapping: rustdoc keeps nothing it writes but
/// what the derivation gives it. Its splices name every run they splice
/// as an input, as it reads no manifests. `deps` is its dependency
/// directory, `link_captures` its linked packages' env captures, and
/// `with_view` whether it names its source view, for hints.
pub(crate) fn rustdoc_command<R: Resolve>(
    id: &UnitId,
    d: &Unit,
    r: &R,
    deps: BTreeSet<OutRef>,
    link_captures: Vec<String>,
    with_view: bool,
) -> Result<RenderedCompile, R::Error> {
    let overlay = r.env_overlay(id, d)?;
    let env_capture = r.env_capture(id, d)?;
    let (env, env_append) = crate::render::recorded_env(env(&d.env, r)?);
    let strong = BTreeSet::new();
    Ok(RenderedCompile {
        package: d.package.clone(),
        krate: d.krate().clone(),
        platform: d.platform,
        program: d
            .program
            .iter()
            .map(|t| text(t, r))
            .collect::<Result<_, _>>()?,
        args: d
            .args
            .iter()
            .map(|a| {
                Ok(match a {
                    Arg::Literal(s) => RenderedArg::Literal(s.clone()),
                    Arg::Concat(p) => RenderedArg::Literal(text(&Text::Concat(p.clone()), r)?),
                    Arg::Splice(s) => RenderedArg::Splice(splice(s, r, &strong)?),
                    Arg::SearchPaths(s) => RenderedArg::SearchPaths(search_paths(s, r)?),
                    Arg::Runner(s) => RenderedArg::Runner(*s),
                })
            })
            .collect::<Result<_, _>>()?,
        env,
        env_append,
        env_layers: overlay,
        env_splices: d
            .env_splices
            .iter()
            .map(|s| splice(s, r, &strong))
            .collect::<Result<_, _>>()?,
        dylib_path_from: d
            .dylib_path_from
            .iter()
            .map(|u| flags(u, r, &strong))
            .collect::<Result<_, _>>()?,
        cwd: d.cwd.render(r)?,
        outputs: Vec::new(),
        deps: deps
            .into_iter()
            .map(|o| r.reference(&Reference::Out(o)))
            .collect::<Result<_, _>>()?,
        dep_manifests: Vec::new(),
        link_manifest_crates: false,
        manifest_crates: Vec::new(),
        remap: Vec::new(),
        remap_scope: None,
        env_capture,
        link_captures,
        hints: Hints {
            view: if with_view {
                r.source_view(id, d)?
            } else {
                None
            },
            repository_paths: Vec::new(),
        },
        // rustdoc compiles no C; the derivation adds no C flags.
        seed: None,
    })
}
