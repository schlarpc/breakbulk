//! The trace golden test ("Testing and conformance", item 2): render a traced
//! plan back to concrete argv in a real Cargo build's layout, expand its
//! splices with the real build scripts' output, and compare unit by unit with
//! the argv the real `cargo build -v` printed.
//!
//! Both sides run at the same verbosity: the planner traces without `-v`, and
//! `-v` only prints argv (`-vv` would change it, spike A S11). The real build
//! must run with its sources at the plan's `skeletonRoot`, so path crates
//! outside the workspace root hash the same.
//!
//! Compared: every compile's arguments, minus what breakbulk replaces
//! (`--out-dir`, Cargo's own `-L dependency=`, `-C incremental=`). Not
//! compared: the program (the planner passes rustc by absolute path).
//!
//! With [`CompareOptions::env`] and a `-vv` log (the directive differential
//! test, `tests/differential`), env is compared too: each compile's, with
//! `rustc-env` and dynamic-library path splices expanded, and each
//! build-script run's, with `DEP_*` metadata and dynamic-library paths. `-vv`
//! changes argv only for non-local crates (`--cap-lints`), so a workspace of
//! path crates compares the same argv at both verbosities.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use breakbulk_format::{
    CompileUnit, Plan, Reference, Resolve, Unit, UnitId, render_doctest, render_unit,
};
use breakbulk_unit::directives::{BuildOutput, MetadataFile, ParseContext, parse};
use breakbulk_unit::doctest;
use breakbulk_unit::run::run_env;
use breakbulk_unit::spec::RenderedUnit;
use breakbulk_unit::splice::{
    DYLIB_PATH_VAR, expand_args, expand_dylib_path, expand_env, prepend_dylib_path,
};

use crate::graph::{CARGO_BUILD_DIR_REMAP, OVERRIDDEN_OUT_DIR};
use crate::records::{Metadata, Package};

/// Split a command line as Cargo prints it (`shell-escape` quoting: single
/// quotes, and backslash escapes outside quotes).
pub fn shell_split(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                for c in chars.by_ref() {
                    if c == '\'' {
                        break;
                    }
                    cur.push(c);
                }
            }
            '"' => {
                in_word = true;
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => {
                            if let Some(n) = chars.next() {
                                cur.push(n);
                            }
                        }
                        c => cur.push(c),
                    }
                }
            }
            '\\' => {
                in_word = true;
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            c if c.is_whitespace() => {
                if in_word {
                    out.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            c => {
                in_word = true;
                cur.push(c);
            }
        }
    }
    if in_word {
        out.push(cur);
    }
    out
}

/// One process from a `cargo … -v` log: the env Cargo printed (only with
/// `-vv`), the program and its arguments.
#[derive(Clone, Debug)]
pub struct RealProcess {
    pub env: BTreeMap<String, String>,
    pub program: String,
    pub args: Vec<String>,
}

/// Every `Running` line of a `cargo … -v` or `-vv` log.
pub fn real_processes(log: &str) -> Vec<RealProcess> {
    let mut out = Vec::new();
    for line in log.lines() {
        let Some(cmd) = line
            .trim_start()
            .strip_prefix("Running `")
            .and_then(|l| l.strip_suffix('`'))
        else {
            continue;
        };
        let argv = shell_split(cmd);
        // Leading `KEY=value` words (only with -vv) and the program.
        let Some(prog) = argv
            .iter()
            .position(|a| !a.contains('=') || a.starts_with('/'))
        else {
            continue;
        };
        let env = argv[..prog]
            .iter()
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
        out.push(RealProcess {
            env,
            program: argv[prog].clone(),
            args: argv[prog + 1..].to_vec(),
        });
    }
    out
}

/// One rustc command from the real build: its arguments with breakbulk's
/// replacements stripped, its `--out-dir`, and its env (empty unless the log
/// is `-vv`).
#[derive(Clone, Debug)]
pub struct RealCompile {
    pub args: Vec<String>,
    pub out_dir: String,
    pub env: BTreeMap<String, String>,
}

/// The rustc commands of a `cargo … -v` log, keyed `c-<-C metadata>`.
///
/// `-L dependency=<dir>` is dropped when `<dir>` is a `deps` directory, some
/// compile's `--out-dir`, or another unit directory of the new layout
/// (`…/build/<pkg>/<hash>/out`): breakbulk passes its own instead. A build
/// script's `rustc-link-search=dependency=…` is kept, unless it names an
/// `OUT_DIR` itself.
pub fn real_compiles(log: &str) -> BTreeMap<UnitId, RealCompile> {
    let mut out = BTreeMap::new();
    let compiles: Vec<RealProcess> = real_processes(log)
        .into_iter()
        .filter(|p| p.program.ends_with("rustc") && p.args.iter().any(|a| a == "--crate-name"))
        .collect();
    let out_dirs: BTreeSet<String> = compiles
        .iter()
        .filter_map(|p| {
            let i = p.args.iter().position(|a| a == "--out-dir")?;
            p.args.get(i + 1).cloned()
        })
        .collect();
    for p in compiles {
        let args = &p.args;
        let mut kept = Vec::new();
        let mut out_dir = String::new();
        let mut metadata = None;
        let mut i = 0;
        while i < args.len() {
            let a = args[i].as_str();
            let next = args.get(i + 1).map(String::as_str).unwrap_or("");
            match a {
                "--out-dir" => {
                    out_dir = next.to_owned();
                    i += 2;
                    continue;
                }
                "-C" if next.starts_with("incremental=") => {
                    i += 2;
                    continue;
                }
                "-L" if next.strip_prefix("dependency=").is_some_and(|d| {
                    d.ends_with("/deps")
                        || out_dirs.contains(d)
                        || (d.ends_with("/out") && d.contains("/build/"))
                }) =>
                {
                    i += 2;
                    continue;
                }
                "-C" if next.starts_with("metadata=") => {
                    metadata = Some(next["metadata=".len()..].to_owned());
                }
                _ => {}
            }
            kept.push(a.to_owned());
            i += 1;
        }
        if let Some(m) = metadata {
            out.insert(
                format!("c-{m}"),
                RealCompile {
                    args: kept,
                    out_dir,
                    env: p.env,
                },
            );
        }
    }
    out
}

/// The build-script runs of a `cargo … -vv` log: their env, keyed by
/// `OUT_DIR`.
pub fn real_runs(log: &str) -> BTreeMap<String, BTreeMap<String, String>> {
    real_processes(log)
        .into_iter()
        .filter(|p| {
            Path::new(&p.program)
                .file_name()
                .is_some_and(|f| f.to_string_lossy().starts_with("build"))
        })
        .filter_map(|p| Some((p.env.get("OUT_DIR")?.clone(), p.env)))
        .collect()
}

/// Find each run's directory in the real target directory: classic
/// `…/build/<pkg>-<hash>` (with `output`), or the new layout's
/// `…/build/<pkg>/<hash>` (with `run/stdout`). Returns (OUT_DIR, stdout).
fn find_run(target: &Path, pkg: &str, hash: &str) -> Option<(PathBuf, PathBuf)> {
    let mut stack = vec![target.to_owned()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let p = e.path();
            if !p.is_dir() {
                continue;
            }
            let name = e.file_name().to_string_lossy().into_owned();
            if d.file_name().is_some_and(|n| n == "build") && name == format!("{pkg}-{hash}") {
                return Some((p.join("out"), p.join("output")));
            }
            if name == hash
                && d.parent()
                    .and_then(|x| x.file_name())
                    .is_some_and(|n| n == "build")
            {
                return Some((p.join("out"), p.join("run/stdout")));
            }
            stack.push(p);
        }
    }
    None
}

struct Real<'a> {
    plan: &'a Plan,
    skeleton: String,
    crate_dirs: BTreeMap<String, String>,
    packages: BTreeMap<&'a str, &'a Package>,
    out_dirs: BTreeMap<UnitId, String>,
    run_dirs: BTreeMap<UnitId, String>,
}

impl Resolve for Real<'_> {
    type Error = String;
    /// Golden comparisons diff argv and env, never a unit's outputs, so the
    /// `debug` output the traits decide does not matter here.
    fn target_traits(&self) -> &breakbulk_format::TargetTraits {
        breakbulk_format::TargetTraits::NONE
    }
    fn reference(&self, r: &Reference) -> Result<String, String> {
        let join = |base: &str, rel: &str| {
            if rel.is_empty() {
                base.to_owned()
            } else {
                format!("{}/{rel}", base.trim_end_matches('/'))
            }
        };
        match r {
            Reference::Src(s) => Ok(join(&self.skeleton, &s.rel)),
            Reference::CrateSrc(s) => self
                .crate_dirs
                .get(&s.crate_src)
                .map(|d| join(d, &s.rel))
                .ok_or_else(|| format!("no crate directory for {}", s.crate_src)),
            // A run's `out` holds its `OUT_DIR` at `RunUnit::out_dir`, Cargo's
            // path below the target directory (with the profile directory
            // named after `PROFILE`), so the `out` stands for that target
            // directory: the real OUT_DIR with as many components dropped.
            Reference::Out(o) => match self.plan.units.get(&o.out) {
                Some(Unit::Run(run)) => self
                    .run_dirs
                    .get(&o.out)
                    .map(|d| {
                        let mut p = Path::new(d);
                        if !run.out_dir.is_empty() {
                            for _ in run.out_dir.split('/') {
                                p = p.parent().unwrap_or(p);
                            }
                        }
                        p.display().to_string()
                    })
                    .ok_or_else(|| format!("the real build did not run {}", o.out)),
                _ => self
                    .out_dirs
                    .get(&o.out)
                    .map(|d| join(d, o.file.as_deref().unwrap_or("")))
                    .ok_or_else(|| format!("the real build did not compile {}", o.out)),
            },
        }
    }
    fn flags(&self, run: &UnitId) -> Result<String, String> {
        Ok(run.clone())
    }
    fn remap_name(&self, _: &Reference) -> Result<String, String> {
        Ok(String::new())
    }
}

/// The comparison's result: one line per difference, and what was compared.
#[derive(Debug, Default)]
pub struct Report {
    pub compared: usize,
    pub problems: Vec<String>,
}

/// What [`compare_with`] compares besides argv.
#[derive(Clone, Copy, Debug, Default)]
pub struct CompareOptions {
    /// Also compare env: every compile's (with `rustc-env` and dynamic-path
    /// splices expanded) and every build-script run's (with `DEP_*`
    /// metadata and dynamic-path splices). Needs a `-vv` log.
    pub env: bool,
    /// The negative control ("Testing and conformance", item 2): expand with
    /// a deliberately naive rule, every search path treated as inside its
    /// run's `OUT_DIR` (no ordering by class), so a comparison that finds no
    /// difference on inputs that exercise the rule is vacuous.
    pub negative_control: bool,
}

/// Compare `plan` with the real build whose `-v` stderr is `log`, whose
/// target directory is `target`, whose sources sit at the plan's
/// `skeletonRoot`, and whose `cargo metadata` is `metadata`.
pub fn compare(plan: &Plan, log: &str, target: &Path, metadata: &Metadata) -> Report {
    compare_with(plan, log, target, metadata, CompareOptions::default(), None)
}

/// The env comparison's normal form, applied to both sides. What it removes
/// or replaces is what breakbulk replaces by design ("Env filtering" in
/// `docs/src/explanation/internals/planner.md`):
///
/// - `NUM_JOBS`: the plan records 1; `breakbulk-unit` sets the core count.
/// - In the dynamic-library path, Cargo's `deps` and profile directories
///   (inside `target`, but not inside any run's `OUT_DIR`), which have no
///   counterpart in breakbulk; a path left empty is dropped.
/// - `CARGO_TARGET_TMPDIR`, which the plan points at a fixed directory, and
///   `CARGO_BIN_EXE_*`, which name the bin's linked output rather than
///   Cargo's uplifted copy: only their presence is compared.
/// - `CARGO`, with symlinks resolved: Cargo sets it to its own executable
///   as the OS reports it, and the planner keeps the toolchain path it was
///   given when that is the same file (a symlink tree such as rust-overlay's
///   toolchains), so only the file is compared.
fn normal_env(
    env: &BTreeMap<String, String>,
    target: &Path,
    run_dirs: &[&str],
) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (k, v) in env {
        if k == "NUM_JOBS" {
            continue;
        }
        let v = if k == DYLIB_PATH_VAR {
            let kept: Vec<&str> = v
                .split(':')
                .filter(|e| {
                    !e.is_empty()
                        && (!Path::new(e).starts_with(target)
                            || run_dirs.iter().any(|d| Path::new(e).starts_with(d)))
                })
                .collect();
            if kept.is_empty() {
                continue;
            }
            kept.join(":")
        } else if k == "OUT_DIR"
            && (v.starts_with(OVERRIDDEN_OUT_DIR)
                || (Path::new(v).starts_with(target) && !Path::new(v).is_dir())
                || (Path::new(v).starts_with(target) && is_empty_dir(Path::new(v))))
        {
            // A package whose build script a `links` override replaces.
            // Classic layout: Cargo's OUT_DIR does not exist. New layout
            // (nightly 1.101): it exists, empty.
            "(a directory that does not exist)".to_owned()
        } else if k == "CARGO_TARGET_TMPDIR" || k.starts_with("CARGO_BIN_EXE_") {
            "(a path)".to_owned()
        } else if k == "CARGO" {
            std::fs::canonicalize(v).map_or_else(|_| v.clone(), |p| p.display().to_string())
        } else {
            v.clone()
        };
        out.insert(k.clone(), v);
    }
    out
}

/// Cargo's trim-paths arguments in their comparable form. Cargo remaps its
/// one build directory (`--remap-path-prefix=<target>=/cargo/build-dir`)
/// for every unit; the plan has the same pair once per run whose `out` the
/// unit names (each `out` copies the target directory around its
/// `OUT_DIR`, so it resolves to `<target>` here). Both are checked to name
/// `<target>` and dropped. When the planner turned
/// trim-paths on itself, it dropped Cargo's `--remap-path-scope` (breakbulk
/// sets the scope), so the real side's is dropped too.
///
/// The package remap differs by design when the real build reads a git or
/// registry source from `$CARGO_HOME` and the planner reads the same crate
/// from its vendor directory. Cargo remaps a git checkout's root
/// (`<checkouts>/<repo>/<rev>=/cargo/git/<repo hash>/<rev>`) or a registry's
/// source directory (`=/cargo/registry/<id>`) only when the package lies
/// there; any other package outside the workspace gets its own root remapped
/// to `/cargo/deps/<name>-<version>` (cargo `src/compiler/trim_paths.rs`,
/// `package_remap` and `git_checkout`, at 3c747ea3e; introduced by
/// 5b3974ed2). The real side's `$CARGO_HOME` form is therefore rewritten to
/// the vendored one, after checking that it names a directory holding `pkg`.
fn trim_paths_normal(
    args: &[String],
    target: &Path,
    plan: &Plan,
    traced: bool,
    pkg: Option<&Package>,
) -> Result<Vec<String>, String> {
    if !plan.trim_paths {
        return Ok(args.to_vec());
    }
    let mut out = Vec::new();
    for a in args {
        if let Some((from, to)) = a
            .strip_prefix("--remap-path-prefix=")
            .and_then(|r| r.rsplit_once('='))
        {
            if !traced && to == CARGO_BUILD_DIR_REMAP && Path::new(from) == target {
                continue;
            }
            if !traced && (to.starts_with("/cargo/git/") || to.starts_with("/cargo/registry/")) {
                let Some(p) = pkg.filter(|p| Path::new(p.dir()).starts_with(from)) else {
                    return Err(format!(
                        "the source remap `{a}` does not name the directory of {}",
                        pkg.map_or("the unit's package", |p| p.id.as_str())
                    ));
                };
                out.push(format!(
                    "--remap-path-prefix={}=/cargo/deps/{}-{}",
                    p.dir(),
                    p.name,
                    p.version
                ));
                continue;
            }
            if traced && to == CARGO_BUILD_DIR_REMAP {
                if Path::new(from) != target {
                    return Err(format!(
                        "the build-directory remap `{a}` does not name `{}`",
                        target.display()
                    ));
                }
                continue;
            }
        }
        if !traced && plan.trim_paths_default && a.starts_with("--remap-path-scope=") {
            continue;
        }
        out.push(a.clone());
    }
    Ok(out)
}

fn is_empty_dir(p: &Path) -> bool {
    std::fs::read_dir(p).is_ok_and(|mut d| d.next().is_none())
}

/// One line per variable that differs.
fn env_diff(want: &BTreeMap<String, String>, got: &BTreeMap<String, String>) -> Vec<String> {
    let keys: BTreeSet<&String> = want.keys().chain(got.keys()).collect();
    keys.into_iter()
        .filter(|k| want.get(*k) != got.get(*k))
        .map(|k| {
            format!(
                "    {k}: real {:?}, traced {:?}",
                want.get(k).map(String::as_str).unwrap_or("(unset)"),
                got.get(k).map(String::as_str).unwrap_or("(unset)")
            )
        })
        .collect()
}

/// [`compare`], with options.
pub fn compare_with(
    plan: &Plan,
    log: &str,
    target: &Path,
    metadata: &Metadata,
    opts: CompareOptions,
    doc_log: Option<&str>,
) -> Report {
    let mut report = Report::default();
    let real = real_compiles(log);
    let planned: BTreeSet<&UnitId> = plan
        .units
        .iter()
        .filter(|(_, u)| matches!(u, Unit::Compile(_)))
        .map(|(id, _)| id)
        .collect();
    let real_ids: BTreeSet<&UnitId> = real.keys().collect();
    for id in planned.difference(&real_ids) {
        report
            .problems
            .push(format!("{id}: in the plan, not in the real build"));
    }
    for id in real_ids.difference(&planned) {
        report.problems.push(format!(
            "{id}: in the real build, not in the plan: {}",
            real[*id].args.join(" ")
        ));
    }

    let mut resolver = Real {
        plan,
        skeleton: plan.skeleton_root.clone(),
        crate_dirs: metadata
            .packages
            .iter()
            .map(|p| (p.id.clone(), p.dir().to_owned()))
            .collect(),
        packages: metadata
            .packages
            .iter()
            .map(|p| (p.id.as_str(), p))
            .collect(),
        out_dirs: real
            .iter()
            .map(|(k, v)| (k.clone(), v.out_dir.clone()))
            .collect(),
        run_dirs: BTreeMap::new(),
    };
    // Every run's directory first: a run's parse needs its upstream runs'.
    let mut stdouts: BTreeMap<&UnitId, PathBuf> = BTreeMap::new();
    for (id, u) in &plan.units {
        if !matches!(u, Unit::Run(_)) {
            continue;
        }
        let Some((pkg, hash)) = id.strip_prefix("r-").and_then(|rest| rest.rsplit_once('-')) else {
            report.problems.push(format!("{id}: not a run id"));
            continue;
        };
        let Some((out_dir, stdout)) = find_run(target, pkg, hash) else {
            report
                .problems
                .push(format!("{id}: the real build has no such build-script run"));
            continue;
        };
        stdouts.insert(id, stdout);
        resolver
            .run_dirs
            .insert(id.clone(), out_dir.display().to_string());
    }
    let mut outputs: BTreeMap<String, BuildOutput> = BTreeMap::new();
    for (id, stdout) in &stdouts {
        let Unit::Run(r) = &plan.units[*id] else {
            continue;
        };
        let text = std::fs::read(stdout).unwrap_or_default();
        let out_dir = PathBuf::from(&resolver.run_dirs[*id]);
        let upstream: Vec<PathBuf> = r
            .metadata_from
            .iter()
            .filter_map(|m| resolver.run_dirs.get(m).map(PathBuf::from))
            .collect();
        let ctx = ParseContext {
            pkg_descr: &r.package,
            out_dir: &out_dir,
            nightly_features_allowed: r.nightly_features_allowed,
            targets: &r.targets,
            rust_version: r.rust_version.as_deref(),
            upstream_out_dirs: &upstream,
        };
        match parse(&text, &ctx) {
            Ok(o) => {
                outputs.insert((*id).clone(), o);
            }
            Err(e) => report.problems.push(format!("{id}: {}", e.0)),
        }
    }
    if opts.negative_control {
        for o in outputs.values_mut() {
            for p in &mut o.library_paths {
                p.in_out_dir = true;
            }
        }
    }
    let run_dirs: Vec<&str> = resolver.run_dirs.values().map(String::as_str).collect();
    let name_of = |id: &UnitId| match &plan.units[id] {
        Unit::Compile(CompileUnit { krate, .. }) => krate.name.clone(),
        Unit::Run(r) => r.package.clone(),
    };

    for id in planned.intersection(&real_ids) {
        let rendered = match render_unit(plan, id, &resolver) {
            Ok(RenderedUnit::Compile(c)) => c,
            Ok(_) => continue,
            Err(e) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        let lookup = |f: &str| outputs.get(f);
        let got = match expand_args(&rendered.args, lookup) {
            Ok(a) => a,
            Err(e) => {
                report.problems.push(format!("{id}: {}", e.0));
                continue;
            }
        };
        report.compared += 1;
        let pkg = match &plan.units[*id] {
            Unit::Compile(c) => resolver.packages.get(c.package.as_str()).copied(),
            Unit::Run(_) => None,
        };
        let (got, want) = match (
            trim_paths_normal(&got, target, plan, true, pkg),
            trim_paths_normal(&real[*id].args, target, plan, false, pkg),
        ) {
            (Ok(g), Ok(w)) => (g, w),
            (Err(e), _) | (_, Err(e)) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        if got != want {
            report.problems.push(format!(
                "{id} ({}): argv differs\n    real:   {}\n    traced: {}",
                name_of(id),
                want.join(" "),
                got.join(" ")
            ));
        }
        if opts.env {
            let env = expand_env(&rendered.env, &rendered.env_splices, lookup).and_then(|mut e| {
                expand_dylib_path(&mut e, &rendered.dylib_path_from, lookup)?;
                Ok(e)
            });
            match env {
                Ok(e) => {
                    let d = env_diff(
                        &normal_env(&real[*id].env, target, &run_dirs),
                        &normal_env(&e, target, &run_dirs),
                    );
                    if !d.is_empty() {
                        report.problems.push(format!(
                            "{id} ({}): env differs\n{}",
                            name_of(id),
                            d.join("\n")
                        ));
                    }
                }
                Err(e) => report.problems.push(format!("{id}: {}", e.0)),
            }
        }
    }

    if opts.env {
        let real_runs = real_runs(log);
        for (id, out_dir) in &resolver.run_dirs {
            let Some(want) = real_runs.get(out_dir) else {
                report.problems.push(format!(
                    "{id}: the real build's log has no run with OUT_DIR {out_dir}"
                ));
                continue;
            };
            let r = match render_unit(plan, id, &resolver) {
                Ok(RenderedUnit::Run(r)) => r,
                Ok(_) => continue,
                Err(e) => {
                    report.problems.push(format!("{id}: {e}"));
                    continue;
                }
            };
            let md: Vec<MetadataFile> = r
                .metadata_from
                .iter()
                .filter_map(|m| {
                    let Unit::Run(u) = plan.units.get(m)? else {
                        return None;
                    };
                    Some(MetadataFile {
                        links: u.links.clone()?,
                        metadata: outputs.get(m)?.metadata.clone(),
                        out: resolver.run_dirs.get(m).cloned(),
                    })
                })
                .collect();
            let mut got = run_env(&r, Path::new(out_dir), &md);
            if let Err(e) = expand_dylib_path(&mut got, &r.dylib_path_from, |f| outputs.get(f)) {
                report.problems.push(format!("{id}: {}", e.0));
                continue;
            }
            report.compared += 1;
            let d = env_diff(
                &normal_env(want, target, &run_dirs),
                &normal_env(&got, target, &run_dirs),
            );
            if !d.is_empty() {
                report.problems.push(format!(
                    "{id} ({}): run env differs\n{}",
                    name_of(id),
                    d.join("\n")
                ));
            }
        }
    }

    if let Some(doc_log) = doc_log {
        compare_doctests(
            plan,
            doc_log,
            target,
            opts,
            &resolver,
            &outputs,
            &run_dirs,
            &mut report,
        );
    }
    report
}

/// The doctest half of [`compare_with`]: each traced `rustdoc --test` against
/// the one a real `cargo test --doc -vv` ran (`doc_log`), keyed by
/// `CARGO_PKG_NAME`. The `-L` list of every run's search paths is rebuilt
/// with `breakbulk-unit`'s own [`doctest::search_paths`] and the env with its
/// dynamic-library path rule.
#[allow(clippy::too_many_arguments)]
fn compare_doctests(
    plan: &Plan,
    doc_log: &str,
    target: &Path,
    opts: CompareOptions,
    resolver: &Real<'_>,
    outputs: &BTreeMap<String, BuildOutput>,
    run_dirs: &[&str],
    report: &mut Report,
) {
    let mut real: BTreeMap<String, RealProcess> = BTreeMap::new();
    for p in real_processes(doc_log) {
        if !p.program.ends_with("rustdoc") || !p.args.iter().any(|a| a == "--test") {
            continue;
        }
        let Some(name) = p.env.get("CARGO_PKG_NAME") else {
            report
                .problems
                .push("the doctest log has no env (not -vv?)".to_owned());
            return;
        };
        real.insert(format!("d-{name}"), p);
    }
    let planned: BTreeSet<&String> = plan.doctests.keys().collect();
    let real_ids: BTreeSet<&String> = real.keys().collect();
    for id in planned.difference(&real_ids) {
        report.problems.push(format!(
            "{id}: in the plan, not in the real `cargo test --doc`"
        ));
    }
    for id in real_ids.difference(&planned) {
        report.problems.push(format!(
            "{id}: in the real `cargo test --doc`, not in the plan"
        ));
    }
    let lookup = |f: &str| outputs.get(f);
    for id in planned.intersection(&real_ids) {
        let d = match render_doctest(plan, id, resolver) {
            Ok(d) => d,
            Err(e) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        let (before, after) = d.compile.args.split_at(d.search_paths_at);
        let got = (|| -> Result<Vec<String>, String> {
            let mut a = expand_args(before, lookup).map_err(|e| e.0)?;
            for p in doctest::search_paths(&d.search_paths_of, &d.search_paths_literals, lookup)
                .map_err(|e| e.0)?
            {
                a.extend(["-L".to_owned(), p]);
            }
            a.extend(expand_args(after, lookup).map_err(|e| e.0)?);
            Ok(a)
        })();
        let got = match got {
            Ok(a) => a,
            Err(e) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        report.compared += 1;
        // Cargo's own `-L dependency=` directories: breakbulk passes its own.
        // The classic layout has one `deps` directory; the new layout one
        // unit directory (`…/build/<pkg>/<hash>/out`) per dependency, the
        // build script's compile included. A build script's own
        // `rustc-link-search=dependency=…` is in the traced list too.
        let r = &real[*id];
        let traced_deps: BTreeSet<&str> = got
            .windows(2)
            .filter(|w| w[0] == "-L")
            .filter_map(|w| w[1].strip_prefix("dependency="))
            .collect();
        let mut want = Vec::new();
        let mut i = 0;
        while i < r.args.len() {
            if r.args[i] == "-L"
                && r.args
                    .get(i + 1)
                    .and_then(|v| v.strip_prefix("dependency="))
                    .is_some_and(|v| {
                        v.ends_with("/deps")
                            || (v.ends_with("/out")
                                && v.contains("/build/")
                                && !traced_deps.contains(v))
                    })
            {
                i += 2;
                continue;
            }
            want.push(r.args[i].clone());
            i += 1;
        }
        let pkg = resolver
            .packages
            .get(plan.doctests[id.as_str()].package.as_str())
            .copied();
        let (got, want) = match (
            trim_paths_normal(&got, target, plan, true, pkg),
            trim_paths_normal(&want, target, plan, false, pkg),
        ) {
            (Ok(g), Ok(w)) => (g, w),
            (Err(e), _) | (_, Err(e)) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        if got != want {
            report.problems.push(format!(
                "{id}: argv differs\n    real:   {}\n    traced: {}",
                want.join(" "),
                got.join(" ")
            ));
        }
        if opts.env {
            let env =
                expand_env(&d.compile.env, &d.compile.env_splices, lookup).and_then(|mut e| {
                    prepend_dylib_path(&mut e, &d.compile.dylib_path_from, lookup)?;
                    Ok(e)
                });
            match env {
                Ok(e) => {
                    let diff = env_diff(
                        &normal_env(&r.env, target, run_dirs),
                        &normal_env(&e, target, run_dirs),
                    );
                    if !diff.is_empty() {
                        report
                            .problems
                            .push(format!("{id}: env differs\n{}", diff.join("\n")));
                    }
                }
                Err(e) => report.problems.push(format!("{id}: {}", e.0)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split() {
        assert_eq!(
            shell_split(r#"rustc --check-cfg 'cfg(feature, values("a"))' a\ b -C x=1"#),
            [
                "rustc",
                "--check-cfg",
                r#"cfg(feature, values("a"))"#,
                "a b",
                "-C",
                "x=1"
            ]
        );
    }

    #[test]
    fn cargo_compared_as_a_file() {
        let dir = std::env::temp_dir().join(format!("bb-golden-cargo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let real = dir.join("cargo-real");
        let link = dir.join("cargo-link");
        let other = dir.join("cargo-other");
        std::fs::write(&real, "").unwrap();
        std::fs::write(&other, "").unwrap();
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let env = |v: &Path| BTreeMap::from([("CARGO".to_owned(), v.display().to_string())]);
        let t = Path::new("/nonexistent-target");
        assert_eq!(
            normal_env(&env(&real), t, &[]),
            normal_env(&env(&link), t, &[])
        );
        assert_ne!(
            normal_env(&env(&real), t, &[]),
            normal_env(&env(&other), t, &[])
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn trim_paths_forms() {
        let mut plan: Plan = serde_json::from_value(serde_json::json!({
            "version": 2, "kind": "build", "cargo": "1.101.0", "rustc": "1.101.0",
            "host": "h", "target": "t",
            "variant": { "profile": "dev", "features": [], "mode": "build" },
            "skeletonRoot": "/build/skeleton", "trimPaths": true, "trimPathsDefault": true,
            "units": {}, "roots": []
        }))
        .unwrap();
        let t = Path::new("/tmp/t");
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let real = a(&[
            "--remap-path-scope=all",
            "--remap-path-prefix=/s/ws=.",
            "--remap-path-prefix=/tmp/t=/cargo/build-dir",
            "-C",
            "x",
        ]);
        let traced = a(&[
            "--remap-path-prefix=/s/ws=.",
            "--remap-path-prefix=/tmp/t=/cargo/build-dir",
            "--remap-path-prefix=/tmp/t=/cargo/build-dir",
            "-C",
            "x",
        ]);
        let want = a(&["--remap-path-prefix=/s/ws=.", "-C", "x"]);
        assert_eq!(
            trim_paths_normal(&real, t, &plan, false, None).unwrap(),
            want
        );
        assert_eq!(
            trim_paths_normal(&traced, t, &plan, true, None).unwrap(),
            want
        );
        // A remap that names another directory than <target>.
        let wrong = a(&["--remap-path-prefix=/x=/cargo/build-dir"]);
        assert!(trim_paths_normal(&wrong, t, &plan, true, None).is_err());
        // A git package read from $CARGO_HOME by the real build: Cargo
        // remaps the checkout root; the vendored plan remaps the package
        // root to /cargo/deps/<name>-<version>.
        let pkg: Package = serde_json::from_value(serde_json::json!({
            "id": "git+file:///r#a@1.0.0", "name": "a", "version": "1.0.0",
            "source": "git+file:///r#b7d7b61", "targets": [],
            "manifest_path": "/h/git/checkouts/r-1/b7d7b61/crates/a/Cargo.toml"
        }))
        .unwrap();
        let vendored =
            a(&["--remap-path-prefix=/h/git/checkouts/r-1/b7d7b61/crates/a=/cargo/deps/a-1.0.0"]);
        for to in [
            "/cargo/git/9d632b146c62ec3e/b7d7b61",
            "/cargo/registry/0123",
        ] {
            let real = vec![format!(
                "--remap-path-prefix=/h/git/checkouts/r-1/b7d7b61={to}"
            )];
            assert_eq!(
                trim_paths_normal(&real, t, &plan, false, Some(&pkg)).unwrap(),
                vendored
            );
            // Without the package, or naming a directory not holding it.
            assert!(trim_paths_normal(&real, t, &plan, false, None).is_err());
            let other = vec![format!(
                "--remap-path-prefix=/h/git/checkouts/r-2/b7d7b61={to}"
            )];
            assert!(trim_paths_normal(&other, t, &plan, false, Some(&pkg)).is_err());
        }
        // The traced side is compared as it is.
        assert_eq!(
            trim_paths_normal(&vendored, t, &plan, true, Some(&pkg)).unwrap(),
            vendored
        );
        // The project's own setting: its scope is compared.
        plan.trim_paths_default = false;
        assert_eq!(
            trim_paths_normal(&real, t, &plan, false, None).unwrap()[0],
            "--remap-path-scope=all"
        );
    }

    #[test]
    fn real_log() {
        let log = "   Compiling x v0.1.0\n     Running `/nix/store/r/bin/rustc --crate-name x --edition=2021 src/lib.rs --out-dir /t/debug/deps -C metadata=ab -C incremental=/t/i -L dependency=/t/debug/deps --cfg 'feature=\"y\"'`\n";
        let r = real_compiles(log);
        assert_eq!(
            r["c-ab"].args,
            [
                "--crate-name",
                "x",
                "--edition=2021",
                "src/lib.rs",
                "-C",
                "metadata=ab",
                "--cfg",
                "feature=\"y\""
            ]
        );
        assert_eq!(r["c-ab"].out_dir, "/t/debug/deps");
    }
}
