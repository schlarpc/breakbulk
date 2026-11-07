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
//! (`--out-dir`, `-L dependency=`, `-C incremental=`). Not compared: env
//! (`-v` does not print it) and the program (the planner passes rustc by
//! absolute path).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use breakbulk_format::{CompileUnit, Plan, Reference, Resolve, Unit, UnitId, render_unit};
use breakbulk_unit::directives::{BuildOutput, ParseContext, parse};
use breakbulk_unit::spec::RenderedUnit;
use breakbulk_unit::splice::expand_args;

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

/// One rustc command from the real build: its arguments with breakbulk's
/// replacements stripped, and its `--out-dir`.
#[derive(Clone, Debug)]
pub struct RealCompile {
    pub args: Vec<String>,
    pub out_dir: String,
}

/// The rustc commands of a `cargo … -v` log, keyed `c-<-C metadata>`.
pub fn real_compiles(log: &str) -> BTreeMap<UnitId, RealCompile> {
    let mut out = BTreeMap::new();
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
        if !argv[prog].ends_with("rustc") || !argv.iter().any(|a| a == "--crate-name") {
            continue;
        }
        let args = &argv[prog + 1..];
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
                "-L" if next.starts_with("dependency=") => {
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
                },
            );
        }
    }
    out
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

/// Compare `plan` with the real build whose `-v` stderr is `log`, whose
/// target directory is `target`, whose sources sit at the plan's
/// `skeletonRoot`, and whose `cargo metadata` is `metadata`.
pub fn compare(plan: &Plan, log: &str, target: &Path, metadata: &Metadata) -> Report {
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
    let mut outputs: BTreeMap<String, BuildOutput> = BTreeMap::new();
    for (id, u) in &plan.units {
        let Unit::Run(r) = u else { continue };
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
        let text = std::fs::read(&stdout).unwrap_or_default();
        let ctx = ParseContext {
            pkg_descr: &r.package,
            out_dir: &out_dir,
            nightly_features_allowed: r.nightly_features_allowed,
            targets: &r.targets,
            rust_version: r.rust_version.as_deref(),
        };
        match parse(&text, &ctx) {
            Ok(o) => {
                outputs.insert(id.clone(), o);
            }
            Err(e) => report.problems.push(format!("{id}: {}", e.0)),
        }
        resolver
            .run_dirs
            .insert(id.clone(), out_dir.display().to_string());
    }

    for id in planned.intersection(&real_ids) {
        let rendered = match render_unit(plan, id, &resolver) {
            Ok(RenderedUnit::Compile(c)) => c,
            Ok(_) => continue,
            Err(e) => {
                report.problems.push(format!("{id}: {e}"));
                continue;
            }
        };
        let got = match expand_args(&rendered.args, |f| outputs.get(f)) {
            Ok(a) => a,
            Err(e) => {
                report.problems.push(format!("{id}: {}", e.0));
                continue;
            }
        };
        report.compared += 1;
        let want = &real[*id].args;
        if &got != want {
            let name = match &plan.units[*id] {
                Unit::Compile(CompileUnit { krate, .. }) => krate.name.clone(),
                _ => String::new(),
            };
            report.problems.push(format!(
                "{id} ({name}): argv differs\n    real:   {}\n    traced: {}",
                want.join(" "),
                got.join(" ")
            ));
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
