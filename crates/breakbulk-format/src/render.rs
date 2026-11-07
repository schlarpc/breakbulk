//! Rendering a plan unit into the `BREAKBULK_UNIT` value.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use breakbulk_unit::env::merge_layer;
use breakbulk_unit::spec::{RenderedArg, RenderedCompile, RenderedRun, RenderedUnit};

use crate::normalize::normalize_unit;
use crate::plan::{
    Arg, CompileUnit, CrateSrcRef, OutRef, Piece, Plan, Reference, RunUnit, SrcRef, Text, Unit,
    UnitId, for_each_reference,
};
use crate::{CanonicalError, Splice, to_canonical_json};

/// How instantiation resolves what a unit names, and the per-unit choices
/// that come from configuration rather than from the plan.
pub trait Resolve {
    type Error;
    /// The literal path a reference stands for.
    fn reference(&self, r: &Reference) -> Result<String, Self::Error>;
    /// The `flags` output directory of a run unit.
    fn flags(&self, run: &UnitId) -> Result<String, Self::Error>;
    /// The stable name a source base is remapped to with
    /// `--remap-path-prefix`. `base` is a `src` or `crateSrc` reference with
    /// an empty `rel` (a source view or crate source), or a run's `out`
    /// reference (an `OUT_DIR`). See [`remap_bases`].
    fn remap_name(&self, base: &Reference) -> Result<String, Self::Error>;
    /// The `--remap-path-scope` for a compile unit, or `None` for no scope
    /// flag (every scope). See [`default_remap_scope`].
    fn remap_scope(&self, _id: &UnitId, _unit: &CompileUnit) -> Option<String> {
        None
    }
    /// The env capture (`env.json`) for the unit's package and platform:
    /// layer 2 of the environment contract.
    fn env_capture(&self, _id: &UnitId, _unit: &Unit) -> Result<Option<String>, Self::Error> {
        Ok(None)
    }
    /// Layers 4 and 5 of the environment contract, merged with
    /// [`merge_layer`] (list-like variables such as `PATH` append): the
    /// toolchain spec's env for the unit's platform, then the package
    /// override's. Applied over Cargo's recorded env the same way.
    fn env_overlay(
        &self,
        _id: &UnitId,
        _unit: &Unit,
    ) -> Result<BTreeMap<String, String>, Self::Error> {
        Ok(BTreeMap::new())
    }
    /// `strictSources` for a run's package.
    fn strict_sources(&self, _id: &UnitId, _run: &RunUnit) -> bool {
        false
    }
}

fn text<R: Resolve>(t: &Text, r: &R) -> Result<String, R::Error> {
    match t {
        Text::Literal(s) => Ok(s.clone()),
        Text::Concat(pieces) => {
            let mut out = String::new();
            for p in pieces {
                match p {
                    Piece::Literal(s) => out.push_str(s),
                    Piece::Ref(x) => out.push_str(&r.reference(x)?),
                }
            }
            Ok(out)
        }
    }
}

fn env<R: Resolve>(
    e: &BTreeMap<String, Text>,
    r: &R,
) -> Result<BTreeMap<String, String>, R::Error> {
    e.iter()
        .map(|(k, v)| Ok((k.clone(), text(v, r)?)))
        .collect()
}

fn splice<R: Resolve>(s: &Splice, r: &R) -> Result<breakbulk_unit::spec::Splice<String>, R::Error> {
    let flags = r.flags(&s.splice)?;
    Ok(s.map(|_| flags))
}

/// Whether a compile unit links: its own output needs the `rlib`s of its
/// whole dependency graph, not only their metadata.
pub fn is_linking(c: &CompileUnit) -> bool {
    c.krate.types.iter().any(|t| {
        matches!(
            t.as_str(),
            "bin" | "dylib" | "cdylib" | "staticlib" | "proc-macro"
        )
    }) || c
        .args
        .iter()
        .any(|a| matches!(a, Arg::Literal(s) if s == "--test"))
}

fn is_proc_macro(c: &CompileUnit) -> bool {
    c.krate.types.iter().any(|t| t == "proc-macro")
}

/// The crate files a compile unit names directly in its arguments: `out`
/// references to another compile unit's outputs other than `bin`.
fn direct_crate_refs<'a>(plan: &'a Plan, c: &'a CompileUnit) -> impl Iterator<Item = &'a OutRef> {
    c.args.iter().flat_map(move |a| {
        let pieces: &[Piece] = match a {
            Arg::Concat(p) => p,
            _ => &[],
        };
        pieces.iter().filter_map(move |p| match p {
            Piece::Ref(Reference::Out(o))
                if o.output != "bin"
                    && matches!(plan.units.get(&o.out), Some(Unit::Compile(_))) =>
            {
                Some(o)
            }
            _ => None,
        })
    })
}

/// Every crate file rustc may need to load for unit `id`: the files its
/// arguments name, plus, for each of those crates, the crates it depends on,
/// transitively. This replaces Cargo's shared `deps` directory.
///
/// Transitive crates are taken as `rlib` when the unit links (see [`is_linking`])
/// and as `rmeta` otherwise, falling back to whatever the dependency's own
/// arguments named when that output does not exist. A proc macro's
/// dependencies are not followed: they are linked into the proc macro, and
/// rustc does not load them.
///
/// # Panics
///
/// If `id` is not a compile unit of `plan`.
pub fn crate_deps(plan: &Plan, id: &UnitId) -> BTreeSet<OutRef> {
    let Some(Unit::Compile(c)) = plan.units.get(id) else {
        panic!("{id} is not a compile unit of the plan");
    };
    let want = if is_linking(c) { "rlib" } else { "rmeta" };
    let mut out: BTreeSet<OutRef> = BTreeSet::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut queue: VecDeque<&str> = VecDeque::new();
    for o in direct_crate_refs(plan, c) {
        out.insert(o.clone());
        if seen.insert(&o.out) {
            queue.push_back(&o.out);
        }
    }
    while let Some(dep) = queue.pop_front() {
        let Some(Unit::Compile(d)) = plan.units.get(dep) else {
            continue;
        };
        if is_proc_macro(d) {
            continue;
        }
        for o in direct_crate_refs(plan, d) {
            let Some(Unit::Compile(e)) = plan.units.get(&o.out) else {
                continue;
            };
            let chosen = match e.outputs.get(want) {
                Some(files) if files.len() == 1 && !is_proc_macro(e) => OutRef {
                    out: o.out.clone(),
                    output: want.to_owned(),
                    file: files.iter().next().cloned(),
                },
                _ => o.clone(),
            };
            out.insert(chosen);
            if seen.insert(&o.out) {
                queue.push_back(&o.out);
            }
        }
    }
    out
}

/// The bases a compile unit's paths are remapped from: the source view or
/// crate source of every `src` and `crateSrc` reference (with `rel` empty),
/// and every run `out` reference (an `OUT_DIR`).
pub fn remap_bases(plan: &Plan, unit: &Unit) -> BTreeSet<Reference> {
    let mut bases = BTreeSet::new();
    for_each_reference(unit, &mut |r, _| {
        let base = match r {
            Reference::Src(s) => Reference::Src(SrcRef {
                src: s.src.clone(),
                rel: String::new(),
            }),
            Reference::CrateSrc(s) => Reference::CrateSrc(CrateSrcRef {
                crate_src: s.crate_src.clone(),
                rel: String::new(),
            }),
            Reference::Out(o) if matches!(plan.units.get(&o.out), Some(Unit::Run(_))) => {
                Reference::Out(OutRef {
                    out: o.out.clone(),
                    output: "out".into(),
                    file: None,
                })
            }
            Reference::Out(_) => return,
        };
        bases.insert(base);
    });
    bases
}

/// The remap scope the design gives a compile unit ("Source paths at run
/// time" in `docs/implementation.md`): test binaries remap every scope
/// (`None`); everything else, when its product gets `splitDebug`, remaps
/// `macro,diagnostics` (plus `coverage` in coverage variants) and keeps store
/// paths in debug info; without `splitDebug`, every scope.
pub fn default_remap_scope(
    unit: &CompileUnit,
    split_debug: bool,
    coverage: bool,
) -> Option<String> {
    let is_test = unit
        .args
        .iter()
        .any(|a| matches!(a, Arg::Literal(s) if s == "--test"));
    if is_test || !split_debug {
        return None;
    }
    Some(
        if coverage {
            "macro,diagnostics,coverage"
        } else {
            "macro,diagnostics"
        }
        .to_owned(),
    )
}

/// Render unit `id` of `plan`: every reference becomes a path, every splice
/// names its run's `flags` directory, and the configuration-dependent parts
/// (env layers, remapping, dependency files) are filled in. The unit is
/// normalized first, so equal units render equally.
///
/// # Panics
///
/// If `id` is not a unit of `plan`.
pub fn render_unit<R: Resolve>(plan: &Plan, id: &UnitId, r: &R) -> Result<RenderedUnit, R::Error> {
    let mut unit = plan
        .units
        .get(id)
        .unwrap_or_else(|| panic!("{id} is not a unit of the plan"))
        .clone();
    normalize_unit(&mut unit);
    let overlay = r.env_overlay(id, &unit)?;
    let env_capture = r.env_capture(id, &unit)?;
    Ok(match &unit {
        Unit::Compile(c) => {
            let mut env = env(&c.env, r)?;
            merge_layer(&mut env, overlay);
            let (remap, remap_scope) = if plan.trim_paths {
                (Vec::new(), None)
            } else {
                let mut remap = remap_bases(plan, &unit)
                    .iter()
                    .map(|b| {
                        let from = r.reference(b)?;
                        let from = match from.trim_end_matches('/') {
                            "" => from,
                            f => f.to_owned(),
                        };
                        Ok((from, r.remap_name(b)?))
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                remap.sort();
                remap.dedup();
                (remap, r.remap_scope(id, c))
            };
            RenderedUnit::Compile(RenderedCompile {
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
                            Arg::Concat(p) => {
                                RenderedArg::Literal(text(&Text::Concat(p.clone()), r)?)
                            }
                            Arg::Splice(s) => RenderedArg::Splice(splice(s, r)?),
                            Arg::SearchPaths(_) => {
                                panic!("searchPathsOf splices appear only in doctests (validated)")
                            }
                        })
                    })
                    .collect::<Result<_, _>>()?,
                env,
                env_splices: c
                    .env_splices
                    .iter()
                    .map(|s| splice(s, r))
                    .collect::<Result<_, _>>()?,
                dylib_path_from: c
                    .dylib_path_from
                    .iter()
                    .map(|u| r.flags(u))
                    .collect::<Result<_, _>>()?,
                cwd: r.reference(&c.cwd)?,
                outputs: c
                    .outputs
                    .iter()
                    .map(|(k, v)| (k.clone(), v.iter().cloned().collect()))
                    .collect(),
                deps: crate_deps(plan, id)
                    .into_iter()
                    .map(|o| r.reference(&Reference::Out(o)))
                    .collect::<Result<_, _>>()?,
                remap,
                remap_scope,
                env_capture,
            })
        }
        Unit::Run(run) => {
            // breakbulk-unit sets OUT_DIR to the run's own `out`, which a
            // derivation cannot name in its own attributes. Dropped before
            // resolving, so the resolver never sees the self-reference.
            let mut recorded = run.env.clone();
            recorded.remove("OUT_DIR");
            let mut env = env(&recorded, r)?;
            merge_layer(&mut env, overlay);
            RenderedUnit::Run(RenderedRun {
                package: run.package.clone(),
                platform: run.platform,
                links: run.links.clone(),
                script: r.reference(&run.script)?,
                env,
                cwd: r.reference(&run.cwd)?,
                metadata_from: run
                    .metadata_from
                    .iter()
                    .map(|u| r.flags(u))
                    .collect::<Result<_, _>>()?,
                dylib_path_from: run
                    .dylib_path_from
                    .iter()
                    .map(|u| r.flags(u))
                    .collect::<Result<_, _>>()?,
                rust_version: run.rust_version.clone(),
                targets: run.targets.clone(),
                nightly_features_allowed: run.nightly_features_allowed,
                env_capture,
                // Prefix maps for C code the script compiles. Not tied to
                // `trimPaths`: Cargo's own remaps never reach C compilers.
                remap: run_remap(plan, id, &unit, r)?,
                out_dir_remap: Some(r.remap_name(&Reference::Out(OutRef {
                    out: id.clone(),
                    output: "out".into(),
                    file: None,
                }))?),
                strict_sources: r.strict_sources(id, run),
            })
        }
    })
}

/// A run's remap pairs: as a compile unit's, from [`remap_bases`], without
/// its own `OUT_DIR` (`out_dir_remap`), which it cannot name.
fn run_remap<R: Resolve>(
    plan: &Plan,
    id: &UnitId,
    unit: &Unit,
    r: &R,
) -> Result<Vec<(String, String)>, R::Error> {
    let mut remap = remap_bases(plan, unit)
        .iter()
        .filter(|b| !matches!(b, Reference::Out(o) if &o.out == id))
        .map(|b| {
            let from = r.reference(b)?;
            let from = match from.trim_end_matches('/') {
                "" => from,
                f => f.to_owned(),
            };
            Ok((from, r.remap_name(b)?))
        })
        .collect::<Result<Vec<_>, _>>()?;
    remap.sort();
    remap.dedup();
    Ok(remap)
}

/// The `BREAKBULK_UNIT` value: canonical JSON of a rendered unit.
pub fn unit_env_value(unit: &RenderedUnit) -> Result<String, CanonicalError> {
    to_canonical_json(unit)
}
