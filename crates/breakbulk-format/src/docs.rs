//! Rendering a doc plan's rustdoc commands into the `BREAKBULK_UNIT` of its
//! docs derivation (`breakbulk-unit docs`, see `breakbulk_unit::docs`).

use std::collections::BTreeSet;

use breakbulk_unit::docs::{DocsKind, RenderedDocs};
use breakbulk_unit::spec::{RenderedArg, RenderedCompile};

use crate::deps::doc_deps;
use crate::normalize::{normalize_arg, normalize_text};
use crate::plan::{Arg, Doc, Plan, Reference, Text, Unit};
use crate::render::{Resolve, env, flags, splice, text};

/// Render every rustdoc command of `plan`, in the plan's order. Each is
/// rendered as a compile unit with no outputs and no remapping: rustdoc
/// writes into the one output the derivation gives every command.
pub fn render_docs<R: Resolve>(plan: &Plan, r: &R) -> Result<RenderedDocs, R::Error> {
    let commands = plan
        .docs
        .iter()
        .enumerate()
        .map(|(i, d)| render_doc(plan, &d.label(i), d, r))
        .collect::<Result<_, _>>()?;
    Ok(RenderedDocs {
        kind: DocsKind::Docs,
        commands,
    })
}

fn render_doc<R: Resolve>(
    plan: &Plan,
    id: &str,
    d: &Doc,
    r: &R,
) -> Result<RenderedCompile, R::Error> {
    let mut d = d.clone();
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

    let c = d.as_compile();
    let id = id.to_owned();
    let unit = Unit::Compile(c.clone());
    let overlay = r.env_overlay(&id, &unit)?;
    let env_capture = r.env_capture(&id, &unit)?;
    let mut env = env(&c.env, r)?;
    crate::render::merge_layer_with(r, &mut env, overlay)?;
    // The docs derivation reads no manifests: every run it splices is an
    // input.
    let strong = BTreeSet::new();
    Ok(RenderedCompile {
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
                    Arg::SearchPaths(_) => {
                        unreachable!("searchPathsOf only in doctests (validated)")
                    }
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
        cwd: c.cwd.render(r)?,
        outputs: Default::default(),
        uplifted: Default::default(),
        deps: doc_deps(plan, &c)
            .into_iter()
            .map(|o| r.reference(&Reference::Out(o)))
            .collect::<Result<_, _>>()?,
        dep_manifests: Vec::new(),
        link_manifest_crates: false,
        manifest_crates: Vec::new(),
        remap: Vec::new(),
        remap_scope: None,
        env_capture,
        link_captures: Vec::new(),
        view: None,
        seed: None,
    })
}
