//! `breakbulk-plan-golden`: the trace golden test. Compares a traced
//! `plan.json` with a real `cargo … -v` build of the same sources at the
//! plan's `skeletonRoot` (see `breakbulk_plan::golden`).
//!
//! ```text
//! breakbulk-plan-golden --plan plan.json --log build.log \
//!   --target-dir DIR --metadata metadata.json
//! ```

use std::path::PathBuf;
use std::process::ExitCode;

use breakbulk_format::Plan;
use breakbulk_plan::golden::compare;
use breakbulk_plan::records::Metadata;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let (mut plan, mut log, mut target, mut metadata) = (None, None, None, None);
    while let Some(a) = args.next() {
        let v = args.next();
        match a.as_str() {
            "--plan" => plan = v,
            "--log" => log = v,
            "--target-dir" => target = v,
            "--metadata" => metadata = v,
            _ => v.map_or((), |_| ()),
        }
    }
    let (Some(plan), Some(log), Some(target), Some(metadata)) = (plan, log, target, metadata)
    else {
        eprintln!(
            "usage: breakbulk-plan-golden --plan FILE --log FILE --target-dir DIR --metadata FILE"
        );
        return ExitCode::from(2);
    };
    let read = |p: &str| std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{p}: {e}"));
    let plan = Plan::from_json(&read(&plan)).unwrap_or_else(|e| panic!("{e}"));
    let metadata =
        Metadata::read(PathBuf::from(&metadata).as_path()).unwrap_or_else(|e| panic!("{e}"));
    let report = compare(&plan, &read(&log), &PathBuf::from(target), &metadata);
    println!(
        "compared {} compile units (Cargo {})",
        report.compared, plan.cargo
    );
    if report.problems.is_empty() {
        println!("golden: traced argv equals the real build's for every unit");
        ExitCode::SUCCESS
    } else {
        for p in &report.problems {
            println!("{p}");
        }
        ExitCode::FAILURE
    }
}
