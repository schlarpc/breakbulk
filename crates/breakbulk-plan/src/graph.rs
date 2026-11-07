//! From records to `plan.json`: unit identity, edges, sentinel conversion,
//! path rewriting, env filtering and roots ("Unit identity and graph
//! edges", "Path rewriting" and "Env filtering" in `docs/implementation.md`).

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{
    Arg, CompileUnit, CrateInfo, LinkArgKind, OutRef, PLAN_VERSION, PackageTarget, Plan, PlanKind,
    Platform, Reference, Root, RootKind, RunUnit, SearchIn, Splice, SpliceKind, Text, Unit, UnitId,
    Variant, contains_sentinel,
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
    /// Cargo's `nightly_features_allowed`.
    pub nightly: bool,
    /// Whether the clippy variant's `RUSTC_WORKSPACE_WRAPPER` is kept.
    pub keep_workspace_wrapper: bool,
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

fn parent(p: &str) -> &str {
    p.rsplit_once('/').map_or("", |(d, _)| d)
}

fn file_name(p: &str) -> &str {
    p.rsplit_once('/').map_or(p, |(_, f)| f)
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
                "query" | "rustdoc" => {}
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
    /// bin's output when exactly one bin compile of that target exists.
    fn register_uplifted_bins(&mut self) {
        let mut by_name: BTreeMap<(Platform, String), Vec<OutRef>> = BTreeMap::new();
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
                        .push(r.clone());
                }
            }
        }
        for ((platform, name), refs) in by_name {
            if let [r] = refs.as_slice() {
                self.rw.uplifted_bins.insert((platform, name), r.clone());
            }
        }
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
            if self.baseline.get(k) == Some(v) && !ALWAYS_KEPT_ENV.contains(&k.as_str()) {
                continue;
            }
            let v = if run && k == "RUSTDOC" {
                self.ctx.rustdoc.clone()
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
        for e in value.split(':').filter(|e| !e.is_empty()) {
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

    fn compile_unit(&self, c: &CompileRec<'a>) -> Result<Unit, Error> {
        let id = &c.id;
        let args = &c.rec.args;
        let mut out: Vec<Arg> = Vec::new();
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
                if r.platform != c.platform {
                    return Err(self.shape_error(
                        id,
                        a,
                        &format!(
                            "`{a} {n}` from a {:?} run on a {:?} unit",
                            r.platform, c.platform
                        ),
                        args,
                    ));
                }
                let run = r.id.clone();
                let is_link_arg = matches!(s, ArgSentinel::LinkArg(..));
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
            if contains_sentinel(a) {
                return Err(self.shape_error(id, "unknown", &format!("`{a}`"), args));
            }
            let t = self
                .rw
                .text(a, Some(&c.package.id))
                .map_err(|e| Error(format!("unit {id}: argument `{a}`: {}", e.0)))?;
            out.push(t.into());
            i += 1;
        }
        if args.iter().any(|a| a.contains("=/cargo/build-dir")) {
            bail!("unit {id}: Cargo's trim-paths is in effect; breakbulk does not support it yet");
        }

        // Env: sentinels first, then filtering and rewriting.
        let mut env = BTreeMap::new();
        let mut env_splices = Vec::new();
        for (k, v) in &c.rec.env {
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
        let (env, dylib) = self.rewrite_env(id, &c.package.id, self.filter_env(&env, false))?;
        for (k, v) in &env {
            if contains_sentinel(k) {
                return Err(self.shape_error(id, "env", &format!("`{k}={v:?}`"), args));
            }
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
    /// every test harness and every example.
    fn roots(&self) -> Vec<Root> {
        let mut roots = Vec::new();
        for c in &self.compiles {
            if c.rec.env.get("CARGO_PRIMARY_PACKAGE").map(String::as_str) != Some("1") {
                continue;
            }
            let Some(t) = self.target_of(c) else { continue };
            if t.has_kind("custom-build") {
                continue;
            }
            let root = |kind| Root {
                package: c.package.id.clone(),
                target: t.name.clone(),
                kind,
                unit: c.id.clone(),
                test: c.test,
            };
            let kinds: Vec<RootKind> = match self.ctx.kind {
                PlanKind::Build if !c.test => {
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
                PlanKind::Test if c.test => vec![if t.has_kind("bin") {
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
                _ => vec![],
            };
            roots.extend(kinds.into_iter().map(root));
        }
        roots
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
