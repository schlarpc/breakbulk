//! Running cargo with the shim ("Invocation" in `docs/implementation.md`).
//!
//! Cargo runs with an empty environment apart from `PATH`, `TMPDIR` and the
//! planner's own variables, a scratch `HOME` and `CARGO_HOME`, and one
//! generated config file passed with `--config` that sets the rustc, the
//! shim as rustc wrapper and rustdoc, and the scratch target and build
//! directories. `--config` has the highest precedence, so the project's
//! config cannot redirect any of them. The project's own config files apply
//! as they do locally; nothing from the user's home is visible.

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
    pub target: String,
    pub profile: String,
    pub features: Vec<String>,
    pub all_features: bool,
    pub no_default_features: bool,
    /// `-p` selection; empty means `--workspace`.
    pub packages: Vec<String>,
    /// Extra `--config` values (files or `key=value`): source replacement,
    /// the toolchain spec's rustflags and linkers.
    pub configs: Vec<String>,
    /// A writable directory for Cargo's target directory and the records.
    pub scratch: String,
    /// Paths no literal in the plan may contain (besides the scratch
    /// directory and the skeleton).
    pub forbidden: Vec<String>,
}

/// What one trace produced.
pub struct Trace {
    pub records: Vec<Record>,
    pub metadata: Metadata,
    pub cargo_version: String,
    pub rustc_version: String,
    pub host: String,
}

impl Trace {
    pub fn context(&self, opts: &Options) -> Context {
        Context {
            scratch: target_dir(opts),
            skeleton: opts.skeleton.trim_end_matches('/').to_owned(),
            host: self.host.clone(),
            target: opts.target.clone(),
            kind: opts.kind,
            variant: Variant {
                profile: opts.profile.clone(),
                features: opts.features.iter().cloned().collect(),
                mode: VariantMode::Build,
            },
            cargo_version: self.cargo_version.clone(),
            rustc_version: self.rustc_version.clone(),
            rustdoc: opts.rustdoc.clone(),
            cargo: opts.cargo.clone(),
            nightly: self.cargo_version.contains("-nightly") || self.cargo_version.contains("-dev"),
            keep_workspace_wrapper: false,
        }
    }
}

fn target_dir(opts: &Options) -> String {
    format!("{}/target", opts.scratch.trim_end_matches('/'))
}

fn workspace_dir(opts: &Options) -> PathBuf {
    let root = Path::new(&opts.skeleton);
    if opts.workspace.is_empty() {
        root.to_owned()
    } else {
        root.join(&opts.workspace)
    }
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
    for k in ["PATH", "TMPDIR"] {
        if let Some(v) = std::env::var_os(k) {
            cmd.env(k, v);
        }
    }
    cmd.env("HOME", scratch.join("home"))
        .env("CARGO_HOME", scratch.join("cargo-home"))
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
    for c in &opts.configs {
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
    a.extend(["--target".into(), opts.target.clone()]);
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
fn check_location(opts: &Options, metadata: &Metadata) -> Result<(), Error> {
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
    if rustdoc_link.symlink_metadata().is_err() {
        std::os::unix::fs::symlink(&opts.shim, &rustdoc_link)
            .map_err(|e| Error(format!("linking {}: {e}", rustdoc_link.display())))?;
    }
    let target = target_dir(opts);
    let config = scratch.join("breakbulk-config.toml");
    let config_text = format!(
        "[build]\nrustc = {}\nrustc-wrapper = {}\nrustdoc = {}\ntarget-dir = {}\nbuild-dir = {}\n",
        toml_str(&opts.rustc),
        toml_str(&opts.shim),
        toml_str(&rustdoc_link.display().to_string()),
        toml_str(&target),
        toml_str(&target),
    );
    std::fs::write(&config, config_text)
        .map_err(|e| Error(format!("writing {}: {e}", config.display())))?;

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

    // cargo metadata, for the stubs and for the planner.
    let mut cmd = command(opts, &opts.cargo);
    cmd.args(["metadata", "--format-version", "1"])
        .args(common_args(opts, &config));
    let meta_text = output(cmd, "cargo metadata")?;
    let meta_path = scratch.join("metadata.json");
    std::fs::write(&meta_path, &meta_text)
        .map_err(|e| Error(format!("writing {}: {e}", meta_path.display())))?;
    let metadata = Metadata::read(&meta_path)?;
    check_location(opts, &metadata)?;

    let invocations: Vec<Vec<&str>> = match opts.kind {
        PlanKind::Build => vec![vec!["build"]],
        PlanKind::Test => {
            let mut v = vec![vec!["test", "--no-run"]];
            if has_doctests(opts, &metadata) {
                v.push(vec!["test", "--doc"]);
            }
            v
        }
    };
    let mut records = Vec::new();
    for (n, sub) in invocations.iter().enumerate() {
        let record = scratch.join(format!("record-{n}"));
        mkdir(&record)?;
        let mut cmd = command(opts, &opts.cargo);
        cmd.args(sub)
            .args(common_args(opts, &config))
            .args(selection_args(opts))
            .env("BREAKBULK_RECORD", &record);
        output(cmd, &format!("cargo {}", sub.join(" ")))?;
        records.extend(read_records(&record)?);
    }
    Ok(Trace {
        records,
        metadata,
        cargo_version,
        rustc_version,
        host,
    })
}

/// Whether `cargo test --doc` has anything to do: a selected member with a
/// doctestable library. Cargo fails `--doc` when no library is selected.
fn has_doctests(opts: &Options, m: &Metadata) -> bool {
    m.packages
        .iter()
        .filter(|p| m.workspace_members.contains(&p.id))
        .filter(|p| opts.packages.is_empty() || opts.packages.contains(&p.name))
        .flat_map(|p| &p.targets)
        .any(|t| {
            t.is_lib()
                && t.doctest
                && t.crate_types
                    .iter()
                    .any(|c| matches!(c.as_str(), "lib" | "rlib" | "proc-macro"))
        })
}
