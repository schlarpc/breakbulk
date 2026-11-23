//! Types for `plan.json`, as described in `docs/src/reference/plan-format.md`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

pub use breakbulk_unit::spec::{
    CrateInfo, LinkArgKind, PackageTarget, Platform, SearchIn, SpliceKind,
};

/// The only plan format version this crate reads and writes.
pub const PLAN_VERSION: u32 = 6;

/// A unit's key: `c-<hash>` for compile units (Cargo's `-C metadata`),
/// `r-<pkg>-<hash>` for build-script runs (from `OUT_DIR`), `d-<package
/// name>` for doctests, `o-<package name>-<version>-<crate name>` for the
/// rustdoc commands of a doc plan.
pub type UnitId = String;

/// A splice point in `plan.json`: names a run unit.
pub type Splice = breakbulk_unit::spec::Splice<UnitId>;

/// One `plan.json`: every unit of one (workspace, target, variant, plan kind).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Plan {
    pub version: u32,
    /// The plan kind, a label: what Cargo ran is the variant's command for
    /// it (`lib/cargo-commands.nix`). It decides which units are roots.
    pub kind: PlanKind,
    /// `cargo -V` version.
    pub cargo: String,
    /// Cargo's `nightly_features_allowed` for the planning toolchain:
    /// whether a build script's `rustc-env=RUSTC_BOOTSTRAP=…` is an error
    /// or a warning.
    pub nightly_features_allowed: bool,
    /// `rustc -vV` release line.
    pub rustc: String,
    pub host: String,
    pub target: PlanTarget,
    pub variant: Variant,
    /// The canonical absolute skeleton path planning ran at.
    pub skeleton_root: String,
    pub remap: Remap,
    /// The variables the project's `[env]` config table sets on the
    /// processes Cargo starts. Units keep them in their recorded env;
    /// test runs take their values from the test unit's recorded env, as
    /// `cargo test` gives them to test processes.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub config_env: BTreeSet<String>,
    /// What `cargo metadata` says about each package that has a unit in
    /// the plan, by package id.
    pub packages: BTreeMap<String, PackageFacts>,
    pub units: BTreeMap<UnitId, Unit>,
    /// The plan's products: a set, serialized as a sorted array.
    pub roots: BTreeSet<Root>,
}

/// The planned target, as the planning toolchain describes it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanTarget {
    /// What Cargo was given as `--target`: a triple, or a `.json` spec's
    /// path.
    pub arg: String,
    /// Cargo's short name: the triple, or the spec's file stem.
    pub short_name: String,
    /// The spec's `exe-suffix`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub exe_suffix: String,
    /// The debuginfo side files the target's links write, from the
    /// planning rustc's target spec. Required, so that no plan silently
    /// gives its units another target's `debug` outputs.
    pub debuginfo: TargetDebuginfo,
}

/// How the plan's source paths are remapped.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Remap {
    /// Whether Cargo's `trim-paths` was in effect: every compile unit
    /// carries Cargo's own remaps, and breakbulk adds none.
    pub trim_paths: bool,
    /// Whether the planner turned `trim-paths` on itself, because the
    /// project had not ("trim-paths" in
    /// `docs/src/explanation/internals/planner.md`). Cargo's
    /// `--remap-path-scope` is then left out of the plan, and breakbulk
    /// sets the scope per product kind, as with its own remaps.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub trim_paths_default: bool,
    /// When the toolchain ships the `rust-src` component: the remap
    /// `[<sysroot>/lib/rustlib/src/rust, /rustc/<commit-hash>]`. rustc
    /// rewrites standard-library paths (`/rustc/<hash>/library/…`) to that
    /// local copy, so without it panic locations in std code instantiated
    /// in the user's crates name the toolchain's store path, and every
    /// product references the whole toolchain. Cargo's `trim-paths` adds
    /// the same remap (cargo 0.97.0, `core/compiler/mod.rs`,
    /// `sysroot_remap`); breakbulk adds it to its own remaps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_src: Option<(String, String)>,
}

/// A package of the plan ([`Plan::packages`]), as `cargo metadata`
/// describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PackageFacts {
    /// Every Cargo target of the package, built or not. Sorted. Build-script
    /// runs check `rustc-link-arg-*` directives against them; the cargo
    /// metadata synthesized for nextest lists them.
    pub targets: Vec<PathTarget>,
    /// The package's `rust-version`, for Cargo's `cargo::` syntax check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<String>,
    /// The package's `links`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<String>,
    /// A path package under the skeleton: its dependency edges to the other
    /// such packages that one of the plan's compile units uses, from the
    /// resolve of `cargo metadata --all-features` (so not the optional
    /// dependencies the variant's features leave off). Sorted by package
    /// id.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dependencies: Vec<PathDependency>,
}

impl PackageFacts {
    /// The targets as build-script runs check directives against them.
    pub fn run_targets(&self) -> Vec<PackageTarget> {
        self.targets
            .iter()
            .map(|t| PackageTarget {
                name: t.name.clone(),
                kind: t.kind.clone(),
            })
            .collect()
    }
}

/// One Cargo target of a package, as `cargo metadata` lists it.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PathTarget {
    pub name: String,
    /// `bin`, `example`, `test`, `bench`, `custom-build`, or a library's
    /// crate types.
    pub kind: Vec<String>,
    pub crate_types: Vec<String>,
    /// For a path package under the skeleton: the source path relative to
    /// the skeleton root. Other packages' sources are no paths a plan may
    /// hold.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src_path: Option<String>,
}

/// A dependency edge between two path packages: Cargo's resolve node `deps`
/// entry, one `(kind, target)` per way the dependency is declared.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PathDependency {
    pub package: String,
    /// Sorted.
    pub kinds: Vec<DepKind>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DepKind {
    /// `dev` or `build`; None for a normal dependency.
    pub kind: Option<String>,
    /// The `[target.<cfg>]` table the dependency is declared in.
    pub target: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlanKind {
    Build,
    Test,
    /// `cargo bench --no-run`: bench binaries and harnesses in bench mode.
    Bench,
    /// `cargo doc`: the check-mode units rustdoc reads, and its rustdoc
    /// commands (`doc` units).
    Doc,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Variant {
    pub profile: String,
    pub features: BTreeSet<String>,
    pub mode: VariantMode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VariantMode {
    Build,
    Check,
}

/// A working directory: a reference, or a literal store path. The literal
/// form is a toolchain path: the standard library's own packages under
/// `-Zbuild-std`, which Cargo compiles and runs in their directories in
/// the sysroot's `rust-src` ("build-std" in
/// `docs/src/explanation/internals/toolchains.md`).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Cwd {
    Ref(Reference),
    Literal(String),
}

impl Cwd {
    /// The rendered directory.
    pub fn render<R: crate::Resolve>(&self, r: &R) -> Result<String, R::Error> {
        match self {
            Cwd::Ref(x) => r.reference(x),
            Cwd::Literal(s) => Ok(s.clone()),
        }
    }
}

impl From<Reference> for Cwd {
    fn from(r: Reference) -> Cwd {
        Cwd::Ref(r)
    }
}

/// A path the planner rewrote: resolved to a store path at instantiation.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reference {
    /// `<skeleton>/<rel>` inside a workspace package.
    Src(SrcRef),
    /// `<vendor dir>/<source>/<crate>/<rel>`.
    CrateSrc(CrateSrcRef),
    /// An output of another unit in the plan.
    Out(OutRef),
    /// `<skeleton>/<rel>` in a unit of a package that has no source view
    /// (a registry or git crate): `<rel>` in one constant empty directory.
    Empty(EmptyRef),
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SrcRef {
    /// The workspace package.
    pub src: String,
    /// Relative path inside it; empty for the package directory.
    pub rel: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CrateSrcRef {
    /// The package id.
    pub crate_src: String,
    pub rel: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyRef {
    /// Relative path inside the empty directory; empty for the directory.
    #[serde(rename = "empty")]
    pub rel: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutRef {
    pub out: UnitId,
    /// `rmeta`, `rlib` or `bin` for a compile unit (a key of its `outputs`);
    /// `out` for a run unit.
    pub output: String,
    /// A file inside the output; listed in the compile unit's `outputs`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

/// One part of a concatenated argument.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Piece {
    Literal(String),
    Ref(Reference),
}

/// A string value: a literal, or literals and references concatenated.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Text {
    Literal(String),
    Concat(Vec<Piece>),
}

/// One argument segment.
///
/// A string is a literal argument. An array is one argument made by
/// concatenating literals and references. A splice object expands at build
/// time to zero or more arguments.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Arg {
    Literal(String),
    Concat(Vec<Piece>),
    Splice(Splice),
    /// Doctest units only.
    SearchPaths(SearchPathsSplice),
}

/// `{ "searchPathsOf": [R, …] }`: the search paths of every listed run, both
/// classes, deduplicated and sorted by value at build time. Cargo gives
/// `rustdoc --test` an `-L` for every run in the invocation this way
/// (`run_doc_tests`, from `Compilation::native_dirs`, a `BTreeSet`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SearchPathsSplice {
    /// Sorted, no duplicates.
    pub search_paths_of: Vec<UnitId>,
    /// Search paths that are no run's: those of `links` overrides in
    /// config, which Cargo puts in the same set. Sorted with the runs'
    /// values at build time. Sorted, no duplicates.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub literals: Vec<String>,
}

impl From<Text> for Arg {
    fn from(t: Text) -> Arg {
        match t {
            Text::Literal(s) => Arg::Literal(s),
            Text::Concat(p) => Arg::Concat(p),
        }
    }
}

/// What a unit is: the tool its program runs and the role its derivation
/// has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum UnitKind {
    /// A rustc (or wrapper) invocation, with outputs.
    Compile,
    /// A traced `rustdoc --test` of one library, from `cargo test`, run by
    /// the doctest derivation, which compiles and runs the examples in one
    /// process. No outputs.
    Doctest,
    /// A traced `rustdoc` of one Cargo target (a library or a bin), from
    /// `cargo doc`, without its output directory (`-o`): the docs
    /// derivation runs every doc unit of the plan into one output. No
    /// outputs.
    Doc,
    /// A build-script run: `program` is the script, an `out` reference to
    /// its compile unit.
    Run,
}

impl std::fmt::Display for UnitKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            UnitKind::Compile => "compile",
            UnitKind::Doctest => "doctest",
            UnitKind::Doc => "doc",
            UnitKind::Run => "run",
        })
    }
}

/// One unit of the plan: its kind, the tag of one shape ([`UnitBody`]) for
/// every kind.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Unit {
    Compile(UnitBody),
    Doctest(UnitBody),
    Doc(UnitBody),
    Run(UnitBody),
}

impl std::ops::Deref for Unit {
    type Target = UnitBody;
    fn deref(&self) -> &UnitBody {
        match self {
            Unit::Compile(b) | Unit::Doctest(b) | Unit::Doc(b) | Unit::Run(b) => b,
        }
    }
}

impl std::ops::DerefMut for Unit {
    fn deref_mut(&mut self) -> &mut UnitBody {
        match self {
            Unit::Compile(b) | Unit::Doctest(b) | Unit::Doc(b) | Unit::Run(b) => b,
        }
    }
}

impl Unit {
    /// A unit of `kind` with `body`.
    pub fn new(kind: UnitKind, body: UnitBody) -> Unit {
        match kind {
            UnitKind::Compile => Unit::Compile(body),
            UnitKind::Doctest => Unit::Doctest(body),
            UnitKind::Doc => Unit::Doc(body),
            UnitKind::Run => Unit::Run(body),
        }
    }

    pub fn kind(&self) -> UnitKind {
        match self {
            Unit::Compile(_) => UnitKind::Compile,
            Unit::Doctest(_) => UnitKind::Doctest,
            Unit::Doc(_) => UnitKind::Doc,
            Unit::Run(_) => UnitKind::Run,
        }
    }

    pub fn package(&self) -> &str {
        &self.package
    }

    pub fn is_compile(&self) -> bool {
        matches!(self, Unit::Compile(_))
    }

    pub fn is_run(&self) -> bool {
        matches!(self, Unit::Run(_))
    }
}

/// The fields of a unit. Those that apply to some kinds only are empty on
/// the others (validated).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct UnitBody {
    pub package: String,
    /// The crate rustc or rustdoc compiles; none for a run.
    #[serde(rename = "crate", default, skip_serializing_if = "Option::is_none")]
    pub krate: Option<CrateInfo>,
    /// Observed from Cargo's output layout for compiles, runs and docs (a
    /// proc macro's docs are the host's, which Cargo documents into its
    /// host directory even with `--target`); for a doctest, `host` when the
    /// command has no `--target` (a proc macro's doctest, which Cargo builds
    /// and runs for the host), else `target`. Instantiation picks the
    /// matching toolchain spec, env capture and (doctests) runner.
    pub platform: Platform,
    /// Compile units: whether this is a test unit, one Cargo builds with
    /// the package's dev-dependencies, from its Cargo target rather than
    /// its arguments. That is a `--test` compile (a lib, bin, test or bench
    /// harness), a test or bench target with or without the libtest
    /// harness (`harness = false` compiles a plain bin, without `--test`),
    /// or an example. Test units see the package's test view ("Source
    /// views" in `docs/src/explanation/internals/sources.md`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub test: bool,
    /// Compile units: the Cargo target the unit compiles, when the planner
    /// could match it to one of the package's targets. Instantiation looks
    /// up a view of the unit's own target by it, and falls back to the
    /// package's view.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cargo_target: Option<CargoTarget>,
    /// The program and wrapper chain, e.g. `[clippy-driver, rustc]`; a
    /// run's build-script executable.
    pub program: Vec<Text>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<Arg>,
    pub env: BTreeMap<String, Text>,
    /// Runs whose `rustc-env` values are added to `env`, in order; a later
    /// run's value wins.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_splices: Vec<Splice>,
    /// Dynamic-path splices: runs whose search paths inside their own `out`
    /// go on the process's dynamic-library path (`LD_LIBRARY_PATH`), in this
    /// order, before the recorded value. Cargo adds them for host plugin
    /// dependencies (proc macros, build dependencies with build scripts),
    /// and for a run, the runs of packages its build script depends on.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<UnitId>,
    /// The working directory Cargo gave the process.
    pub cwd: Cwd,
    /// Compile units: output name to file names.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub outputs: BTreeMap<String, BTreeSet<String>>,
    /// Compile units: files of `outputs` that rustc writes under another
    /// name: the name in `outputs` to rustc's. A bin or example Cargo
    /// uplifts is stored under its uplifted name (`app`, not rustc's
    /// `app-<hash>`), so the path a test gets in `CARGO_BIN_EXE_<name>` is
    /// a file of that name, for `argv[0]` and `current_exe()`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub uplifted: BTreeMap<String, String>,
    /// Runs: upstream runs whose `DEP_<links>_*` metadata this run receives.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub metadata_from: BTreeSet<UnitId>,
    /// Runs, with Cargo's `trim-paths` ([`Remap::trim_paths`]): the name
    /// Cargo's build-directory remap gives the `OUT_DIR` of each run this
    /// run names (`/cargo/build-dir/<OUT_DIR relative to the build
    /// directory>`), its own included. Its C prefix maps use them with the
    /// pairs of `CARGO_TRIM_PATHS_REMAP`, so they agree with cc-rs's.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_dir_remap: BTreeMap<UnitId, String>,
    /// Runs: where `OUT_DIR` is inside the run's `out`: the traced
    /// `OUT_DIR` relative to Cargo's target directory (`<triple>/<profile>/
    /// build/<pkg>-<hash>/out`). A script that walks up from `OUT_DIR` to
    /// Cargo's target directory then finds the `out` itself, as under Cargo
    /// (#23). Empty: `OUT_DIR` is the `out`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub out_dir: String,
    /// Doc units: the doc units that run before this one, because it reads
    /// the crates they document (its `--extern`s). rustdoc links to a
    /// crate's items only when the crate's directory is already in its
    /// output directory, and Cargo runs a crate's rustdoc after its
    /// dependencies' when it documents them ([`doc_order`]).
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub after: BTreeSet<UnitId>,
}

/// An empty crate, for a run's [`UnitBody::krate`].
static NO_CRATE: CrateInfo = CrateInfo {
    name: String::new(),
    types: Vec::new(),
    edition: String::new(),
};

impl UnitBody {
    /// The crate of a compile, doctest or doc unit; empty for a run.
    pub fn krate(&self) -> &CrateInfo {
        self.krate.as_ref().unwrap_or(&NO_CRATE)
    }

    /// A run's script: `program[0]`, an `out` reference to its compile
    /// unit.
    pub fn script(&self) -> Option<&OutRef> {
        match self.program.as_slice() {
            [Text::Concat(p)] => match p.as_slice() {
                [Piece::Ref(Reference::Out(o))] => Some(o),
                _ => None,
            },
            _ => None,
        }
    }

    /// A body with every field empty.
    pub fn empty(package: impl Into<String>, platform: Platform) -> UnitBody {
        UnitBody {
            package: package.into(),
            krate: None,
            platform,
            test: false,
            cargo_target: None,
            program: Vec::new(),
            args: Vec::new(),
            env: BTreeMap::new(),
            env_splices: Vec::new(),
            dylib_path_from: Vec::new(),
            cwd: Cwd::Literal(String::new()),
            outputs: BTreeMap::new(),
            uplifted: BTreeMap::new(),
            metadata_from: BTreeSet::new(),
            build_dir_remap: BTreeMap::new(),
            out_dir: String::new(),
            after: BTreeSet::new(),
        }
    }
}

/// The order the docs derivation runs a plan's doc units in: each after
/// the units in its `after`, otherwise by crate name, then package, then
/// id. `Err` names a cycle.
pub fn doc_order(plan: &Plan) -> Result<Vec<UnitId>, String> {
    let docs: BTreeMap<&UnitId, &Unit> = plan
        .units
        .iter()
        .filter(|(_, u)| u.kind() == UnitKind::Doc)
        .collect();
    let mut waits_for: BTreeMap<&UnitId, usize> = docs.keys().map(|id| (*id, 0)).collect();
    let mut unblocks: BTreeMap<&UnitId, Vec<&UnitId>> = BTreeMap::new();
    for (id, u) in &docs {
        for a in &u.after {
            if docs.contains_key(a) && a != *id {
                *waits_for.get_mut(id).expect("a doc unit") += 1;
                unblocks.entry(a).or_default().push(id);
            }
        }
    }
    let key = |id: &&UnitId| {
        let u = docs[id];
        (u.krate().name.clone(), u.package.clone(), (*id).clone())
    };
    let mut ready: BTreeSet<_> = waits_for
        .iter()
        .filter(|(_, n)| **n == 0)
        .map(|(id, _)| key(id))
        .collect();
    let mut order = Vec::with_capacity(docs.len());
    while let Some((_, _, id)) = ready.pop_first() {
        for j in unblocks.get(&id).into_iter().flatten() {
            let n = waits_for.get_mut(j).expect("a doc unit");
            *n -= 1;
            if *n == 0 {
                ready.insert(key(j));
            }
        }
        order.push(id);
    }
    if order.len() != docs.len() {
        return Err(
            "the rustdoc commands of `cargo doc` read each other's crates in a cycle".into(),
        );
    }
    Ok(order)
}

/// A Cargo target of a package, as source views name it.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CargoTarget {
    /// `lib` (whatever its crate types), `bin`, `example`, `test`,
    /// `bench` or `custom-build`.
    pub kind: String,
    pub name: String,
}

impl CargoTarget {
    /// `<kind>/<name>`, the target's part of a per-target view key.
    pub fn key(&self) -> String {
        format!("{}/{}", self.kind, self.name)
    }
}

impl UnitBody {
    /// Whether the unit gets a `debug` derivation output for the
    /// debuginfo side files rustc writes, by
    /// [`writes_debuginfo_side_files`] on a target with this `debuginfo`:
    /// - a target-platform unit with a `bin` output (bins, tests,
    ///   examples, benches, cdylibs, dylibs, staticlibs): any of its
    ///   artifacts;
    /// - a target-platform library with an `rlib` output: only the
    ///   per-object ones (`.dwo` with `-C split-debuginfo=unpacked`), which
    ///   rustc writes beside each object file it compiles, linked or not.
    ///   The linked binary's skeleton units name them; with `packed`, rustc
    ///   keeps the DWARF objects in the rlib and packs them at the link.
    ///
    /// Nix outputs are fixed before the build, so this is decided from the
    /// command line; host units (build scripts, proc macros) only run
    /// during the build, so theirs are discarded, and a metadata-only
    /// library (`check`) compiles no objects. Only compile units have
    /// outputs.
    pub fn has_debug_output(&self, debuginfo: &TargetDebuginfo) -> bool {
        if self.outputs.contains_key("bin") {
            self.writes_side_files(debuginfo, false)
        } else {
            self.writes_per_object_debug_files(debuginfo)
        }
    }

    /// Whether the unit writes the target's per-object debuginfo side
    /// files (`.dwo` with `-C split-debuginfo=unpacked`): a target-platform
    /// unit that compiles objects (a `bin` or `rlib` output), with
    /// arguments that make one of those artifacts apply. These are the
    /// side files a binary linked from the unit's objects names, and so the
    /// only ones a product takes from the units below its root
    /// ([`crate::deps::debug_units_below`]); a per-output artifact (a
    /// `.dwp`, msvc's `.pdb`) of a unit below belongs to that unit's own
    /// linked output (a cdylib), which the product does not ship.
    pub fn writes_per_object_debug_files(&self, debuginfo: &TargetDebuginfo) -> bool {
        (self.outputs.contains_key("bin") || self.outputs.contains_key("rlib"))
            && self.writes_side_files(debuginfo, true)
    }

    /// [`writes_debuginfo_side_files`] for a target-platform unit, with
    /// only the per-object artifacts when `per_object_only`.
    fn writes_side_files(&self, debuginfo: &TargetDebuginfo, per_object_only: bool) -> bool {
        self.platform == Platform::Target
            && writes_debuginfo_side_files(
                self.args.iter().map(|a| match a {
                    Arg::Literal(s) => Some(s.as_str()),
                    _ => None,
                }),
                &self.krate().types,
                &TargetDebuginfo {
                    split_default: debuginfo.split_default,
                    artifacts: debuginfo
                        .artifacts
                        .iter()
                        .filter(|a| a.per_object || !per_object_only)
                        .cloned()
                        .collect(),
                },
            )
    }
}

/// The debuginfo side files rustc's links write for the plan's target,
/// which `--print file-names` does not name. The planner reads them from
/// its rustc's target spec (`rustc --print target-spec-json`), so a
/// custom target (`--target foo.json`) is described by its own spec, and
/// instantiation decides from them which units get a `debug` output.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TargetDebuginfo {
    /// The `-C split-debuginfo` rustc uses when the arguments give none
    /// (the spec's `split-debuginfo`; rustc_session's
    /// `Session::split_debuginfo`): `packed` on msvc and Apple targets,
    /// `off` elsewhere.
    pub split_default: SplitDebuginfo,
    /// `.pdb` on msvc and UEFI, `.dwp`/`.dwo` on the ELF targets whose
    /// spec supports split debuginfo, `.dSYM` on Apple targets. Empty:
    /// none (wasm, most bare-metal targets).
    pub artifacts: Vec<DebugArtifact>,
}

/// A `-C split-debuginfo` value.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SplitDebuginfo {
    #[default]
    Off,
    Packed,
    Unpacked,
}

impl SplitDebuginfo {
    /// The value as rustc spells it, or `None` for one it does not take.
    pub fn parse(s: &str) -> Option<SplitDebuginfo> {
        match s {
            "off" => Some(SplitDebuginfo::Off),
            "packed" => Some(SplitDebuginfo::Packed),
            "unpacked" => Some(SplitDebuginfo::Unpacked),
            _ => None,
        }
    }
}

/// One kind of debuginfo side file ([`TargetDebuginfo::artifacts`]).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DebugArtifact {
    /// The file name suffix: `.pdb`, `.dwp`, `.dwo`, `.dSYM`.
    pub suffix: String,
    /// When rustc's link writes it.
    pub when: DebugArtifactWhen,
    /// One per object file (`.dwo`), not one per linked output.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub per_object: bool,
    /// A directory (`.dSYM`), not a file.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub directory: bool,
}

/// When a [`DebugArtifact`] is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DebugArtifactWhen {
    /// For every crate the linker produces (`bin`, `cdylib`, `dylib`,
    /// `--test`), whatever `-C debuginfo` and `-C strip` say: rustc passes
    /// `/DEBUG` to an MSVC-style linker unconditionally (rustc_codegen_ssa
    /// back/linker.rs, `MsvcLinker::debuginfo` ignores its `strip`
    /// argument; 1.95 through master, and an msvc release build with
    /// `-C strip=debuginfo` was seen to write a 1.2 MB PDB).
    Always,
    /// With debuginfo on and `-C split-debuginfo` packed.
    SplitPacked,
    /// With debuginfo on and `-C split-debuginfo` unpacked.
    SplitUnpacked,
}

/// Whether rustc, given these command-line arguments (`None` for an
/// argument that is not a literal: a build script's splices cannot set
/// codegen options) for a crate of these types, writes debuginfo side files
/// next to its linked output, on a target with this `debuginfo`: whether
/// any of its [`DebugArtifact`]s applies.
///
/// - [`DebugArtifactWhen::Always`] applies to every crate type the linker
///   produces (`bin`, `cdylib`, `dylib`, and `--test`). A staticlib is
///   archived, not linked.
/// - [`DebugArtifactWhen::SplitPacked`] and
///   [`DebugArtifactWhen::SplitUnpacked`] apply when the effective
///   `-C split-debuginfo` is that value and debuginfo is on: the last
///   `-C split-debuginfo` given, else the target's
///   [`TargetDebuginfo::split_default`] (rustc_session's
///   `Session::split_debuginfo`). Cargo passes `-C split-debuginfo` only
///   together with `-C debuginfo` (cargo src/compiler/mod.rs,
///   `build_base_args`), but rustflags can add either. As in rustc
///   (rustc_session config.rs `select_debuginfo`), a `-g` after the last
///   `-C debuginfo` means full debuginfo, and the last `-C` of an option
///   wins.
pub fn writes_debuginfo_side_files<'a>(
    args: impl IntoIterator<Item = Option<&'a str>>,
    crate_types: &[String],
    debuginfo: &TargetDebuginfo,
) -> bool {
    let mut debuginfo_on = false;
    let mut split = None;
    let mut test = false;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        let Some(a) = a else { continue };
        let codegen = match a {
            "-C" | "--codegen" => it.next().flatten(),
            "-g" => {
                debuginfo_on = true;
                None
            }
            "--test" => {
                test = true;
                None
            }
            _ => a
                .strip_prefix("--codegen=")
                .or_else(|| a.strip_prefix("-C")),
        };
        match codegen.and_then(|c| c.split_once('=')) {
            Some(("debuginfo", v)) => debuginfo_on = !matches!(v, "0" | "none"),
            Some(("split-debuginfo", v)) => split = SplitDebuginfo::parse(v),
            _ => {}
        }
    }
    let split = split.unwrap_or(debuginfo.split_default);
    let links = test
        || crate_types
            .iter()
            .any(|t| matches!(t.as_str(), "bin" | "cdylib" | "dylib"));
    debuginfo.artifacts.iter().any(|a| match a.when {
        DebugArtifactWhen::Always => links,
        DebugArtifactWhen::SplitPacked => debuginfo_on && split == SplitDebuginfo::Packed,
        DebugArtifactWhen::SplitUnpacked => debuginfo_on && split == SplitDebuginfo::Unpacked,
    })
}

/// A product of the plan.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Root {
    pub package: String,
    /// The Cargo target name.
    pub target: String,
    pub kind: RootKind,
    pub unit: UnitId,
    pub test: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RootKind {
    /// A library's own test harness (`--test` on the lib target).
    Lib,
    Bin,
    Cdylib,
    Dylib,
    Staticlib,
    Example,
    Test,
    Bench,
}

impl Reference {
    /// The unit this reference names, for `out` references.
    pub fn unit(&self) -> Option<&str> {
        match self {
            Reference::Out(o) => Some(&o.out),
            _ => None,
        }
    }
}

/// Visit every literal string of a unit that becomes part of a command, an
/// env value or an env name, with a description of where it is. The
/// literals of a doctest's `searchPathsOf` splice are included.
pub(crate) fn for_each_literal(unit: &Unit, f: &mut dyn FnMut(&str, &dyn Fn() -> String)) {
    fn text(t: &Text, what: &dyn Fn() -> String, f: &mut dyn FnMut(&str, &dyn Fn() -> String)) {
        match t {
            Text::Literal(s) => f(s, what),
            Text::Concat(pieces) => pieces.iter().for_each(|p| {
                if let Piece::Literal(s) = p {
                    f(s, what)
                }
            }),
        }
    }
    for (i, p) in unit.program.iter().enumerate() {
        text(p, &|| format!("program[{i}]"), f);
    }
    for (i, a) in unit.args.iter().enumerate() {
        match a {
            Arg::Literal(s) => f(s, &|| format!("args[{i}]")),
            Arg::Concat(p) => text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f),
            Arg::SearchPaths(s) => {
                for l in &s.literals {
                    f(l, &|| format!("args[{i}] (searchPathsOf literal)"));
                }
            }
            Arg::Splice(_) => {}
        }
    }
    for (k, v) in &unit.env {
        f(k, &|| format!("env name `{k}`"));
        text(v, &|| format!("env `{k}`"), f);
    }
    if let Cwd::Literal(s) = &unit.cwd {
        f(s, &|| "cwd".into());
    }
}

/// Visit every reference of a unit.
pub(crate) fn for_each_reference(unit: &Unit, f: &mut dyn FnMut(&Reference, &dyn Fn() -> String)) {
    fn text(
        t: &Text,
        what: &dyn Fn() -> String,
        f: &mut dyn FnMut(&Reference, &dyn Fn() -> String),
    ) {
        if let Text::Concat(pieces) = t {
            for p in pieces {
                if let Piece::Ref(r) = p {
                    f(r, what)
                }
            }
        }
    }
    for (i, p) in unit.program.iter().enumerate() {
        text(p, &|| format!("program[{i}]"), f);
    }
    for (i, a) in unit.args.iter().enumerate() {
        if let Arg::Concat(p) = a {
            text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f);
        }
    }
    for (k, v) in &unit.env {
        text(v, &|| format!("env `{k}`"), f);
    }
    if let Cwd::Ref(r) = &unit.cwd {
        f(r, &|| "cwd".into());
    }
}
