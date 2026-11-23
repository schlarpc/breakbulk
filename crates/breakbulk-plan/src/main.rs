//! `breakbulk-plan`: trace one (workspace, target, variant, plan kind) and
//! write `plan.json`.
//!
//! ```text
//! breakbulk-plan --cargo C --rustc R --rustdoc D --shim S \
//!   --skeleton DIR [--workspace REL] [--canonical-root /build/skeleton] \
//!   --kind build|test|bench|doc [--mode build|check] --cargo-arg A… \
//!   [--rustc-wrapper PATH] [--rustc-workspace-wrapper PATH] [--wrapper-env K=V]… \
//!   [--variant-option NAME] --target TRIPLE --profile P [--features F]… \
//!   [--all-features] [--no-default-features] [-p PKG]… \
//!   [--config FILE-OR-VALUE]… [--cargo-config FILE] [--spec FILE] --capabilities FILE \
//!   [--crates-io-source NAME --crates-io-directory DIR] \
//!   [--trim-paths auto|on|off] --scratch DIR [--forbid PATH]… --out plan.json \
//!   [--cargo-env cargo-env.json]
//!
//! breakbulk-plan --cargo-env-only --rustc R --skeleton DIR [--workspace REL] \
//!   --target TRIPLE [--spec FILE] [--capabilities FILE --profile P… [--trim-paths auto|on|off]] \
//!   --scratch DIR --cargo-env cargo-env.json
//!
//! breakbulk-plan --build-target-only --skeleton DIR [--workspace REL] --out FILE
//! ```
//!
//! `--cargo-env-only` writes only the dev shell's `cargo-env.json`, from the
//! project's Cargo config files and rustc, without running Cargo; with
//! `--capabilities`, also the trim-paths variable for each `--profile`, by the
//! planner's rule from the workspace root's `Cargo.toml` and the config
//! files, read as TOML rather than by running Cargo, so the dev shell still
//! opens while a manifest is broken.
//!
//! `--build-target-only` writes `{"buildTarget": [...] | null}`: the
//! project's `build.target` from its config files (not `$CARGO_HOME`'s or
//! the environment's), merged by Cargo's rules, as written.
//!
//! `--capabilities` is the toolchain's capabilities as JSON
//! (`breakbulk_format::Capabilities`, the Nix library's `toolchainFacts`):
//! whether Cargo has `trim-paths`. Whether Cargo allows unstable features
//! the planner asks the cargo it runs.
//!
//! `--cargo-config` is the variant's own Cargo configuration
//! (`variants.<v>.cargoConfig`), a TOML file: Cargo gets it with
//! `--config`, and the planner's reader of the project's config loads it
//! last, over the project's files.
//!
//! `--crates-io-source` and `--crates-io-directory` name the directory
//! source that the vendor config (a `--config` file) replaces crates.io
//! with, where `-Zbuild-std` adds the standard library's dependencies.
//!
//! `--cargo-arg`s are the traced command (`test`; `check --lib --bins
//! --tests --examples`; `doc --no-deps`), from the Nix library's table of
//! plan commands (`lib/cargo-commands.nix`); `--kind` and `--mode` label
//! the plan and decide which units are its roots.
//!
//! `--wrapper-env K=V` sets `K` on the traced Cargo; only the compile units
//! whose program chain contains the `--rustc-workspace-wrapper` keep it.
//! `--variant-option` names where the variant's wrappers are set, for the
//! error when one does not match rustc.

use std::process::ExitCode;

use breakbulk_format::{PlanKind, VariantMode};
use breakbulk_plan::trace::{Options, Target, workspace_dir};

fn usage() -> ! {
    eprintln!(
        "usage: breakbulk-plan --cargo C --rustc R --rustdoc D --shim S --skeleton DIR \
         [--workspace REL] [--canonical-root DIR] --kind build|test|bench|doc \
         [--mode build|check] --cargo-arg A... [--rustc-wrapper PATH] \
         [--rustc-workspace-wrapper PATH] [--wrapper-env K=V]... [--variant-option NAME] \
         --target TRIPLE \
         --profile P [--features F]... [--all-features] [--no-default-features] [-p PKG]... \
         [--config X]... [--cargo-config FILE] [--spec FILE] --capabilities FILE \
         [--crates-io-source NAME --crates-io-directory DIR] [--trim-paths auto|on|off] --scratch DIR [--forbid PATH]... --out FILE [--cargo-env FILE]\n       \
         breakbulk-plan --cargo-env-only --rustc R --skeleton DIR [--workspace REL] \
         --target TRIPLE [--spec FILE] [--capabilities FILE --profile P... [--trim-paths auto|on|off]] \
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
        rustc_wrapper: None,
        rustc_workspace_wrapper: None,
        wrapper_env: Vec::new(),
        variant_option: None,
        cargo_args: Vec::new(),
        target: Target::default(),
        profile: "dev".into(),
        features: Vec::new(),
        all_features: false,
        no_default_features: false,
        packages: Vec::new(),
        configs: Vec::new(),
        cargo_config: None,
        crates_io: None,
        scratch: String::new(),
        forbidden: Vec::new(),
        spec: None,
        trim_paths: Default::default(),
        trim_paths_default: false,
        std_vendor: None,
        capabilities: None,
    };
    let mut out = None;
    // Every `--profile`: `--cargo-env-only` exports trim-paths for each
    // (the build plan's and the test plan's); planning takes the last.
    let mut profiles = Vec::new();
    let mut cargo_env_out: Option<String> = None;
    let mut cargo_env_only = false;
    let mut build_target_only = false;
    let mut crates_io_source = None;
    let mut crates_io_directory = None;
    let mut target = String::new();
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
                    "doc" => PlanKind::Doc,
                    _ => usage(),
                }
            }
            "--mode" => {
                opts.mode = match val().as_str() {
                    "build" => VariantMode::Build,
                    "check" => VariantMode::Check,
                    _ => usage(),
                }
            }
            "--cargo-arg" => opts.cargo_args.push(val()),
            "--rustc-wrapper" => opts.rustc_wrapper = Some(val()),
            "--rustc-workspace-wrapper" => opts.rustc_workspace_wrapper = Some(val()),
            "--wrapper-env" => match val().split_once('=') {
                Some((k, v)) if !k.is_empty() => {
                    opts.wrapper_env.push((k.to_owned(), v.to_owned()))
                }
                _ => usage(),
            },
            "--variant-option" => opts.variant_option = Some(val()),
            "--target" => target = val(),
            "--profile" => {
                opts.profile = val();
                profiles.push(opts.profile.clone());
            }
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
            "--cargo-config" => opts.cargo_config = Some(val()),
            "--crates-io-source" => crates_io_source = Some(val()),
            "--crates-io-directory" => crates_io_directory = Some(val()),
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
    opts.crates_io = match (crates_io_source, crates_io_directory) {
        (Some(name), Some(dir)) => Some((name, dir)),
        (None, None) => None,
        _ => usage(),
    };
    opts.target = Target::new(&target, &workspace_dir(&opts));
    if cargo_env_only {
        return write_cargo_env_only(&opts, &profiles, cargo_env_out);
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
        &opts.target.arg,
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

fn write_cargo_env_only(opts: &Options, profiles: &[String], out: Option<String>) -> ExitCode {
    let Some(out) = out else { usage() };
    if [&opts.rustc, &opts.skeleton, &opts.target.arg, &opts.scratch]
        .iter()
        .any(|s| s.is_empty())
    {
        usage();
    }
    match breakbulk_plan::cargo_env(opts, profiles) {
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
