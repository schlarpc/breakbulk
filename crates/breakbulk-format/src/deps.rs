//! Which crate files and build-script outputs a compile unit reaches, and
//! which of them its derivation names directly.
//!
//! rustc loads the metadata of every crate below the one it compiles, and
//! Cargo passes `-L` for the search paths of every build script below it
//! (`to_link`). Naming all of those as derivation inputs makes the input
//! edges of a graph grow with the sum of all closure sizes, roughly the
//! square of the unit count (`docs/spikes/scale.md`). Instead, a library
//! unit's derivation names only its direct dependencies; each library's
//! `rmeta` output carries a manifest ([`breakbulk_unit::manifest`]) naming
//! its own `rmeta`, the proc macros it names, the `flags` of the build
//! scripts whose search paths it was given that its dependencies' manifests
//! do not already name, and its direct dependencies' `rmeta` directories.
//! Nix's reference scanning then puts everything below into the sandbox, and
//! `breakbulk-unit` walks the manifests to build the dependency directory.
//!
//! Units that link (bins, tests, proc macros, cdylibs, build scripts) still
//! name every `rlib` they link. An `rlib` output cannot carry such a manifest:
//! Nix records a reference only to a path in the builder's input closure, and
//! a library compile has only `rmeta` inputs. Giving it the `rlib`s too would
//! fetch them for every compile and check, which is what the separate
//! outputs avoid.
//!
//! [`Graph`] memoizes the per-unit transitive sets, so rendering every unit
//! of a plan costs the total size of the sets once, not a search per unit.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use crate::plan::{Arg, CompileUnit, OutRef, Piece, Plan, Reference, Unit, UnitId};
use crate::render::is_linking;
use breakbulk_unit::spec::SpliceKind;

pub(crate) fn is_proc_macro(c: &CompileUnit) -> bool {
    c.krate.types.iter().any(|t| t == "proc-macro")
}

/// Whether a compile unit's `rmeta` output carries a manifest: a library
/// (not a proc macro) with exactly one `rmeta` file. `breakbulk-unit`
/// writes one for every unit with an `rmeta` output.
pub fn has_manifest(c: &CompileUnit) -> bool {
    !is_proc_macro(c) && c.outputs.get("rmeta").is_some_and(|f| f.len() == 1)
}

/// Whether a library was compiled with `-Zembed-metadata=no` (nightly Cargo
/// and rustc): its `rlib` has no metadata, which is only in its `rmeta`.
pub fn embeds_no_metadata(c: &CompileUnit) -> bool {
    c.args.iter().any(
        |a| matches!(a, Arg::Literal(s) if s == "embed-metadata=no" || s == "-Zembed-metadata=no"),
    )
}

/// The crate files a compile unit names directly in its arguments: `out`
/// references to another compile unit's outputs other than `bin`.
pub(crate) fn direct_crate_refs<'a>(
    plan: &'a Plan,
    c: &'a CompileUnit,
) -> impl Iterator<Item = &'a OutRef> {
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

/// How a unit reaches what lies below it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UnitDeps {
    /// Crate files symlinked into the dependency directory, as derivation
    /// inputs: the files the arguments name; for a linking unit, every
    /// crate file below it ([`Graph::crate_deps`]); otherwise, below a
    /// direct dependency that has no manifest (not a proc macro), its
    /// transitive crates.
    pub deps: BTreeSet<OutRef>,
    /// The direct dependencies whose manifests `breakbulk-unit` reads: those
    /// with [`has_manifest`]. Empty for a linking unit without an `rmeta`
    /// output, which needs none.
    pub manifests: BTreeSet<UnitId>,
    /// Whether the crates the manifests name go into the dependency
    /// directory: units that do not link, and linking units whose
    /// libraries' rlibs carry no metadata ([`embeds_no_metadata`]).
    pub link_manifest_crates: bool,
    /// For the unit's own manifest (units with an `rmeta` output): the crate
    /// files below it that no manifest names, the direct dependencies
    /// without a manifest (proc macros), as `rmeta` where they have one.
    pub manifest_crates: BTreeSet<OutRef>,
    /// The runs whose `flags` the manifests name: the unit's splices of
    /// these need not be derivation inputs.
    pub reachable_runs: Rc<BTreeSet<UnitId>>,
}

/// A shared set of crate files.
type CrateSet = Rc<BTreeSet<OutRef>>;

/// Memoized dependency sets of one plan's compile units.
pub struct Graph<'p> {
    pub plan: &'p Plan,
    /// (unit, `rmeta` or `rlib`) to the crate files below the unit's own
    /// direct dependencies, chosen as that output where they have it.
    below: RefCell<HashMap<(UnitId, &'static str), CrateSet>>,
    /// A unit with a manifest to the runs its manifest and the ones below
    /// it name.
    runs: RefCell<HashMap<UnitId, Rc<BTreeSet<UnitId>>>>,
}

impl<'p> Graph<'p> {
    pub fn new(plan: &'p Plan) -> Self {
        Graph {
            plan,
            below: RefCell::default(),
            runs: RefCell::default(),
        }
    }

    fn compile(&self, id: &str) -> Option<&'p CompileUnit> {
        match self.plan.units.get(id) {
            Some(Unit::Compile(c)) => Some(c),
            _ => None,
        }
    }

    /// `o`, or the `want` output of the unit it names when that unit is a
    /// library with exactly one such file.
    fn chosen(&self, o: &OutRef, want: &'static str) -> OutRef {
        match self.compile(&o.out) {
            Some(e) if !is_proc_macro(e) => match e.outputs.get(want) {
                Some(files) if files.len() == 1 => OutRef {
                    out: o.out.clone(),
                    output: want.to_owned(),
                    file: files.iter().next().cloned(),
                },
                _ => o.clone(),
            },
            _ => o.clone(),
        }
    }

    /// The crate files below `id`'s direct dependencies (not through proc
    /// macros): what a dependent of `id` loads besides `id` itself.
    fn below(&self, id: &str, want: &'static str) -> Rc<BTreeSet<OutRef>> {
        if let Some(s) = self.below.borrow().get(&(id.to_owned(), want)) {
            return s.clone();
        }
        let mut set = BTreeSet::new();
        if let Some(c) = self.compile(id)
            && !is_proc_macro(c)
        {
            for o in direct_crate_refs(self.plan, c) {
                set.insert(self.chosen(o, want));
                set.extend(self.below(&o.out, want).iter().cloned());
            }
        }
        let set = Rc::new(set);
        self.below
            .borrow_mut()
            .insert((id.to_owned(), want), set.clone());
        set
    }

    /// Every crate file rustc may need to load for unit `id`: the files its
    /// arguments name, plus, for each of those crates, the crates it depends
    /// on, transitively. This replaces Cargo's shared `deps` directory.
    ///
    /// Transitive crates are taken as `rlib` when the unit links (see
    /// [`is_linking`]) and as `rmeta` otherwise, falling back to whatever the
    /// dependency's own arguments named when that output does not exist. A
    /// proc macro's dependencies are not followed: they are linked into the
    /// proc macro, and rustc does not load them.
    ///
    /// # Panics
    ///
    /// If `id` is not a compile unit of the plan.
    pub fn crate_deps(&self, id: &UnitId) -> BTreeSet<OutRef> {
        let c = self
            .compile(id)
            .unwrap_or_else(|| panic!("{id} is not a compile unit of the plan"));
        self.crate_deps_of(c)
    }

    /// [`Graph::crate_deps`] of a compile unit that need not be one of the
    /// plan's units (a doctest's [`crate::Doctest::as_compile`]).
    pub fn crate_deps_of(&self, c: &CompileUnit) -> BTreeSet<OutRef> {
        let want = if is_linking(c) { "rlib" } else { "rmeta" };
        let mut out = BTreeSet::new();
        for o in direct_crate_refs(self.plan, c) {
            out.insert(o.clone());
            out.extend(self.below(&o.out, want).iter().cloned());
        }
        out
    }

    /// The runs whose `flags` directory the manifest of `id` (a unit with
    /// [`has_manifest`]) and every manifest below it name: the runs of its
    /// own `rustc-link-search` splices, and those of its dependencies'
    /// manifests. `breakbulk-unit` writes the same set.
    pub fn manifest_runs(&self, id: &str) -> Rc<BTreeSet<UnitId>> {
        if let Some(s) = self.runs.borrow().get(id) {
            return s.clone();
        }
        let mut set = BTreeSet::new();
        if let Some(c) = self.compile(id) {
            for a in &c.args {
                if let Arg::Splice(s) = a
                    && s.kind == SpliceKind::RustcLinkSearch
                {
                    set.insert(s.splice.clone());
                }
            }
            for m in self.manifest_deps(c) {
                set.extend(self.manifest_runs(&m).iter().cloned());
            }
        }
        let set = Rc::new(set);
        self.runs.borrow_mut().insert(id.to_owned(), set.clone());
        set
    }

    /// The direct dependencies of `c` that carry a manifest.
    fn manifest_deps(&self, c: &CompileUnit) -> BTreeSet<UnitId> {
        direct_crate_refs(self.plan, c)
            .filter(|o| self.compile(&o.out).is_some_and(has_manifest))
            .map(|o| o.out.clone())
            .collect()
    }

    /// How unit `id` reaches what lies below it. See [`UnitDeps`].
    ///
    /// # Panics
    ///
    /// If `id` is not a compile unit of the plan.
    pub fn unit_deps(&self, id: &UnitId) -> UnitDeps {
        let c = self
            .compile(id)
            .unwrap_or_else(|| panic!("{id} is not a compile unit of the plan"));
        let linking = is_linking(c);
        let writes_manifest = c.outputs.contains_key("rmeta");
        // With nightly's `-Zembed-metadata=no` on its libraries, a linking
        // unit's rlibs carry no metadata, so rustc needs every rmeta below
        // too: from the manifests, as for units that do not link.
        let no_embed = linking
            && direct_crate_refs(self.plan, c)
                .any(|o| self.compile(&o.out).is_some_and(embeds_no_metadata));
        let link_manifests = !linking || no_embed;
        let manifests = if !link_manifests && !writes_manifest {
            BTreeSet::new()
        } else {
            self.manifest_deps(c)
        };
        let mut deps = BTreeSet::new();
        let mut manifest_crates = BTreeSet::new();
        if linking {
            deps = self.crate_deps(id);
        }
        for o in direct_crate_refs(self.plan, c) {
            if !linking {
                deps.insert(o.clone());
            }
            let Some(d) = self.compile(&o.out) else {
                continue;
            };
            if has_manifest(d) {
                continue;
            }
            // A proc macro, or a library without an rmeta output: nothing
            // describes what is below it, so it is named here.
            let below = self.below(&o.out, "rmeta");
            if !linking {
                deps.extend(below.iter().cloned());
            }
            if writes_manifest {
                manifest_crates.insert(self.chosen(o, "rmeta"));
                manifest_crates.extend(below.iter().cloned());
            }
        }
        let mut reachable = BTreeSet::new();
        for m in &manifests {
            reachable.extend(self.manifest_runs(m).iter().cloned());
        }
        UnitDeps {
            deps,
            link_manifest_crates: link_manifests && !manifests.is_empty(),
            manifests,
            manifest_crates,
            reachable_runs: Rc::new(reachable),
        }
    }
}

/// [`Graph::crate_deps`] for one unit.
pub fn crate_deps(plan: &Plan, id: &UnitId) -> BTreeSet<OutRef> {
    Graph::new(plan).crate_deps(id)
}

/// [`Graph::crate_deps_of`] for one compile unit.
pub fn crate_deps_of(plan: &Plan, c: &CompileUnit) -> BTreeSet<OutRef> {
    Graph::new(plan).crate_deps_of(c)
}

/// What a doctest (rustdoc compiling and linking the crate's examples)
/// puts in its dependency directory: every crate file below it, as for a
/// linking unit, plus every `rmeta` below it when its libraries' rlibs carry
/// no metadata (nightly's `-Zembed-metadata=no`). Doctests name everything
/// as inputs: they read no manifests.
pub fn doctest_deps(plan: &Plan, c: &CompileUnit) -> BTreeSet<OutRef> {
    let g = Graph::new(plan);
    let mut deps = g.crate_deps_of(c);
    let no_embed =
        direct_crate_refs(plan, c).any(|o| g.compile(&o.out).is_some_and(embeds_no_metadata));
    if no_embed {
        for o in direct_crate_refs(plan, c) {
            deps.insert(g.chosen(o, "rmeta"));
            deps.extend(g.below(&o.out, "rmeta").iter().cloned());
        }
    }
    deps
}

/// Every unit `id` depends on, transitively, by any route: references
/// (`out` of compiles and runs, a run's script), splices, search-path
/// splices, `envSplices`, `dylibPathFrom` and `metadataFrom`. Ids that are
/// not units of the plan (doctests, stubs) are left out. Without `id`.
pub fn units_below(plan: &Plan, id: &UnitId) -> BTreeSet<UnitId> {
    fn direct(unit: &Unit) -> Vec<UnitId> {
        let mut out = Vec::new();
        crate::plan::for_each_reference(unit, &mut |r, _| {
            if let Reference::Out(o) = r {
                out.push(o.out.clone());
            }
        });
        match unit {
            Unit::Compile(c) => {
                for a in &c.args {
                    match a {
                        Arg::Splice(s) => out.push(s.splice.clone()),
                        Arg::SearchPaths(s) => out.extend(s.search_paths_of.iter().cloned()),
                        _ => {}
                    }
                }
                out.extend(c.env_splices.iter().map(|s| s.splice.clone()));
                out.extend(c.dylib_path_from.iter().cloned());
            }
            Unit::Run(r) => {
                out.extend(r.metadata_from.iter().cloned());
                out.extend(r.dylib_path_from.iter().cloned());
            }
        }
        out
    }
    let mut seen = BTreeSet::new();
    let mut stack = vec![id.clone()];
    while let Some(u) = stack.pop() {
        let Some(unit) = plan.units.get(&u) else {
            continue;
        };
        for d in direct(unit) {
            if plan.units.contains_key(&d) && seen.insert(d.clone()) {
                stack.push(d);
            }
        }
    }
    seen.remove(id);
    seen
}

/// The compile units among [`units_below`] `id` that have a `debug` output
/// on a target with these traits ([`CompileUnit::has_debug_output`]): the
/// libraries whose `.dwo` files a binary linked from them names
/// (`split-debuginfo=unpacked`, decision 126).
pub fn debug_units_below(
    plan: &Plan,
    id: &UnitId,
    traits: &crate::TargetTraits,
) -> BTreeSet<UnitId> {
    units_below(plan, id)
        .into_iter()
        .filter(
            |u| matches!(plan.units.get(u), Some(Unit::Compile(c)) if c.has_debug_output(traits)),
        )
        .collect()
}

/// The target-platform runs among [`units_below`] `id`: the build scripts
/// whose copies of Cargo's `<profile>` directory sit next to `id`'s output
/// (#23).
pub fn target_runs_below(plan: &Plan, id: &UnitId) -> BTreeSet<UnitId> {
    units_below(plan, id)
        .into_iter()
        .filter(|u| matches!(plan.units.get(u), Some(Unit::Run(r)) if r.platform == crate::Platform::Target))
        .collect()
}
