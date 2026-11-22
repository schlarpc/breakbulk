//! Running cargo with the shim ("Invocation" in
//! `docs/src/explanation/internals/planner.md`).
//!
//! Cargo runs with an empty environment apart from `PATH`, `TMPDIR` and the
//! planner's own variables, a scratch `HOME` and `CARGO_HOME`, and one
//! generated config file passed with `--config` that sets the rustc, the
//! shim as rustc wrapper and rustdoc, and the scratch target and build
//! directories. `--config` has the highest precedence, so the project's
//! config cannot redirect any of them. The project's own config files apply
//! as they do locally; nothing from the user's home is visible. The
//! variant's `cargoConfig` follows as a second `--config` file (the Nix
//! library rejects the keys the generated file and the toolchain spec set).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use breakbulk_format::{PlanKind, Variant, VariantMode};

use crate::graph::Context;
use crate::records::{Metadata, Record, read_records};
use crate::{Error, bail};

#[derive(Clone, Debug)]
pub struct Options {
    pub cargo: String,
    pub rustc: String,
    pub rustdoc: String,
    pub shim: String,
    /// The skeleton root: the planning copy of the repository root.
    pub skeleton: String,
    /// The workspace directory, relative to the skeleton root.
    pub workspace: String,
    /// The canonical skeleton location (`/build/skeleton`). When the
    /// skeleton is elsewhere and a path package lies outside the workspace
    /// root, planning fails: Cargo would hash its absolute path.
    pub canonical_root: Option<String>,
    pub kind: PlanKind,
    /// What the variant compiles: `build` and `coverage` trace `cargo
    /// build` / `cargo test` / `cargo bench --no-run`; `check` and
    /// `clippy` trace `cargo check` (build plan) and `cargo check
    /// --all-targets` (test plan). Coverage's `-C instrument-coverage`
    /// comes in through `configs` like any spec rustflag.
    pub mode: VariantMode,
    /// The variant's rustc wrapper (Cargo's `build.rustc-wrapper`): a
    /// program every rustc invocation goes through, `wrapper rustc ARGS…`.
    /// The shim already is Cargo's wrapper, so it gets this one in
    /// `BREAKBULK_RUSTC_WRAPPER` and puts it first in the chain.
    pub rustc_wrapper: Option<String>,
    /// The variant's workspace wrapper (Cargo's
    /// `build.rustc-workspace-wrapper`), for workspace members only: Cargo
    /// then starts `shim [wrapper] workspace-wrapper rustc …`. A clippy
    /// variant's is clippy-driver.
    pub rustc_workspace_wrapper: Option<String>,
    /// The option that sets a clippy variant's workspace wrapper
    /// (`workspaces.<ws>.toolchain.clippy`), for the error when it does not
    /// match rustc.
    pub clippy_option: Option<String>,
    /// Clippy's own arguments (`-D warnings`, `-W clippy::pedantic`), as
    /// `cargo clippy -- ARGS` passes them: `CLIPPY_ARGS`, each argument
    /// followed by `__CLIPPY_HACKERY__`. Kept only on clippy-driver units.
    pub clippy_args: Vec<String>,
    pub target: Target,
    pub profile: String,
    pub features: Vec<String>,
    pub all_features: bool,
    pub no_default_features: bool,
    /// `-p` selection; empty means `--workspace`.
    pub packages: Vec<String>,
    /// Doc plans: `cargo doc --no-deps`, documenting the selected packages
    /// only.
    pub no_deps: bool,
    /// Extra `--config` values (files or `key=value`): source replacement,
    /// the toolchain spec's rustflags and linkers.
    pub configs: Vec<String>,
    /// The variant's own Cargo configuration (`cargoConfig`), a TOML file:
    /// passed with `--config` before `configs`, so that the spec's
    /// rustflags follow its own, and read by [`ProjectConfig::of`] as the
    /// project's highest layer.
    ///
    /// [`ProjectConfig::of`]: crate::spec::ProjectConfig::of
    pub cargo_config: Option<String>,
    /// The directory source that `configs` replace crates.io with, as
    /// (source name, directory) (`--crates-io-source`,
    /// `--crates-io-directory`): where `-Zbuild-std` adds the standard
    /// library's dependencies ([`crate::build_std`]).
    pub crates_io: Option<(String, String)>,
    /// A writable directory for Cargo's target directory and the records.
    pub scratch: String,
    /// Paths no literal in the plan may contain (besides the scratch
    /// directory and the skeleton).
    pub forbidden: Vec<String>,
    /// The toolchain spec file (`--spec`, see [`crate::spec`]).
    pub spec: Option<String>,
    /// `--trim-paths auto|on|off` (`cargoTrimPaths`): whether
    /// the planner may turn Cargo's `trim-paths` on ([`crate::trim_paths`]).
    pub trim_paths: crate::trim_paths::Mode,
    /// Set by the planner when it turned Cargo's `trim-paths` on
    /// ([`crate::plan`], [`with_trim_paths`]).
    pub trim_paths_default: bool,
    /// Set by the planner when the project uses `-Zbuild-std`
    /// ([`crate::build_std`]).
    pub std_vendor: Option<crate::build_std::StdVendor>,
    /// What the toolchain can do (`--capabilities`, from the Nix library's
    /// `toolchainFacts`). Planning needs it; the dev shell's
    /// `--cargo-env-only` does not.
    pub capabilities: Option<breakbulk_format::Capabilities>,
}

/// What one trace produced.
pub struct Trace {
    pub records: Vec<Record>,
    pub metadata: Metadata,
    pub cargo_version: String,
    pub rustc_version: String,
    /// Whether this cargo allows unstable features ([`nightly_features_allowed`]).
    pub nightly_features_allowed: bool,
    pub host: String,
    /// [`breakbulk_format::plan::Plan::rust_src_remap`].
    pub rust_src_remap: Option<(String, String)>,
    /// The target's spec, as rustc reads it.
    pub target_spec: crate::target_spec::TargetSpec,
}

impl Trace {
    pub fn context(&self, opts: &Options) -> Result<Context, Error> {
        let project = crate::spec::ProjectConfig::of(opts)?;
        Ok(Context {
            scratch: target_dir(opts),
            skeleton: opts.skeleton.trim_end_matches('/').to_owned(),
            host: self.host.clone(),
            target: opts.target.clone(),
            kind: opts.kind,
            variant: Variant {
                profile: opts.profile.clone(),
                features: opts.features.iter().cloned().collect(),
                mode: opts.mode,
            },
            cargo_version: self.cargo_version.clone(),
            rustc_version: self.rustc_version.clone(),
            rustdoc: opts.rustdoc.clone(),
            cargo: opts.cargo.clone(),
            nightly: self.nightly_features_allowed,
            executable_suffix: self.target_spec.exe_suffix.clone(),
            target_debuginfo: self.target_spec.debuginfo.clone(),
            keep_workspace_wrapper: runs_wrappers(opts) && opts.rustc_workspace_wrapper.is_some(),
            rustc_wrapper: opts.rustc_wrapper.clone().filter(|_| runs_wrappers(opts)),
            config_env: project.applied_env(&cargo_env_names(opts))?,
            rust_src_remap: self.rust_src_remap.clone(),
            trim_paths_default: opts.trim_paths_default,
            std_vendor: opts
                .std_vendor
                .as_ref()
                .map(|v| (v.dir.clone(), v.library.clone())),
        })
    }
}

/// The variables of the environment the planner starts traced Cargo
/// invocations with ([`command`] and [`run`]).
fn cargo_env_names(opts: &Options) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = BASE_ENV
        .iter()
        .filter(|k| std::env::var_os(k).is_some())
        .chain(&[
            "HOME",
            "CARGO_HOME",
            "CARGO_CACHE_RUSTC_INFO",
            "BREAKBULK_RUSTDOC",
            "BREAKBULK_METADATA",
            "BREAKBULK_RECORD",
        ])
        .map(|k| (*k).to_owned())
        .collect();
    if runs_wrappers(opts) {
        if opts.rustc_wrapper.is_some() {
            names.insert(RUSTC_WRAPPER_ENV.into());
        }
        if opts.rustc_workspace_wrapper.is_some() {
            names.insert("RUSTC_WORKSPACE_WRAPPER".into());
        }
        if opts.mode == VariantMode::Clippy && !opts.clippy_args.is_empty() {
            names.insert("CLIPPY_ARGS".into());
        }
    }
    names
}

/// How the planner hands the shim the variant's rustc wrapper
/// (`breakbulk-shim`'s `RUSTC_WRAPPER_ENV`).
pub const RUSTC_WRAPPER_ENV: &str = "BREAKBULK_RUSTC_WRAPPER";

/// Whether the trace runs the variant's wrappers: every plan but the doc
/// plan, whose check-mode units rustdoc reads are then a plain check
/// variant's, and whose docs neither a lint nor a verifier can fail.
fn runs_wrappers(opts: &Options) -> bool {
    opts.kind != PlanKind::Doc
}

/// Variables passed through from the planner's own environment.
const BASE_ENV: [&str; 2] = ["PATH", "TMPDIR"];

fn target_dir(opts: &Options) -> String {
    format!("{}/target", opts.scratch.trim_end_matches('/'))
}

pub fn workspace_dir(opts: &Options) -> PathBuf {
    let root = Path::new(&opts.skeleton);
    if opts.workspace.is_empty() {
        root.to_owned()
    } else {
        root.join(&opts.workspace)
    }
}

/// The remap of the toolchain's `rust-src` copy to rustc's virtual
/// `/rustc/<commit-hash>` ([`breakbulk_format::plan::Plan::rust_src_remap`]),
/// when the sysroot has one and rustc names its commit.
fn rust_src_remap(opts: &Options, rustc_vv: &str) -> Result<Option<(String, String)>, Error> {
    let Some(hash) = rustc_vv
        .lines()
        .find_map(|l| l.strip_prefix("commit-hash: "))
        .map(str::trim)
        .filter(|h| !h.is_empty() && *h != "unknown")
    else {
        return Ok(None);
    };
    let sysroot = output(
        {
            let mut c = command(opts, &opts.rustc);
            c.args(["--print", "sysroot"]);
            c
        },
        "rustc --print sysroot",
    )?;
    let src = Path::new(sysroot.trim()).join("lib/rustlib/src/rust");
    Ok(src
        .is_dir()
        .then(|| (src.display().to_string(), format!("/rustc/{hash}"))))
}

/// The toolchain's sysroot (`rustc --print sysroot`).
fn sysroot(opts: &Options) -> Result<PathBuf, Error> {
    let s = output(
        {
            let mut c = command(opts, &opts.rustc);
            c.args(["--print", "sysroot"]);
            c
        },
        "rustc --print sysroot",
    )?;
    Ok(PathBuf::from(s.trim()))
}

/// clippy-driver is a rustc with its own sysroot compiled in: one built for
/// another rustc (nixpkgs' `clippy` beside a rust-overlay toolchain, even of
/// the same release) makes the traced units point into that rustc's
/// sysroot, which instantiation later rejects as an undeclared input. Both
/// `--print sysroot` answers must therefore be the same path
/// (`clippy-driver --rustc` behaves as plain rustc).
fn check_clippy_driver(opts: &Options, driver: &str) -> Result<(), Error> {
    let option = opts
        .clippy_option
        .as_deref()
        .unwrap_or("the toolchain's clippy");
    if !Path::new(driver).is_file() {
        bail!(
            "the clippy variant needs {driver}, which does not exist; set {option} to a \
             package with bin/clippy-driver built for this rustc"
        );
    }
    let ours = output(
        {
            let mut c = command(opts, driver);
            c.args(["--rustc", "--print", "sysroot"]);
            c
        },
        "clippy-driver --rustc --print sysroot",
    )?;
    let rustc = sysroot(opts)?;
    if Path::new(ours.trim()) != rustc {
        bail!(
            "{driver} is built for another rustc: its sysroot is {}, rustc's is {}; set \
             {option} to the clippy of this rustc (a rustup-style toolchain with the clippy \
             component has bin/clippy-driver)",
            ours.trim(),
            rustc.display()
        );
    }
    Ok(())
}

/// When the project's config turns on `-Zbuild-std`: the merged crates.io
/// directory with the standard library's vendored dependencies
/// ([`crate::build_std`]).
pub fn std_vendor(opts: &Options) -> Result<Option<crate::build_std::StdVendor>, Error> {
    if !crate::spec::ProjectConfig::of(opts)?.uses_build_std() {
        return Ok(None);
    }
    let scratch = PathBuf::from(&opts.scratch);
    mkdir(&scratch)?;
    crate::build_std::prepare(&sysroot(opts)?, opts.crates_io.as_ref(), &scratch)
}

fn mkdir(p: &Path) -> Result<(), Error> {
    std::fs::create_dir_all(p).map_err(|e| Error(format!("creating {}: {e}", p.display())))
}

fn toml_str(s: &str) -> String {
    serde_json::to_string(s).expect("strings serialize")
}

/// A command with the planner's controlled environment.
fn command(opts: &Options, program: &str) -> Command {
    let scratch = Path::new(&opts.scratch);
    let mut cmd = Command::new(program);
    cmd.env_clear();
    for k in BASE_ENV {
        if let Some(v) = std::env::var_os(k) {
            cmd.env(k, v);
        }
    }
    cmd.env("HOME", scratch.join("home"))
        .env("CARGO_HOME", scratch.join("cargo-home"))
        // No rustc-info cache (`<build-dir>/.rustc_info.json`): every Cargo
        // invocation then sends its `rustc -vV` through the shim, whose
        // record is Cargo's own environment (`graph::Builder::new`), however
        // the build directory came to exist. Cargo reads the variable once
        // at startup (cargo `src/context/mod.rs`, `GlobalContext::new`; any
        // value but `0` keeps the cache) and passes no cache location to
        // `Rustc::new` (`load_global_rustc`). It reaches every process
        // Cargo starts, so the baseline subtraction drops it from units.
        .env("CARGO_CACHE_RUSTC_INFO", "0")
        .env("BREAKBULK_RUSTDOC", &opts.rustdoc)
        .env("BREAKBULK_METADATA", scratch.join("metadata.json"))
        .current_dir(workspace_dir(opts));
    cmd
}

fn output(mut cmd: Command, what: &str) -> Result<String, Error> {
    let out = cmd
        .output()
        .map_err(|e| Error(format!("could not run {what}: {e}")))?;
    if !out.status.success() {
        bail!(
            "{what} failed ({}):\n{}{}",
            out.status,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    String::from_utf8(out.stdout).map_err(|e| Error(format!("{what}: {e}")))
}

/// The cargo arguments every invocation shares.
fn common_args(opts: &Options, config: &Path) -> Vec<String> {
    let mut a = vec!["--frozen".to_owned(), "--offline".to_owned()];
    a.push("--config".into());
    a.push(config.display().to_string());
    for c in opts.cargo_config.iter().chain(&opts.configs) {
        a.push("--config".into());
        a.push(c.clone());
    }
    a
}

fn selection_args(opts: &Options) -> Vec<String> {
    let mut a = Vec::new();
    if opts.packages.is_empty() {
        a.push("--workspace".into());
    } else {
        for p in &opts.packages {
            a.push("-p".into());
            a.push(p.clone());
        }
    }
    a.extend(build_args(opts));
    a
}

/// The target, profile and feature arguments of [`selection_args`].
fn build_args(opts: &Options) -> Vec<String> {
    let mut a = Vec::new();
    a.extend(["--target".into(), opts.target.arg.clone()]);
    a.extend(["--profile".into(), opts.profile.clone()]);
    if !opts.features.is_empty() {
        a.extend(["--features".into(), opts.features.join(",")]);
    }
    if opts.all_features {
        a.push("--all-features".into());
    }
    if opts.no_default_features {
        a.push("--no-default-features".into());
    }
    a
}

/// Fail when the skeleton is not at its canonical location and a path
/// package lies outside the workspace root ("Fixed skeleton location").
/// Not needed when Cargo's `trim-paths` is in effect: Cargo then hashes
/// such a package without its absolute path.
pub fn check_location(opts: &Options, metadata: &Metadata) -> Result<(), Error> {
    let Some(canonical) = &opts.canonical_root else {
        return Ok(());
    };
    if canonical.trim_end_matches('/') == opts.skeleton.trim_end_matches('/') {
        return Ok(());
    }
    let root = format!("{}/", metadata.workspace_root.trim_end_matches('/'));
    let outside: Vec<String> = metadata
        .packages
        .iter()
        .filter(|p| p.is_path() && !format!("{}/", p.dir()).starts_with(&root))
        .map(|p| format!("{} {}", p.name, p.version))
        .collect();
    if outside.is_empty() {
        return Ok(());
    }
    bail!(
        "the planning skeleton is at {}, not at {canonical}, and these path crates lie outside \
         the workspace root, so Cargo hashes their absolute path into `-C metadata`: {}. \
         Plan in a sandboxed Nix build with the default sandbox-build-dir (/build).",
        opts.skeleton,
        outside.join(", ")
    )
}

/// Run the trace for the plan kind and collect every record.
pub fn run(opts: &Options) -> Result<Trace, Error> {
    let scratch = PathBuf::from(&opts.scratch);
    for d in ["home", "cargo-home", "bin"] {
        mkdir(&scratch.join(d))?;
    }
    let rustdoc_link = scratch.join("bin/rustdoc");
    let runner_link = scratch.join(format!("bin/{TEST_RUNNER}"));
    for link in [&rustdoc_link, &runner_link] {
        if link.symlink_metadata().is_err() {
            std::os::unix::fs::symlink(&opts.shim, link)
                .map_err(|e| Error(format!("linking {}: {e}", link.display())))?;
        }
    }
    let target = target_dir(opts);

    let cargo_version = output(
        {
            let mut c = command(opts, &opts.cargo);
            c.arg("-V");
            c
        },
        "cargo -V",
    )?;
    let cargo_version = cargo_version
        .trim()
        .strip_prefix("cargo ")
        .unwrap_or(cargo_version.trim())
        .to_owned();
    let nightly_features_allowed = nightly_features_allowed(opts)?;
    let rustc_vv = output(
        {
            let mut c = command(opts, &opts.rustc);
            c.arg("-vV");
            c
        },
        "rustc -vV",
    )?;
    let mut lines = rustc_vv.lines();
    let rustc_version = lines
        .next()
        .unwrap_or_default()
        .trim()
        .strip_prefix("rustc ")
        .unwrap_or_default()
        .to_owned();
    let host = rustc_vv
        .lines()
        .find_map(|l| l.strip_prefix("host: "))
        .map(|h| h.trim().to_owned())
        .ok_or_else(|| Error("`rustc -vV` names no host".into()))?;
    let rust_src_remap = rust_src_remap(opts, &rustc_vv)?;
    let target_spec = target_spec(opts)?;

    let checking = matches!(opts.mode, VariantMode::Check | VariantMode::Clippy);
    // Plain `cargo test`, not `cargo test --no-run` and then `cargo test
    // --doc`: `--no-run` stops before the doctests, and `--doc` doc-tests
    // other libraries than `cargo test` does (also those with `doctest =
    // false`), whose dependencies' build-script runs then reach every
    // doctest's `-L` list. Cargo starts each test binary through the
    // runner, which does nothing, and then asks rustdoc for the doctests.
    // A doc plan is `cargo doc` in every variant: rustdoc reads check-mode
    // units, which a check variant's plans share.
    let sub: &[&str] = match opts.kind {
        PlanKind::Doc if opts.no_deps => &["doc", "--no-deps"],
        PlanKind::Doc => &["doc"],
        PlanKind::Build if checking => &["check"],
        PlanKind::Test if checking => &["check", "--all-targets"],
        PlanKind::Bench if checking => {
            bail!("a bench plan needs a build or coverage variant, not check or clippy")
        }
        PlanKind::Build => &["build"],
        PlanKind::Test => &["test"],
        PlanKind::Bench => &["bench", "--no-run"],
    };
    let config = scratch.join("breakbulk-config.toml");
    let mut config_text = format!(
        "[build]\nrustc = {}\nrustc-wrapper = {}\nrustdoc = {}\ntarget-dir = {}\nbuild-dir = {}\n",
        toml_str(&opts.rustc),
        toml_str(&opts.shim),
        toml_str(&rustdoc_link.display().to_string()),
        toml_str(&target),
        toml_str(&target),
    );
    if sub == ["test"] {
        // Cargo looks the runner up per compile kind: proc macros' tests
        // run for the host.
        let mut keys = vec![opts.target.short_name.as_str(), host.as_str()];
        keys.dedup();
        for key in keys {
            config_text.push_str(&format!(
                "[target.{}]\nrunner = [{}]\n",
                toml_str(key),
                toml_str(&runner_link.display().to_string())
            ));
        }
    }
    std::fs::write(&config, config_text)
        .map_err(|e| Error(format!("writing {}: {e}", config.display())))?;

    // cargo metadata, for the stubs and for the planner. It lists the
    // packages of the resolve for the features it is given, so it gets all
    // of them rather than the variant's: `cargo metadata` selects every
    // member, and a bare feature name applies to each selected member that
    // has it, which is not what the variant's `-p` selection means.
    let mut cmd = command(opts, &opts.cargo);
    cmd.args(["metadata", "--format-version", "1", "--all-features"])
        .args(common_args(opts, &config));
    let mut meta_text = output(cmd, "cargo metadata")?;
    // -Zbuild-std: the standard library's packages too, for the stubs
    // (compiler_builtins has a build script) and the planner.
    if let Some(v) = &opts.std_vendor {
        let mut cmd = command(opts, &opts.cargo);
        // Every optional dependency: Cargo resolves std with
        // `-Zbuild-std-features`, which may turn any of them on.
        cmd.args([
            "metadata",
            "--format-version",
            "1",
            "--all-features",
            "--manifest-path",
        ])
        .arg(Path::new(&v.library).join("Cargo.toml"))
        .args(common_args(opts, &config));
        let std_text = output(cmd, "cargo metadata (the standard library's workspace)")?;
        let mut meta: serde_json::Value =
            serde_json::from_str(&meta_text).map_err(|e| Error(format!("cargo metadata: {e}")))?;
        let std_meta: serde_json::Value = serde_json::from_str(&std_text)
            .map_err(|e| Error(format!("cargo metadata (std): {e}")))?;
        if let (Some(p), Some(s)) = (
            meta["packages"].as_array_mut(),
            std_meta["packages"].as_array(),
        ) {
            for pkg in s {
                if !p.iter().any(|q| q["id"] == pkg["id"]) {
                    p.push(pkg.clone());
                }
            }
        }
        meta_text = meta.to_string();
    }
    let meta_path = scratch.join("metadata.json");
    std::fs::write(&meta_path, &meta_text)
        .map_err(|e| Error(format!("writing {}: {e}", meta_path.display())))?;
    let metadata = Metadata::read(&meta_path)?;

    if opts.mode == VariantMode::Clippy && runs_wrappers(opts) {
        let Some(driver) = &opts.rustc_workspace_wrapper else {
            bail!("the clippy variant needs --rustc-workspace-wrapper (clippy-driver)");
        };
        check_clippy_driver(opts, driver)?;
    }
    let record = scratch.join("record");
    if record.exists() {
        std::fs::remove_dir_all(&record)
            .map_err(|e| Error(format!("removing {}: {e}", record.display())))?;
    }
    mkdir(&record)?;
    let mut cmd = command(opts, &opts.cargo);
    cmd.args(sub)
        .args(common_args(opts, &config))
        .args(selection_args(opts))
        .env("BREAKBULK_RECORD", &record);
    if runs_wrappers(opts) {
        if let Some(w) = &opts.rustc_wrapper {
            cmd.env(RUSTC_WRAPPER_ENV, w);
        }
        if let Some(w) = &opts.rustc_workspace_wrapper {
            cmd.env("RUSTC_WORKSPACE_WRAPPER", w);
        }
        if opts.mode == VariantMode::Clippy && !opts.clippy_args.is_empty() {
            let joined: String = opts
                .clippy_args
                .iter()
                .map(|a| format!("{a}__CLIPPY_HACKERY__"))
                .collect();
            cmd.env("CLIPPY_ARGS", joined);
        }
    }
    output(cmd, &format!("cargo {}", sub.join(" ")))?;
    let records = read_records(&record)?;
    // With the rustc-info cache off, every invocation asks; one that did
    // not means Cargo ignored `CARGO_CACHE_RUSTC_INFO=0` (assumption T2 in
    // `docs/src/reference/assumptions.md`).
    if !records
        .iter()
        .any(|r| r.mode == "query" && r.args == ["-vV"])
    {
        bail!(
            "`cargo {}` sent no `rustc -vV` through the shim although its \
             rustc-info cache is off (CARGO_CACHE_RUSTC_INFO=0)",
            sub.join(" ")
        );
    }
    Ok(Trace {
        records,
        metadata,
        cargo_version,
        rustc_version,
        nightly_features_allowed,
        host,
        rust_src_remap,
        target_spec,
    })
}

/// Cargo's `nightly_features_allowed`, asked of the cargo the trace runs:
/// any `-Z` flag fails on a channel without unstable features (cargo
/// `CliUnstable::parse`, from `GlobalContext::configure`). Not `-Zhelp` or
/// `-V`, which succeed on every channel, and not `cargo -V`'s version
/// string: a cargo built without a release channel (nixpkgs') is a `dev`
/// build whatever its version says. The environment is the trace's, without
/// `RUSTC_BOOTSTRAP`, which makes any cargo a `dev` build.
fn nightly_features_allowed(opts: &Options) -> Result<bool, Error> {
    let mut cmd = command(opts, &opts.cargo);
    cmd.args(["-Zunstable-options", "help"]);
    let out = cmd
        .output()
        .map_err(|e| Error(format!("could not run cargo -Zunstable-options help: {e}")))?;
    Ok(out.status.success())
}

/// The target's spec (`rustc --print target-spec-json`), asked where
/// Cargo runs, so that a custom target's relative `.json` path names the
/// same file. The print is unstable, so this one command gets
/// `RUSTC_BOOTSTRAP=1`; Cargo's processes do not, as build scripts would
/// see it and the units would record it.
fn target_spec(opts: &Options) -> Result<crate::target_spec::TargetSpec, Error> {
    let json = output(
        {
            let mut c = command(opts, &opts.rustc);
            c.env("RUSTC_BOOTSTRAP", "1").args([
                "-Z",
                "unstable-options",
                "--print",
                "target-spec-json",
                "--target",
                &opts.target.arg,
            ]);
            c
        },
        "rustc --print target-spec-json",
    )?;
    crate::target_spec::TargetSpec::from_json(&json)
}

/// The toolchain's capabilities, which planning needs.
pub fn capabilities(opts: &Options) -> Result<breakbulk_format::Capabilities, Error> {
    opts.capabilities.ok_or_else(|| {
        Error(
            "planning needs the toolchain's capabilities (--capabilities FILE, from the Nix \
             library's toolchainFacts)"
                .into(),
        )
    })
}

/// The options of a trace with Cargo's `trim-paths` on for the profile:
/// `--config` overrides the project's setting, which is why it is passed
/// only by [`crate::trim_paths::decide`]'s rule.
pub fn with_trim_paths(opts: &Options) -> Options {
    let mut o = opts.clone();
    o.configs
        .push(format!("profile.{}.trim-paths=\"all\"", opts.profile));
    o.trim_paths_default = true;
    o
}

/// The file name of the shim as the test runner of a traced `cargo test`
/// (the shim's `TEST_RUNNER`).
const TEST_RUNNER: &str = "breakbulk-test-runner";

/// The planned target as Cargo names it (cargo `CompileTarget`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Target {
    /// What Cargo and rustc are given as `--target`: a triple, or the path
    /// of a `.json` target spec.
    pub arg: String,
    /// Cargo's short name (`CompileTarget::short_name`): the triple, or a
    /// `.json` spec's file stem. Cargo keys the target's configuration by
    /// it (`[target.<short name>]`, `CARGO_TARGET_<SHORT NAME>_*`), names
    /// the target's directory in the target directory after it, and gives
    /// it to build scripts as `TARGET`.
    pub short_name: String,
}

impl Target {
    /// `arg` as Cargo started in `cwd` reads it (`CompileTarget::new`): a
    /// `.json` path canonicalized, so a symlink's target names it.
    pub fn new(arg: &str, cwd: &Path) -> Target {
        let arg = arg.trim();
        let short_name = if arg.ends_with(".json") {
            let path = std::fs::canonicalize(cwd.join(arg)).unwrap_or_else(|_| arg.into());
            path.file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
        } else {
            arg.to_owned()
        };
        Target {
            arg: arg.to_owned(),
            short_name,
        }
    }

    /// A triple: its own short name.
    pub fn triple(t: &str) -> Target {
        Target {
            arg: t.to_owned(),
            short_name: t.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_names() {
        let at = |arg: &str| Target::new(arg, Path::new("/nonexistent")).short_name;
        assert_eq!(at("x86_64-unknown-linux-gnu"), "x86_64-unknown-linux-gnu");
        assert_eq!(at("/specs/my-target.json"), "my-target");
        assert_eq!(at("my-target.json"), "my-target");
        let d = std::env::temp_dir().join(format!("bb-target-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("board.json"), "{}").unwrap();
        std::os::unix::fs::symlink("board.json", d.join("alias.json")).unwrap();
        let alias = Target::new("alias.json", &d);
        std::fs::remove_dir_all(&d).unwrap();
        assert_eq!(alias.arg, "alias.json");
        assert_eq!(alias.short_name, "board");
    }
}
