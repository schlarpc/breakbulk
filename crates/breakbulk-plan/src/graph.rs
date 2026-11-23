//! From records to `plan.json`: unit identity, edges, sentinel conversion,
//! path rewriting, env filtering and roots ("Unit identity and graph
//! edges", "Path rewriting" and "Env filtering" in
//! `docs/src/explanation/internals/planner.md`).

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{
    Arg, CargoTarget, CrateInfo, Cwd, DepKind, LinkArgKind, OutRef, PLAN_VERSION, PackageFacts,
    PathDependency, PathTarget, Piece, Plan, PlanKind, PlanTarget, Platform, Reference, Remap,
    Root, RootKind, RunnerSlot, SearchIn, SearchPathsSplice, Splice, SpliceKind, Text, Unit,
    UnitBody, UnitId, UnitKind, Variant, VariantMode, contains_sentinel,
};

use crate::describe;
use crate::records::{Metadata, Package, Record, Target};
use crate::rewrite::Rewriter;
use crate::sentinel::{ArgSentinel, dep_sentinel, dylib_sentinel, env_sentinel, parse_pair};
use crate::{Error, bail};

/// Facts about the trace that do not come from the records.
#[derive(Clone, Debug)]
pub struct Context {
    /// The directory given to Cargo as its target and build directory.
    pub scratch: String,
    /// The skeleton root (the repository root's planning copy).
    pub skeleton: String,
    pub host: String,
    pub target: crate::trace::Target,
    pub kind: PlanKind,
    pub variant: Variant,
    /// `cargo -V`, without the leading `cargo `.
    pub cargo_version: String,
    /// `rustc -V`, without the leading `rustc `.
    pub rustc_version: String,
    /// The real rustdoc: build-script runs get it as `RUSTDOC`.
    pub rustdoc: String,
    /// The cargo the planner ran, as it was given (a toolchain path).
    pub cargo: String,
    /// Cargo's `nightly_features_allowed`.
    pub nightly: bool,
    /// The target's executable suffix (its spec's `exe-suffix`).
    pub executable_suffix: String,
    /// [`Plan::target_debuginfo`].
    pub target_debuginfo: breakbulk_format::TargetDebuginfo,
    /// The variant's workspace wrapper (`RUSTC_WORKSPACE_WRAPPER`, kept in
    /// units' env when set).
    pub workspace_wrapper: Option<String>,
    /// The variables the planner set on Cargo for the units the workspace
    /// wrapper runs on (`--wrapper-env`): kept only on those.
    pub wrapper_env: BTreeSet<String>,
    /// The variant's rustc wrapper: build-script runs get it as
    /// `RUSTC_WRAPPER`, where Cargo gives them its own (the shim).
    pub rustc_wrapper: Option<String>,
    /// The variables the project's `[env]` table sets on Cargo's
    /// processes ([`crate::spec::ProjectConfig::applied_env`]).
    pub config_env: BTreeSet<String>,
    /// [`breakbulk_format::plan::Plan::rust_src_remap`].
    pub rust_src_remap: Option<(String, String)>,
    /// The planner turned on Cargo's `trim-paths` itself (the project had
    /// not): Cargo's `--remap-path-scope` is dropped, and breakbulk sets the
    /// scope per product kind ([`Plan::trim_paths_default`]).
    pub trim_paths_default: bool,
    /// `-Zbuild-std`: the merged crates.io directory and the toolchain's
    /// `library` ([`crate::build_std::StdVendor`]).
    pub std_vendor: Option<(String, String)>,
}

/// What Cargo's `trim-paths` remaps its build directory to (cargo
/// `src/compiler/trim_paths.rs`, `build_dir_remap`).
pub const CARGO_BUILD_DIR_REMAP: &str = "/cargo/build-dir";

/// Whether a compile's arguments carry Cargo's `trim-paths` remaps: the
/// build-directory remap, which user rustflags never produce.
pub fn has_cargo_trim_paths(args: &[String]) -> bool {
    args.iter().any(|a| {
        a.strip_prefix("--remap-path-prefix=")
            .and_then(|r| r.strip_suffix(CARGO_BUILD_DIR_REMAP))
            .is_some_and(|r| r.ends_with('='))
    })
}

/// Whether any compile record of the trace carries Cargo's `trim-paths`.
pub fn trace_trims_paths(records: &[Record]) -> bool {
    records
        .iter()
        .any(|r| r.mode == "compile" && has_cargo_trim_paths(&r.args))
}

/// Whether `value` names `dir` or a path below it, as a whole path.
fn names_path(value: &str, dir: &str) -> bool {
    let dir = dir.trim_end_matches('/');
    let b = value.as_bytes();
    let mut from = 0;
    while let Some(off) = value[from..].find(dir) {
        let end = from + off + dir.len();
        if end == b.len() || matches!(b[end], b'/' | b':' | b' ' | b'=' | 0x1f) {
            return true;
        }
        from += off + 1;
        while !value.is_char_boundary(from) {
            from += 1;
        }
    }
    false
}

/// Variables never kept in a unit's env: the planner's own, and the ones the
/// design drops ("Env filtering").
const DROPPED_ENV: &[&str] = &[
    "RUSTC_WRAPPER",
    crate::trace::RUSTC_WRAPPER_ENV,
    "CARGO_MAKEFLAGS",
    "BREAKBULK_RECORD",
    "BREAKBULK_RUSTDOC",
    "BREAKBULK_METADATA",
];

/// Variables Cargo sets on every process it starts, kept even when equal to
/// Cargo's own environment (from 1.97 Cargo also sets `CARGO` on itself, so
/// subtracting the baseline would drop it).
const ALWAYS_KEPT_ENV: &[&str] = &["CARGO"];

/// The remap pairs Cargo gives build scripts under trim-paths (cargo
/// `src/compiler/custom_build.rs`), `:`-separated.
const TRIM_PATHS_REMAP_VAR: &str = "CARGO_TRIM_PATHS_REMAP";

/// The dynamic-library path variable on the planning host, where Cargo ran
/// every recorded process (one definition, `breakbulk-unit`'s).
const DYLIB_VAR: &str = breakbulk_format::HOST_DYLIB_PATH_VAR;

/// What `CARGO_TARGET_TMPDIR` (compile-time env of integration tests and
/// benches) becomes: a relative path, which resolves against the working
/// directory wherever the binary runs. Test runs and test apps give a
/// binary that contains it a private working directory with this path
/// writable ("Tests" in `docs/src/explanation/internals/products.md`).
/// Not an absolute path: the value is baked in with `env!`, and no one
/// absolute path is private and writable for every run, on every machine
/// and for every user the binary may run on.
pub const TARGET_TMPDIR: &str = "target/tmp";

/// Where `CARGO_BIN_EXE_<bin>` points for a bin Cargo did not build (its
/// required features are off): `<this>/<bin>`, which never exists, so a
/// test that runs it fails as it does under Cargo.
pub const NOT_BUILT_BIN_DIR: &str = "/breakbulk/not-built";

/// Where `OUT_DIR` points for a package whose build script a `links`
/// override in config replaces: `<this>/<pkg>-<hash>/out` (the part of
/// Cargo's path after `build/`), which never exists, as Cargo's does not.
pub const OVERRIDDEN_OUT_DIR: &str = "/breakbulk/overridden";

fn arg_value<'a>(args: &'a [String], flag: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == flag {
            if let Some(v) = args.get(i + 1) {
                out.push(v.as_str());
            }
            i += 2;
            continue;
        }
        if let Some(v) = a.strip_prefix(flag).and_then(|r| r.strip_prefix('=')) {
            out.push(v);
        }
        i += 1;
    }
    out
}

/// `-C <name>=<value>` (or `-C<name>=…`, `--codegen …`) values for `name`.
fn codegen_value<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        let v = match a {
            "-C" | "--codegen" => {
                i += 1;
                args.get(i).map(String::as_str)
            }
            _ => a
                .strip_prefix("-C")
                .or_else(|| a.strip_prefix("--codegen=")),
        };
        if let Some(v) = v
            .and_then(|v| v.strip_prefix(name))
            .and_then(|v| v.strip_prefix('='))
        {
            return Some(v);
        }
        i += 1;
    }
    None
}

/// The input file: the one positional argument.
/// A `cargo metadata` target as source views name it: a library by `lib`
/// whatever its crate types.
fn cargo_target(t: &Target) -> CargoTarget {
    let kind = ["bin", "example", "test", "bench", "custom-build"]
        .into_iter()
        .find(|k| t.has_kind(k))
        .unwrap_or("lib");
    CargoTarget {
        kind: kind.to_owned(),
        name: t.name.clone(),
    }
}

fn input_file(args: &[String]) -> Option<&str> {
    const TAKES_VALUE: &[&str] = &[
        "-o",
        "-L",
        "-l",
        "-C",
        "-Z",
        "-W",
        "-A",
        "-D",
        "-F",
        "--cfg",
        "--check-cfg",
        "--crate-type",
        "--crate-name",
        "--edition",
        "--emit",
        "--print",
        "--out-dir",
        "--target",
        "--cap-lints",
        "--extern",
        "--sysroot",
        "--error-format",
        "--json",
        "--color",
        "--remap-path-prefix",
        "--remap-path-scope",
        "--env-set",
        "--codegen",
        "--warn",
        "--allow",
        "--deny",
        "--forbid",
        "--force-warn",
        "--diagnostic-width",
    ];
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if !a.starts_with('-') {
            return Some(a);
        }
        i += if TAKES_VALUE.contains(&a) { 2 } else { 1 };
    }
    None
}

fn under<'a>(path: &'a str, dir: &str) -> Option<&'a str> {
    let rest = path.strip_prefix(dir.trim_end_matches('/'))?;
    if rest.is_empty() {
        Some("")
    } else {
        rest.strip_prefix('/')
    }
}

/// Whether two paths name the same file, after resolving symlinks.
fn same_file(a: &str, b: &str) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

fn parent(p: &str) -> &str {
    p.rsplit_once('/').map_or("", |(d, _)| d)
}

fn file_name(p: &str) -> &str {
    p.rsplit_once('/').map_or(p, |(_, f)| f)
}

/// The `-L` pairs of a traced `rustdoc --test` that hold Cargo's
/// `native_dirs`: the contiguous block of `-L <path>` pairs (not
/// `-L dependency=`) around the search sentinels, as (index of the first
/// pair's `-L`, index of the last pair's `-L`). `None` without sentinels:
/// then every `-L` is a literal Cargo already sorted.
fn doctest_native_block(args: &[String]) -> Option<(usize, usize)> {
    let is_l = |i: usize| {
        args.get(i).is_some_and(|a| a == "-L")
            && args
                .get(i + 1)
                .is_some_and(|n| !n.starts_with("dependency="))
    };
    let sentinel = |i: usize| {
        is_l(i)
            && matches!(
                parse_pair("-L", &args[i + 1]),
                Some(Ok(ArgSentinel::SearchIn(..) | ArgSentinel::SearchOther(_)))
            )
    };
    let first = (0..args.len()).find(|&i| sentinel(i))?;
    let last = (0..args.len()).rev().find(|&i| sentinel(i))?;
    let mut from = first;
    while from >= 2 && is_l(from - 2) {
        from -= 2;
    }
    let mut to = last;
    while is_l(to + 2) {
        to += 2;
    }
    Some((from, to))
}

/// The `--crate-name` of recorded arguments, or empty.
fn crate_name(args: &[String]) -> String {
    arg_value(args, "--crate-name")
        .first()
        .map(|s| s.to_string())
        .unwrap_or_default()
}

/// A traced `rustdoc` without its output directory: Cargo passes `-o DIR`,
/// and `breakbulk-unit` gives every command of the docs derivation its own
/// output.
fn without_output_dir(args: &[String]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-o" {
            i += 2;
            continue;
        }
        out.push(args[i].clone());
        i += 1;
    }
    out
}

struct CompileRec<'a> {
    id: UnitId,
    rec: &'a Record,
    platform: Platform,
    package: &'a Package,
    outputs: BTreeMap<String, BTreeSet<String>>,
    /// [`CompileUnit::uplifted`]: a stored file name to rustc's.
    uplifted: BTreeMap<String, String>,
    /// Whether Cargo uplifts the compile's executable ([`Builder::uplift`]).
    uplifts: bool,
    types: Vec<String>,
    test: bool,
}

impl CompileRec<'_> {
    /// The name the unit stores a file rustc writes under.
    fn stored<'s>(&'s self, rustc: &'s str) -> &'s str {
        self.uplifted
            .iter()
            .find(|(_, r)| *r == rustc)
            .map_or(rustc, |(s, _)| s)
    }
}

struct RunRec<'a> {
    id: UnitId,
    rec: &'a Record,
    platform: Platform,
    package: &'a Package,
    out_dir: String,
}

/// [`describe::compile`] of a compile record: the same text as
/// [`describe::unit`] of the unit it becomes.
fn describe_compile(c: &CompileRec<'_>) -> String {
    describe::compile(
        &c.id,
        &c.package.name,
        &c.package.version,
        arg_value(&c.rec.args, "--crate-name")
            .first()
            .copied()
            .unwrap_or_default(),
        &c.types,
        c.test,
        c.platform,
    )
}

fn describe_run(r: &RunRec<'_>) -> String {
    describe::run(&r.id, &r.package.name, &r.package.version, r.platform)
}

/// Builds the plan from one or more traced invocations' records.
pub struct Builder<'a> {
    ctx: &'a Context,
    metadata: &'a Metadata,
    baseline: BTreeMap<String, String>,
    compiles: Vec<CompileRec<'a>>,
    runs: Vec<RunRec<'a>>,
    run_by_tag: BTreeMap<String, usize>,
    /// `rustdoc` records (the doctests of `cargo test`).
    rustdocs: Vec<&'a Record>,
    rw: Rewriter,
}

impl<'a> Builder<'a> {
    pub fn new(
        ctx: &'a Context,
        metadata: &'a Metadata,
        records: &'a [Record],
    ) -> Result<Builder<'a>, Error> {
        let baseline = records
            .iter()
            .find(|r| r.mode == "query" && r.args == ["-vV"])
            .map(|r| r.env.clone())
            .ok_or_else(|| {
                Error("the trace has no `rustc -vV` query record to take Cargo's env from".into())
            })?;
        let mut b = Builder {
            ctx,
            metadata,
            baseline,
            compiles: Vec::new(),
            runs: Vec::new(),
            run_by_tag: BTreeMap::new(),
            rustdocs: Vec::new(),
            rw: Rewriter::new(&ctx.scratch, &ctx.skeleton, &ctx.target, metadata),
        };
        let mut seen = BTreeSet::new();
        for rec in records {
            match rec.mode.as_str() {
                "compile" => {
                    let c = b.compile_rec(rec)?;
                    if !seen.insert(c.id.clone()) {
                        let other = b.compiles.iter().find(|o| o.id == c.id);
                        bail!(
                            "{} and {} have the same `-C metadata`; unit keys must be unique \
                             within a plan",
                            other.map_or_else(|| c.id.clone(), describe_compile),
                            describe_compile(&c)
                        );
                    }
                    b.compiles.push(c);
                }
                "run" => {
                    let r = b.run_rec(rec)?;
                    if !seen.insert(r.id.clone()) {
                        bail!("{} was traced twice", describe_run(&r));
                    }
                    let tag = rec.tag.clone().expect("checked in run_rec");
                    if let Some(&other) = b.run_by_tag.get(&tag) {
                        bail!(
                            "{} and {} have the same tag `{tag}`; a sentinel names its run by \
                             the tag alone",
                            describe_run(&b.runs[other]),
                            describe_run(&r)
                        );
                    }
                    b.run_by_tag.insert(tag, b.runs.len());
                    b.runs.push(r);
                }
                "rustdoc" => b.rustdocs.push(rec),
                "query" => {}
                m => bail!("{}: unknown record mode `{m}`", rec.file),
            }
        }
        // Register outputs and run directories for path rewriting.
        for c in &b.compiles {
            for o in &c.rec.outputs {
                if let Some(name) = output_name(&o.emit, &o.path, &c.types) {
                    b.rw.outputs.insert(
                        o.path.clone(),
                        OutRef {
                            out: c.id.clone(),
                            output: name.into(),
                            file: Some(c.stored(file_name(&o.path)).into()),
                        },
                    );
                }
            }
        }
        for r in &b.runs {
            let rel = b
                .out_dir_rel(r)
                .map_err(|e| Error(format!("{}: {}", describe_run(r), e.0)))?;
            b.rw.run_dirs.insert(r.out_dir.clone(), (r.id.clone(), rel));
        }
        if let Some((dir, library)) = &ctx.std_vendor {
            b.rw.add_std_vendor(dir, library)?;
        }
        b.register_uplifted_bins();
        Ok(b)
    }

    /// A compile for a target other than the planned one and the host
    /// would be planned as a host unit (`platform_of`) with the wrong
    /// traits, linker and spec. Cargo does that for a package with nightly
    /// `package.forced-target` (`per-package-target`), which overrides
    /// `--target` (#39). A `.json` target counts by its short name: Cargo
    /// passes rustc the canonical path, not the planner's argument.
    fn check_target(&self, rec: &Record) -> Result<(), Error> {
        let Some(t) = arg_value(&rec.args, "--target").first().copied() else {
            return Ok(());
        };
        let short = crate::trace::Target::new(t, std::path::Path::new(&rec.cwd)).short_name;
        if t == self.ctx.host || short == self.ctx.target.short_name {
            return Ok(());
        }
        let package = rec
            .env
            .get("CARGO_PKG_NAME")
            .map(String::as_str)
            .unwrap_or("?");
        bail!(
            "package `{package}` builds for `{t}`, not for the planned target `{}`: \
             breakbulk plans one target at a time and does not support \
             `package.forced-target` (cargo-features = [\"per-package-target\"]); \
             remove it, or leave the package out of this target's plans \
             (`workspaces.<ws>.variants.<v>.packages`, for every variant in \
             `workspaces.<ws>.targets.<triple>.variantDefaults`)",
            self.ctx.target.arg
        )
    }

    fn platform_of(&self, path: &str) -> Platform {
        self.rw.platform_of(path)
    }

    fn package_of(&self, rec: &Record) -> Result<&'a Package, Error> {
        let dir = rec.env.get("CARGO_MANIFEST_DIR").ok_or_else(|| {
            Error(format!(
                "{}: the record has no CARGO_MANIFEST_DIR",
                rec.file
            ))
        })?;
        self.metadata.package_at(dir)
    }

    fn compile_rec(&self, rec: &'a Record) -> Result<CompileRec<'a>, Error> {
        self.check_target(rec)?;
        let Some(hash) = codegen_value(&rec.args, "metadata") else {
            bail!(
                "{}: the compile of `{}` has no `-C metadata`",
                rec.file,
                arg_value(&rec.args, "--crate-name").join(",")
            );
        };
        let out_dir = arg_value(&rec.args, "--out-dir")
            .first()
            .map(|s| s.to_string())
            .or_else(|| rec.outputs.first().map(|o| parent(&o.path).to_owned()))
            .unwrap_or_default();
        let mut types: Vec<String> = arg_value(&rec.args, "--crate-type")
            .into_iter()
            .map(str::to_owned)
            .collect();
        if types.is_empty() {
            types.push("bin".into());
        }
        let mut c = CompileRec {
            id: format!("c-{hash}"),
            rec,
            platform: self.platform_of(&out_dir),
            package: self.package_of(rec)?,
            outputs: BTreeMap::new(),
            uplifted: BTreeMap::new(),
            uplifts: false,
            test: rec.args.iter().any(|a| a == "--test"),
            types,
        };
        if let Some((rustc, stored)) = self.uplift(&c)? {
            c.uplifts = true;
            if rustc != stored {
                c.uplifted.insert(stored, rustc);
            }
        }
        for o in &rec.outputs {
            if let Some(name) = output_name(&o.emit, &o.path, &c.types) {
                let file = c.stored(file_name(&o.path)).to_owned();
                c.outputs.entry(name.into()).or_default().insert(file);
            }
        }
        Ok(c)
    }

    /// A compile whose executable Cargo uplifts (cargo
    /// `CompilationFiles::uplift_to`): a bin, or an example, built as
    /// itself rather than as a test, for the target. Returns rustc's file
    /// name, `<crate name><-C extra-filename><suffix>`, and the uplifted
    /// one, `<target name><suffix>`, which the unit stores it under. The
    /// suffix is the target spec's `exe-suffix`, which Cargo takes from
    /// rustc too (`--print file-names`).
    fn uplift(&self, c: &CompileRec<'a>) -> Result<Option<(String, String)>, Error> {
        if c.test || c.platform != Platform::Target || c.types != ["bin"] {
            return Ok(None);
        }
        let Some(t) = self.target_of(c) else {
            return Ok(None);
        };
        if !t.has_kind("bin") && !t.has_kind("example") {
            return Ok(None);
        }
        let Some(o) = c.rec.outputs.iter().find(|o| o.emit == "link") else {
            return Ok(None);
        };
        let rustc = file_name(&o.path);
        let crate_name = arg_value(&c.rec.args, "--crate-name")
            .first()
            .copied()
            .unwrap_or_default();
        let extra = codegen_value(&c.rec.args, "extra-filename").unwrap_or_default();
        let suffix = &self.ctx.executable_suffix;
        let expected = format!("{crate_name}{extra}{suffix}");
        if rustc != expected {
            bail!(
                "{}: rustc names `{}`'s executable `{rustc}`, not `{expected}` with the \
                 executable suffix `{suffix}` of {}'s target spec",
                describe_compile(c),
                t.name,
                self.ctx.target.arg
            );
        }
        Ok(Some((rustc.to_owned(), format!("{}{suffix}", t.name))))
    }

    fn run_rec(&self, rec: &'a Record) -> Result<RunRec<'a>, Error> {
        let Some(tag) = &rec.tag else {
            bail!("{}: run record without a tag", rec.file);
        };
        if !breakbulk_sentinel::is_tag(tag) {
            bail!(
                "{}: run record with tag `{tag}`, not lowercase hex",
                rec.file
            );
        }
        let Some(out_dir) = rec.env.get("OUT_DIR") else {
            bail!("{}: run record without OUT_DIR", rec.file);
        };
        let package = self.package_of(rec)?;
        Ok(RunRec {
            id: format!("r-{}-{tag}", package.name),
            rec,
            platform: self.platform_of(out_dir),
            package,
            out_dir: out_dir.trim_end_matches('/').to_owned(),
        })
    }

    /// Bins are also linked ("uplifted") to `<profile dir>/<target
    /// name><suffix>`, which is what `CARGO_BIN_EXE_<name>` names, and the
    /// unit stores the file under that name ([`Builder::uplift`]). Map
    /// such a path to the bin's output: the one bin compile of that name,
    /// or the one of the referring unit's package (see
    /// [`crate::rewrite::Rewriter::uplifted_bins`]).
    fn register_uplifted_bins(&mut self) {
        let mut by_name: BTreeMap<(Platform, String), Vec<(String, OutRef)>> = BTreeMap::new();
        for c in &self.compiles {
            if !c.uplifts || !self.target_of(c).is_some_and(|t| t.has_kind("bin")) {
                continue;
            }
            for o in &c.rec.outputs {
                if let Some(r) = self.rw.outputs.get(&o.path)
                    && r.output == "bin"
                    && let Some(file) = &r.file
                {
                    by_name
                        .entry((c.platform, file.clone()))
                        .or_default()
                        .push((c.package.id.clone(), r.clone()));
                }
            }
        }
        self.rw.uplifted_bins = by_name;
    }

    /// Whether `cargo metadata` lists a bin `bin` for the package `owner`
    /// and no compile links it (its required features are off, or the plan
    /// only checks).
    fn bin_not_linked(&self, owner: &str, bin: &str) -> bool {
        let listed =
            self.metadata.packages.iter().any(|p| {
                p.id == owner && p.targets.iter().any(|t| t.name == bin && t.has_kind("bin"))
            });
        listed
            && !self.compiles.iter().any(|c| {
                c.uplifts
                    && c.package.id == owner
                    && self
                        .target_of(c)
                        .is_some_and(|t| t.name == bin && t.has_kind("bin"))
            })
    }

    /// Whether a compile is a test unit ([`CompileUnit::test`]): one Cargo
    /// builds with dev-dependencies (`unit_dependencies.rs`: the target is
    /// a test or an example, or the mode is a test mode, as it is for every
    /// bench a plan builds). Not `--test` alone: a test mode passes it only
    /// to a target with the libtest harness, so an unharnessed test or
    /// bench compiles as a plain bin.
    fn is_test_unit(&self, c: &CompileRec<'a>) -> bool {
        c.test
            || self
                .target_of(c)
                .is_some_and(|t| t.has_kind("test") || t.has_kind("bench") || t.has_kind("example"))
    }

    /// The `cargo metadata` target a compile builds: matched by source path
    /// and crate name.
    fn target_of(&self, c: &CompileRec<'a>) -> Option<&'a Target> {
        let input = input_file(&c.rec.args)?;
        let abs = if input.starts_with('/') {
            input.to_owned()
        } else {
            format!("{}/{input}", c.rec.cwd.trim_end_matches('/'))
        };
        let crate_name = arg_value(&c.rec.args, "--crate-name").first().copied()?;
        let canon = |p: &str| std::fs::canonicalize(p).ok();
        c.package.targets.iter().find(|t| {
            t.name.replace('-', "_") == crate_name
                && (t.src_path == abs || canon(&t.src_path).is_some_and(|x| Some(x) == canon(&abs)))
        })
    }

    /// The run whose sentinels carry `tag`, found in `place` (an env
    /// variable) or, with `None`, in the unit's arguments or env.
    fn run_id(&self, tag: &str, place: Option<&str>) -> Result<&RunRec<'a>, Error> {
        self.run_by_tag
            .get(tag)
            .map(|&i| &self.runs[i])
            .ok_or_else(|| {
                Error(format!(
                    "a sentinel{} names run `{tag}`, but no build script with that tag ran",
                    place.map(|p| format!(" in {p}")).unwrap_or_default()
                ))
            })
    }

    fn shape_error(&self, kind: &str, seen: &str, args: &[String]) -> Error {
        Error(format!(
            "a {kind} sentinel is in a shape the sentinel table does not allow (Cargo {}): \
             {seen}{}",
            self.ctx.cargo_version,
            if args.is_empty() {
                String::new()
            } else {
                format!("\n  arguments: {}", args.join(" "))
            }
        ))
    }

    /// Filter a recorded env ("Env filtering"), before rewriting.
    fn filter_env(&self, env: &BTreeMap<String, String>, run: bool) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        for (k, v) in env {
            if run
                && k == "RUSTC_WRAPPER"
                && let Some(w) = &self.ctx.rustc_wrapper
            {
                out.insert(k.clone(), w.clone());
                continue;
            }
            if DROPPED_ENV.contains(&k.as_str()) {
                continue;
            }
            if k == "RUSTC_WORKSPACE_WRAPPER" && self.ctx.workspace_wrapper.is_none() {
                continue;
            }
            if run && k == "RUSTC_BOOTSTRAP" {
                continue;
            }
            // Cargo applies `[env]` to its `rustc -vV` query too
            // (`apply_env_config` in `Rustc::new`), so the baseline has
            // those variables; they are still per-process env.
            if self.baseline.get(k) == Some(v)
                && !ALWAYS_KEPT_ENV.contains(&k.as_str())
                && !self.ctx.config_env.contains(k)
            {
                continue;
            }
            let v = if run && k == "RUSTDOC" {
                self.ctx.rustdoc.clone()
            } else if k == "NUM_JOBS" {
                // breakbulk-unit replaces it with $NIX_BUILD_CORES; the
                // planning machine's job count must not reach the plan.
                "1".to_owned()
            } else {
                v.clone()
            };
            out.insert(k.clone(), v);
        }
        out
    }

    /// Split a dynamic-library path value: sentinel entries name runs; entries
    /// in the scratch directory (Cargo's `deps` and profile directories,
    /// which have no counterpart in breakbulk) are dropped; the rest is kept.
    fn dylib_path(&self, value: &str) -> Result<(Vec<UnitId>, Option<String>), Error> {
        let mut runs = Vec::new();
        let mut kept = Vec::new();
        let mut entries: Vec<&str> = value.split(':').filter(|e| !e.is_empty()).collect();
        // Cargo appends its own process's value to the paths it adds, or
        // uses that value alone when it already starts with them (cargo
        // 0.97.0, `core/compiler/compilation.rs`, `fill_env`:
        // `search_path.extend(paths::dylib_path())`); a compile with host
        // plugin dependencies then gets their runs' paths appended after it
        // (`core/compiler/mod.rs`, `add_plugin_deps`). That inherited value
        // is the planner's environment, not the unit's (rust-overlay's cargo
        // wrapper puts libsecret there), so it never reaches a unit: drop
        // the last occurrence of it that only run paths follow.
        let inherited: Vec<&str> = self
            .baseline
            .get(DYLIB_VAR)
            .map(|v| v.split(':').filter(|e| !e.is_empty()).collect())
            .unwrap_or_default();
        if !inherited.is_empty() && entries.len() >= inherited.len() {
            let found = (0..=entries.len() - inherited.len()).rev().find(|&i| {
                entries[i..i + inherited.len()] == inherited[..]
                    && entries[i + inherited.len()..]
                        .iter()
                        .all(|e| dylib_sentinel(e).is_some())
            });
            if let Some(i) = found {
                entries.drain(i..i + inherited.len());
            }
        }
        for e in entries {
            if let Some((tag, dir)) = dylib_sentinel(e) {
                let r = self.run_id(&tag, Some(DYLIB_VAR))?;
                if dir != r.out_dir {
                    return Err(self.shape_error("dynamic-library path", e, &[]));
                }
                if !runs.contains(&r.id) {
                    runs.push(r.id.clone());
                }
            } else if contains_sentinel(e) {
                return Err(self.shape_error("dynamic-library path", e, &[]));
            } else if !self.rw.in_scratch(e) {
                kept.push(e);
            }
        }
        Ok((runs, (!kept.is_empty()).then(|| kept.join(":"))))
    }

    fn rewrite_env(
        &self,
        owner: &str,
        env: BTreeMap<String, String>,
    ) -> Result<(BTreeMap<String, Text>, Vec<UnitId>), Error> {
        let mut out = BTreeMap::new();
        let mut dylib = Vec::new();
        for (k, v) in env {
            if k == "CARGO_TARGET_TMPDIR" {
                out.insert(k, Text::Literal(TARGET_TMPDIR.into()));
                continue;
            }
            // Cargo sets CARGO_BIN_EXE_<bin> on integration tests for every
            // bin of the package, also bins it does not build because their
            // required features are off (Cargo 0.100.0 at 5f94df4,
            // `src/compiler/artifact.rs`, `get_env`: it filters targets on
            // `is_bin()` only). Such a path names no unit's output; it
            // becomes a path that does not exist, as Cargo's does not.
            // Only for a bin of the package that no compile links: any
            // other path that does not rewrite is the planner's error.
            if let Some(bin) = k.strip_prefix("CARGO_BIN_EXE_")
                && self.rw.in_scratch(&v)
                && self.bin_not_linked(owner, bin)
                && self.rw.text(&v, Some(owner)).is_err()
            {
                out.insert(
                    k.clone(),
                    Text::Literal(format!("{NOT_BUILT_BIN_DIR}/{bin}")),
                );
                continue;
            }
            // A `links` override in config replaces the package's build
            // script: Cargo never runs it and never creates its OUT_DIR
            // (`custom_build::prepare` skips `build_work`, which creates
            // it), but still sets OUT_DIR on the package's compiles
            // (`build_base_args`'s first run dependency). Cargo 0.100.0 at
            // 5f94df4, `src/compiler/custom_build.rs` and
            // `src/compiler/mod.rs`. There is no run unit to point at; the
            // value becomes a path that does not exist, as Cargo's does not.
            if k == "OUT_DIR"
                && self
                    .metadata
                    .packages
                    .iter()
                    .any(|p| p.id == owner && p.links.is_some())
                && self.rw.in_scratch(&v)
                && self.rw.text(&v, Some(owner)).is_err()
            {
                let (parts, at) = self.build_dir_parts(&v)?;
                let tail = parts[at + 2..].join("/");
                out.insert(k, Text::Literal(format!("{OVERRIDDEN_OUT_DIR}/{tail}")));
                continue;
            }
            // Cargo sets CARGO to its own executable as the OS reports it,
            // with symlinks resolved (`std::env::current_exe`). In a
            // toolchain that is a symlink tree (rust-overlay's), that is a
            // store path of a component, not the toolchain path the
            // planner was given and instantiation knows. Same file: keep
            // the given path.
            let v = if k == "CARGO" && same_file(&v, &self.ctx.cargo) {
                self.ctx.cargo.clone()
            } else {
                v
            };
            let v = if k == DYLIB_VAR {
                let (runs, rest) = self.dylib_path(&v)?;
                dylib = runs;
                match rest {
                    Some(r) => r,
                    None => continue,
                }
            } else {
                v
            };
            let t = self
                .rw
                .text(&v, Some(owner))
                .map_err(|e| Error(format!("env `{k}`: {}", e.0)))?;
            out.insert(k, t);
        }
        Ok((out, dylib))
    }

    /// Convert recorded arguments: drop what breakbulk replaces, turn
    /// sentinels into splices (checking their shapes), rewrite paths.
    /// `platform` is the unit's: every splice must name a run of that
    /// platform. Doctests (`None`) get Cargo's search paths of every run in
    /// the invocation, which become one `searchPathsOf` splice.
    fn convert_args(
        &self,
        args: &[String],
        env: &BTreeMap<String, String>,
        owner: &str,
        platform: Option<Platform>,
    ) -> Result<Vec<Arg>, Error> {
        let mut out: Vec<Arg> = Vec::new();
        // Where Cargo's trim-paths build-directory remap was.
        let mut build_dir_remap_at: Option<usize> = None;
        let mut search_paths: Option<(usize, Vec<UnitId>, Vec<String>)> = None;
        // In a doctest, Cargo passes one `-L` per entry of `native_dirs`, a
        // sorted set of every run's search paths and every `links`
        // override's: the block of `-L` pairs around the sentinels. Its
        // literals (the overrides') join the searchPathsOf splice, to be
        // sorted with the runs' values at build time.
        let native_block = if platform.is_none() {
            doctest_native_block(args)
        } else {
            None
        };
        // Link-arg splices: the run, and the index in `out` of its splice.
        let mut link_arg_at: BTreeMap<String, usize> = BTreeMap::new();
        let mut last_was_link_arg_of: Option<String> = None;
        let mut i = 0;
        while i < args.len() {
            let a = args[i].as_str();
            let next = args.get(i + 1).map(String::as_str);
            // Arguments that name Cargo's shared directories:
            // breakbulk-unit adds its own.
            match (a, next) {
                ("--out-dir", _) => {
                    i += 2;
                    continue;
                }
                ("-C", Some(n)) if n.starts_with("incremental=") => {
                    i += 2;
                    continue;
                }
                ("-L", Some(n)) if n.starts_with("dependency=") => {
                    i += 2;
                    continue;
                }
                _ if a.starts_with("--out-dir=")
                    || a.starts_with("-Cincremental=")
                    || a.starts_with("-Ldependency=") =>
                {
                    i += 1;
                    continue;
                }
                // A doctest's runner: the trace's, which Cargo passes as
                // `--test-runtool R` and `--test-runtool-arg A` pairs, is
                // the planner's; the doctest's builder puts the configured
                // one in its place.
                ("--test-runtool" | "--test-runtool-arg", Some(_)) if platform.is_none() => {
                    if !out.iter().any(|a| matches!(a, Arg::Runner(_))) {
                        out.push(Arg::Runner(RunnerSlot::TEST));
                    }
                    i += 2;
                    continue;
                }
                _ => {}
            }
            // Cargo's trim-paths remaps its one build directory; breakbulk
            // has one store path per OUT_DIR instead ("Path rewriting").
            if let Some(from) = a
                .strip_prefix("--remap-path-prefix=")
                .and_then(|r| r.strip_suffix(CARGO_BUILD_DIR_REMAP))
                .and_then(|r| r.strip_suffix('='))
            {
                if from.trim_end_matches('/') != self.ctx.scratch.trim_end_matches('/') {
                    bail!(
                        "Cargo's trim-paths remaps `{from}`, not the planner's build directory {}",
                        self.ctx.scratch
                    );
                }
                build_dir_remap_at = Some(out.len());
                last_was_link_arg_of = None;
                i += 1;
                continue;
            }
            // When breakbulk turned trim-paths on, it sets the scope per
            // product kind at instantiation.
            if self.ctx.trim_paths_default && a.starts_with("--remap-path-scope=") {
                last_was_link_arg_of = None;
                i += 1;
                continue;
            }
            if let Some(n) = next
                && matches!(a, "--cfg" | "--check-cfg" | "-l" | "-L" | "-C")
                && let Some(s) = parse_pair(a, n)
            {
                let s = s.map_err(|seen| self.shape_error(a, &seen, args))?;
                let r = self.run_id(s.tag(), None)?;
                if let Some(p) = platform
                    && r.platform != p
                {
                    return Err(self.shape_error(
                        a,
                        &format!(
                            "`{a} {n}` from {} on a {} unit",
                            describe_run(r),
                            describe::platform_name(p)
                        ),
                        args,
                    ));
                }
                let run = r.id.clone();
                let is_link_arg = matches!(s, ArgSentinel::LinkArg(..));
                if platform.is_none()
                    && matches!(s, ArgSentinel::SearchIn(..) | ArgSentinel::SearchOther(_))
                {
                    let (_, runs, _) = search_paths.get_or_insert_with(|| {
                        out.push(Arg::SearchPaths(SearchPathsSplice {
                            search_paths_of: Vec::new(),
                            literals: Vec::new(),
                        }));
                        (out.len() - 1, Vec::new(), Vec::new())
                    });
                    runs.push(run);
                    last_was_link_arg_of = None;
                    i += 2;
                    continue;
                }
                match s {
                    ArgSentinel::Cfg(_) => {
                        out.push(Arg::Splice(Splice::new(run.clone(), SpliceKind::RustcCfg)))
                    }
                    ArgSentinel::CheckCfg(_) => out.push(Arg::Splice(Splice::new(
                        run.clone(),
                        SpliceKind::RustcCheckCfg,
                    ))),
                    ArgSentinel::Lib(_) => out.push(Arg::Splice(Splice::new(
                        run.clone(),
                        SpliceKind::RustcLinkLib,
                    ))),
                    ArgSentinel::SearchIn(_, dir) => {
                        if dir != r.out_dir {
                            return Err(self.shape_error(
                                "rustc-link-search",
                                &format!("`-L {n}` is not inside the run's OUT_DIR {}", r.out_dir),
                                args,
                            ));
                        }
                        out.push(Arg::Splice(Splice::search(run.clone(), SearchIn::Out)))
                    }
                    ArgSentinel::SearchOther(_) => {
                        out.push(Arg::Splice(Splice::search(run.clone(), SearchIn::Other)))
                    }
                    ArgSentinel::LinkArg(_, kind) => {
                        if last_was_link_arg_of.as_deref() == Some(run.as_str()) {
                            let at = link_arg_at[&run];
                            let Arg::Splice(sp) = &mut out[at] else {
                                unreachable!()
                            };
                            let mut kinds: Vec<LinkArgKind> = sp.kinds.take().unwrap_or_default();
                            kinds.push(kind);
                            *sp = Splice::link_args(run.clone(), kinds);
                        } else if link_arg_at.contains_key(&run) {
                            return Err(self.shape_error(
                                "rustc-link-arg",
                                &format!(
                                    "the link-arg sentinels of {} are not adjacent",
                                    describe_run(r)
                                ),
                                args,
                            ));
                        } else {
                            link_arg_at.insert(run.clone(), out.len());
                            out.push(Arg::Splice(Splice::link_args(run.clone(), [kind])));
                        }
                    }
                }
                last_was_link_arg_of = is_link_arg.then_some(run);
                i += 2;
                continue;
            }
            last_was_link_arg_of = None;
            if let (Some((from, to)), Some(n)) = (native_block, next)
                && a == "-L"
                && (from..=to).contains(&i)
            {
                let t = self
                    .rw
                    .text(n, Some(owner))
                    .map_err(|e| Error(format!("argument `-L {n}`: {}", e.0)))?;
                let Text::Literal(l) = t else {
                    bail!(
                        "`-L {n}` from a `links` override names a path breakbulk rewrites; \
                         doctests do not support that yet"
                    );
                };
                let (_, _, lits) = search_paths.get_or_insert_with(|| {
                    out.push(Arg::SearchPaths(SearchPathsSplice {
                        search_paths_of: Vec::new(),
                        literals: Vec::new(),
                    }));
                    (out.len() - 1, Vec::new(), Vec::new())
                });
                lits.push(l);
                i += 2;
                continue;
            }
            if contains_sentinel(a) {
                return Err(self.shape_error("unknown", &format!("`{a}`"), args));
            }
            let t = self
                .rw
                .text(a, Some(owner))
                .map_err(|e| Error(format!("argument `{a}`: {}", e.0)))?;
            out.push(t.into());
            i += 1;
        }
        if let Some(at) = build_dir_remap_at {
            let remaps = self.build_dir_remaps(&out, env);
            out.splice(at..at, remaps);
        }
        if let Some((at, mut runs, mut literals)) = search_paths {
            runs.sort();
            runs.dedup();
            literals.sort();
            literals.dedup();
            out[at] = Arg::SearchPaths(SearchPathsSplice {
                search_paths_of: runs,
                literals,
            });
        }
        Ok(out)
    }

    /// A run's `CARGO_TRIM_PATHS_REMAP` without the build-directory pair.
    /// The run's own `OUT_DIR` is its `out`, which its derivation cannot
    /// name; C code the script compiles there is still remapped, by
    /// breakbulk's own prefix map for it (`outDirRemap`).
    fn without_build_dir_remap(&self, value: &str) -> String {
        let pair = format!(
            "{}={CARGO_BUILD_DIR_REMAP}",
            self.ctx.scratch.trim_end_matches('/')
        );
        value
            .split(':')
            .filter(|p| *p != pair)
            .collect::<Vec<_>>()
            .join(":")
    }

    /// Cargo's trim-paths build-directory remap, expanded: one
    /// `--remap-path-prefix=<OUT_DIR>=/cargo/build-dir/<rel>` per run whose
    /// `OUT_DIR` the unit names (in its env, normally as `OUT_DIR`, or in a
    /// converted argument), so paths below it read as they do under Cargo.
    /// Sorted by run.
    fn build_dir_remaps(&self, args: &[Arg], env: &BTreeMap<String, String>) -> Vec<Arg> {
        let mut runs = BTreeSet::new();
        for a in args {
            let Arg::Concat(pieces) = a else { continue };
            for p in pieces {
                if let Piece::Ref(Reference::Out(o)) = p
                    && self.runs.iter().any(|r| r.id == o.out)
                {
                    runs.insert(o.out.clone());
                }
            }
        }
        runs.extend(self.runs_named_in_env(env));
        runs.into_iter()
            .filter_map(|run| {
                let to = self.build_dir_name(&run)?;
                Some(Arg::Concat(vec![
                    Piece::Literal("--remap-path-prefix=".into()),
                    Piece::Ref(Reference::Out(OutRef {
                        out: run,
                        output: "out".into(),
                        file: None,
                    })),
                    Piece::Literal(format!("={to}")),
                ]))
            })
            .collect()
    }

    /// The runs whose `OUT_DIR` a recorded env names. Values with
    /// sentinels (dynamic-library paths of host plugin dependencies) name
    /// search paths, not code.
    fn runs_named_in_env(&self, env: &BTreeMap<String, String>) -> BTreeSet<UnitId> {
        let mut runs = BTreeSet::new();
        for v in env.values().filter(|v| !contains_sentinel(v)) {
            for (dir, (run, _)) in &self.rw.run_dirs {
                if names_path(v, dir) {
                    runs.insert(run.clone());
                }
            }
        }
        runs
    }

    /// What Cargo's trim-paths build-directory remap makes of a run's
    /// `out`: `/cargo/build-dir`. The `out` holds the `OUT_DIR` at its path
    /// relative to Cargo's build directory (`RunUnit::out_dir`), so paths
    /// below it read as under Cargo.
    fn build_dir_name(&self, run: &UnitId) -> Option<String> {
        self.runs
            .iter()
            .any(|r| &r.id == run)
            .then(|| CARGO_BUILD_DIR_REMAP.to_owned())
    }

    /// A run's `OUT_DIR` relative to Cargo's target (and build) directory,
    /// as the traced Cargo laid it out (`<triple>/<profile>/build/<pkg>-<hash>/out`,
    /// or `…/build/<pkg>/<hash>/out` in the new layout), with one change:
    /// the profile directory is named after the run's `PROFILE` (`debug` or
    /// `release`, what the profile inherits from) rather than the profile, so
    /// a custom profile equal to `release` still shares its units with
    /// `release`. Cargo names that directory after the profile only for
    /// custom ones; for `dev`, `test`, `release` and `bench` the two agree.
    fn out_dir_rel(&self, r: &RunRec<'_>) -> Result<String, Error> {
        let (mut parts, at) = self.build_dir_parts(&r.out_dir)?;
        if let Some(profile) = r.rec.env.get("PROFILE") {
            parts[at] = profile;
        }
        Ok(parts.join("/"))
    }

    /// An `OUT_DIR` relative to Cargo's
    /// build directory, split into components, with the index of the
    /// profile directory: `[<target short name>/]<profile>/build/…`, the
    /// short name there exactly for target units ([`Self::platform_of`]).
    /// Not found by searching for `build`: in the new layout a package
    /// named `build` has `…/build/build/<hash>`.
    fn build_dir_parts<'p>(&self, path: &'p str) -> Result<(Vec<&'p str>, usize), Error> {
        let Some(rel) = under(path, &self.ctx.scratch).filter(|r| !r.is_empty()) else {
            bail!(
                "OUT_DIR {path} is not inside Cargo's target directory {}",
                self.ctx.scratch
            );
        };
        let parts: Vec<&str> = rel.split('/').collect();
        let at = match self.platform_of(path) {
            Platform::Target => 1,
            Platform::Host => 0,
        };
        if parts.get(at + 1) != Some(&"build") || parts.len() < at + 3 {
            bail!(
                "OUT_DIR {path} is not in a profile's `build` directory of Cargo's target \
                 directory {} (`[<target>/]<profile>/build/…`)",
                self.ctx.scratch
            );
        }
        Ok((parts, at))
    }

    /// A recorded working directory: one reference, or (the standard
    /// library's packages under -Zbuild-std) a toolchain store path.
    fn cwd(&self, dir: &str, owner: Option<&str>) -> Result<Cwd, Error> {
        match self.rw.text(dir, owner)? {
            Text::Literal(s) if !self.rw.in_scratch(&s) && s.starts_with('/') => {
                Ok(Cwd::Literal(s))
            }
            _ => Ok(Cwd::Ref(self.rw.reference(dir, owner)?)),
        }
    }

    /// Convert a recorded env: `rustc-env` sentinels become env splices,
    /// the rest is filtered and rewritten; dynamic-library path sentinels
    /// become dynamic-path splices.
    #[allow(clippy::type_complexity)]
    fn convert_env(
        &self,
        rec_env: &BTreeMap<String, String>,
        owner: &str,
        args: &[String],
    ) -> Result<(BTreeMap<String, Text>, Vec<Splice>, Vec<UnitId>), Error> {
        let mut env = BTreeMap::new();
        let mut env_splices = Vec::new();
        for (k, v) in rec_env {
            match env_sentinel(k, v) {
                Some(Ok(tag)) => {
                    let r = self.run_id(&tag, None)?;
                    env_splices.push(Splice::new(r.id.clone(), SpliceKind::RustcEnv));
                }
                Some(Err(seen)) => return Err(self.shape_error("rustc-env", &seen, args)),
                None => {
                    env.insert(k.clone(), v.clone());
                }
            }
        }
        env_splices.sort();
        let (env, dylib) = self.rewrite_env(owner, self.filter_env(&env, false))?;
        for (k, v) in &env {
            if contains_sentinel(k) {
                return Err(self.shape_error("env", &format!("`{k}={v:?}`"), args));
            }
        }
        Ok((env, env_splices, dylib))
    }

    fn compile_unit(&self, c: &CompileRec<'a>) -> Result<Unit, Error> {
        let args = &c.rec.args;
        let out = self.convert_args(args, &c.rec.env, &c.package.id, Some(c.platform))?;
        let (mut env, env_splices, dylib) = self.convert_env(&c.rec.env, &c.package.id, args)?;
        // The variant's wrapper env (clippy's `CLIPPY_ARGS`) reaches every
        // process Cargo starts, so the baseline drops it; it is kept only
        // where the workspace wrapper runs, so units without it stay
        // shared with a variant without the wrapper. By the chain's paths,
        // not its length: with a `rustcWrapper` every unit has a chain.
        if let Some(ww) = &self.ctx.workspace_wrapper
            && c.rec.program.iter().any(|p| p == ww)
        {
            for k in &self.ctx.wrapper_env {
                if let Some(v) = c.rec.env.get(k) {
                    env.insert(k.clone(), Text::Literal(v.clone()));
                }
            }
        }

        let program = c
            .rec
            .program
            .iter()
            .map(|p| self.rw.text(p, None))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error(format!("program: {}", e.0)))?;
        let cwd = self
            .cwd(&c.rec.cwd, Some(&c.package.id))
            .map_err(|e| Error(format!("cwd: {}", e.0)))?;
        let edition = arg_value(args, "--edition")
            .first()
            .map_or("2015".to_owned(), |e| e.to_string());
        let name = arg_value(args, "--crate-name")
            .first()
            .map(|s| s.to_string())
            .unwrap_or_default();
        Ok(Unit::new(
            UnitKind::Compile,
            UnitBody {
                krate: Some(CrateInfo {
                    name,
                    types: c.types.clone(),
                    edition,
                }),
                test: self.is_test_unit(c),
                cargo_target: self.target_of(c).map(cargo_target),
                program,
                args: out,
                env,
                env_splices,
                dylib_path_from: dylib,
                cwd,
                outputs: c.outputs.clone(),
                uplifted: c.uplifted.clone(),
                ..UnitBody::empty(c.package.id.clone(), c.platform)
            },
        ))
    }

    fn run_unit(&self, r: &RunRec<'a>) -> Result<Unit, Error> {
        let id = &r.id;
        let rec = r.rec;
        // The script: the stub's directory plus the compile output's name.
        let Some(program) = rec.program.first() else {
            bail!("the run record has no program ({})", rec.file);
        };
        let binary = rec
            .stub
            .as_ref()
            .and_then(|s| s.compile.binary.clone())
            .unwrap_or_else(|| file_name(program).to_owned());
        let script_path = format!("{}/{binary}", parent(program));
        let Some(script) = self.rw.outputs.get(&script_path) else {
            bail!("its build script {script_path} is no compile unit's output");
        };
        let mut env = BTreeMap::new();
        let mut metadata_from = BTreeSet::new();
        for (k, v) in &rec.env {
            if let Some((_links, tag)) = dep_sentinel(k, v) {
                let up = self.run_id(tag, Some(k))?;
                if up.package.links.is_none() {
                    bail!(
                        "{k} names {}, whose package declares no `links`",
                        describe_run(up)
                    );
                }
                metadata_from.insert(up.id.clone());
                continue;
            }
            if contains_sentinel(k) || contains_sentinel(v) && k != DYLIB_VAR {
                return Err(self.shape_error("env", &format!("`{k}={v}`"), &[]));
            }
            env.insert(k.clone(), v.clone());
        }
        // Under trim-paths, the C prefix maps' names for the OUT_DIRs this
        // run names, its own included: Cargo's one build-directory pair,
        // expanded as for compile units.
        let build_dir_remap = if env.get(TRIM_PATHS_REMAP_VAR).is_some_and(|v| !v.is_empty()) {
            let mut runs = self.runs_named_in_env(&env);
            runs.insert(id.clone());
            runs.into_iter()
                .filter_map(|run| Some((run.clone(), self.build_dir_name(&run)?)))
                .collect()
        } else {
            BTreeMap::new()
        };
        if let Some(v) = env.get_mut(TRIM_PATHS_REMAP_VAR) {
            *v = self.without_build_dir_remap(v);
        }
        let (env, dylib) = self.rewrite_env(&r.package.id, self.filter_env(&env, true))?;
        let cwd = self
            .cwd(&rec.cwd, Some(&r.package.id))
            .map_err(|e| Error(format!("cwd: {}", e.0)))?;
        Ok(Unit::new(
            UnitKind::Run,
            UnitBody {
                program: vec![Text::Concat(vec![Piece::Ref(Reference::Out(
                    script.clone(),
                ))])],
                env,
                cwd,
                metadata_from,
                dylib_path_from: dylib,
                build_dir_remap,
                out_dir: self.out_dir_rel(r)?,
                ..UnitBody::empty(r.package.id.clone(), r.platform)
            },
        ))
    }

    /// The plan's products ("Fields", `roots`): in a build plan, bins and
    /// linkable library crate types of selected packages; in a test plan,
    /// every test harness and every example; in a bench plan, every bench
    /// (with or without the libtest harness) and the lib and bin harnesses
    /// in bench mode. Check variants link nothing and have no roots, and
    /// neither have doc plans.
    fn roots(&self) -> BTreeSet<Root> {
        let mut roots = BTreeSet::new();
        if self.ctx.variant.mode == VariantMode::Check || self.ctx.kind == PlanKind::Doc {
            return roots;
        }
        for c in &self.compiles {
            if c.rec.env.get("CARGO_PRIMARY_PACKAGE").map(String::as_str) != Some("1") {
                continue;
            }
            let Some(t) = self.target_of(c) else { continue };
            if t.has_kind("custom-build") {
                continue;
            }
            // An integration test or bench without the libtest harness
            // (`harness = false`, e.g. Criterion) is compiled as a plain
            // bin, but it is a test or bench plan's test root all the same,
            // as root prediction has it.
            let unharnessed = match self.ctx.kind {
                PlanKind::Test => t.has_kind("test"),
                PlanKind::Bench => t.has_kind("bench"),
                PlanKind::Build | PlanKind::Doc => false,
            };
            let test = c.test || unharnessed;
            let root = |kind| Root {
                package: c.package.id.clone(),
                target: t.name.clone(),
                kind,
                unit: c.id.clone(),
                test,
            };
            let kinds: Vec<RootKind> = match self.ctx.kind {
                // A workspace member that is also a build dependency is
                // compiled for the host too, and Cargo marks that unit
                // primary as well (CARGO_PRIMARY_PACKAGE). Products are the
                // target's. (Test harnesses stay: a proc macro's is a host
                // unit, and the only one.)
                PlanKind::Build if !c.test && c.platform == Platform::Target => {
                    if t.has_kind("bin") {
                        vec![RootKind::Bin]
                    } else if t.is_lib() {
                        c.types
                            .iter()
                            .filter_map(|ty| match ty.as_str() {
                                "cdylib" => Some(RootKind::Cdylib),
                                "dylib" => Some(RootKind::Dylib),
                                "staticlib" => Some(RootKind::Staticlib),
                                _ => None,
                            })
                            .collect()
                    } else {
                        vec![]
                    }
                }
                PlanKind::Test if test => vec![if t.has_kind("bin") {
                    RootKind::Bin
                } else if t.has_kind("test") {
                    RootKind::Test
                } else if t.has_kind("bench") {
                    RootKind::Bench
                } else if t.has_kind("example") {
                    RootKind::Example
                } else {
                    RootKind::Lib
                }],
                PlanKind::Test if t.has_kind("example") => vec![RootKind::Example],
                PlanKind::Bench if t.has_kind("bench") => vec![RootKind::Bench],
                PlanKind::Bench if c.test => vec![if t.has_kind("bin") {
                    RootKind::Bin
                } else {
                    RootKind::Lib
                }],
                _ => vec![],
            };
            roots.extend(kinds.into_iter().map(root));
        }
        roots
    }

    /// [`Plan::packages`]: what `cargo metadata` says about every package
    /// with a unit in `units`, and for the path packages under the
    /// skeleton, their source paths and the dependency edges between them
    /// from `cargo metadata`'s resolve graph that one of the compile units
    /// uses. The planner's `cargo metadata` runs with `--all-features`, so
    /// its resolve also holds the optional dependencies the variant's
    /// features leave off.
    fn packages(
        &self,
        units: &BTreeMap<UnitId, Unit>,
    ) -> Result<BTreeMap<String, PackageFacts>, Error> {
        let skeleton = self.ctx.skeleton.trim_end_matches('/');
        let under = |p: &str| {
            p.strip_prefix(skeleton)
                .and_then(|r| r.strip_prefix('/'))
                .map(str::to_owned)
        };
        let local = |p: &Package| p.is_path() && (p.dir() == skeleton || under(p.dir()).is_some());
        let mut used: BTreeSet<(&str, &str)> = BTreeSet::new();
        for c in units.values().filter(|u| u.is_compile()) {
            for a in &c.args {
                let Arg::Concat(pieces) = a else { continue };
                for p in pieces {
                    if let Piece::Ref(Reference::Out(o)) = p
                        && o.output != "bin"
                        && let Some(d) = units.get(&o.out)
                        && d.is_compile()
                    {
                        used.insert((c.package.as_str(), d.package.as_str()));
                    }
                }
            }
        }
        let ids: BTreeSet<&str> = units.values().map(|u| u.package.as_str()).collect();
        let nodes = self
            .metadata
            .resolve
            .as_ref()
            .map(|r| &r.nodes[..])
            .unwrap_or(&[]);
        let mut out = BTreeMap::new();
        for id in &ids {
            let Some(p) = self.metadata.packages.iter().find(|p| p.id == *id) else {
                bail!("package {id} has units but is not in `cargo metadata`");
            };
            let is_local = local(p);
            let mut targets: Vec<PathTarget> = p
                .targets
                .iter()
                .map(|t| PathTarget {
                    name: t.name.clone(),
                    kind: t.kind.clone(),
                    crate_types: t.crate_types.clone(),
                    src_path: if is_local { under(&t.src_path) } else { None },
                })
                .collect();
            targets.sort();
            let mut dependencies: Vec<PathDependency> = if is_local {
                nodes
                    .iter()
                    .filter(|n| n.id == *id)
                    .flat_map(|n| &n.deps)
                    .filter(|d| {
                        used.contains(&(*id, d.pkg.as_str()))
                            && self
                                .metadata
                                .packages
                                .iter()
                                .any(|q| q.id == d.pkg && local(q))
                    })
                    .map(|d| {
                        let mut kinds: Vec<DepKind> = d
                            .dep_kinds
                            .iter()
                            .map(|k| DepKind {
                                kind: k.kind.clone(),
                                target: k.target.clone(),
                            })
                            .collect();
                        kinds.sort();
                        kinds.dedup();
                        PathDependency {
                            package: d.pkg.clone(),
                            kinds,
                        }
                    })
                    .collect()
            } else {
                Vec::new()
            };
            dependencies.sort();
            out.insert(
                (*id).to_owned(),
                PackageFacts {
                    targets,
                    rust_version: p.rust_version.clone(),
                    links: p.links.clone(),
                    dependencies,
                },
            );
        }
        Ok(out)
    }

    /// The traced `rustdoc --test` commands, one doctest unit per library,
    /// keyed `d-<package name>`. Errors go to `errors`, by doctest.
    fn doctests(
        &self,
        units: &mut BTreeMap<UnitId, Unit>,
        errors: &mut Vec<(String, String)>,
    ) -> Result<(), Error> {
        for rec in &self.rustdocs {
            if !rec.args.iter().any(|a| a == "--test") {
                continue;
            }
            let package = self.package_of(rec)?;
            let id = format!("d-{}", package.name);
            let subject = describe::doctest(&id, &package.name, &package.version);
            // A doctest has no output to read its platform from
            // (`platform_of`). Cargo passes `--target` exactly for
            // target-kind units (`CompileKind::add_target_arg`), and the
            // planner always plans with one.
            let platform = if arg_value(&rec.args, "--target").is_empty() {
                Platform::Host
            } else {
                Platform::Target
            };
            match self.rustdoc_unit(UnitKind::Doctest, rec, &rec.args, package, platform) {
                Ok(d) if !d.args.iter().any(|a| matches!(a, Arg::Runner(_))) => errors.push((
                    subject,
                    "the traced `rustdoc --test` has no `--test-runtool`, where the doctest's \
                     runner goes"
                        .into(),
                )),
                Ok(d) => {
                    if units.insert(id, d).is_some() {
                        errors.push((
                            subject,
                            "two `rustdoc --test` commands for one package".into(),
                        ));
                    }
                }
                Err(e) => errors.push((subject, e.0)),
            }
        }
        Ok(())
    }

    /// A traced rustdoc command (`args`, the recorded ones with what
    /// breakbulk-unit gives itself removed) as a unit of `kind`.
    fn rustdoc_unit(
        &self,
        kind: UnitKind,
        rec: &Record,
        args: &[String],
        package: &Package,
        platform: Platform,
    ) -> Result<Unit, Error> {
        let converted = self.convert_args(
            args,
            &rec.env,
            &package.id,
            (kind == UnitKind::Doc).then_some(platform),
        )?;
        let (env, env_splices, dylib) = self.convert_env(&rec.env, &package.id, &rec.args)?;
        let program = rec
            .program
            .iter()
            .map(|p| self.rw.text(p, None))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error(format!("program: {}", e.0)))?;
        let cwd = self
            .cwd(&rec.cwd, Some(&package.id))
            .map_err(|e| Error(format!("cwd: {}", e.0)))?;
        let mut types: Vec<String> = arg_value(&rec.args, "--crate-type")
            .into_iter()
            .map(str::to_owned)
            .collect();
        if types.is_empty() {
            types.push("lib".into());
        }
        Ok(Unit::new(
            kind,
            UnitBody {
                krate: Some(CrateInfo {
                    name: crate_name(&rec.args),
                    types,
                    edition: arg_value(&rec.args, "--edition")
                        .first()
                        .map_or("2015".to_owned(), |e| e.to_string()),
                }),
                program,
                args: converted,
                env,
                env_splices,
                dylib_path_from: dylib,
                cwd,
                ..UnitBody::empty(package.id.clone(), platform)
            },
        ))
    }

    /// The traced `rustdoc` commands of `cargo doc`, as doc units keyed
    /// `o-<package name>-<version>-<crate name>`, each `after` the doc
    /// units of the documented crates it reads (its `--extern`s), as Cargo
    /// runs a crate's rustdoc after its dependencies' when it documents
    /// them (`unit_dependencies.rs`, `compute_deps_doc`). rustdoc links to
    /// a crate's items only when the crate's directory is in its output
    /// directory when it starts (`ExternalCrate::location` in rustdoc's
    /// `clean/types.rs`), and under `--no-deps` Cargo does not order
    /// members' rustdocs at all, so replaying them dependencies first is
    /// the order in which every link that can resolve does.
    #[allow(clippy::type_complexity)]
    fn docs(
        &self,
        units: &mut BTreeMap<UnitId, Unit>,
        errors: &mut Vec<(String, String)>,
    ) -> Result<(), Error> {
        let mut documented: BTreeMap<(String, String), UnitId> = BTreeMap::new();
        let mut traced: Vec<(UnitId, Unit, BTreeSet<(String, String)>)> = Vec::new();
        for rec in &self.rustdocs {
            if rec.args.iter().any(|a| a == "--test") {
                continue;
            }
            let package = self.package_of(rec)?;
            let name = crate_name(&rec.args);
            let subject = describe::doc(&name, &package.name, &package.version);
            match self.doc(rec, package) {
                Ok((d, reads)) => {
                    let id = format!("o-{}-{}-{name}", package.name, package.version);
                    if documented
                        .insert((package.id.clone(), name.clone()), id.clone())
                        .is_some()
                        || traced.iter().any(|(t, _, _)| *t == id)
                    {
                        bail!(
                            "two rustdoc commands of `cargo doc` document the crate `{name}` of \
                             {} {}",
                            package.name,
                            package.version
                        );
                    }
                    traced.push((id, d, reads));
                }
                Err(e) => errors.push((subject, e.0)),
            }
        }
        for (id, mut d, reads) in traced {
            d.after = reads
                .iter()
                .filter_map(|r| documented.get(r))
                .filter(|a| **a != id)
                .cloned()
                .collect();
            units.insert(id, d);
        }
        Ok(())
    }

    /// One rustdoc command of `cargo doc`, and the documented crates, as
    /// (package, crate name), whose metadata it reads.
    fn doc(
        &self,
        rec: &Record,
        package: &Package,
    ) -> Result<(Unit, BTreeSet<(String, String)>), Error> {
        let Some(out_dir) = arg_value(&rec.args, "-o").first().copied() else {
            bail!("the rustdoc command names no output directory (`-o`)");
        };
        let platform = self.platform_of(out_dir);
        let args = without_output_dir(&rec.args);
        let doc = self.rustdoc_unit(UnitKind::Doc, rec, &args, package, platform)?;
        let mut reads = BTreeSet::new();
        for a in &doc.args {
            let Arg::Concat(pieces) = a else { continue };
            for p in pieces {
                if let Piece::Ref(Reference::Out(o)) = p
                    && let Some(c) = self.compiles.iter().find(|c| c.id == o.out)
                {
                    reads.insert((c.package.id.clone(), crate_name(&c.rec.args)));
                }
            }
        }
        Ok((doc, reads))
    }

    /// Whether Cargo's trim-paths is in effect: for every compile unit or
    /// for none. A profile override that sets it for some packages only
    /// would need breakbulk's own remaps on the others; that is not
    /// supported. Doctests are not counted: rustdoc gets remaps only with
    /// `trim-paths = "all"`.
    fn trim_paths(&self) -> Result<bool, Error> {
        let (with, without): (Vec<_>, Vec<_>) = self
            .compiles
            .iter()
            .partition(|c| has_cargo_trim_paths(&c.rec.args));
        let names = |cs: &[&CompileRec]| {
            cs.iter()
                .map(|c| format!("{} {}", c.package.name, c.package.version))
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect::<Vec<_>>()
                .join(", ")
        };
        if !with.is_empty() && !without.is_empty() {
            bail!(
                "Cargo's trim-paths is on for some packages and off for others (on: {}; off: \
                 {}), for example through a per-package profile override; breakbulk supports \
                 it for all packages or none: set `trim-paths` for the whole profile, or for \
                 none",
                names(&with),
                names(&without)
            );
        }
        Ok(!with.is_empty())
    }

    pub fn plan(&self) -> Result<Plan, Error> {
        let mut units = BTreeMap::new();
        let mut errors = Vec::new();
        for c in &self.compiles {
            match self.compile_unit(c) {
                Ok(u) => {
                    units.insert(c.id.clone(), u);
                }
                Err(e) => errors.push((describe_compile(c), e.0)),
            }
        }
        for r in &self.runs {
            match self.run_unit(r) {
                Ok(u) => {
                    units.insert(r.id.clone(), u);
                }
                Err(e) => errors.push((describe_run(r), e.0)),
            }
        }
        self.doctests(&mut units, &mut errors)?;
        self.docs(&mut units, &mut errors)?;
        if !errors.is_empty() {
            bail!("{}", describe::grouped(errors).join("\n"));
        }
        let mut plan = Plan {
            version: PLAN_VERSION,
            kind: self.ctx.kind,
            cargo: self.ctx.cargo_version.clone(),
            nightly_features_allowed: self.ctx.nightly,
            rustc: self.ctx.rustc_version.clone(),
            host: self.ctx.host.clone(),
            target: PlanTarget {
                arg: self.ctx.target.arg.clone(),
                short_name: self.ctx.target.short_name.clone(),
                exe_suffix: self.ctx.executable_suffix.clone(),
                debuginfo: self.ctx.target_debuginfo.clone(),
            },
            variant: self.ctx.variant.clone(),
            skeleton_root: self.ctx.skeleton.clone(),
            remap: Remap {
                trim_paths: self.trim_paths()?,
                trim_paths_default: self.ctx.trim_paths_default,
                rust_src: self.ctx.rust_src_remap.clone(),
            },
            config_env: self.ctx.config_env.clone(),
            packages: self.packages(&units)?,
            units,
            roots: self.roots(),
        };
        if let Err(e) = breakbulk_format::doc_order(&plan) {
            bail!("{e}");
        }
        plan.normalize();
        Ok(plan)
    }
}

/// The plan output a compile output file belongs to: `rmeta`, `rlib` (an
/// rlib, or a proc macro's shared library) or `bin` (everything linked:
/// bins, cdylibs, dylibs, staticlibs). Dep-info is dropped.
pub fn output_name(emit: &str, path: &str, types: &[String]) -> Option<&'static str> {
    match emit {
        "dep-info" => None,
        "metadata" => Some("rmeta"),
        "link" if path.ends_with(".rlib") => Some("rlib"),
        "link" if types.iter().any(|t| t == "proc-macro") => Some("rlib"),
        _ => Some("bin"),
    }
}

#[cfg(test)]
mod trim_tests {
    use super::*;

    #[test]
    fn output_dir_removed() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            without_output_dir(&a(&[
                "--crate-name",
                "u",
                "-o",
                "/t/doc",
                "--extern",
                "b=/x"
            ])),
            a(&["--crate-name", "u", "--extern", "b=/x"])
        );
    }

    #[test]
    fn cargo_trim_paths_detected() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(has_cargo_trim_paths(&a(&[
            "--remap-path-scope=all",
            "--remap-path-prefix=/s/t=/cargo/build-dir"
        ])));
        // A user's own remap never targets /cargo/build-dir exactly.
        assert!(!has_cargo_trim_paths(&a(&["--remap-path-prefix=/s=/x"])));
        assert!(!has_cargo_trim_paths(&a(&[
            "--remap-path-prefix=/s=/cargo/build-dirx"
        ])));
    }

    #[test]
    fn whole_paths_only() {
        assert!(names_path("/t/build/a-1/out", "/t/build/a-1/out"));
        assert!(names_path("x=/t/build/a-1/out/gen.rs", "/t/build/a-1/out"));
        assert!(names_path("/t/build/a-1/out:/y", "/t/build/a-1/out"));
        assert!(!names_path("/t/build/a-1/outer", "/t/build/a-1/out"));
    }
}

#[cfg(test)]
mod error_tests {
    use super::*;
    use serde_json::json;

    fn context() -> Context {
        Context {
            scratch: "/s".into(),
            skeleton: "/k".into(),
            host: "x86_64-unknown-linux-gnu".into(),
            target: crate::trace::Target::triple("x86_64-unknown-linux-gnu"),
            kind: PlanKind::Build,
            variant: Variant {
                profile: "dev".into(),
                features: BTreeSet::new(),
                mode: VariantMode::Build,
            },
            cargo_version: "1.99.0".into(),
            rustc_version: "1.99.0".into(),
            rustdoc: "rustdoc".into(),
            cargo: "cargo".into(),
            nightly: false,
            executable_suffix: String::new(),
            target_debuginfo: Default::default(),
            workspace_wrapper: None,
            wrapper_env: BTreeSet::new(),
            rustc_wrapper: None,
            config_env: BTreeSet::new(),
            rust_src_remap: None,
            trim_paths_default: false,
            std_vendor: None,
        }
    }

    fn package(name: &str) -> serde_json::Value {
        json!({
            "id": format!("path+file:///k/{name}#0.1.0"),
            "name": name,
            "version": "0.1.0",
            "source": null,
            "manifest_path": format!("/k/{name}/Cargo.toml"),
            "targets": [{
                "name": name,
                "kind": ["lib"],
                "crate_types": ["lib"],
                "src_path": format!("/k/{name}/src/lib.rs"),
            }],
        })
    }

    fn compile(package: &str, hash: &str, extra: &[&str]) -> serde_json::Value {
        let mut args = vec![
            "--crate-name".to_owned(),
            package.replace('-', "_"),
            format!("{package}/src/lib.rs"),
            "--crate-type".into(),
            "lib".into(),
            "-C".into(),
            format!("metadata={hash}"),
            "--out-dir".into(),
            "/s/x86_64-unknown-linux-gnu/debug/deps".into(),
        ];
        args.extend(extra.iter().map(|s| s.to_string()));
        json!({
            "mode": "compile",
            "program": ["rustc"],
            "args": args,
            "cwd": "/k",
            "env": { "CARGO_MANIFEST_DIR": format!("/k/{package}") },
        })
    }

    /// A unit is named by its package, crate, kind and platform, and one
    /// cause is one line, whatever the number of units it concerns.
    #[test]
    fn errors_name_units_and_group_repeats() {
        let metadata: Metadata = serde_json::from_value(json!({
            "packages": [package("a"), package("b-c"), package("d")],
            "workspace_members": [],
            "workspace_root": "/k",
        }))
        .unwrap();
        let records: Vec<Record> = serde_json::from_value(json!([
            { "mode": "query", "program": ["rustc"], "args": ["-vV"], "cwd": "/k", "env": {} },
            compile("a", "1111", &["--cfg", "__bb_abc_cfg"]),
            compile("b-c", "2222", &["--cfg", "__bb_abc_cfg"]),
            compile("d", "3333", &["--cfg", "__bb_def_cfg"]),
        ]))
        .unwrap();
        let ctx = context();
        let b = Builder::new(&ctx, &metadata, &records).unwrap();
        let e = b.plan().unwrap_err().0;
        assert_eq!(
            e.lines().collect::<Vec<_>>(),
            [
                "unit c-1111 (a 0.1.0, lib, target), unit c-2222 (b-c 0.1.0, lib, target): a \
                 sentinel names run `abc`, but no build script with that tag ran",
                "unit c-3333 (d 0.1.0, lib, target): a sentinel names run `def`, but no build \
                 script with that tag ran",
            ]
        );
    }

    /// With a `.json` target, an integration test's `CARGO_BIN_EXE_<bin>`
    /// (under the spec's stem) names the bin unit; a path there that names
    /// no output of a bin that is linked is an error, not a bin Cargo did
    /// not build.
    #[test]
    fn bin_exe_of_a_json_target() {
        let mut tool = package("tool");
        tool["targets"] = json!([
            { "name": "tool", "kind": ["bin"], "crate_types": ["bin"],
              "src_path": "/k/tool/src/main.rs" },
            { "name": "run", "kind": ["test"], "crate_types": ["bin"],
              "src_path": "/k/tool/tests/run.rs" },
        ]);
        let metadata: Metadata = serde_json::from_value(json!({
            "packages": [tool],
            "workspace_members": [],
            "workspace_root": "/k",
        }))
        .unwrap();
        let link = |name: &str, src: &str, hash: &str, extra: &[&str], env: serde_json::Value| {
            let mut args: Vec<String> = [
                "--crate-name",
                name,
                src,
                "-C",
                &format!("metadata={hash}"),
                "-C",
                &format!("extra-filename=-{hash}"),
                "--out-dir",
                "/s/board/debug/deps",
                "--target",
                "/specs/board.json",
            ]
            .map(str::to_owned)
            .into();
            args.extend(extra.iter().map(|s| s.to_string()));
            let mut env = env;
            env["CARGO_MANIFEST_DIR"] = json!("/k/tool");
            json!({
                "mode": "compile",
                "program": ["rustc"],
                "args": args,
                "cwd": "/k/tool",
                "env": env,
                "outputs": [{ "emit": "link", "path": format!("/s/board/debug/deps/{name}-{hash}") }],
            })
        };
        let records = |bin_exe: &str| -> Vec<Record> {
            serde_json::from_value(json!([
                { "mode": "query", "program": ["rustc"], "args": ["-vV"], "cwd": "/k", "env": {} },
                link("tool", "src/main.rs", "1111", &["--crate-type", "bin"], json!({})),
                link("run", "tests/run.rs", "2222", &["--test"],
                     json!({ "CARGO_BIN_EXE_tool": bin_exe })),
            ]))
            .unwrap()
        };
        let ctx = Context {
            target: crate::trace::Target {
                arg: "/specs/board.json".into(),
                short_name: "board".into(),
            },
            ..context()
        };
        let ok = records("/s/board/debug/tool");
        let plan = Builder::new(&ctx, &metadata, &ok).unwrap().plan().unwrap();
        let Unit::Compile(test) = &plan.units["c-2222"] else {
            panic!("c-2222 is not a compile");
        };
        assert_eq!(
            test.env["CARGO_BIN_EXE_tool"],
            Text::Concat(vec![Piece::Ref(Reference::Out(OutRef {
                out: "c-1111".into(),
                output: "bin".into(),
                file: Some("tool".into()),
            }))])
        );
        let bad = records("/s/board/debug/elsewhere");
        let e = Builder::new(&ctx, &metadata, &bad)
            .unwrap()
            .plan()
            .unwrap_err();
        assert!(e.0.contains("/s/board/debug/elsewhere"), "{e}");
    }

    fn run(package: &str, tag: &str, out_dir: &str) -> serde_json::Value {
        json!({
            "mode": "run",
            "program": [format!("{out_dir}/../build-script-build")],
            "args": [],
            "cwd": format!("/k/{package}"),
            "env": {
                "CARGO_MANIFEST_DIR": format!("/k/{package}"),
                "OUT_DIR": out_dir,
                "PROFILE": "release",
            },
            "tag": tag,
        })
    }

    fn metadata(names: &[&str]) -> Metadata {
        serde_json::from_value(json!({
            "packages": names.iter().map(|n| package(n)).collect::<Vec<_>>(),
            "workspace_members": [],
            "workspace_root": "/k",
        }))
        .unwrap()
    }

    /// A run's directory relative to the build directory, with the profile
    /// directory renamed after `PROFILE`: found by position, also for a
    /// package named `build` in the new layout.
    #[test]
    fn out_dir_rel_by_position() {
        let metadata = metadata(&["a", "build"]);
        let records: Vec<Record> = serde_json::from_value(json!([
            { "mode": "query", "program": ["rustc"], "args": ["-vV"], "cwd": "/k", "env": {} },
            run("a", "1111", "/s/custom/build/a-1111/out"),
            run(
                "build",
                "2222",
                "/s/x86_64-unknown-linux-gnu/custom/build/build/2222/out"
            ),
        ]))
        .unwrap();
        let ctx = context();
        let b = Builder::new(&ctx, &metadata, &records).unwrap();
        let rels: Vec<&str> = b.rw.run_dirs.values().map(|(_, r)| r.as_str()).collect();
        assert_eq!(
            rels,
            [
                "release/build/a-1111/out",
                "x86_64-unknown-linux-gnu/release/build/build/2222/out"
            ]
        );

        let records: Vec<Record> = serde_json::from_value(json!([
            { "mode": "query", "program": ["rustc"], "args": ["-vV"], "cwd": "/k", "env": {} },
            run("a", "1111", "/s/x86_64-unknown-linux-gnu/custom/a-1111/out"),
        ]))
        .unwrap();
        let e = Builder::new(&ctx, &metadata, &records).err().unwrap().0;
        assert!(e.contains("is not in a profile's `build` directory"), "{e}");
    }

    #[test]
    fn duplicate_run_tags() {
        let metadata = metadata(&["a", "b"]);
        let records: Vec<Record> = serde_json::from_value(json!([
            { "mode": "query", "program": ["rustc"], "args": ["-vV"], "cwd": "/k", "env": {} },
            run("a", "1111", "/s/debug/build/a-1111/out"),
            run("b", "1111", "/s/debug/build/b-1111/out"),
        ]))
        .unwrap();
        let ctx = context();
        let e = Builder::new(&ctx, &metadata, &records).err().unwrap().0;
        assert!(e.contains("have the same tag `1111`"), "{e}");
    }
}
