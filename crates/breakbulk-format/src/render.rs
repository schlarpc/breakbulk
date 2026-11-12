//! Rendering a plan unit into the `BREAKBULK_UNIT` value.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_unit::env::{append, list_separator};
use breakbulk_unit::spec::{RenderedArg, RenderedCompile, RenderedRun, RenderedUnit, SourceView};

use crate::deps::Graph;
use crate::normalize::normalize_unit;
use crate::plan::{
    Arg, CompileUnit, CrateSrcRef, OutRef, Piece, Plan, Reference, RunUnit, SrcRef, Text, Unit,
    UnitId, VariantMode, for_each_reference,
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
    /// The same path, for a run the unit reaches only through its
    /// dependencies' manifests ([`crate::deps`]): the unit's derivation
    /// names it, but need not have it as an input. The default is
    /// [`Resolve::flags`].
    fn weak_flags(&self, run: &UnitId) -> Result<String, Self::Error> {
        self.flags(run)
    }
    /// The stable name a source base is remapped to with
    /// `--remap-path-prefix`. `base` is a `src` or `crateSrc` reference with
    /// an empty `rel` (a source view or crate source), or a run's `out`
    /// reference (an `OUT_DIR`). See [`remap_bases`].
    fn remap_name(&self, base: &Reference) -> Result<String, Self::Error>;
    /// The `--remap-path-scope` for a compile unit, or `None` for no scope
    /// flag (every scope); `breakbulk-instantiate` gives shipped units
    /// `macro,diagnostics` when their product splits debug info ("Source
    /// paths at run time" in `docs/src/reference/unit-builder.md`).
    fn remap_scope(&self, _id: &UnitId, _unit: &CompileUnit) -> Option<String> {
        None
    }
    /// `sourcePaths = "keep"`: breakbulk adds no remaps of
    /// its own, neither Rust (`--remap-path-prefix`, `--remap-path-scope`)
    /// nor C (`-ffile-prefix-map`). Cargo's own trim-paths remaps, when the
    /// project turned them on, stay in the arguments as traced.
    fn keep_source_paths(&self) -> bool {
        false
    }
    /// The env capture (`env.json`) for the unit's package and platform:
    /// layer 2 of the environment contract.
    fn env_capture(&self, _id: &UnitId, _unit: &Unit) -> Result<Option<String>, Self::Error> {
        Ok(None)
    }
    /// For a unit that links: the env captures of `packages` (the other
    /// packages of its link closure on its platform, [`link_packages`])
    /// that have inputs of their own, whose library search variables reach
    /// its linker. Packages without a capture of their own
    /// are left out.
    fn link_captures(
        &self,
        _id: &UnitId,
        _unit: &CompileUnit,
        _packages: &BTreeSet<String>,
    ) -> Result<Vec<String>, Self::Error> {
        Ok(Vec::new())
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
    /// For a compile unit clippy-driver runs on: the directory clippy
    /// starts its `clippy.toml` lookup in (`CLIPPY_CONF_DIR`), or `None` to
    /// leave clippy to its default (`CARGO_MANIFEST_DIR`). The unit's env
    /// layers still win over it, as a user's `CLIPPY_CONF_DIR` does under
    /// Cargo.
    fn clippy_conf_dir(
        &self,
        _id: &UnitId,
        _unit: &CompileUnit,
    ) -> Result<Option<String>, Self::Error> {
        Ok(None)
    }
    /// For a unit (or doctest) of a repository package: the source view it
    /// sees, for the hints when it fails naming a path the view lacks
    /// (`RenderedCompile::view`).
    fn source_view(&self, _id: &UnitId, _unit: &Unit) -> Result<Option<SourceView>, Self::Error> {
        Ok(None)
    }
    /// A list-like variable's `earlier` value followed by `later`, with
    /// `sep` between them ([`breakbulk_unit::env::append`]): an empty side
    /// is left out. A resolver whose values are placeholders, whose
    /// emptiness is known only once they are substituted, overrides this.
    fn append_list(&self, sep: char, earlier: &str, later: &str) -> Result<String, Self::Error> {
        Ok(append(sep, earlier, later))
    }
}

/// [`breakbulk_unit::env::merge_layer`] through [`Resolve::append_list`]:
/// `layer`'s values replace those in `env`, except that list-like variables
/// are appended.
pub fn merge_layer_with<R: Resolve>(
    r: &R,
    env: &mut BTreeMap<String, String>,
    layer: BTreeMap<String, String>,
) -> Result<(), R::Error> {
    for (k, v) in layer {
        let merged = match (list_separator(&k), env.get(&k)) {
            (Some(sep), Some(earlier)) => r.append_list(sep, earlier, &v)?,
            _ => v,
        };
        env.insert(k, merged);
    }
    Ok(())
}

pub(crate) fn text<R: Resolve>(t: &Text, r: &R) -> Result<String, R::Error> {
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

pub(crate) fn env<R: Resolve>(
    e: &BTreeMap<String, Text>,
    r: &R,
) -> Result<BTreeMap<String, String>, R::Error> {
    e.iter()
        .map(|(k, v)| Ok((k.clone(), text(v, r)?)))
        .collect()
}

pub(crate) fn splice<R: Resolve>(
    s: &Splice,
    r: &R,
    weak: &BTreeSet<UnitId>,
) -> Result<breakbulk_unit::spec::Splice<String>, R::Error> {
    let flags = flags(&s.splice, r, weak)?;
    Ok(s.map(|_| flags))
}

pub(crate) fn flags<R: Resolve>(
    run: &UnitId,
    r: &R,
    weak: &BTreeSet<UnitId>,
) -> Result<String, R::Error> {
    if weak.contains(run) {
        r.weak_flags(run)
    } else {
        r.flags(run)
    }
}

/// Whether a compile unit links: its own output needs the `rlib`s of its
/// whole dependency graph, not only their metadata. That is a `--test`
/// compile (a doctest's `rustdoc --test` too) or a crate type other than
/// `lib` and `rlib`, Cargo's `requires_upstream_objects`. Not the unit's
/// `test`: an example is a test unit, and one built as an `rlib` needs
/// only metadata. Cargo's other test-mode compiles pass no crate type,
/// which is a `bin`.
pub fn is_linking(c: &CompileUnit) -> bool {
    c.args
        .iter()
        .any(|a| matches!(a, Arg::Literal(s) if s == "--test"))
        || c.krate
            .types
            .iter()
            .any(|t| !matches!(t.as_str(), "lib" | "rlib"))
}

/// The packages a linking unit links, other than its own:
/// the packages of the crates in `crates` (its [`Graph::crate_deps`]) that
/// are on the unit's platform and are not proc macros. A target unit's
/// closure never reaches a host unit, and a proc macro's dependencies are
/// not followed ([`Graph::crate_deps`]), so host libraries never reach a
/// target link and the reverse.
pub fn link_packages<'a>(
    plan: &Plan,
    unit: &CompileUnit,
    crates: impl IntoIterator<Item = &'a OutRef>,
) -> BTreeSet<String> {
    crates
        .into_iter()
        .filter_map(|o| match plan.units.get(&o.out) {
            Some(Unit::Compile(d))
                if d.platform == unit.platform
                    && !crate::deps::is_proc_macro(d)
                    && d.package != unit.package =>
            {
                Some(d.package.clone())
            }
            _ => None,
        })
        .collect()
}

/// The bases a compile unit's paths are remapped from: the source view or
/// crate source of every `src` and `crateSrc` reference (with `rel` empty),
/// and every run `out` reference (an `OUT_DIR`). Not the directory of
/// `empty` references: no compiled file is in it.
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
            Reference::Out(_) | Reference::Empty(_) => return,
        };
        bases.insert(base);
    });
    bases
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
    render_unit_in(&Graph::new(plan), id, r)
}

/// [`render_unit`] with a [`Graph`] shared across the units of one plan,
/// which memoizes their dependency sets.
///
/// # Panics
///
/// If `id` is not a unit of the graph's plan.
pub fn render_unit_in<R: Resolve>(
    graph: &Graph,
    id: &UnitId,
    r: &R,
) -> Result<RenderedUnit, R::Error> {
    let plan = graph.plan;
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
            let deps = graph.unit_deps(id);
            let weak = &*deps.reachable_runs;
            let out = |o: OutRef| r.reference(&Reference::Out(o));
            let rmeta_dir = |u: &UnitId| {
                out(OutRef {
                    out: u.clone(),
                    output: "rmeta".into(),
                    file: None,
                })
            };
            let mut env = env(&c.env, r)?;
            // A wrapper chain in a clippy plan is clippy-driver over rustc.
            if plan.variant.mode == VariantMode::Clippy
                && c.program.len() > 1
                && let Some(dir) = r.clippy_conf_dir(id, c)?
            {
                env.insert("CLIPPY_CONF_DIR".into(), dir);
            }
            merge_layer_with(r, &mut env, overlay)?;
            let link_captures = if is_linking(c) {
                let packages = link_packages(plan, c, &graph.crate_deps(id));
                r.link_captures(id, c, &packages)?
            } else {
                Vec::new()
            };
            let (remap, remap_scope) = if r.keep_source_paths() {
                (Vec::new(), None)
            } else if plan.trim_paths {
                // Cargo's remaps are in the arguments. With the project's
                // own setting its scope is too; when breakbulk set it,
                // the scope is breakbulk's, per product kind.
                let scope = if plan.trim_paths_default {
                    r.remap_scope(id, c)
                } else {
                    None
                };
                (Vec::new(), scope)
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
                remap.extend(plan.rust_src_remap.clone());
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
                            Arg::Splice(s) => RenderedArg::Splice(splice(s, r, weak)?),
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
                    .map(|s| splice(s, r, weak))
                    .collect::<Result<_, _>>()?,
                dylib_path_from: c
                    .dylib_path_from
                    .iter()
                    .map(|u| flags(u, r, weak))
                    .collect::<Result<_, _>>()?,
                cwd: c.cwd.render(r)?,
                outputs: c
                    .outputs
                    .iter()
                    .map(|(k, v)| (k.clone(), v.iter().cloned().collect()))
                    .chain(
                        c.has_debug_output(&plan.target_debuginfo)
                            .then(|| (breakbulk_unit::spec::DEBUG_OUTPUT.to_owned(), Vec::new())),
                    )
                    .collect(),
                uplifted: c.uplifted.clone(),
                deps: sorted(deps.deps.iter().cloned().map(out))?,
                dep_manifests: sorted(deps.manifests.iter().map(rmeta_dir))?,
                link_manifest_crates: deps.link_manifest_crates,
                manifest_crates: sorted(deps.manifest_crates.iter().cloned().map(out))?,
                remap,
                remap_scope,
                env_capture,
                link_captures,
                view: r.source_view(id, &unit)?,
                seed: Some(id.to_string()),
            })
        }
        Unit::Run(run) => {
            // breakbulk-unit sets OUT_DIR to the run's own `out`, which a
            // derivation cannot name in its own attributes. Dropped before
            // resolving, so the resolver never sees the self-reference.
            let mut recorded = run.env.clone();
            recorded.remove("OUT_DIR");
            let mut env = env(&recorded, r)?;
            merge_layer_with(r, &mut env, overlay)?;
            let (remap, out_dir_remap) = if r.keep_source_paths() {
                (Vec::new(), None)
            } else if plan.trim_paths {
                cargo_run_remap(id, run, r)?
            } else {
                (
                    run_remap(plan, id, &unit, r)?,
                    Some(r.remap_name(&Reference::Out(OutRef {
                        out: id.clone(),
                        output: "out".into(),
                        file: None,
                    }))?),
                )
            };
            RenderedUnit::Run(RenderedRun {
                package: run.package.clone(),
                platform: run.platform,
                links: run.links.clone(),
                script: r.reference(&run.script)?,
                env,
                out_dir: run.out_dir.clone(),
                cwd: run.cwd.render(r)?,
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
                // Prefix maps for C code the script compiles: breakbulk's
                // names, or Cargo's under trim-paths (`cargo_run_remap`).
                remap,
                out_dir_remap,
                view: r.source_view(id, &unit)?,
                seed: Some(id.to_string()),
            })
        }
    })
}

/// Collect rendered paths, sorted and without duplicates.
fn sorted<E>(paths: impl Iterator<Item = Result<String, E>>) -> Result<Vec<String>, E> {
    Ok(paths
        .collect::<Result<BTreeSet<String>, E>>()?
        .into_iter()
        .collect())
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

/// A run's C prefix maps and its own `OUT_DIR`'s name.
type RunRemap = (Vec<(String, String)>, Option<String>);

/// A run's C prefix maps under Cargo's trim-paths: the
/// pairs of its `CARGO_TRIM_PATHS_REMAP` (the package and the sysroot,
/// which cc-rs turns into `-f*-prefix-map` flags itself) and Cargo's
/// build-directory pair expanded per `OUT_DIR` (`buildDirRemap`, which
/// the planner leaves out of the variable, because a run cannot name its
/// own `out`). So `__FILE__` and C debug info read as under Cargo and
/// breakbulk's maps agree with cc-rs's. Returns the pairs and the run's own
/// `OUT_DIR` name.
fn cargo_run_remap<R: Resolve>(id: &UnitId, run: &RunUnit, r: &R) -> Result<RunRemap, R::Error> {
    let mut remap = Vec::new();
    if let Some(v) = run.env.get("CARGO_TRIM_PATHS_REMAP") {
        for pair in text(v, r)?.split(':') {
            if let Some((from, to)) = pair.rsplit_once('=')
                && !from.is_empty()
            {
                remap.push((from.to_owned(), to.to_owned()));
            }
        }
    }
    let mut own = None;
    for (run_id, to) in &run.build_dir_remap {
        if run_id == id {
            own = Some(to.clone());
        } else {
            let from = r.reference(&Reference::Out(OutRef {
                out: run_id.clone(),
                output: "out".into(),
                file: None,
            }))?;
            remap.push((from, to.clone()));
        }
    }
    remap.sort();
    remap.dedup();
    Ok((remap, own))
}

/// The `BREAKBULK_UNIT` value: canonical JSON of a rendered unit.
pub fn unit_env_value(unit: &RenderedUnit) -> Result<String, CanonicalError> {
    to_canonical_json(unit)
}
