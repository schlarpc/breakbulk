//! `breakbulk-plan`: trace one (workspace, target, variant, plan kind) and
//! write `plan.json`.
//!
//! ```text
//! breakbulk-plan --cargo C --rustc R --rustdoc D --shim S \
//!   --skeleton DIR [--workspace REL] [--canonical-root /build/skeleton] \
//!   --kind build|test --target TRIPLE --profile P [--features F]… \
//!   [--all-features] [--no-default-features] [-p PKG]… \
//!   [--config FILE-OR-VALUE]… [--spec FILE] --scratch DIR [--forbid PATH]… --out plan.json
//! ```

use std::process::ExitCode;

use breakbulk_format::PlanKind;
use breakbulk_plan::trace::Options;

fn usage() -> ! {
    eprintln!(
        "usage: breakbulk-plan --cargo C --rustc R --rustdoc D --shim S --skeleton DIR \
         [--workspace REL] [--canonical-root DIR] --kind build|test --target TRIPLE \
         --profile P [--features F]... [--all-features] [--no-default-features] [-p PKG]... \
         [--config X]... [--spec FILE] --scratch DIR [--forbid PATH]... --out FILE"
    );
    std::process::exit(2)
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let mut opts = Options {
        cargo: String::new(),
        rustc: String::new(),
        rustdoc: String::new(),
        shim: String::new(),
        skeleton: String::new(),
        workspace: String::new(),
        canonical_root: None,
        kind: PlanKind::Build,
        target: String::new(),
        profile: "dev".into(),
        features: Vec::new(),
        all_features: false,
        no_default_features: false,
        packages: Vec::new(),
        configs: Vec::new(),
        scratch: String::new(),
        forbidden: Vec::new(),
        spec: None,
    };
    let mut out = None;
    while let Some(a) = args.next() {
        let mut val = || args.next().unwrap_or_else(|| usage());
        match a.as_str() {
            "--cargo" => opts.cargo = val(),
            "--rustc" => opts.rustc = val(),
            "--rustdoc" => opts.rustdoc = val(),
            "--shim" => opts.shim = val(),
            "--skeleton" => opts.skeleton = val(),
            "--workspace" => opts.workspace = val(),
            "--canonical-root" => opts.canonical_root = Some(val()),
            "--kind" => {
                opts.kind = match val().as_str() {
                    "build" => PlanKind::Build,
                    "test" => PlanKind::Test,
                    _ => usage(),
                }
            }
            "--target" => opts.target = val(),
            "--profile" => opts.profile = val(),
            "--features" => opts.features.extend(
                val()
                    .split([',', ' '])
                    .filter(|f| !f.is_empty())
                    .map(str::to_owned),
            ),
            "--all-features" => opts.all_features = true,
            "--no-default-features" => opts.no_default_features = true,
            "-p" | "--package" => opts.packages.push(val()),
            "--config" => opts.configs.push(val()),
            "--scratch" => opts.scratch = val(),
            "--forbid" => opts.forbidden.push(val()),
            "--spec" => opts.spec = Some(val()),
            "--out" => out = Some(val()),
            _ => usage(),
        }
    }
    if [
        &opts.cargo,
        &opts.rustc,
        &opts.rustdoc,
        &opts.shim,
        &opts.skeleton,
        &opts.target,
        &opts.scratch,
    ]
    .iter()
    .any(|s| s.is_empty())
    {
        usage();
    }
    let Some(out) = out else { usage() };
    match breakbulk_plan::plan(&opts) {
        Ok(plan) => {
            let mut text = plan.to_canonical_json();
            text.push('\n');
            if let Err(e) = std::fs::write(&out, text) {
                eprintln!("breakbulk-plan: writing {out}: {e}");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("breakbulk-plan: {e}");
            ExitCode::FAILURE
        }
    }
}
