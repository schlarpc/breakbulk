//! Build-script directive parsing, matching Cargo.
//!
//! Every rule here is copied from Cargo 1.99 (`rust-lang/cargo` tag `0.100.0`,
//! commit `5f94df4789f005f9a352888e8355ffc645b7ed0e`), file
//! `src/compiler/custom_build.rs`, unless noted:
//!
//! - [`parse`] is `BuildOutput::parse`.
//! - [`parse_rustc_flags`] is `BuildOutput::parse_rustc_flags`.
//! - [`parse_rustc_env`] is `BuildOutput::parse_rustc_env`.
//! - [`streamed_log_messages`] is the `exec_with_streaming` callback in
//!   `build_work`, which decides "build script logged errors".
//! - [`is_inside`]'s prefix handling is `get_dynamic_search_path` in
//!   `src/compiler/mod.rs`, used by `LibraryPath::new`.
//! - [`envify`] and [`metadata_env`] are `envify` in `src/compiler/mod.rs` and
//!   the `DEP_*` loop in `build_work`.
//!
//! One part of `BuildOutput::parse` is deliberately absent: the rewrite of
//! the old output directory to the new one in every value
//! (`script_out_dir_when_generated` → `script_out_dir`). It only matters when a
//! fresh build's target directory has moved, and breakbulk always runs the
//! script with its final `OUT_DIR`, where the rewrite is the identity.

use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::spec::{PackageTarget, SpliceKind};

/// Cargo's `const DOCS_LINK_SUGGESTION`.
const DOCS_LINK_SUGGESTION: &str = "See https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script \
     for more information about build script outputs.";

/// Old-syntax keys Cargo recognizes; any other `cargo:KEY=VALUE` is metadata.
/// Cargo's `RESERVED_PREFIXES`. No key may be added to this list, by Cargo's
/// own rule, so it is also the complete list for every later Cargo.
pub const RESERVED_PREFIXES: &[&str] = &[
    "rustc-flags=",
    "rustc-link-lib=",
    "rustc-link-search=",
    "rustc-link-arg-cdylib=",
    "rustc-cdylib-link-arg=",
    "rustc-link-arg-bins=",
    "rustc-link-arg-bin=",
    "rustc-link-arg-tests=",
    "rustc-link-arg-benches=",
    "rustc-link-arg-examples=",
    "rustc-link-arg=",
    "rustc-cfg=",
    "rustc-check-cfg=",
    "rustc-env=",
    "warning=",
    "rerun-if-changed=",
    "rerun-if-env-changed=",
];

/// Cargo's `CARGO_ERROR_SYNTAX`.
const CARGO_ERROR_SYNTAX: &str = "cargo::error=";
/// Cargo's `OLD_CARGO_WARNING_SYNTAX`.
const OLD_CARGO_WARNING_SYNTAX: &str = "cargo:warning=";
/// Cargo's `NEW_CARGO_WARNING_SYNTAX`.
const NEW_CARGO_WARNING_SYNTAX: &str = "cargo::warning=";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogMessage {
    pub severity: Severity,
    pub message: String,
}

/// A `-L` value, with Cargo's `LibraryPath` classification.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct LibraryPath {
    /// The value exactly as printed, including any `native=`-style prefix.
    pub value: String,
    /// Cargo's `LibraryPath::CargoArtifact`: the path, without its kind prefix,
    /// lies inside the script's own `OUT_DIR`. Such paths are passed to rustc
    /// before every `External` one.
    pub in_out_dir: bool,
    /// The path lies inside the script's own `OUT_DIR` or inside the
    /// `OUT_DIR` of a run whose `DEP_*` metadata the script received
    /// ([`ParseContext::upstream_out_dirs`]), typically through a
    /// `DEP_<LINKS>_ROOT`-style value. breakbulk's stand-in for Cargo's
    /// "inside the target directory", the rule for dynamic-library paths
    /// (`filter_dynamic_search_path` in `src/compiler/mod.rs`). Absent in
    /// files written before it existed; read as `in_out_dir` then.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub in_build_dir: bool,
}

impl LibraryPath {
    /// Classify a `-L` value printed by a script ([`ParseContext`]).
    pub fn new(value: String, ctx: &ParseContext<'_>) -> LibraryPath {
        let in_out_dir = is_inside(&value, ctx.out_dir);
        let in_build_dir = in_out_dir || ctx.upstream_out_dirs.iter().any(|d| is_inside(&value, d));
        LibraryPath {
            value,
            in_out_dir,
            in_build_dir,
        }
    }

    /// Whether Cargo would put this path on a dynamic-library path.
    pub fn for_dylib_path(&self) -> bool {
        self.in_out_dir || self.in_build_dir
    }
}

/// One `rustc-link-arg*` value. `kind` is the splice kind that receives it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinkArg {
    pub kind: SpliceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bin: Option<String>,
    pub value: String,
}

/// The parsed output of one build-script run: Cargo's `BuildOutput`.
///
/// Each list keeps the order the script printed. `rustc-flags` contributes to
/// `library_links` and `library_paths` at its position. This is what a run
/// writes to `$flags/directives.json`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct BuildOutput {
    pub library_paths: Vec<LibraryPath>,
    pub library_links: Vec<String>,
    pub linker_args: Vec<LinkArg>,
    pub cfgs: Vec<String>,
    pub check_cfgs: Vec<String>,
    pub env: Vec<(String, String)>,
    pub metadata: Vec<(String, String)>,
    pub rerun_if_changed: Vec<String>,
    pub rerun_if_env_changed: Vec<String>,
    pub log_messages: Vec<LogMessage>,
    /// Not a directive: the directories of the run's `out` that copy
    /// Cargo's `<profile>` and `<profile>/deps` and hold files the script
    /// wrote there (#23), in that order. Cargo puts both on a test's or
    /// `cargo run`'s dynamic-library path, after the search paths
    /// (`Compilation::fill_env`), so libraries scripts copy next to the
    /// binaries are found; breakbulk's test runs do the same with these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_dirs: Vec<String>,
}

impl BuildOutput {
    pub fn has_errors(&self) -> bool {
        self.log_messages
            .iter()
            .any(|m| m.severity == Severity::Error)
    }
}

/// Facts about the package that `BuildOutput::parse` takes as arguments.
#[derive(Clone, Debug)]
pub struct ParseContext<'a> {
    /// Cargo's `pkg_descr`, used only in messages.
    pub pkg_descr: &'a str,
    /// The script's `OUT_DIR` (Cargo's `script_out_dir`).
    pub out_dir: &'a Path,
    /// Cargo's `nightly_features_allowed`.
    pub nightly_features_allowed: bool,
    /// The package's targets.
    pub targets: &'a [PackageTarget],
    /// The package's `rust-version`, if it declares one.
    pub rust_version: Option<&'a str>,
    /// The `OUT_DIR`s of the runs whose `DEP_*` metadata the script
    /// received, for [`LibraryPath::in_build_dir`].
    pub upstream_out_dirs: &'a [PathBuf],
}

/// A directive Cargo would reject. The message follows Cargo's wording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectiveError(pub String);

impl fmt::Display for DirectiveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DirectiveError {}

macro_rules! bail {
    ($($arg:tt)*) => {
        return Err(DirectiveError(format!($($arg)*)))
    };
}

fn has_reserved_prefix(flag: &str) -> bool {
    RESERVED_PREFIXES.iter().any(|p| flag.starts_with(p))
}

/// Whether `rust_version` permits the `cargo::` syntax: Cargo's
/// `check_minimum_supported_rust_version_for_new_syntax`, which asks whether
/// `RustVersion::new(1, 77, 0).is_compatible_with(msrv)`, that is whether the
/// caret requirement `^1.77.0` matches the MSRV with missing parts read as 0
/// (`cargo-util-schemas`, `manifest/rust_version.rs`). So `1` and `1.76.9`
/// are rejected, `1.77` and `1.80.1` accepted, and `2.0` rejected.
pub fn msrv_allows_new_syntax(rust_version: &str) -> Result<bool, DirectiveError> {
    let mut parts = rust_version.split('.');
    let mut next = |required: bool| -> Result<u64, DirectiveError> {
        match parts.next() {
            Some(p) if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) => p
                .parse()
                .map_err(|_| DirectiveError(format!("invalid rust-version `{rust_version}`"))),
            None if !required => Ok(0),
            _ => bail!("invalid rust-version `{rust_version}`"),
        }
    };
    let major = next(true)?;
    let minor = next(false)?;
    let patch = next(false)?;
    if parts.next().is_some() {
        bail!("invalid rust-version `{rust_version}`");
    }
    Ok(major == 1 && (minor, patch) >= (77, 0))
}

fn check_msrv_for_new_syntax(ctx: &ParseContext<'_>, flag: &str) -> Result<(), DirectiveError> {
    let Some(msrv) = ctx.rust_version else {
        return Ok(());
    };
    if msrv_allows_new_syntax(msrv)? {
        return Ok(());
    }
    let old_syntax_suggestion = if has_reserved_prefix(flag) {
        format!("Switch to the old `cargo:{flag}` syntax (note the single colon).\n")
    } else if let Some(old_format_flag) = flag.strip_prefix("metadata=") {
        format!(
            "Switch to the old `cargo:{old_format_flag}` syntax instead of `cargo::{flag}` (note the single colon).\n"
        )
    } else {
        String::new()
    };
    bail!(
        "the `cargo::` syntax for build script output instructions was added in \
         Rust 1.77.0, but the minimum supported Rust version of `{}` is {msrv}.\n\
         {old_syntax_suggestion}{DOCS_LINK_SUGGESTION}",
        ctx.pkg_descr
    )
}

/// Cargo's `parse_directive` and `parse_metadata`: split `KEY=VALUE` on the
/// first `=` and trim the end of the value.
fn split_key_value<'a>(
    whence: &str,
    line: &str,
    data: &'a str,
    syntax: &str,
) -> Result<(&'a str, &'a str), DirectiveError> {
    match data.split_once('=') {
        Some((k, v)) => Ok((k, v.trim_end())),
        None => bail!(
            "invalid output in {whence}: `{line}`\n\
             Expected a line with `{syntax}KEY=VALUE` with an `=` character, \
             but none was found.\n\
             {DOCS_LINK_SUGGESTION}"
        ),
    }
}

/// The path a `-L` value names, without rustc's `KIND=` prefix: Cargo's
/// `get_dynamic_search_path`. Only the kinds rustc accepts are stripped.
pub fn search_path_without_kind(value: &str) -> &str {
    match value.split_once('=') {
        Some(("native" | "crate" | "dependency" | "framework" | "all", path)) => path,
        _ => value,
    }
}

/// Whether a `-L` value lies inside `dir`, comparing whole path components as
/// `Path::starts_with` does: Cargo's `LibraryPath::new`.
pub fn is_inside(value: &str, dir: &Path) -> bool {
    Path::new(search_path_without_kind(value)).starts_with(dir)
}

/// Parse a build script's stdout as Cargo 1.99 does.
///
/// Lines are split on `\n`; a line that is not valid UTF-8 is skipped; each
/// line is trimmed of Unicode whitespace at both ends; lines that do not then
/// start with `cargo:` are ignored. An `Err` is a failure of the run with
/// Cargo's message. `error` directives are returned as log messages, not as
/// `Err`; see [`streamed_log_messages`] for when they fail the run.
pub fn parse(input: &[u8], ctx: &ParseContext<'_>) -> Result<BuildOutput, DirectiveError> {
    let mut out = BuildOutput::default();
    let whence = format!("build script of `{}`", ctx.pkg_descr);
    let pkg_descr = ctx.pkg_descr;

    for line in input.split(|b| *b == b'\n') {
        let Ok(line) = std::str::from_utf8(line) else {
            continue;
        };
        let line = line.trim();
        let mut old_syntax = false;
        let (key, value) = if let Some(data) = line.strip_prefix("cargo::") {
            check_msrv_for_new_syntax(ctx, data)?;
            split_key_value(&whence, line, data, "cargo::")?
        } else if let Some(data) = line.strip_prefix("cargo:") {
            old_syntax = true;
            if has_reserved_prefix(data) {
                split_key_value(&whence, line, data, "cargo:")?
            } else {
                // `cargo:foo=bar` is metadata.
                ("metadata", data)
            }
        } else {
            continue;
        };
        let value = value.to_owned();
        let syntax_prefix = if old_syntax { "cargo:" } else { "cargo::" };

        // Cargo's `check_and_add_target!`.
        let check_and_add_target = |out: &mut BuildOutput,
                                    target_kind: &str,
                                    is_kind: fn(&PackageTarget) -> bool,
                                    kind: SpliceKind|
         -> Result<(), DirectiveError> {
            if !ctx.targets.iter().any(is_kind) {
                bail!(
                    "invalid instruction `{syntax_prefix}{key}` from {whence}\n\
                     The package {pkg_descr} does not have a {target_kind} target."
                );
            }
            out.linker_args.push(LinkArg {
                kind,
                bin: None,
                value: value.clone(),
            });
            Ok(())
        };

        match key {
            "rustc-flags" => {
                let (paths, links) = parse_rustc_flags(&value, &whence)?;
                out.library_links.extend(links);
                out.library_paths
                    .extend(paths.into_iter().map(|p| LibraryPath::new(p, ctx)));
            }
            "rustc-link-lib" => out.library_links.push(value),
            "rustc-link-search" => out.library_paths.push(LibraryPath::new(value, ctx)),
            "rustc-link-arg-cdylib" | "rustc-cdylib-link-arg" => {
                if !ctx.targets.iter().any(PackageTarget::is_cdylib) {
                    out.log_messages.push(LogMessage {
                        severity: Severity::Warning,
                        message: format!(
                            "{syntax_prefix}{key} was specified in the build script of {pkg_descr}, \
                             but that package does not contain a cdylib target\n\
                             \n\
                             Allowing this was an unintended change in the 1.50 \
                             release, and may become an error in the future. \
                             For more information, see \
                             <https://github.com/rust-lang/cargo/issues/9562>."
                        ),
                    });
                }
                out.linker_args.push(LinkArg {
                    kind: SpliceKind::RustcLinkArgCdylib,
                    bin: None,
                    value,
                });
            }
            "rustc-link-arg-bins" => check_and_add_target(
                &mut out,
                "bin",
                PackageTarget::is_bin,
                SpliceKind::RustcLinkArgBins,
            )?,
            "rustc-link-arg-bin" => {
                let Some((bin_name, arg)) = value.split_once('=') else {
                    bail!(
                        "invalid instruction `{syntax_prefix}{key}={value}` from {whence}\n\
                         The instruction should have the form {syntax_prefix}{key}=BIN=ARG"
                    );
                };
                if !ctx.targets.iter().any(|t| t.is_bin() && t.name == bin_name) {
                    bail!(
                        "invalid instruction `{syntax_prefix}{key}` from {whence}\n\
                         The package {pkg_descr} does not have a bin target with the name `{bin_name}`."
                    );
                }
                out.linker_args.push(LinkArg {
                    kind: SpliceKind::RustcLinkArgBin,
                    bin: Some(bin_name.to_owned()),
                    value: arg.to_owned(),
                });
            }
            "rustc-link-arg-tests" => check_and_add_target(
                &mut out,
                "test",
                PackageTarget::is_test,
                SpliceKind::RustcLinkArgTests,
            )?,
            "rustc-link-arg-benches" => check_and_add_target(
                &mut out,
                "benchmark",
                PackageTarget::is_bench,
                SpliceKind::RustcLinkArgBenches,
            )?,
            "rustc-link-arg-examples" => check_and_add_target(
                &mut out,
                "example",
                PackageTarget::is_example,
                SpliceKind::RustcLinkArgExamples,
            )?,
            "rustc-link-arg" => out.linker_args.push(LinkArg {
                kind: SpliceKind::RustcLinkArg,
                bin: None,
                value,
            }),
            "rustc-cfg" => out.cfgs.push(value),
            "rustc-check-cfg" => out.check_cfgs.push(value),
            "rustc-env" => {
                let (name, val) = parse_rustc_env(&value, &whence)?;
                // Build scripts may not set RUSTC_BOOTSTRAP
                // (rust-lang/cargo#7088). Cargo also downgrades this to a
                // warning when its own environment's RUSTC_BOOTSTRAP lists the
                // library's crate name; breakbulk never gives Cargo
                // RUSTC_BOOTSTRAP, so that case cannot arise.
                if name == "RUSTC_BOOTSTRAP" {
                    if ctx.nightly_features_allowed {
                        out.log_messages.push(LogMessage {
                            severity: Severity::Warning,
                            message: format!(
                                "cannot set `RUSTC_BOOTSTRAP={val}` from {whence}.\n\
                                 note: crates cannot set `RUSTC_BOOTSTRAP` themselves, as doing so would subvert the stability guarantees of Rust for your project."
                            ),
                        });
                    } else {
                        // Cargo's `library_name`: the library's crate name.
                        let allow = ctx
                            .targets
                            .iter()
                            .find(|t| t.is_lib())
                            .map_or("1".to_owned(), |t| t.name.replace('-', "_"));
                        bail!(
                            "cannot set `RUSTC_BOOTSTRAP={val}` from {whence}.\n\
                             note: crates cannot set `RUSTC_BOOTSTRAP` themselves, as doing so would subvert the stability guarantees of Rust for your project.\n\
                             help: If you're sure you want to do this in your project, set the environment variable `RUSTC_BOOTSTRAP={allow}` before running cargo instead."
                        );
                    }
                } else {
                    out.env.push((name, val));
                }
            }
            "error" => out.log_messages.push(LogMessage {
                severity: Severity::Error,
                message: value,
            }),
            "warning" => out.log_messages.push(LogMessage {
                severity: Severity::Warning,
                message: value,
            }),
            "rerun-if-changed" => out.rerun_if_changed.push(value),
            "rerun-if-env-changed" => out.rerun_if_env_changed.push(value),
            "metadata" => {
                let syntax = if old_syntax {
                    "cargo:"
                } else {
                    "cargo::metadata="
                };
                let (k, v) = split_key_value(&whence, line, &value, syntax)?;
                out.metadata.push((k.to_owned(), v.to_owned()));
            }
            _ => bail!(
                "invalid output in {whence}: `{line}`\n\
                 Unknown key: `{key}`.\n\
                 {DOCS_LINK_SUGGESTION}"
            ),
        }
    }
    Ok(out)
}

/// Split a `rustc-flags` value into `-L` paths and `-l` libraries.
///
/// Whitespace-separated words; `-l` and `-L` take their value attached
/// (`-lfoo`) or as the next word (`-l foo`, even when that word starts with
/// `-`). Any other word is an error.
pub fn parse_rustc_flags(
    value: &str,
    whence: &str,
) -> Result<(Vec<String>, Vec<String>), DirectiveError> {
    let value = value.trim();
    let mut words = value
        .split(char::is_whitespace)
        .filter(|w| w.chars().any(|c| !c.is_whitespace()));
    let (mut paths, mut links) = (Vec::new(), Vec::new());
    while let Some(word) = words.next() {
        if word.starts_with("-l") || word.starts_with("-L") {
            let (flag, mut arg) = word.split_at(2);
            if arg.is_empty() {
                arg = match words.next() {
                    Some(v) => v,
                    // Cargo prints the (empty) value here, not the flag.
                    None => bail!("flag in rustc-flags has no value in {whence}: {arg}"),
                };
            }
            match flag {
                "-l" => links.push(arg.to_owned()),
                _ => paths.push(arg.to_owned()),
            }
        } else {
            bail!("only `-l` and `-L` flags are allowed in {whence}: `{value}`");
        }
    }
    Ok((paths, links))
}

/// Split a `rustc-env` value on its first `=`.
pub fn parse_rustc_env(value: &str, whence: &str) -> Result<(String, String), DirectiveError> {
    match value.split_once('=') {
        Some((n, v)) => Ok((n.to_owned(), v.to_owned())),
        None => bail!("Variable rustc-env has no value in {whence}: {value}"),
    }
}

/// The log messages Cargo collects while the script runs.
///
/// Cargo decodes stdout lossily, splits it with `str::lines` (so `\r\n` and
/// `\n` both end a line), and does not trim: only a line that starts exactly
/// with `cargo::error=` is an error, and only such lines make Cargo fail a run
/// that exited successfully ("build script logged errors"). An error directive
/// with leading whitespace is reported by [`parse`] but does not fail the run.
/// Warnings here are only shown when the run fails.
pub fn streamed_log_messages(stdout: &[u8]) -> Vec<LogMessage> {
    let text = String::from_utf8_lossy(stdout);
    let mut messages = Vec::new();
    for line in text.lines() {
        if let Some(error) = line.strip_prefix(CARGO_ERROR_SYNTAX) {
            messages.push(LogMessage {
                severity: Severity::Error,
                message: error.to_owned(),
            });
        }
        if let Some(warning) = line
            .strip_prefix(OLD_CARGO_WARNING_SYNTAX)
            .or(line.strip_prefix(NEW_CARGO_WARNING_SYNTAX))
        {
            messages.push(LogMessage {
                severity: Severity::Warning,
                message: warning.to_owned(),
            });
        }
    }
    messages
}

/// Cargo's `envify`: uppercase (Unicode-aware) and map `-` to `_`.
pub fn envify(s: &str) -> String {
    s.chars()
        .flat_map(char::to_uppercase)
        .map(|c| if c == '-' { '_' } else { c })
        .collect()
}

/// The `DEP_<LINKS>_<KEY>` variables a dependent run receives from a run whose
/// package declares `links`. Later values for the same key win, as with
/// Cargo's repeated `Command::env`.
pub fn metadata_env(links: &str, metadata: &[(String, String)]) -> Vec<(String, String)> {
    metadata
        .iter()
        .map(|(k, v)| (format!("DEP_{}_{}", envify(links), envify(k)), v.clone()))
        .collect()
}

/// `$flags/metadata.json`: what a run with `links` passes to dependents.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataFile {
    pub links: String,
    pub metadata: Vec<(String, String)>,
    /// The run's `OUT_DIR`, for dependents' [`LibraryPath::in_build_dir`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out: Option<String>,
}

impl MetadataFile {
    pub fn env(&self) -> Vec<(String, String)> {
        metadata_env(&self.links, &self.metadata)
    }
}

#[cfg(test)]
mod tests;
