//! `breakbulk-plan`: trace one (workspace, target, variant, plan kind) and
//! write `plan.json`.
//!
//! ```text
//! breakbulk-plan --cargo C --rustc R --rustdoc D --shim S \
//!   --skeleton DIR [--workspace REL] [--canonical-root /build/skeleton] \
//!   --kind build|test|bench [--mode build|check|clippy|coverage] \
//!   [--clippy-driver PATH [--clippy-option NAME]] [--clippy-arg A]… --target TRIPLE --profile P [--features F]… \
//!   [--all-features] [--no-default-features] [-p PKG]… \
//!   [--config FILE-OR-VALUE]… [--spec FILE] --capabilities FILE \
//!   [--trim-paths auto|on|off] --scratch DIR [--forbid PATH]… --out plan.json \
//!   [--cargo-env cargo-env.json]
//!
//! breakbulk-plan --cargo-env-only --rustc R --skeleton DIR [--workspace REL] \
//!   --target TRIPLE [--spec FILE] [--capabilities FILE --profile P [--trim-paths auto|on|off]] \
//!   --scratch DIR --cargo-env cargo-env.json
//!
//! breakbulk-plan --build-target-only --skeleton DIR [--workspace REL] --out FILE
//! ```
//!
//! `--cargo-env-only` writes only the dev shell's `cargo-env.json`, from the
//! project's Cargo config files and rustc, without running Cargo; with
//! `--capabilities`, also the trim-paths variable for `--profile`, by the
//! planner's rule from the workspace root's `Cargo.toml` and the config
//! files, read as TOML (decision 135).
//!
//! `--build-target-only` writes `{"buildTarget": [...] | null}`: the
//! project's `build.target` from its config files (not `$CARGO_HOME`'s or
//! the environment's), merged by Cargo's rules, as written.
//!
//! `--capabilities` is the toolchain's capabilities as JSON
//! (`breakbulk_format::Capabilities`, the Nix library's `toolchainFacts`):
//! whether Cargo has `trim-paths` and allows unstable features.

use std::process::ExitCode;

use breakbulk_format::{PlanKind, VariantMode};
use breakbulk_plan::trace::Options;

fn usage() -> ! {
    eprintln!(
        "usage: breakbulk-plan --cargo C --rustc R --rustdoc D --shim S --skeleton DIR \
         [--workspace REL] [--canonical-root DIR] --kind build|test|bench \
         [--mode build|check|clippy|coverage] [--clippy-driver PATH] [--clippy-option NAME] \
         [--clippy-arg A]... \
         --target TRIPLE \
         --profile P [--features F]... [--all-features] [--no-default-features] [-p PKG]... \
         [--config X]... [--spec FILE] --capabilities FILE [--trim-paths auto|on|off] \
         --scratch DIR [--forbid PATH]... --out FILE [--cargo-env FILE]\n       \
         breakbulk-plan --cargo-env-only --rustc R --skeleton DIR [--workspace REL] \
         --target TRIPLE [--spec FILE] [--capabilities FILE --profile P [--trim-paths auto|on|off]] \
         --scratch DIR --cargo-env FILE\n       \
         breakbulk-plan --build-target-only --skeleton DIR [--workspace REL] --out FILE"
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
        mode: VariantMode::Build,
        clippy_driver: None,
        clippy_option: None,
        clippy_args: Vec::new(),
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
        trim_paths: Default::default(),
        trim_paths_default: false,
        std_vendor: None,
        capabilities: None,
    };
    let mut out = None;
    let mut cargo_env_out: Option<String> = None;
    let mut cargo_env_only = false;
    let mut build_target_only = false;
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
                    "bench" => PlanKind::Bench,
                    _ => usage(),
                }
            }
            "--mode" => {
                opts.mode = match val().as_str() {
                    "build" => VariantMode::Build,
                    "check" => VariantMode::Check,
                    "clippy" => VariantMode::Clippy,
                    "coverage" => VariantMode::Coverage,
                    _ => usage(),
                }
            }
            "--clippy-driver" => opts.clippy_driver = Some(val()),
            "--clippy-option" => opts.clippy_option = Some(val()),
            "--clippy-arg" => opts.clippy_args.push(val()),
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
            "--trim-paths" => {
                opts.trim_paths =
                    breakbulk_plan::trim_paths::Mode::parse(&val()).unwrap_or_else(|| usage())
            }
            "--capabilities" => match breakbulk_format::Capabilities::read(&val()) {
                Ok(c) => opts.capabilities = Some(c),
                Err(e) => {
                    eprintln!("breakbulk-plan: --capabilities: {e}");
                    return ExitCode::FAILURE;
                }
            },
            "--out" => out = Some(val()),
            "--cargo-env" => cargo_env_out = Some(val()),
            "--cargo-env-only" => cargo_env_only = true,
            "--build-target-only" => build_target_only = true,
            _ => usage(),
        }
    }
    if cargo_env_only {
        return write_cargo_env_only(&opts, cargo_env_out);
    }
    if build_target_only {
        return write_build_target_only(&opts, out);
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
    if opts.capabilities.is_none() {
        usage();
    }
    match breakbulk_plan::plan_with_cargo_env(&opts) {
        Ok((plan, cargo_env)) => {
            let mut text = plan.to_canonical_json();
            text.push('\n');
            if let Err(e) = std::fs::write(&out, text) {
                eprintln!("breakbulk-plan: writing {out}: {e}");
                return ExitCode::FAILURE;
            }
            if let Some(path) = cargo_env_out {
                let text = serde_json::to_string(&cargo_env).expect("strings serialize");
                if let Err(e) = std::fs::write(&path, text) {
                    eprintln!("breakbulk-plan: writing {path}: {e}");
                    return ExitCode::FAILURE;
                }
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("breakbulk-plan: {e}");
            ExitCode::FAILURE
        }
    }
}

fn write_build_target_only(opts: &Options, out: Option<String>) -> ExitCode {
    let Some(out) = out else { usage() };
    if opts.skeleton.is_empty() {
        usage();
    }
    match breakbulk_plan::build_target(opts) {
        Ok(t) => {
            let text = serde_json::json!({ "buildTarget": t }).to_string();
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

fn write_cargo_env_only(opts: &Options, out: Option<String>) -> ExitCode {
    let Some(out) = out else { usage() };
    if [&opts.rustc, &opts.skeleton, &opts.target, &opts.scratch]
        .iter()
        .any(|s| s.is_empty())
    {
        usage();
    }
    match breakbulk_plan::cargo_env(opts) {
        Ok(cargo_env) => {
            let text = serde_json::to_string(&cargo_env).expect("strings serialize");
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
