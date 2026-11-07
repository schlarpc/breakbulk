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

use breakbulk_format::{CompileUnit, Plan, Reference, Resolve, Unit, UnitId, render_unit};
use breakbulk_unit::directives::{BuildOutput, MetadataFile, ParseContext, parse};
use breakbulk_unit::run::run_env;
use breakbulk_unit::spec::RenderedUnit;
use breakbulk_unit::splice::{DYLIB_PATH_VAR, expand_args, expand_dylib_path, expand_env};

use crate::graph::OVERRIDDEN_OUT_DIR;
use crate::records::Metadata;

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
/// `-L dependency=<dir>` is dropped when `<dir>` is a `deps` directory or
/// some compile's `--out-dir` (in the new layout, a dependency's own
/// directory): breakbulk passes its own instead. A build script's
/// `rustc-link-search=dependency=…` is kept.
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
                "-L" if next
                    .strip_prefix("dependency=")
                    .is_some_and(|d| d.ends_with("/deps") || out_dirs.contains(d)) =>
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
    out_dirs: BTreeMap<UnitId, String>,
    run_dirs: BTreeMap<UnitId, String>,
}

impl Resolve for Real<'_> {
    type Error = String;
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
            Reference::Out(o) => match self.plan.units.get(&o.out) {
                Some(Unit::Run(_)) => self
                    .run_dirs
                    .get(&o.out)
                    .cloned()
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
}

/// Compare `plan` with the real build whose `-v` stderr is `log`, whose
/// target directory is `target`, whose sources sit at the plan's
/// `skeletonRoot`, and whose `cargo metadata` is `metadata`.
pub fn compare(plan: &Plan, log: &str, target: &Path, metadata: &Metadata) -> Report {
    compare_with(plan, log, target, metadata, CompareOptions::default())
}

/// The env comparison's normal form, applied to both sides. What it removes
/// or replaces is what breakbulk replaces by design ("Env filtering" in
/// `docs/implementation.md`):
///
/// - `NUM_JOBS`: the plan records 1; `breakbulk-unit` sets the core count.
/// - In the dynamic-library path, Cargo's `deps` and profile directories
///   (inside `target`, but not inside any run's `OUT_DIR`), which have no
///   counterpart in breakbulk; a path left empty is dropped.
/// - `CARGO_TARGET_TMPDIR`, which the plan points at a fixed directory, and
///   `CARGO_BIN_EXE_*`, which name the bin's linked output rather than
///   Cargo's uplifted copy: only their presence is compared.
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
                || (Path::new(v).starts_with(target) && !Path::new(v).is_dir()))
        {
            // A package whose build script a `links` override replaces.
            "(a directory that does not exist)".to_owned()
        } else if k == "CARGO_TARGET_TMPDIR" || k.starts_with("CARGO_BIN_EXE_") {
            "(a path)".to_owned()
        } else {
            v.clone()
        };
        out.insert(k.clone(), v);
    }
    out
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
        let want = &real[*id].args;
        if &got != want {
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
    report
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
