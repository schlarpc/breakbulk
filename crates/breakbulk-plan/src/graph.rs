//! From records to `plan.json`: unit identity, edges, sentinel conversion,
//! path rewriting, env filtering and roots ("Unit identity and graph
//! edges", "Path rewriting" and "Env filtering" in `docs/implementation.md`).

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{
    Arg, CompileUnit, CrateInfo, Doctest, LinkArgKind, OutRef, PLAN_VERSION, PackageTarget, Plan,
    PlanKind, Platform, Reference, Root, RootKind, RunUnit, SearchIn, SearchPathsSplice, Splice,
    SpliceKind, Text, Unit, UnitId, Variant, VariantMode, contains_sentinel,
};

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
    pub target: String,
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
    /// Whether the clippy variant's `RUSTC_WORKSPACE_WRAPPER` is kept.
    pub keep_workspace_wrapper: bool,
    /// The variables the project's `[env]` table sets on Cargo's
    /// processes ([`crate::spec::ProjectConfig::applied_env`]).
    pub config_env: BTreeSet<String>,
    /// [`breakbulk_format::plan::Plan::rust_src_remap`].
    pub rust_src_remap: Option<(String, String)>,
}

/// Variables never kept in a unit's env: the planner's own, and the ones the
/// design drops ("Env filtering").
const DROPPED_ENV: &[&str] = &[
    "RUSTC_WRAPPER",
    "CARGO_MAKEFLAGS",
    "BREAKBULK_RECORD",
    "BREAKBULK_RUSTDOC",
    "BREAKBULK_METADATA",
];

/// Variables Cargo sets on every process it starts, kept even when equal to
/// Cargo's own environment (from 1.97 Cargo also sets `CARGO` on itself, so
/// subtracting the baseline would drop it).
const ALWAYS_KEPT_ENV: &[&str] = &["CARGO"];

/// The dynamic-library path variable on the planning host.
const DYLIB_VAR: &str = "LD_LIBRARY_PATH";

/// What `CARGO_TARGET_TMPDIR` (compile-time env of integration tests and
/// benches) becomes: a fixed path that the test-run derivation creates
/// before running the test ("Tests" in `docs/implementation.md`). Cargo's
/// value names its target directory, which breakbulk does not have.
pub const TARGET_TMPDIR: &str = "/tmp/breakbulk-target-tmp";

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

/// `cargo metadata`'s description of a package's targets, for run units.
fn package_targets(p: &Package) -> Vec<PackageTarget> {
    let mut v: Vec<PackageTarget> = p
        .targets
        .iter()
        .map(|t| PackageTarget {
            name: t.name.clone(),
            kind: t.kind.clone(),
        })
        .collect();
    v.sort();
    v
}

struct CompileRec<'a> {
    id: UnitId,
    rec: &'a Record,
    platform: Platform,
    package: &'a Package,
    outputs: BTreeMap<String, BTreeSet<String>>,
    types: Vec<String>,
    test: bool,
}

struct RunRec<'a> {
    id: UnitId,
    rec: &'a Record,
    platform: Platform,
    package: &'a Package,
    out_dir: String,
}

/// Builds the plan from one or more traced invocations' records.
pub struct Builder<'a> {
    ctx: &'a Context,
    metadata: &'a Metadata,
    baseline: BTreeMap<String, String>,
    compiles: Vec<CompileRec<'a>>,
    runs: Vec<RunRec<'a>>,
    run_by_tag: BTreeMap<String, usize>,
    /// `rustdoc` records (from `cargo test --doc`).
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
            rw: Rewriter::new(&ctx.scratch, &ctx.skeleton, metadata),
        };
        let mut seen = BTreeSet::new();
        for rec in records {
            match rec.mode.as_str() {
                "compile" => {
                    let c = b.compile_rec(rec)?;
                    if !seen.insert(c.id.clone()) {
                        bail!(
                            "two compiles have `-C metadata={}` ({}); unit keys must be unique within a plan",
                            &c.id[2..],
                            rec.file
                        );
                    }
                    b.compiles.push(c);
                }
                "run" => {
                    let r = b.run_rec(rec)?;
                    if !seen.insert(r.id.clone()) {
                        bail!("the build script run {} was traced twice", r.id);
                    }
                    b.run_by_tag
                        .insert(rec.tag.clone().expect("checked in run_rec"), b.runs.len());
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
                            file: Some(file_name(&o.path).into()),
                        },
                    );
                }
            }
        }
        for r in &b.runs {
            b.rw.run_dirs.insert(r.out_dir.clone(), r.id.clone());
        }
        b.register_uplifted_bins();
        Ok(b)
    }

    fn platform_of(&self, path: &str) -> Platform {
        match under(path, &self.ctx.scratch).and_then(|r| r.split('/').next()) {
            Some(first) if first == self.ctx.target => Platform::Target,
            _ => Platform::Host,
        }
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
        let mut outputs: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for o in &rec.outputs {
            if let Some(name) = output_name(&o.emit, &o.path, &types) {
                outputs
                    .entry(name.into())
                    .or_default()
                    .insert(file_name(&o.path).into());
            }
        }
        Ok(CompileRec {
            id: format!("c-{hash}"),
            rec,
            platform: self.platform_of(&out_dir),
            package: self.package_of(rec)?,
            outputs,
            types,
            test: rec.args.iter().any(|a| a == "--test"),
        })
    }

    fn run_rec(&self, rec: &'a Record) -> Result<RunRec<'a>, Error> {
        let Some(tag) = &rec.tag else {
            bail!("{}: run record without a tag", rec.file);
        };
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

    /// Bins are also copied ("uplifted") to `<profile dir>/<target name>`,
    /// which is what `CARGO_BIN_EXE_<name>` names. Map such a path to the
    /// bin's output: the one bin compile of that name, or the one of the
    /// referring unit's package (see [`crate::rewrite::Rewriter::uplifted_bins`]).
    fn register_uplifted_bins(&mut self) {
        let mut by_name: BTreeMap<(Platform, String), Vec<(String, OutRef)>> = BTreeMap::new();
        for c in &self.compiles {
            if c.test || !c.types.iter().any(|t| t == "bin") {
                continue;
            }
            let Some(t) = self.target_of(c) else { continue };
            if !t.has_kind("bin") {
                continue;
            }
            for o in &c.rec.outputs {
                if let Some(r) = self.rw.outputs.get(&o.path)
                    && r.output == "bin"
                {
                    by_name
                        .entry((c.platform, t.name.clone()))
                        .or_default()
                        .push((c.package.id.clone(), r.clone()));
                }
            }
        }
        self.rw.uplifted_bins = by_name;
        self.rw.target_triple = self.ctx.target.clone();
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

    fn run_id(&self, tag: &str, what: &dyn Fn() -> String) -> Result<&RunRec<'a>, Error> {
        self.run_by_tag
            .get(tag)
            .map(|&i| &self.runs[i])
            .ok_or_else(|| {
                Error(format!(
                    "{}: a sentinel names run `{tag}`, but no build script with that tag ran",
                    what()
                ))
            })
    }

    fn shape_error(&self, unit: &str, kind: &str, seen: &str, args: &[String]) -> Error {
        Error(format!(
            "unit {unit}: a {kind} sentinel is in a shape the sentinel table does not allow \
             (Cargo {}): {seen}\n  arguments: {}",
            self.ctx.cargo_version,
            args.join(" ")
        ))
    }

    /// Filter a recorded env ("Env filtering"), before rewriting.
    fn filter_env(&self, env: &BTreeMap<String, String>, run: bool) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        for (k, v) in env {
            if DROPPED_ENV.contains(&k.as_str()) {
                continue;
            }
            if k == "RUSTC_WORKSPACE_WRAPPER" && !self.ctx.keep_workspace_wrapper {
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
    fn dylib_path(&self, unit: &str, value: &str) -> Result<(Vec<UnitId>, Option<String>), Error> {
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
                let r = self.run_id(&tag, &|| format!("unit {unit}: {DYLIB_VAR}"))?;
                if dir != r.out_dir {
                    return Err(self.shape_error(unit, "dynamic-library path", e, &[]));
                }
                if !runs.contains(&r.id) {
                    runs.push(r.id.clone());
                }
            } else if contains_sentinel(e) {
                return Err(self.shape_error(unit, "dynamic-library path", e, &[]));
            } else if !self.rw.in_scratch(e) {
                kept.push(e);
            }
        }
        Ok((runs, (!kept.is_empty()).then(|| kept.join(":"))))
    }

    fn rewrite_env(
        &self,
        unit: &str,
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
            if let Some(bin) = k.strip_prefix("CARGO_BIN_EXE_")
                && self.rw.in_scratch(&v)
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
                && let Some((_, tail)) = v.rsplit_once("/build/")
            {
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
                let (runs, rest) = self.dylib_path(unit, &v)?;
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
                .map_err(|e| Error(format!("unit {unit}: env `{k}`: {}", e.0)))?;
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
        id: &str,
        args: &[String],
        owner: &str,
        platform: Option<Platform>,
    ) -> Result<Vec<Arg>, Error> {
        let mut out: Vec<Arg> = Vec::new();
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
                _ => {}
            }
            if let Some(n) = next
                && matches!(a, "--cfg" | "--check-cfg" | "-l" | "-L" | "-C")
                && let Some(s) = parse_pair(a, n)
            {
                let s = s.map_err(|seen| self.shape_error(id, a, &seen, args))?;
                let r = self.run_id(s.tag(), &|| format!("unit {id}"))?;
                if let Some(p) = platform
                    && r.platform != p
                {
                    return Err(self.shape_error(
                        id,
                        a,
                        &format!("`{a} {n}` from a {:?} run on a {p:?} unit", r.platform),
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
                                id,
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
                                id,
                                "rustc-link-arg",
                                &format!("the link-arg sentinels of run {run} are not adjacent"),
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
                    .map_err(|e| Error(format!("unit {id}: argument `-L {n}`: {}", e.0)))?;
                let Text::Literal(l) = t else {
                    bail!(
                        "unit {id}: `-L {n}` from a `links` override names a path breakbulk \
                         rewrites; doctests do not support that yet"
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
                return Err(self.shape_error(id, "unknown", &format!("`{a}`"), args));
            }
            let t = self
                .rw
                .text(a, Some(owner))
                .map_err(|e| Error(format!("unit {id}: argument `{a}`: {}", e.0)))?;
            out.push(t.into());
            i += 1;
        }
        if args.iter().any(|a| a.contains("=/cargo/build-dir")) {
            bail!("unit {id}: Cargo's trim-paths is in effect; breakbulk does not support it yet");
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

    /// Convert a recorded env: `rustc-env` sentinels become env splices,
    /// the rest is filtered and rewritten; dynamic-library path sentinels
    /// become dynamic-path splices.
    #[allow(clippy::type_complexity)]
    fn convert_env(
        &self,
        id: &str,
        rec_env: &BTreeMap<String, String>,
        owner: &str,
        args: &[String],
    ) -> Result<(BTreeMap<String, Text>, Vec<Splice>, Vec<UnitId>), Error> {
        let mut env = BTreeMap::new();
        let mut env_splices = Vec::new();
        for (k, v) in rec_env {
            match env_sentinel(k, v) {
                Some(Ok(tag)) => {
                    let r = self.run_id(&tag, &|| format!("unit {id}"))?;
                    env_splices.push(Splice::new(r.id.clone(), SpliceKind::RustcEnv));
                }
                Some(Err(seen)) => return Err(self.shape_error(id, "rustc-env", &seen, args)),
                None => {
                    env.insert(k.clone(), v.clone());
                }
            }
        }
        env_splices.sort();
        let (env, dylib) = self.rewrite_env(id, owner, self.filter_env(&env, false))?;
        for (k, v) in &env {
            if contains_sentinel(k) {
                return Err(self.shape_error(id, "env", &format!("`{k}={v:?}`"), args));
            }
        }
        Ok((env, env_splices, dylib))
    }

    fn compile_unit(&self, c: &CompileRec<'a>) -> Result<Unit, Error> {
        let id = &c.id;
        let args = &c.rec.args;
        let out = self.convert_args(id, args, &c.package.id, Some(c.platform))?;
        let (mut env, env_splices, dylib) =
            self.convert_env(id, &c.rec.env, &c.package.id, args)?;
        // The clippy variant: `cargo clippy` passes clippy's own arguments
        // (`-- -D warnings`) to clippy-driver in `CLIPPY_ARGS`, which Cargo
        // inherits to every rustc it starts; keep it only where
        // clippy-driver runs (a wrapper chain), so dependencies stay shared
        // with the check variant.
        if self.ctx.keep_workspace_wrapper
            && c.rec.program.len() > 1
            && let Some(v) = c.rec.env.get("CLIPPY_ARGS")
        {
            env.insert("CLIPPY_ARGS".into(), Text::Literal(v.clone()));
        }

        let program = c
            .rec
            .program
            .iter()
            .map(|p| self.rw.text(p, None))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error(format!("unit {id}: program: {}", e.0)))?;
        let cwd = self
            .rw
            .reference(&c.rec.cwd, Some(&c.package.id))
            .map_err(|e| Error(format!("unit {id}: cwd: {}", e.0)))?;
        let edition = arg_value(args, "--edition")
            .first()
            .map_or("2015".to_owned(), |e| e.to_string());
        let name = arg_value(args, "--crate-name")
            .first()
            .map(|s| s.to_string())
            .unwrap_or_default();
        Ok(Unit::Compile(CompileUnit {
            package: c.package.id.clone(),
            krate: CrateInfo {
                name,
                types: c.types.clone(),
                edition,
            },
            platform: c.platform,
            program,
            args: out,
            env,
            env_splices,
            dylib_path_from: dylib,
            cwd,
            outputs: c.outputs.clone(),
        }))
    }

    fn run_unit(&self, r: &RunRec<'a>) -> Result<Unit, Error> {
        let id = &r.id;
        let rec = r.rec;
        // The script: the stub's directory plus the compile output's name.
        let Some(program) = rec.program.first() else {
            bail!("{}: run record without a program", rec.file);
        };
        let binary = rec
            .stub
            .as_ref()
            .and_then(|s| s.compile.binary.clone())
            .unwrap_or_else(|| file_name(program).to_owned());
        let script_path = format!("{}/{binary}", parent(program));
        let Some(script) = self.rw.outputs.get(&script_path) else {
            bail!("run {id}: its build script {script_path} is no compile unit's output");
        };
        let mut env = BTreeMap::new();
        let mut metadata_from = BTreeSet::new();
        for (k, v) in &rec.env {
            if let Some((_links, tag)) = dep_sentinel(k, v) {
                let up = self.run_id(tag, &|| format!("run {id}: {k}"))?;
                if up.package.links.is_none() {
                    bail!(
                        "run {id}: {k} names run {}, whose package declares no `links`",
                        up.id
                    );
                }
                metadata_from.insert(up.id.clone());
                continue;
            }
            if contains_sentinel(k) || contains_sentinel(v) && k != DYLIB_VAR {
                return Err(self.shape_error(id, "env", &format!("`{k}={v}`"), &[]));
            }
            env.insert(k.clone(), v.clone());
        }
        let (env, dylib) = self.rewrite_env(id, &r.package.id, self.filter_env(&env, true))?;
        let cwd = self
            .rw
            .reference(&rec.cwd, Some(&r.package.id))
            .map_err(|e| Error(format!("run {id}: cwd: {}", e.0)))?;
        Ok(Unit::Run(RunUnit {
            package: r.package.id.clone(),
            platform: r.platform,
            links: r.package.links.clone(),
            script: Reference::Out(script.clone()),
            env,
            cwd,
            metadata_from,
            dylib_path_from: dylib,
            rust_version: r.package.rust_version.clone(),
            targets: package_targets(r.package),
            nightly_features_allowed: self.ctx.nightly,
        }))
    }

    /// The plan's products ("Fields", `roots`): in a build plan, bins and
    /// linkable library crate types of selected packages; in a test plan,
    /// every test harness and every example; in a bench plan, every bench
    /// (with or without the libtest harness) and the lib and bin harnesses
    /// in bench mode. Check and clippy variants link nothing and have no
    /// roots.
    fn roots(&self) -> Vec<Root> {
        let mut roots = Vec::new();
        if matches!(
            self.ctx.variant.mode,
            VariantMode::Check | VariantMode::Clippy
        ) {
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
                PlanKind::Build => false,
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

    /// The traced `rustdoc --test` commands, one per library, keyed
    /// `d-<package name>`.
    fn doctests(&self) -> Result<BTreeMap<String, Doctest>, Error> {
        let mut out = BTreeMap::new();
        for rec in &self.rustdocs {
            if !rec.args.iter().any(|a| a == "--test") {
                continue;
            }
            let package = self.package_of(rec)?;
            let id = format!("d-{}", package.name);
            let args = self.convert_args(&id, &rec.args, &package.id, None)?;
            let (env, env_splices, dylib) =
                self.convert_env(&id, &rec.env, &package.id, &rec.args)?;
            let program = rec
                .program
                .iter()
                .map(|p| self.rw.text(p, None))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| Error(format!("{id}: program: {}", e.0)))?;
            let cwd = self
                .rw
                .reference(&rec.cwd, Some(&package.id))
                .map_err(|e| Error(format!("{id}: cwd: {}", e.0)))?;
            let mut types: Vec<String> = arg_value(&rec.args, "--crate-type")
                .into_iter()
                .map(str::to_owned)
                .collect();
            if types.is_empty() {
                types.push("lib".into());
            }
            let doctest = Doctest {
                package: package.id.clone(),
                krate: CrateInfo {
                    name: arg_value(&rec.args, "--crate-name")
                        .first()
                        .map(|s| s.to_string())
                        .unwrap_or_default(),
                    types,
                    edition: arg_value(&rec.args, "--edition")
                        .first()
                        .map_or("2015".to_owned(), |e| e.to_string()),
                },
                program,
                args,
                env,
                env_splices,
                dylib_path_from: dylib,
                cwd,
            };
            if out.insert(id.clone(), doctest).is_some() {
                bail!("{id}: two `rustdoc --test` commands for one package");
            }
        }
        Ok(out)
    }

    pub fn plan(&self) -> Result<Plan, Error> {
        let mut units = BTreeMap::new();
        let mut errors = Vec::new();
        for c in &self.compiles {
            match self.compile_unit(c) {
                Ok(u) => {
                    units.insert(c.id.clone(), u);
                }
                Err(e) => errors.push(e.0),
            }
        }
        for r in &self.runs {
            match self.run_unit(r) {
                Ok(u) => {
                    units.insert(r.id.clone(), u);
                }
                Err(e) => errors.push(e.0),
            }
        }
        if !errors.is_empty() {
            bail!("{}", errors.join("\n"));
        }
        let mut plan = Plan {
            version: PLAN_VERSION,
            kind: self.ctx.kind,
            cargo: self.ctx.cargo_version.clone(),
            rustc: self.ctx.rustc_version.clone(),
            host: self.ctx.host.clone(),
            target: self.ctx.target.clone(),
            variant: self.ctx.variant.clone(),
            skeleton_root: self.ctx.skeleton.clone(),
            trim_paths: false,
            units,
            roots: self.roots(),
            doctests: self.doctests()?,
            config_env: self.ctx.config_env.clone(),
            rust_src_remap: self.ctx.rust_src_remap.clone(),
        };
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
