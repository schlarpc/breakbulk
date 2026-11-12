//! `breakbulk-plan-golden`: the trace golden test. Compares a traced
//! `plan.json` with a real `cargo … -v` build of the same sources at the
//! plan's `skeletonRoot` (see `breakbulk_plan::golden`).
//!
//! ```text
//! breakbulk-plan-golden --plan plan.json --log build.log \
//!   --target-dir DIR --metadata metadata.json [--doc-log doc.log] \
//!   [--env] [--negative-control]
//! ```
//!
//! With `--env` (and a `-vv` log), env is compared too: every compile's and
//! every build-script run's. `--negative-control` expands with a naive rule
//! (no search-path ordering) and should exit non-zero on inputs that
//! exercise it. `--doc-log` (a `cargo test -vv` log, with a test plan)
//! also compares every traced `rustdoc --test`.

use std::path::PathBuf;
use std::process::ExitCode;

use breakbulk_format::Plan;
use breakbulk_plan::golden::{CompareOptions, compare_with};
use breakbulk_plan::records::Metadata;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let (mut plan, mut log, mut target, mut metadata) = (None, None, None, None);
    let mut doc_log = None;
    let mut opts = CompareOptions::default();
    while let Some(a) = args.next() {
        if a == "--env" {
            opts.env = true;
            continue;
        }
        if a == "--negative-control" {
            opts.negative_control = true;
            continue;
        }
        let v = args.next();
        match a.as_str() {
            "--plan" => plan = v,
            "--log" => log = v,
            "--target-dir" => target = v,
            "--metadata" => metadata = v,
            "--doc-log" => doc_log = v,
            _ => v.map_or((), |_| ()),
        }
    }
    let (Some(plan), Some(log), Some(target), Some(metadata)) = (plan, log, target, metadata)
    else {
        eprintln!(
            "usage: breakbulk-plan-golden --plan FILE --log FILE --target-dir DIR --metadata FILE [--doc-log FILE] [--env] [--negative-control]"
        );
        return ExitCode::from(2);
    };
    let read = |p: &str| std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{p}: {e}"));
    let plan = Plan::from_json(&read(&plan)).unwrap_or_else(|e| panic!("{e}"));
    let metadata =
        Metadata::read(PathBuf::from(&metadata).as_path()).unwrap_or_else(|e| panic!("{e}"));
    let doc_log = doc_log.map(|p| read(&p));
    let report = compare_with(
        &plan,
        &read(&log),
        &PathBuf::from(target),
        &metadata,
        opts,
        doc_log.as_deref(),
    );
    println!(
        "compared {} units{} (Cargo {})",
        report.compared,
        if opts.env {
            ", argv and env"
        } else {
            ", argv only"
        },
        plan.cargo
    );
    if report.problems.is_empty() {
        println!("golden: the traced plan equals the real build for every unit");
        ExitCode::SUCCESS
    } else {
        for p in &report.problems {
            println!("{p}");
        }
        ExitCode::FAILURE
    }
}
