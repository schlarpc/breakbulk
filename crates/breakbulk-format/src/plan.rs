//! Types for `plan.json`, as described under "Plan format" in
//! `docs/implementation.md`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

pub use breakbulk_unit::spec::{
    CrateInfo, LinkArgKind, PackageTarget, Platform, SearchIn, SpliceKind,
};

/// The only plan format version this crate reads and writes.
pub const PLAN_VERSION: u32 = 1;

/// A unit's key: `c-<hash>` for compile units (Cargo's `-C metadata`),
/// `r-<pkg>-<hash>` for build-script runs (from `OUT_DIR`).
pub type UnitId = String;

/// A splice point in `plan.json`: names a run unit.
pub type Splice = breakbulk_unit::spec::Splice<UnitId>;

/// One `plan.json`: every unit of one (workspace, target, variant, plan kind).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Plan {
    pub version: u32,
    pub kind: PlanKind,
    /// `cargo -V` version.
    pub cargo: String,
    /// `rustc -vV` release line.
    pub rustc: String,
    pub host: String,
    pub target: String,
    pub variant: Variant,
    /// The canonical absolute skeleton path planning ran at.
    pub skeleton_root: String,
    /// Whether Cargo's `trim-paths` was in effect: every compile unit
    /// carries Cargo's own remaps, and breakbulk adds none.
    pub trim_paths: bool,
    /// Whether the planner turned `trim-paths` on itself, because the
    /// project had not ("trim-paths" in `docs/implementation.md`). Cargo's
    /// `--remap-path-scope` is then left out of the plan, and breakbulk
    /// sets the scope per product kind, as with its own remaps.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub trim_paths_default: bool,
    pub units: BTreeMap<UnitId, Unit>,
    /// The plan's products: a set, serialized as a sorted array.
    pub roots: BTreeSet<Root>,
    /// Test plans: one traced `rustdoc --test` per library, keyed
    /// `d-<package name>`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub doctests: BTreeMap<String, Doctest>,
    /// The variables the project's `[env]` config table sets on the
    /// processes Cargo starts. Units keep them in their recorded env;
    /// test runs take their values from the test unit's recorded env, as
    /// `cargo test` gives them to test processes.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub config_env: BTreeSet<String>,
    /// When the toolchain ships the `rust-src` component: the remap
    /// `[<sysroot>/lib/rustlib/src/rust, /rustc/<commit-hash>]`. rustc
    /// rewrites standard-library paths (`/rustc/<hash>/library/…`) to that
    /// local copy, so without it panic locations in std code instantiated
    /// in the user's crates name the toolchain's store path, and every
    /// product references the whole toolchain. Cargo's `trim-paths` adds
    /// the same remap (cargo 0.97.0, `core/compiler/mod.rs`,
    /// `sysroot_remap`); breakbulk adds it to its own remaps.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_src_remap: Option<(String, String)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlanKind {
    Build,
    Test,
    /// `cargo bench --no-run`: bench binaries and harnesses in bench mode.
    Bench,
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
    Clippy,
    Coverage,
}

/// A working directory: a reference, or a literal store path. The literal
/// form is a toolchain path: the standard library's own packages under
/// `-Zbuild-std`, which Cargo compiles and runs in their directories in
/// the sysroot's `rust-src` ("build-std" in `docs/implementation.md`).
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
    /// Only in doctests.
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

/// A traced `rustdoc --test` of one library, from `cargo test --doc`. Run
/// by the doctest derivation (M4), which compiles and runs the examples in
/// one process. Its shape is a compile unit's, without outputs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Doctest {
    pub package: String,
    #[serde(rename = "crate")]
    pub krate: CrateInfo,
    pub program: Vec<Text>,
    pub args: Vec<Arg>,
    pub env: BTreeMap<String, Text>,
    pub env_splices: Vec<Splice>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<UnitId>,
    pub cwd: Cwd,
}

impl Doctest {
    /// The doctest as a compile unit with no outputs, for the checks and
    /// normalization compile units share. `searchPathsOf` splices are left
    /// out.
    pub fn as_compile(&self) -> CompileUnit {
        CompileUnit {
            package: self.package.clone(),
            krate: self.krate.clone(),
            platform: Platform::Target,
            program: self.program.clone(),
            args: self
                .args
                .iter()
                .filter(|a| !matches!(a, Arg::SearchPaths(_)))
                .cloned()
                .collect(),
            env: self.env.clone(),
            env_splices: self.env_splices.clone(),
            dylib_path_from: self.dylib_path_from.clone(),
            cwd: self.cwd.clone(),
            outputs: BTreeMap::new(),
        }
    }
}

impl From<Text> for Arg {
    fn from(t: Text) -> Arg {
        match t {
            Text::Literal(s) => Arg::Literal(s),
            Text::Concat(p) => Arg::Concat(p),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Unit {
    Compile(CompileUnit),
    Run(RunUnit),
}

impl Unit {
    pub fn package(&self) -> &str {
        match self {
            Unit::Compile(c) => &c.package,
            Unit::Run(r) => &r.package,
        }
    }
}

/// A rustc (or wrapper) invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CompileUnit {
    pub package: String,
    #[serde(rename = "crate")]
    pub krate: CrateInfo,
    pub platform: Platform,
    /// The program and wrapper chain, e.g. `[clippy-driver, rustc]`.
    pub program: Vec<Text>,
    pub args: Vec<Arg>,
    pub env: BTreeMap<String, Text>,
    /// Runs whose `rustc-env` values are added to `env`, in order; a later
    /// run's value wins.
    pub env_splices: Vec<Splice>,
    /// Dynamic-path splices: runs whose search paths inside their own `out`
    /// go on the process's dynamic-library path (`LD_LIBRARY_PATH`), in this
    /// order, before the recorded value. Cargo adds them for host plugin
    /// dependencies (proc macros, build dependencies with build scripts).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<UnitId>,
    pub cwd: Cwd,
    /// Output name to file names.
    pub outputs: BTreeMap<String, BTreeSet<String>>,
}

impl CompileUnit {
    /// Whether the unit gets a `debug` derivation output for the
    /// debuginfo side files rustc writes next to a linked output (decision
    /// 89): a target-platform unit with a `bin` output (bins, tests,
    /// examples, benches, cdylibs, dylibs, staticlibs) whose traced command
    /// makes rustc write side files on a target with these `traits`, by
    /// [`writes_debuginfo_side_files`].
    /// Nix outputs are fixed before the build, so this is decided from the
    /// command line; host units (build scripts, proc macros) only run
    /// during the build, so theirs are discarded.
    pub fn has_debug_output(&self, traits: &TargetTraits) -> bool {
        self.platform == Platform::Target
            && self.outputs.contains_key("bin")
            && writes_debuginfo_side_files(
                self.args.iter().map(|a| match a {
                    Arg::Literal(s) => Some(s.as_str()),
                    _ => None,
                }),
                &self.krate.types,
                traits,
            )
    }
}

/// What breakbulk's Rust programs need to know about the target platform.
/// The Nix library decides it from its target traits (`lib/target-traits.nix`,
/// `forRust`; "Target traits" in `docs/implementation.md`) and passes it in
/// `toolchains.json` as `targetTraits`, so no program re-derives a platform
/// fact from the spelling of a triple, and a target the user declared
/// traits for behaves as declared.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TargetTraits {
    /// The debuginfo files rustc's link writes beside a linked output,
    /// which `--print file-names` does not name (the traits'
    /// `debugArtifacts`): `.pdb` on msvc, `.dwp`/`.dwo` on ELF, `.dSYM` on
    /// Apple targets. Empty: none (wasm, a target with no split debuginfo).
    pub debug_artifacts: Vec<DebugArtifact>,
}

impl TargetTraits {
    /// A target whose links write no debuginfo side files.
    pub const NONE: &'static TargetTraits = &TargetTraits {
        debug_artifacts: Vec::new(),
    };
}

/// One kind of debuginfo side file (the traits' `debugArtifacts` entries).
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
    /// `--test`), whatever `-C debuginfo` and `-C strip` say: on
    /// `*-windows-msvc`, rustc passes `/DEBUG` to the MSVC-style linker
    /// unconditionally (rustc_codegen_ssa back/linker.rs,
    /// `MsvcLinker::debuginfo` ignores its `strip` argument; 1.95 through
    /// master, and an msvc release build with `-C strip=debuginfo` was seen
    /// to write a 1.2 MB PDB).
    Always,
    /// With debuginfo on and `-C split-debuginfo=packed`.
    SplitPacked,
    /// With debuginfo on and `-C split-debuginfo=unpacked`.
    SplitUnpacked,
}

/// Whether rustc, given these command-line arguments (`None` for an
/// argument that is not a literal: a build script's splices cannot set
/// codegen options) for a crate of these types, writes debuginfo side files
/// next to its linked output, on a target with these traits: whether any of
/// the traits' [`DebugArtifact`]s applies.
///
/// - [`DebugArtifactWhen::Always`] applies to every crate type the linker
///   produces (`bin`, `cdylib`, `dylib`, and `--test`). A staticlib is
///   archived, not linked.
/// - [`DebugArtifactWhen::SplitPacked`] and
///   [`DebugArtifactWhen::SplitUnpacked`] apply when the effective
///   `-C split-debuginfo` is that value and debuginfo is on. Cargo passes
///   `-C split-debuginfo` only together with `-C debuginfo` (cargo
///   src/compiler/mod.rs, `build_base_args`), but rustflags can add
///   either. As in rustc (rustc_session config.rs `select_debuginfo`), a
///   `-g` after the last `-C debuginfo` means full debuginfo, and the last
///   `-C` of an option wins.
pub fn writes_debuginfo_side_files<'a>(
    args: impl IntoIterator<Item = Option<&'a str>>,
    crate_types: &[String],
    traits: &TargetTraits,
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
            Some(("split-debuginfo", v)) => split = Some(v),
            _ => {}
        }
    }
    let links = test
        || crate_types
            .iter()
            .any(|t| matches!(t.as_str(), "bin" | "cdylib" | "dylib"));
    traits.debug_artifacts.iter().any(|a| match a.when {
        DebugArtifactWhen::Always => links,
        DebugArtifactWhen::SplitPacked => debuginfo_on && split == Some("packed"),
        DebugArtifactWhen::SplitUnpacked => debuginfo_on && split == Some("unpacked"),
    })
}

/// A build-script run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RunUnit {
    pub package: String,
    pub platform: Platform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub links: Option<String>,
    /// The build-script executable: an `out` reference to its compile unit.
    pub script: Reference,
    pub env: BTreeMap<String, Text>,
    /// The working directory Cargo gave the script (the package directory).
    pub cwd: Cwd,
    /// Upstream runs whose `DEP_<links>_*` metadata this run receives.
    pub metadata_from: BTreeSet<UnitId>,
    /// Dynamic-path splices, as for compile units: the runs of packages the
    /// build script depends on.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dylib_path_from: Vec<UnitId>,
    /// The package's `rust-version`, for Cargo's `cargo::` syntax check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust_version: Option<String>,
    /// The package's targets, for Cargo's `rustc-link-arg-*` validations.
    /// Sorted.
    pub targets: Vec<PackageTarget>,
    /// Cargo's `nightly_features_allowed` for the planning toolchain.
    pub nightly_features_allowed: bool,
    /// With Cargo's `trim-paths` ([`Plan::trim_paths`]): the name Cargo's
    /// build-directory remap gives the `OUT_DIR` of each run this run names
    /// (`/cargo/build-dir/<OUT_DIR relative to the build directory>`), its
    /// own included. Its C prefix maps use them with the pairs of
    /// `CARGO_TRIM_PATHS_REMAP`, so they agree with cc-rs's (decision
    /// 121). Empty without trim-paths.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_dir_remap: BTreeMap<UnitId, String>,
    /// Where `OUT_DIR` is inside the run's `out`: the traced `OUT_DIR`
    /// relative to Cargo's target directory (`<triple>/<profile>/build/
    /// <pkg>-<hash>/out`). A script that walks up from `OUT_DIR` to Cargo's
    /// target directory then finds the `out` itself, as under Cargo (#23).
    /// Empty: `OUT_DIR` is the `out`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub out_dir: String,
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
/// env value or an env name, with a description of where it is.
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
    let env = |env: &BTreeMap<String, Text>, f: &mut dyn FnMut(&str, &dyn Fn() -> String)| {
        for (k, v) in env {
            f(k, &|| format!("env name `{k}`"));
            text(v, &|| format!("env `{k}`"), f);
        }
    };
    match unit {
        Unit::Compile(c) => {
            for (i, p) in c.program.iter().enumerate() {
                text(p, &|| format!("program[{i}]"), f);
            }
            for (i, a) in c.args.iter().enumerate() {
                match a {
                    Arg::Literal(s) => f(s, &|| format!("args[{i}]")),
                    Arg::Concat(p) => text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f),
                    Arg::Splice(_) | Arg::SearchPaths(_) => {}
                }
            }
            env(&c.env, f);
            if let Cwd::Literal(s) = &c.cwd {
                f(s, &|| "cwd".into());
            }
        }
        Unit::Run(r) => {
            env(&r.env, f);
            if let Cwd::Literal(s) = &r.cwd {
                f(s, &|| "cwd".into());
            }
        }
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
    let env = |env: &BTreeMap<String, Text>, f: &mut dyn FnMut(&Reference, &dyn Fn() -> String)| {
        for (k, v) in env {
            text(v, &|| format!("env `{k}`"), f);
        }
    };
    match unit {
        Unit::Compile(c) => {
            for (i, p) in c.program.iter().enumerate() {
                text(p, &|| format!("program[{i}]"), f);
            }
            for (i, a) in c.args.iter().enumerate() {
                if let Arg::Concat(p) = a {
                    text(&Text::Concat(p.clone()), &|| format!("args[{i}]"), f);
                }
            }
            env(&c.env, f);
            if let Cwd::Ref(r) = &c.cwd {
                f(r, &|| "cwd".into());
            }
        }
        Unit::Run(r) => {
            env(&r.env, f);
            f(&r.script, &|| "script".into());
            if let Cwd::Ref(c) = &r.cwd {
                f(c, &|| "cwd".into());
            }
        }
    }
}
