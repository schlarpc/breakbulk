//! Rendering a plan unit into the `BREAKBULK_UNIT` value.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_unit::env::{EnvAppend, EnvLayer, list_separator};
use breakbulk_unit::spec::{
    DylibPath, Hints, OutDirRemove, OutputInto, OutputRule, RenderedArg, RenderedCompile,
    RenderedRun, RenderedUnit, RepositoryPath, SearchPaths, SourceView,
};

use crate::deps::Graph;
use crate::normalize::normalize_unit;
use crate::plan::{
    Arg, CrateSrcRef, DEBUG_OUTPUT, EmptyRef, OutRef, Piece, Plan, Reference, SrcRef, Text, Unit,
    UnitId, UnitKind, derivation_output, for_each_reference,
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
    fn remap_scope(&self, _id: &UnitId, _unit: &Unit) -> Option<String> {
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
        _unit: &Unit,
        _packages: &BTreeSet<String>,
    ) -> Result<Vec<String>, Self::Error> {
        Ok(Vec::new())
    }
    /// Layers 4 and 5 of the environment contract, lowest first: the
    /// toolchain spec's env for the unit's platform, then the package
    /// override's. Each value replaces the earlier layers' or appends to
    /// them ([`LayerValue`]); `breakbulk-unit` folds them over Cargo's
    /// recorded env at build time, when instantiation's values are known.
    fn env_overlay(&self, _id: &UnitId, _unit: &Unit) -> Result<Vec<EnvLayer>, Self::Error> {
        Ok(Vec::new())
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
        _unit: &Unit,
    ) -> Result<Option<(String, String)>, Self::Error> {
        Ok(None)
    }
    /// For a build-script run: what to delete from its output after it
    /// succeeds (`packages.<name>.buildScript.outDirRemove`).
    fn out_dir_remove(&self, _id: &UnitId, _unit: &Unit) -> Vec<OutDirRemove> {
        Vec::new()
    }
    /// The output rules for the files a compile unit writes beyond its
    /// crate files and debuginfo ([`OutputRule`]) when one of the variant's wrappers
    /// runs it (its program chain names the wrapper): what the variant's
    /// rustc driver writes, such as files for its dependents to read.
    /// Plain rustc writes nothing more, and units without a wrapper stay
    /// the same as a plain variant's, and shared. They come after the
    /// debuginfo rules.
    fn side_files(&self, _unit: &Unit) -> Vec<OutputRule> {
        Vec::new()
    }
    /// For a unit (or doctest) of a repository package: the source view it
    /// sees, for the hints when it fails naming a path the view lacks
    /// (`Hints::view`).
    fn source_view(&self, _id: &UnitId, _unit: &Unit) -> Result<Option<SourceView>, Self::Error> {
        Ok(None)
    }
    /// The build machine's dynamic-library path variable, which the
    /// processes of every unit read (instantiation's `toolchains.json`),
    /// or none.
    fn dylib_path(&self) -> Option<DylibPath> {
        None
    }
    /// For a build-script run: the file holding the table of its failure
    /// hints (`Hints::build_script_hints`), or none.
    fn build_script_hints(&self) -> Result<Option<String>, Self::Error> {
        Ok(None)
    }
    /// For a doctest: its package's test configuration (runners, test
    /// arguments, env, post-run program), as text. The default has none.
    fn doctest_config(
        &self,
        _id: &UnitId,
        _unit: &Unit,
    ) -> Result<breakbulk_unit::spec::DoctestConfig, Self::Error> {
        Ok(Default::default())
    }
}

/// The dynamic-library path variable of a unit with dynamic-path splices
/// (`runs`), none for one without.
pub(crate) fn dylib_path<R: Resolve>(runs: &[UnitId], r: &R) -> Option<DylibPath> {
    if runs.is_empty() {
        None
    } else {
        r.dylib_path()
    }
}

/// Cargo's recorded env (layer 3), with its list-like variables
/// ([`list_separator`]) appending to the env capture: their recorded
/// values extend what a setup hook put there.
pub fn recorded_env(values: BTreeMap<String, String>) -> (BTreeMap<String, String>, EnvAppend) {
    let appends = values
        .keys()
        .filter_map(|k| Some((k.clone(), list_separator(k)?)))
        .collect();
    (values, appends)
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
pub fn is_linking(c: &Unit) -> bool {
    c.args
        .iter()
        .any(|a| matches!(a, Arg::Literal(s) if s == "--test"))
        || c.krate()
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
    unit: &Unit,
    crates: impl IntoIterator<Item = &'a OutRef>,
) -> BTreeSet<String> {
    crates
        .into_iter()
        .filter_map(|o| match plan.units.get(&o.out) {
            Some(d)
                if d.is_compile()
                    && d.platform == unit.platform
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
            Reference::Out(o) if plan.units.get(&o.out).is_some_and(Unit::is_run) => {
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
/// sets: whether it replaces or appends is known only at build time, and
/// replaces: a package's `env` is the way to give the unit that path.
fn repository_paths(
    env: &BTreeMap<String, Text>,
    args: &[Arg],
    overlay: &[EnvLayer],
) -> Vec<RepositoryPath> {
    let mut out = Vec::new();
    for (k, v) in env {
        let Text::Concat(pieces) = v else { continue };
        if overlay.iter().any(|l| l.contains_key(k)) {
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
            Arg::Splice(_) | Arg::SearchPaths(_) | Arg::Runner(_) => (String::new(), None),
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
/// If `id` is not a unit of the graph's plan, or is a doctest or doc unit.
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
    let c = &unit;
    Ok(match unit.kind() {
        UnitKind::Compile => {
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
            let (mut env, mut env_append) = recorded_env(env(&c.env, r)?);
            if let Some((var, dir)) = r.wrapper_config_dir(id, c)? {
                env_append.remove(&var);
                env.insert(var, dir);
            }
            let link_captures = if is_linking(c) {
                let packages = link_packages(plan, c, &graph.crate_deps(id));
                r.link_captures(id, c, &packages)?
            } else {
                Vec::new()
            };
            let (remap, remap_scope) = if r.keep_source_paths() {
                (Vec::new(), None)
            } else if plan.remap.trim_paths {
                // Cargo's remaps are in the arguments. With the project's
                // own setting its scope is too; when breakbulk set it,
                // the scope is breakbulk's, per product kind.
                let scope = if plan.remap.trim_paths_default {
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
                remap.extend(plan.remap.rust_src.clone());
                sort_remap(&mut remap);
                (remap, r.remap_scope(id, c))
            };
            RenderedUnit::Compile(RenderedCompile {
                package: c.package.clone(),
                krate: c.krate().clone(),
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
                            Arg::SearchPaths(s) => RenderedArg::SearchPaths(search_paths(s, r)?),
                            Arg::Runner(s) => RenderedArg::Runner(*s),
                        })
                    })
                    .collect::<Result<_, _>>()?,
                env,
                env_append,
                env_layers: overlay,
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
                dylib_path: dylib_path(&c.dylib_path_from, r),
                cwd: c.cwd.render(r)?,
                outputs: output_rules(plan, c, r),
                deps: sorted(deps.deps.iter().cloned().map(out))?,
                dep_manifests: sorted(deps.manifests.iter().map(rmeta_dir))?,
                link_manifest_crates: deps.link_manifest_crates,
                manifest_crates: sorted(deps.manifest_crates.iter().cloned().map(out))?,
                remap,
                remap_scope,
                env_capture,
                link_captures,
                hints: Hints {
                    view: r.source_view(id, &unit)?,
                    repository_paths,
                    ..Hints::default()
                },
                seed: Some(id.to_string()),
            })
        }
        UnitKind::Doctest | UnitKind::Doc => {
            panic!(
                "{id} is a {} unit; render_doctest and render_docs render those",
                unit.kind()
            )
        }
        UnitKind::Run => {
            let run = &unit;
            let facts = plan.packages.get(&run.package);
            // breakbulk-unit sets OUT_DIR to the run's own `out`, which a
            // derivation cannot name in its own attributes. Dropped before
            // resolving, so the resolver never sees the self-reference.
            let mut recorded = run.env.clone();
            recorded.remove("OUT_DIR");
            let repository_paths = repository_paths(&recorded, &[], &overlay);
            let (env, env_append) = recorded_env(env(&recorded, r)?);
            let (remap, out_dir_remap) = if r.keep_source_paths() {
                (Vec::new(), None)
            } else if plan.remap.trim_paths {
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
                links: facts.and_then(|f| f.links.clone()),
                script: match run.script() {
                    Some(o) => r.reference(&Reference::Out(o.clone()))?,
                    None => panic!("{id}: a run's program is its script (validated)"),
                },
                env,
                env_append,
                env_layers: overlay,
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
                dylib_path: dylib_path(&run.dylib_path_from, r),
                rust_version: facts.and_then(|f| f.rust_version.clone()),
                targets: facts.map(|f| f.run_targets()).unwrap_or_default(),
                nightly_features_allowed: plan.nightly_features_allowed,
                env_capture,
                // Prefix maps for C code the script compiles: breakbulk's
                // names, or Cargo's under trim-paths (`cargo_run_remap`).
                remap,
                out_dir_remap,
                out_dir_remove: r.out_dir_remove(id, &unit),
                hints: Hints {
                    view: r.source_view(id, &unit)?,
                    repository_paths,
                    build_script_hints: r.build_script_hints()?,
                },
                seed: Some(id.to_string()),
            })
        }
    })
}

/// Where a compile unit's files go ([`OutputRule`]): each file of its
/// `outputs` into its derivation output (a bin uplifted under its stored
/// name), dep-info nowhere, the target's debuginfo side files into `debug`
/// when the unit has that output, then the variant's rules for wrapper
/// units, without those into an output the unit lacks.
pub fn output_rules<R: Resolve>(plan: &Plan, c: &Unit, r: &R) -> Vec<OutputRule> {
    let mut rules = Vec::new();
    for (output, files) in &c.outputs {
        for f in files {
            let written = c.uplifted.get(f);
            rules.push(OutputRule {
                stored: written.map(|_| f.clone()),
                ..OutputRule::file(written.unwrap_or(f), derivation_output(output))
            });
        }
    }
    rules.push(OutputRule::suffix(".d", OutputInto::Discard));
    if c.has_debug_output(&plan.target.debuginfo) {
        rules.extend(
            plan.target.debuginfo.artifacts.iter().map(|a| {
                OutputRule::suffix(&a.suffix, OutputInto::Output(DEBUG_OUTPUT.to_owned()))
            }),
        );
    }
    let outputs: BTreeSet<String> = rules
        .iter()
        .filter_map(|r| r.output().map(str::to_owned))
        .collect();
    rules.extend(
        r.side_files(c)
            .into_iter()
            .filter(|rule| rule.output().is_none_or(|o| outputs.contains(o))),
    );
    rules
}

/// A `searchPathsOf` splice with each run as its `flags` directory.
pub(crate) fn search_paths<R: Resolve>(
    s: &crate::plan::SearchPathsSplice,
    r: &R,
) -> Result<SearchPaths, R::Error> {
    Ok(SearchPaths {
        search_paths_of: s
            .search_paths_of
            .iter()
            .map(|u| r.flags(u))
            .collect::<Result<_, _>>()?,
        literals: s.literals.clone(),
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
    sort_remap(&mut remap);
    Ok(remap)
}

/// Sort remap pairs by the name each path becomes, unique per base, and
/// drop repeats. Not by the path: a resolver's paths can be placeholders
/// whose order is not that of the paths they stand for, and the unit would
/// then differ by who rendered it. The bases never nest, so the order
/// decides no match.
fn sort_remap(remap: &mut Vec<(String, String)>) {
    remap.sort_by(|a, b| (&a.1, &a.0).cmp(&(&b.1, &b.0)));
    remap.dedup();
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
fn cargo_run_remap<R: Resolve>(id: &UnitId, run: &Unit, r: &R) -> Result<RunRemap, R::Error> {
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
        let overlay = [BTreeMap::from([(
            "REPLACED".to_owned(),
            breakbulk_unit::env::LayerValue::set("/nix/store/x"),
        )])];
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
