//! The per-unit specification `breakbulk-unit` reads from `BREAKBULK_UNIT`.
//!
//! This is a unit from `plan.json` after instantiation: every reference
//! (`src`, `crateSrc`, `out`) is rendered to a literal path, and every splice
//! names the `flags` output directory of its build-script run instead of the
//! run's unit id. `breakbulk-format` produces it; it lives here so that
//! `breakbulk-unit`, an input of every unit, does not depend on the plan format.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};

/// A directive kind that reaches compiles: what a splice expands, and the kind
/// of each parsed link argument.
///
/// The names are the directive keys of the `cargo::` syntax. The two spellings
/// of the cdylib directive (`rustc-link-arg-cdylib`, `rustc-cdylib-link-arg`)
/// are one kind, as in Cargo.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SpliceKind {
    RustcCfg,
    RustcCheckCfg,
    RustcEnv,
    RustcLinkLib,
    RustcLinkSearch,
    RustcLinkArg,
    RustcLinkArgBins,
    /// `rustc-link-arg-bin=NAME=ARG`; a [`LinkArgKind`] carries the bin name.
    RustcLinkArgBin,
    RustcLinkArgTests,
    RustcLinkArgBenches,
    RustcLinkArgExamples,
    RustcLinkArgCdylib,
}

impl SpliceKind {
    pub const ALL: [SpliceKind; 12] = [
        SpliceKind::RustcCfg,
        SpliceKind::RustcCheckCfg,
        SpliceKind::RustcEnv,
        SpliceKind::RustcLinkLib,
        SpliceKind::RustcLinkSearch,
        SpliceKind::RustcLinkArg,
        SpliceKind::RustcLinkArgBins,
        SpliceKind::RustcLinkArgBin,
        SpliceKind::RustcLinkArgTests,
        SpliceKind::RustcLinkArgBenches,
        SpliceKind::RustcLinkArgExamples,
        SpliceKind::RustcLinkArgCdylib,
    ];

    /// The directive key, as written after `cargo::`.
    pub fn as_str(self) -> &'static str {
        match self {
            SpliceKind::RustcCfg => "rustc-cfg",
            SpliceKind::RustcCheckCfg => "rustc-check-cfg",
            SpliceKind::RustcEnv => "rustc-env",
            SpliceKind::RustcLinkLib => "rustc-link-lib",
            SpliceKind::RustcLinkSearch => "rustc-link-search",
            SpliceKind::RustcLinkArg => "rustc-link-arg",
            SpliceKind::RustcLinkArgBins => "rustc-link-arg-bins",
            SpliceKind::RustcLinkArgBin => "rustc-link-arg-bin",
            SpliceKind::RustcLinkArgTests => "rustc-link-arg-tests",
            SpliceKind::RustcLinkArgBenches => "rustc-link-arg-benches",
            SpliceKind::RustcLinkArgExamples => "rustc-link-arg-examples",
            SpliceKind::RustcLinkArgCdylib => "rustc-link-arg-cdylib",
        }
    }

    /// True for `rustc-link-arg` and its target-specific forms.
    pub fn is_link_arg(self) -> bool {
        matches!(
            self,
            SpliceKind::RustcLinkArg
                | SpliceKind::RustcLinkArgBins
                | SpliceKind::RustcLinkArgBin
                | SpliceKind::RustcLinkArgTests
                | SpliceKind::RustcLinkArgBenches
                | SpliceKind::RustcLinkArgExamples
                | SpliceKind::RustcLinkArgCdylib
        )
    }
}

impl std::fmt::Display for SpliceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A splice point: "run `splice`'s directives of `kind` go here".
///
/// `S` names the run: a unit id in `plan.json`, the run's `flags` directory in
/// `BREAKBULK_UNIT`. The shapes ("Fields" in
/// `docs/src/reference/plan-format.md`):
///
/// - `rustc-cfg`, `rustc-check-cfg`, `rustc-link-lib` (arguments) and
///   `rustc-env` (`envSplices`): the run's values of that kind.
/// - `rustc-link-search` with `in`: the run's search paths inside its own
///   `out` (`"in": "out"`), or all its other search paths (`"other"`).
/// - `rustc-link-arg` with `kinds`: the run's link arguments whose kind is in
///   `kinds`, in printed order across kinds.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Splice<S = String> {
    pub splice: S,
    pub kind: SpliceKind,
    /// Which search paths, for `rustc-link-search` only.
    #[serde(default, rename = "in", skip_serializing_if = "Option::is_none")]
    pub search: Option<SearchIn>,
    /// The link-arg kinds that apply to the unit, for `rustc-link-arg` only.
    /// A set: sorted, no duplicates.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<LinkArgKind>>,
}

impl<S> Splice<S> {
    /// A splice of one simple kind (`rustc-cfg`, `rustc-check-cfg`,
    /// `rustc-link-lib`, `rustc-env`).
    pub fn new(splice: S, kind: SpliceKind) -> Self {
        Splice {
            splice,
            kind,
            search: None,
            kinds: None,
        }
    }

    /// A `rustc-link-search` splice.
    pub fn search(splice: S, search: SearchIn) -> Self {
        Splice {
            splice,
            kind: SpliceKind::RustcLinkSearch,
            search: Some(search),
            kinds: None,
        }
    }

    /// A `rustc-link-arg` splice for the given kinds (sorted here).
    pub fn link_args(splice: S, kinds: impl IntoIterator<Item = LinkArgKind>) -> Self {
        let mut kinds: Vec<LinkArgKind> = kinds.into_iter().collect();
        kinds.sort();
        kinds.dedup();
        Splice {
            splice,
            kind: SpliceKind::RustcLinkArg,
            search: None,
            kinds: Some(kinds),
        }
    }

    /// Change what names the run, keeping the shape.
    pub fn map<T>(&self, f: impl FnOnce(&S) -> T) -> Splice<T> {
        Splice {
            splice: f(&self.splice),
            kind: self.kind,
            search: self.search,
            kinds: self.kinds.clone(),
        }
    }

    /// Whether the fields fit the kind. `Err` describes the mismatch.
    pub fn check_shape(&self) -> Result<(), String> {
        match self.kind {
            SpliceKind::RustcCfg
            | SpliceKind::RustcCheckCfg
            | SpliceKind::RustcLinkLib
            | SpliceKind::RustcEnv => {
                if self.search.is_some() || self.kinds.is_some() {
                    return Err(format!(
                        "a {} splice takes neither `in` nor `kinds`",
                        self.kind
                    ));
                }
            }
            SpliceKind::RustcLinkSearch => {
                if self.search.is_none() || self.kinds.is_some() {
                    return Err("a rustc-link-search splice needs `in` and no `kinds`".into());
                }
            }
            SpliceKind::RustcLinkArg => {
                let Some(kinds) = &self.kinds else {
                    return Err("a rustc-link-arg splice needs `kinds`".into());
                };
                if self.search.is_some() {
                    return Err("a rustc-link-arg splice takes no `in`".into());
                }
                if kinds.is_empty() {
                    return Err("a rustc-link-arg splice has empty `kinds`".into());
                }
                if kinds.windows(2).any(|w| w[0] >= w[1]) {
                    return Err("`kinds` must be sorted and without duplicates".into());
                }
            }
            k => {
                return Err(format!(
                    "{k} is not a splice kind; link-arg kinds go in the `kinds` of a rustc-link-arg splice"
                ));
            }
        }
        Ok(())
    }
}

/// Which of a run's `rustc-link-search` values a splice stands for. Cargo
/// puts the paths inside the printing script's own `OUT_DIR`
/// (`LibraryPath::CargoArtifact`) before all others (`External`), across all
/// runs a unit links; the stub prints one sentinel of each class, so the
/// trace shows where each class goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SearchIn {
    /// Paths inside the run's `out`.
    Out,
    /// Every other path.
    Other,
}

/// One link-arg kind in a `rustc-link-arg` splice: `rustc-link-arg`,
/// `rustc-link-arg-bins`, …, or `rustc-link-arg-bin=NAME` for one bin.
/// Serialized as that string.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LinkArgKind {
    pub kind: SpliceKind,
    /// The bin name, for `rustc-link-arg-bin` only.
    pub bin: Option<String>,
}

impl LinkArgKind {
    pub fn new(kind: SpliceKind) -> Self {
        LinkArgKind { kind, bin: None }
    }
    pub fn bin(name: impl Into<String>) -> Self {
        LinkArgKind {
            kind: SpliceKind::RustcLinkArgBin,
            bin: Some(name.into()),
        }
    }
}

impl fmt::Display for LinkArgKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.bin {
            Some(b) => write!(f, "{}={b}", self.kind),
            None => write!(f, "{}", self.kind),
        }
    }
}

impl std::str::FromStr for LinkArgKind {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        let (k, bin) = match s.split_once('=') {
            Some((k, b)) => (k, Some(b.to_owned())),
            None => (s, None),
        };
        let kind = SpliceKind::ALL
            .into_iter()
            .find(|x| x.as_str() == k && x.is_link_arg())
            .ok_or_else(|| format!("`{s}` is not a link-arg kind"))?;
        if (kind == SpliceKind::RustcLinkArgBin) != bin.as_ref().is_some_and(|b| !b.is_empty()) {
            return Err(format!(
                "`{s}`: rustc-link-arg-bin needs `=NAME`, and only it takes one"
            ));
        }
        Ok(LinkArgKind { kind, bin })
    }
}

impl Serialize for LinkArgKind {
    fn serialize<Se: serde::Serializer>(&self, s: Se) -> Result<Se::Ok, Se::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for LinkArgKind {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        s.parse().map_err(serde::de::Error::custom)
    }
}

/// A target of the package a build script belongs to, as `cargo metadata`
/// reports it. Used for Cargo's `rustc-link-arg-*` validations.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageTarget {
    pub name: String,
    /// `cargo metadata`'s `kind`: `bin`, `example`, `test`, `bench`,
    /// `custom-build`, or the crate types of a library (`lib`, `rlib`,
    /// `cdylib`, …).
    pub kind: Vec<String>,
}

impl PackageTarget {
    fn has_kind(&self, k: &str) -> bool {
        self.kind.iter().any(|x| x == k)
    }
    /// Cargo's `Target::is_bin`.
    pub fn is_bin(&self) -> bool {
        self.has_kind("bin")
    }
    /// Cargo's `Target::is_test`.
    pub fn is_test(&self) -> bool {
        self.has_kind("test")
    }
    /// Cargo's `Target::is_bench`.
    pub fn is_bench(&self) -> bool {
        self.has_kind("bench")
    }
    /// Cargo's `Target::is_example` (any example, whatever its crate type).
    pub fn is_example(&self) -> bool {
        self.has_kind("example")
    }
    /// Cargo's `Target::is_cdylib`: a library target with crate type `cdylib`.
    /// `cargo metadata` lists a library's crate types as its kinds, and an
    /// example's kind as `example` whatever its crate type.
    pub fn is_cdylib(&self) -> bool {
        self.has_kind("cdylib")
    }
    /// Cargo's `Target::is_lib`: the library, whatever its crate types.
    pub fn is_lib(&self) -> bool {
        !self.kind.iter().any(|k| {
            matches!(
                k.as_str(),
                "bin" | "example" | "test" | "bench" | "custom-build"
            )
        })
    }
}

/// `host` or `target`, observed from Cargo's output layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Platform {
    Host,
    Target,
}

/// One argument of a rendered command: a literal, or a splice point.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RenderedArg {
    Literal(String),
    Splice(Splice<String>),
    SearchPaths(SearchPaths),
    /// Doctests only: where the test runner goes.
    Runner(RunnerSlot),
}

/// `{ "runner": "test" }`: where a doctest's `rustdoc --test` takes the
/// runner of its platform, as `--test-runtool R --test-runtool-arg A …`:
/// where Cargo passed the traced one, which the planner removes. Empty
/// when the platform has no runner.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunnerSlot {
    pub runner: RunnerKind,
}

/// The runner a [`RunnerSlot`] takes: the platform's test runner (the only
/// one).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RunnerKind {
    Test,
}

impl RunnerSlot {
    pub const TEST: RunnerSlot = RunnerSlot {
        runner: RunnerKind::Test,
    };
}

/// `{ "searchPathsOf": [F, …], "literals": [ … ] }`: `-L P` for every
/// search path of the runs whose `flags` directories are listed, both
/// classes, and for each of `literals`, sorted and without duplicates as
/// Cargo's `BTreeSet<PathBuf>` holds them. Cargo gives `rustdoc --test`
/// its `-L` list this way (`run_doc_tests`, from
/// `Compilation::native_dirs`): computed from values rather than printed
/// positions, so it is one splice rather than one per run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SearchPaths {
    pub search_paths_of: Vec<String>,
    /// Search paths that are no run's (`links` overrides in config).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub literals: Vec<String>,
}

/// The crate a compile unit builds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CrateInfo {
    pub name: String,
    pub types: Vec<String>,
    pub edition: String,
}

/// `BREAKBULK_UNIT`: what one derivation runs, every reference rendered.
/// `breakbulk-unit` does what its `kind` says.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum RenderedUnit {
    /// One rustc (or wrapper) invocation.
    Compile(RenderedCompile),
    /// One build-script run.
    Run(RenderedRun),
    /// One library's `rustdoc --test`, which compiles and runs its
    /// examples (`breakbulk-doctest`).
    Doctest(RenderedDoctest),
    /// A doc plan's rustdoc commands, run in order into one folder
    /// (`breakbulk-docs`).
    Docs(RenderedDocs),
}

/// A doctest derivation's command and the package's test configuration.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenderedDoctest {
    /// The traced `rustdoc --test`. Its `outputs` is empty: rustdoc writes
    /// nothing that is kept.
    pub command: RenderedCompile,
    #[serde(default)]
    pub test: DoctestConfig,
}

/// A doctest's test configuration (`testRuns.doctestConfig` in
/// `lib/test-runs.nix`), each part JSON text, empty for none. Text rather
/// than values: instantiation renders the doctest before the
/// configuration's values are known, and substitutes each as a string.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DoctestConfig {
    /// `{ "host": [P, A, …], "target": [ … ] }`: each platform's runner,
    /// a program and its arguments; a platform without one runs directly.
    #[serde(default)]
    pub runners: String,
    /// `[A, …]`: libtest arguments.
    #[serde(default)]
    pub args: String,
    /// `[L, …]`: env layers ([`crate::env::EnvLayer`]) merged over the
    /// command's environment, lowest first.
    #[serde(default)]
    pub env: String,
    /// A program run after passing doctests (not JSON).
    #[serde(default)]
    pub post_run: String,
}

impl DoctestConfig {
    /// The configuration's parts, by their names in `doctestConfig`.
    pub const PARTS: [&str; 4] = ["runners", "args", "env", "postRun"];

    /// The part named `name` (one of [`DoctestConfig::PARTS`]).
    pub fn part_mut(&mut self, name: &str) -> &mut String {
        match name {
            "runners" => &mut self.runners,
            "args" => &mut self.args,
            "env" => &mut self.env,
            "postRun" => &mut self.post_run,
            _ => panic!("no doctest configuration part `{name}`"),
        }
    }
}

/// A docs derivation's commands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenderedDocs {
    /// The traced `rustdoc` commands, in the order they run. Without `-o`
    /// and `-L dependency=`; `outputs` and `remap` are empty.
    pub commands: Vec<RenderedCompile>,
}

/// What a unit keeps only to explain a failure ([`crate::view_hints`],
/// [`crate::repository_paths`]); nothing in it changes what runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Hints {
    /// For a unit of a repository package: its source view, for the hints
    /// when it fails naming a path the view lacks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view: Option<SourceView>,
    /// For a unit of a registry or git package: the repository paths its
    /// env values and arguments name.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repository_paths: Vec<RepositoryPath>,
}

impl Hints {
    pub fn is_empty(&self) -> bool {
        self.view.is_none() && self.repository_paths.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedCompile {
    pub package: String,
    #[serde(rename = "crate")]
    pub krate: CrateInfo,
    pub platform: Platform,
    pub program: Vec<String>,
    pub args: Vec<RenderedArg>,
    pub env: BTreeMap<String, String>,
    /// The variables of `env` (Cargo's recorded env, layer 3) that append
    /// to the env capture's value (layer 2), with their separators: its
    /// list-like variables. The others replace it
    /// ([`crate::env::merge_rendered`]).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env_append: crate::env::EnvAppend,
    /// Layers 4 and 5: the toolchain spec's env, then the package's, each
    /// value replacing or appending ([`crate::env::fold_layers`]).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_layers: Vec<crate::env::EnvLayer>,
    pub env_splices: Vec<Splice<String>>,
    /// The `flags` directories of the runs whose search paths inside their
    /// `out` go on the dynamic-library path, in order (dynamic-path splices).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<String>,
    pub cwd: String,
    /// Where each file the program writes goes ([`OutputRule`]), first
    /// matching rule first. Every derivation output a rule names is
    /// created, even when no file goes there.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outputs: Vec<OutputRule>,
    /// Crate files (`.rmeta`, `.rlib` or a proc macro's shared library)
    /// that `breakbulk-unit` symlinks into one directory, passed as the only
    /// `-L dependency=`: the files the arguments name, and for a unit that
    /// links, every crate file below it.
    pub deps: Vec<String>,
    /// The `rmeta` output directories of the direct library dependencies.
    /// Each holds a [`crate::manifest::Manifest`]; together, walked down,
    /// they name every crate file and build-script `flags` directory below
    /// this unit, and Nix's reference scanning has put all of them in the
    /// sandbox without the derivation naming them as inputs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dep_manifests: Vec<String>,
    /// Whether the crate files the manifests name go into the dependency
    /// directory too: for units that do not link (which `deps` lists only
    /// the direct dependencies of). A linking unit reads the manifests only
    /// to write its own.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub link_manifest_crates: bool,
    /// For a unit with an `rmeta` output, which gets a manifest: the crate
    /// files below it that no dependency's manifest names (proc macros it
    /// names directly).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub manifest_crates: Vec<String>,
    /// `--remap-path-prefix` pairs (from, to) that `breakbulk-unit` adds.
    /// Empty when Cargo's own `trim-paths` remaps are in the arguments.
    /// The same pairs become `-ffile-prefix-map` in `NIX_CFLAGS_COMPILE`.
    pub remap: Vec<(String, String)>,
    /// The `--remap-path-scope` value to add, for `remap` or for Cargo's
    /// own trim-paths remaps in the arguments; `None` adds no scope flag,
    /// which means every scope.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remap_scope: Option<String>,
    /// Layer 2 of the environment contract: an env capture's `env.json` (a
    /// JSON object of strings) or the capture's output directory holding it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_capture: Option<String>,
    /// For a unit that links: the env captures (as `env_capture`) of the
    /// other packages in its link closure, on its platform, that have their
    /// own inputs. Only their library search variables
    /// ([`crate::env::LINK_VARS`]) are used, appended to layer 2, so the
    /// linker wrapper finds (and records an rpath to) the native libraries
    /// a `-sys` crate below names with `rustc-link-lib` alone.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub link_captures: Vec<String>,
    #[serde(default, skip_serializing_if = "Hints::is_empty")]
    pub hints: Hints,
    /// The value of `-frandom-seed` for C code: the unit's key in the plan
    /// (Cargo's `-C metadata` hash for a compile, its `OUT_DIR` hash for a
    /// run). Unlike stdenv's seed from the output path, it does not change
    /// when an input changes without changing the unit (a new
    /// `breakbulk-unit`, a new env capture), so C objects with debug info,
    /// which record the flag, keep their bytes. The renderer always sets
    /// it; `None` adds no seed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<String>,
}

pub use breakbulk_hints::{SourceView, Widen, package_name_version};

/// A repository path in a unit of a package outside the repository: Cargo
/// config `[env]` with `relative = true`, or `build.rustflags`. Such a
/// unit has no source view, so the path points into an empty directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RepositoryPath {
    /// The path, relative to the repository root (empty for the root).
    pub path: String,
    /// The env variable whose value holds it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<String>,
    /// Whether that value is the path alone, which a package's `env` can
    /// replace with the same directory.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub whole: bool,
    /// The rustc argument that holds it, with the flag before it when the
    /// flag is a separate argument (`-L native=vendor/lib`), and the path
    /// relative to the repository root. Also an argument inside
    /// `CARGO_ENCODED_RUSTFLAGS`, which then is `env`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arg: Option<String>,
}

/// Cargo's description of a package in messages (`PackageId`'s `Display`):
/// `name vX.Y.Z`, followed by the source for packages not from crates.io.
/// Path sources are left out: in a plan they name the planner's skeleton,
/// which means nothing to the reader.
pub fn package_descr(id: &str) -> String {
    match package_name_version(id) {
        Some((name, version)) => {
            let source = id.rsplit_once('#').map_or(id, |(u, _)| u);
            if source == "registry+https://github.com/rust-lang/crates.io-index"
                || source.starts_with("path+")
            {
                format!("{name} v{version}")
            } else {
                format!("{name} v{version} ({source})")
            }
        }
        None => id.to_owned(),
    }
}

/// How Cargo names a package in build-script warnings: `name@version`.
pub fn package_spec(id: &str) -> String {
    match package_name_version(id) {
        Some((name, version)) => format!("{name}@{version}"),
        None => id.to_owned(),
    }
}

/// Where a file the program writes goes: the first rule whose `match` it
/// meets decides.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutputRule {
    #[serde(rename = "match")]
    pub matches: FileMatch,
    pub into: OutputInto,
    /// The name a [`FileMatch::File`] is stored under, when not its own: a
    /// bin Cargo uplifts (`app`, not rustc's `app-<hash>`), so the path a
    /// test gets in `CARGO_BIN_EXE_<name>` names a file of that name.
    #[serde(rename = "as", default, skip_serializing_if = "Option::is_none")]
    pub stored: Option<String>,
}

/// Which files an [`OutputRule`] is for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub enum FileMatch {
    /// The file of this name, which the program must write: the unit
    /// fails when it is missing.
    File(String),
    /// Any file or directory whose name ends in this.
    Suffix(String),
}

/// Where the files of an [`OutputRule`] go.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutputInto {
    /// Into this derivation output.
    Output(String),
    /// Beside a file a [`FileMatch::File`] rule stores: `<stem><suffix>`,
    /// where `<stem>` is that file's name without its extension, goes into
    /// its output (each of them, when an `rlib` and an `rmeta` share the
    /// stem), under its stored stem. A dependent's compile sees it beside
    /// the crate file wherever it sees the crate file: at its real path, in
    /// that output, and in the dependency directory, where `breakbulk-unit`
    /// links it beside the crate file's link (`compile::link_deps`). Verus
    /// reads a `.vir` beside each `--extern`'s real path and beside the
    /// path rustc loaded each other crate from, the link. A file with no
    /// such stem goes on to the next rule.
    Beside,
    /// Nowhere, without a word (rustc's dep-info). A file no rule matches
    /// is discarded with a warning.
    Discard,
}

impl OutputRule {
    /// A required file, stored under its own name.
    pub fn file(name: impl Into<String>, output: impl Into<String>) -> Self {
        OutputRule {
            matches: FileMatch::File(name.into()),
            into: OutputInto::Output(output.into()),
            stored: None,
        }
    }

    /// Every file ending in `suffix`.
    pub fn suffix(suffix: impl Into<String>, into: OutputInto) -> Self {
        OutputRule {
            matches: FileMatch::Suffix(suffix.into()),
            into,
            stored: None,
        }
    }

    /// The derivation output the rule sends files into, if any.
    pub fn output(&self) -> Option<&str> {
        match &self.into {
            OutputInto::Output(o) => Some(o),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RenderedRun {
    pub package: String,
    pub platform: Platform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<String>,
    /// The build-script executable, or its compile unit's `bin` output
    /// directory holding exactly one file.
    pub script: String,
    /// Layer 3 of the environment contract, Cargo's recorded env. Has no `OUT_DIR`:
    /// `breakbulk-unit` sets it inside the run's own `out` (`out_dir`).
    pub env: BTreeMap<String, String>,
    /// The variables of `env` (Cargo's recorded env, layer 3) that append
    /// to the env capture's value (layer 2), with their separators: its
    /// list-like variables. The others replace it
    /// ([`crate::env::merge_rendered`]).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env_append: crate::env::EnvAppend,
    /// Layers 4 and 5: the toolchain spec's env, then the package's, each
    /// value replacing or appending ([`crate::env::fold_layers`]).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_layers: Vec<crate::env::EnvLayer>,
    /// Where `OUT_DIR` is inside the run's `out`, as Cargo laid out its
    /// target directory (`RunUnit::out_dir`, #23). Empty: the `out` itself.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub out_dir: String,
    /// The package directory; the script runs here.
    pub cwd: String,
    /// The `flags` directories of the upstream runs whose `metadata.json`
    /// becomes `DEP_<LINKS>_<KEY>` in this run's env.
    pub metadata_from: Vec<String>,
    /// Dynamic-path splices, as for compiles.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<String>,
    /// The package's `rust-version`, for Cargo's `cargo::` syntax check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<String>,
    /// The package's targets, for Cargo's `rustc-link-arg-*` validations.
    pub targets: Vec<PackageTarget>,
    /// Cargo's `nightly_features_allowed` for the planning toolchain: decides
    /// whether `rustc-env=RUSTC_BOOTSTRAP=…` is an error or a warning.
    pub nightly_features_allowed: bool,
    /// Layer 2 of the environment contract, as for compile units.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env_capture: Option<String>,
    /// Source paths (from, to) that C code compiled by the script must not
    /// embed: the package's source view or crate source, and any `OUT_DIR`
    /// the run names, with the names Rust remaps them to; under Cargo's
    /// trim-paths, Cargo's names (the pairs of `CARGO_TRIM_PATHS_REMAP`
    /// and the expanded build-directory pair), so they agree with the maps
    /// cc-rs derives from that variable. They become
    /// `-ffile-prefix-map` in `NIX_CFLAGS_COMPILE`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub remap: Vec<(String, String)>,
    /// The name the run's own `OUT_DIR` (`$out`, which the unit cannot name
    /// in its attributes) is remapped to, as with `remap`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_dir_remap: Option<String>,
    /// What to delete from `$out` after a successful run
    /// ([`OutDirRemove`]), in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub out_dir_remove: Vec<OutDirRemove>,
    #[serde(default, skip_serializing_if = "Hints::is_empty")]
    pub hints: Hints,
    /// The value of `-frandom-seed` for C code: the unit's key in the plan
    /// (Cargo's `-C metadata` hash for a compile, its `OUT_DIR` hash for a
    /// run). Unlike stdenv's seed from the output path, it does not change
    /// when an input changes without changing the unit (a new
    /// `breakbulk-unit`, a new env capture), so C objects with debug info,
    /// which record the flag, keep their bytes. The renderer always sets
    /// it; `None` adds no seed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<String>,
}

impl RenderedCompile {
    /// Layers 3 to 5 as one env, and which of its variables append to the
    /// env capture.
    pub fn layered_env(&self) -> (BTreeMap<String, String>, crate::env::EnvAppend) {
        crate::env::fold_layers(&self.env, &self.env_append, &self.env_layers)
    }
}

impl RenderedRun {
    /// As for [`RenderedCompile::layered_env`].
    pub fn layered_env(&self) -> (BTreeMap<String, String>, crate::env::EnvAppend) {
        crate::env::fold_layers(&self.env, &self.env_append, &self.env_layers)
    }
}

/// A removal rule for a build-script run's output
/// (`packages.<name>.buildScript.outDirRemove`): in every directory under
/// `$out` that holds a file named `beside`, the entry `path` (a file or a
/// directory, relative to that directory) is deleted after the script
/// succeeds. For state a tool leaves in `OUT_DIR` that nothing reads after
/// the run and that differs between runs, such as CMake's configure log.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutDirRemove {
    pub beside: String,
    pub path: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splice_kind_names_round_trip() {
        for k in SpliceKind::ALL {
            let json = serde_json::to_string(&k).unwrap();
            assert_eq!(json, format!("\"{}\"", k.as_str()));
            assert_eq!(serde_json::from_str::<SpliceKind>(&json).unwrap(), k);
        }
    }

    #[test]
    fn package_ids() {
        let ring = "registry+https://github.com/rust-lang/crates.io-index#ring@0.17.14";
        assert_eq!(package_name_version(ring), Some(("ring", "0.17.14")));
        assert_eq!(package_descr(ring), "ring v0.17.14");
        let app = "path+file:///build/skeleton/app#0.1.0";
        assert_eq!(package_name_version(app), Some(("app", "0.1.0")));
        assert_eq!(package_descr(app), "app v0.1.0");
        assert_eq!(package_spec(app), "app@0.1.0");
        assert_eq!(
            package_descr("git+https://e.com/r?rev=1#x@0.2.0"),
            "x v0.2.0 (git+https://e.com/r?rev=1)"
        );
        assert_eq!(
            package_name_version("path+file:///w/crates/x#other@1.0.0"),
            Some(("other", "1.0.0"))
        );
        assert_eq!(
            package_name_version("git+https://example.com/r/foo?rev=abc#0.2.0"),
            Some(("foo", "0.2.0"))
        );
        assert_eq!(package_name_version("cfg-if"), None);
        assert_eq!(package_descr("cfg-if"), "cfg-if");
    }

    #[test]
    fn rendered_args_parse() {
        let args: Vec<RenderedArg> = serde_json::from_str(
            r#"["--cfg", {"splice": "/nix/store/x-flags", "kind": "rustc-cfg"},
                {"splice": "/f", "kind": "rustc-link-arg",
                 "kinds": ["rustc-link-arg", "rustc-link-arg-bin=app"]},
                {"splice": "/f", "kind": "rustc-link-search", "in": "other"}]"#,
        )
        .unwrap();
        assert_eq!(args[0], RenderedArg::Literal("--cfg".into()));
        assert_eq!(
            args[2],
            RenderedArg::Splice(Splice::link_args(
                "/f".to_owned(),
                [
                    LinkArgKind::new(SpliceKind::RustcLinkArg),
                    LinkArgKind::bin("app")
                ]
            ))
        );
        assert_eq!(
            args[3],
            RenderedArg::Splice(Splice::search("/f".to_owned(), SearchIn::Other))
        );
        for a in &args[1..] {
            let RenderedArg::Splice(s) = a else { panic!() };
            s.check_shape().unwrap();
        }
        assert_eq!(
            serde_json::to_string(&args[2]).unwrap(),
            r#"{"splice":"/f","kind":"rustc-link-arg","kinds":["rustc-link-arg","rustc-link-arg-bin=app"]}"#
        );
        assert!(
            serde_json::from_str::<RenderedArg>(r#"{"splice": "/f", "kind": "nope"}"#).is_err()
        );
        for bad in [
            r#"{"splice": "/f", "kind": "rustc-link-arg", "kinds": ["rustc-cfg"]}"#,
            r#"{"splice": "/f", "kind": "rustc-link-arg", "kinds": ["rustc-link-arg-bin"]}"#,
            r#"{"splice": "/f", "kind": "rustc-link-arg", "kinds": ["rustc-link-arg-bins=x"]}"#,
            r#"{"splice": "/f", "kind": "rustc-link-search", "in": "elsewhere"}"#,
        ] {
            assert!(serde_json::from_str::<RenderedArg>(bad).is_err(), "{bad}");
        }
        for bad_shape in [
            Splice::new("/f", SpliceKind::RustcLinkSearch),
            Splice::new("/f", SpliceKind::RustcLinkArgBins),
            Splice::link_args("/f", []),
            Splice {
                search: Some(SearchIn::Out),
                ..Splice::new("/f", SpliceKind::RustcCfg)
            },
        ] {
            assert!(bad_shape.check_shape().is_err(), "{bad_shape:?}");
        }
        assert!(
            serde_json::from_str::<RenderedArg>(r#"{"splice": "/f", "kind": "rustc-cfg", "x": 1}"#)
                .is_err()
        );
    }
}
