//! Rendering a plan unit into the `BREAKBULK_UNIT` value.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_unit::env::{append, list_separator};
use breakbulk_unit::spec::{
    RenderedArg, RenderedCompile, RenderedRun, RenderedUnit, RepositoryPath, SideFile, SourceView,
    debug_side_files,
};

use crate::deps::Graph;
use crate::normalize::normalize_unit;
use crate::plan::{
    Arg, CompileUnit, CrateSrcRef, EmptyRef, OutRef, Piece, Plan, Reference, RunUnit, SrcRef, Text,
    Unit, UnitId, for_each_reference,
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
    /// For a compile unit the variant's workspace wrapper runs on: the
    /// variable that names the directory the wrapper starts its config
    /// file lookup in, and that directory (the package's in a tree of its
    /// config files: `variants.<v>.wrapperConfig`, clippy's
    /// `CLIPPY_CONF_DIR`), or `None`. The unit's env layers still win over
    /// it, as a user's own value does under Cargo.
    fn wrapper_config_dir(
        &self,
        _id: &UnitId,
        _unit: &CompileUnit,
    ) -> Result<Option<(String, String)>, Self::Error> {
        Ok(None)
    }
    /// The rules for the files a compile unit run through a wrapper
    /// writes beyond its outputs (`RenderedCompile::side_files`): what the
    /// variant's rustc driver writes, such as files for its dependents to
    /// read. They come after the debuginfo rules.
    fn side_files(&self) -> Vec<SideFile> {
        Vec::new()
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

/// `pieces` with each `empty` reference as its path relative to the
/// repository root, and those paths. `None` without such a reference.
fn with_repository_paths(pieces: &[Piece]) -> Option<(String, Vec<String>)> {
    let mut text = String::new();
    let mut rels = Vec::new();
    for p in pieces {
        match p {
            Piece::Literal(s) => text.push_str(s),
            Piece::Ref(Reference::Empty(EmptyRef { rel })) => {
                text.push_str(if rel.is_empty() { "." } else { rel });
                rels.push(rel.clone());
            }
            // Other references never come with an `empty` one in a unit:
            // only a unit without a source view has `empty` references.
            Piece::Ref(_) => text.push('…'),
        }
    }
    (!rels.is_empty()).then_some((text, rels))
}

/// The arguments in `args` (each its text, as [`with_repository_paths`]
/// gives it, or `None`) that name repository paths, each with the flag
/// before it when that is a separate argument (`-L`, `native=vendor/lib`).
fn repository_args(args: &[(String, Option<Vec<String>>)]) -> Vec<RepositoryPath> {
    let mut out = Vec::new();
    for (i, (text, rels)) in args.iter().enumerate() {
        let Some(rels) = rels else { continue };
        let arg = match i.checked_sub(1).map(|j| &args[j].0) {
            Some(flag) if flag.starts_with('-') && !text.starts_with('-') => {
                format!("{flag} {text}")
            }
            _ => text.clone(),
        };
        out.extend(rels.iter().map(|rel| RepositoryPath {
            path: rel.clone(),
            env: None,
            whole: false,
            arg: Some(arg.clone()),
        }));
    }
    out
}

/// The repository paths a unit's env values (Cargo config `[env]` with
/// `relative = true`, or `CARGO_ENCODED_RUSTFLAGS`) and arguments
/// (`build.rustflags`) name, for a unit without a source view, where they
/// are `empty` references. Not a variable that `overlay` (layers 4 and 5)
/// replaces: a package's `env` is the way to give the unit that path.
fn repository_paths(
    env: &BTreeMap<String, Text>,
    args: &[Arg],
    overlay: &BTreeMap<String, String>,
) -> Vec<RepositoryPath> {
    let mut out = Vec::new();
    for (k, v) in env {
        let Text::Concat(pieces) = v else { continue };
        if overlay.contains_key(k) && list_separator(k).is_none() {
            continue;
        }
        if k == "CARGO_ENCODED_RUSTFLAGS" {
            // One argument per `\x1f`-separated part: the parts of each
            // piece, with an `empty` reference inside one part.
            let mut parts: Vec<Vec<Piece>> = vec![Vec::new()];
            for p in pieces {
                match p {
                    Piece::Literal(s) => {
                        for (i, seg) in s.split('\x1f').enumerate() {
                            if i > 0 {
                                parts.push(Vec::new());
                            }
                            if !seg.is_empty() {
                                parts.last_mut().unwrap().push(Piece::Literal(seg.into()));
                            }
                        }
                    }
                    r => parts.last_mut().unwrap().push(r.clone()),
                }
            }
            let args: Vec<_> = parts
                .iter()
                .map(|p| match with_repository_paths(p) {
                    Some((t, rels)) => (t, Some(rels)),
                    None => (text_of_literals(p), None),
                })
                .collect();
            out.extend(repository_args(&args).into_iter().map(|r| RepositoryPath {
                env: Some(k.clone()),
                ..r
            }));
            continue;
        }
        if let Some((_, rels)) = with_repository_paths(pieces) {
            let whole = match pieces.as_slice() {
                [Piece::Ref(Reference::Empty(_))] => true,
                [Piece::Ref(Reference::Empty(_)), Piece::Literal(s)] => s == "/",
                _ => false,
            };
            out.extend(rels.into_iter().map(|rel| RepositoryPath {
                path: rel,
                env: Some(k.clone()),
                whole,
                arg: None,
            }));
        }
    }
    let args: Vec<_> = args
        .iter()
        .map(|a| match a {
            Arg::Literal(s) => (s.clone(), None),
            Arg::Concat(p) => match with_repository_paths(p) {
                Some((t, rels)) => (t, Some(rels)),
                None => (text_of_literals(p), None),
            },
            Arg::Splice(_) | Arg::SearchPaths(_) => (String::new(), None),
        })
        .collect();
    out.extend(repository_args(&args));
    out
}

/// The literal parts of `pieces`, for the flag before an argument.
fn text_of_literals(pieces: &[Piece]) -> String {
    pieces
        .iter()
        .map(|p| match p {
            Piece::Literal(s) => s.as_str(),
            Piece::Ref(_) => "…",
        })
        .collect()
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
            let repository_paths = repository_paths(&c.env, &c.args, &overlay);
            let mut env = env(&c.env, r)?;
            if let Some((var, dir)) = r.wrapper_config_dir(id, c)? {
                env.insert(var, dir);
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
                // The variant's rules apply where a wrapper runs: plain
                // rustc writes nothing more, and units without one stay
                // the same as a plain variant's, and shared.
                side_files: c
                    .has_debug_output(&plan.target_debuginfo)
                    .then(|| {
                        debug_side_files(
                            plan.target_debuginfo
                                .artifacts
                                .iter()
                                .map(|a| a.suffix.as_str()),
                        )
                    })
                    .into_iter()
                    .flatten()
                    .chain(
                        (c.program.len() > 1)
                            .then(|| r.side_files())
                            .into_iter()
                            .flatten(),
                    )
                    .collect(),
                deps: sorted(deps.deps.iter().cloned().map(out))?,
                dep_manifests: sorted(deps.manifests.iter().map(rmeta_dir))?,
                link_manifest_crates: deps.link_manifest_crates,
                manifest_crates: sorted(deps.manifest_crates.iter().cloned().map(out))?,
                remap,
                remap_scope,
                env_capture,
                link_captures,
                view: r.source_view(id, &unit)?,
                repository_paths,
                seed: Some(id.to_string()),
            })
        }
        Unit::Run(run) => {
            // breakbulk-unit sets OUT_DIR to the run's own `out`, which a
            // derivation cannot name in its own attributes. Dropped before
            // resolving, so the resolver never sees the self-reference.
            let mut recorded = run.env.clone();
            recorded.remove("OUT_DIR");
            let repository_paths = repository_paths(&recorded, &[], &overlay);
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
                repository_paths,
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

#[cfg(test)]
mod repository_path_tests {
    use super::*;

    fn empty(rel: &str) -> Piece {
        Piece::Ref(Reference::Empty(EmptyRef { rel: rel.into() }))
    }

    #[test]
    fn env_values_and_arguments() {
        let env = BTreeMap::from([
            (
                "OPENSSL_DIR".to_owned(),
                Text::Concat(vec![empty("vendor/openssl")]),
            ),
            (
                "ASSETS".to_owned(),
                Text::Concat(vec![empty("assets"), Piece::Literal("/logo.svg".into())]),
            ),
            (
                "CARGO_ENCODED_RUSTFLAGS".to_owned(),
                Text::Concat(vec![
                    Piece::Literal("-Copt-level=1\x1f-L\x1fnative=".into()),
                    empty("vendor/lib"),
                ]),
            ),
            ("REPLACED".to_owned(), Text::Concat(vec![empty("x")])),
            ("PLAIN".to_owned(), Text::Literal("1".into())),
        ]);
        let args = [
            Arg::Literal("-L".into()),
            Arg::Concat(vec![Piece::Literal("native=".into()), empty("vendor/lib")]),
            Arg::Concat(vec![Piece::Literal("-Lnative=".into()), empty("other")]),
        ];
        let overlay = BTreeMap::from([("REPLACED".to_owned(), "/nix/store/x".to_owned())]);
        let p = |path: &str, env: Option<&str>, whole: bool, arg: Option<&str>| RepositoryPath {
            path: path.into(),
            env: env.map(Into::into),
            whole,
            arg: arg.map(Into::into),
        };
        assert_eq!(
            repository_paths(&env, &args, &overlay),
            [
                p("assets", Some("ASSETS"), false, None),
                p(
                    "vendor/lib",
                    Some("CARGO_ENCODED_RUSTFLAGS"),
                    false,
                    Some("-L native=vendor/lib")
                ),
                p("vendor/openssl", Some("OPENSSL_DIR"), true, None),
                p("vendor/lib", None, false, Some("-L native=vendor/lib")),
                p("other", None, false, Some("-Lnative=other")),
            ]
        );
    }
}
