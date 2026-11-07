//! `run` mode: one build-script run.
//!
//! 1. Set up the environment contract, with `OUT_DIR=$out` (writable, empty).
//! 2. Add `DEP_<LINKS>_<KEY>` from each `metadataFrom` run's `metadata.json`.
//! 3. Run the script with the package source as the working directory.
//! 4. Parse stdout into `$flags/directives.json`, and `$flags/metadata.json`
//!    when the package declares `links`.
//! 5. Fail on a non-zero exit, on death by signal (naming the signal), on a
//!    directive Cargo rejects, and on an `error` directive by Cargo's rule
//!    (only lines starting exactly with `cargo::error=`; decision log #8).
//!    Print warnings.
//! 6. Check `rerun-if-changed` paths against the sandbox: on failure, hint at
//!    each missing path and each unset `rerun-if-env-changed` variable; on
//!    success, warn about missing paths, or fail with `strictSources`.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::compile::fresh_dir;
use crate::directives::{
    BuildOutput, LogMessage, MetadataFile, ParseContext, Severity, parse, streamed_log_messages,
};
use crate::env::{CFlags, Outer, layered, read_capture};
use crate::process::{command, describe_status, shell_words};
use crate::spec::{RenderedRun, package_descr, package_name_version, package_spec};
use crate::splice::expand_dylib_path;
use crate::{
    DIRECTIVES_FILE, Error, METADATA_FILE, io_err, read_directives, read_metadata, write_json,
};

/// The build script to execute: `script` itself, or the one file in it when
/// it names its compile unit's `bin` output directory.
pub fn script_path(script: &Path) -> Result<PathBuf, Error> {
    if !script.is_dir() {
        return Ok(script.to_owned());
    }
    let mut files: Vec<PathBuf> = std::fs::read_dir(script)
        .map_err(|e| io_err("reading", script, e))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    match files.len() {
        1 => Ok(files.remove(0)),
        n => Err(Error(format!(
            "the build-script output {} holds {n} files; expected exactly one",
            script.display()
        ))),
    }
}

/// The env a run adds to its rendered env: `DEP_*` from upstream runs, then
/// `OUT_DIR`.
pub fn run_env(r: &RenderedRun, out: &Path, metadata: &[MetadataFile]) -> BTreeMap<String, String> {
    let mut env = r.env.clone();
    for m in metadata {
        env.extend(m.env());
    }
    env.insert("OUT_DIR".into(), out.display().to_string());
    env
}

/// What the run adds to C flags: its own random seed, and a prefix map for
/// each remapped path, including its own `OUT_DIR`.
pub fn run_cflags(r: &RenderedRun, outer: &Outer, out: &Path) -> CFlags {
    let mut prefix_maps = r.remap.clone();
    if let Some(name) = &r.out_dir_remap {
        prefix_maps.push((out.display().to_string(), name.clone()));
    }
    CFlags {
        random_seed: outer.random_seed(),
        prefix_maps,
    }
}

/// The `packages.<name>` option prefix for hints.
fn option_prefix(package: &str) -> String {
    let name = package_name_version(package).map_or(package, |(n, _)| n);
    if name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        format!("packages.{name}")
    } else {
        format!("packages.\"{name}\"")
    }
}

/// A `rerun-if-changed` path that is not in the sandbox.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MissingPath {
    /// As the script printed it.
    pub declared: String,
    /// Resolved against the package directory.
    pub path: PathBuf,
}

/// The `rerun-if-changed` paths missing from the sandbox. Relative paths are
/// relative to the package directory, as in Cargo.
pub fn missing_paths(out: &BuildOutput, cwd: &Path) -> Vec<MissingPath> {
    out.rerun_if_changed
        .iter()
        .map(|p| MissingPath {
            declared: p.clone(),
            path: cwd.join(p),
        })
        .filter(|m| m.path.symlink_metadata().is_err())
        .collect()
}

/// The `rerun-if-env-changed` variables not set in the run's env.
pub fn unset_vars<'a>(out: &'a BuildOutput, env: &BTreeMap<String, String>) -> Vec<&'a str> {
    out.rerun_if_env_changed
        .iter()
        .map(String::as_str)
        .filter(|v| !env.contains_key(*v))
        .collect()
}

/// One hint line per missing path.
pub fn path_hints(package: &str, cwd: &Path, missing: &[MissingPath]) -> Vec<String> {
    let opt = option_prefix(package);
    missing
        .iter()
        .map(|m| {
            let inside = Path::new(&m.declared).is_relative() || m.path.starts_with(cwd);
            if inside {
                format!(
                    "the build script declared `rerun-if-changed={}`, but {} is not in the sandbox; \
                     if the script needs it, add it to `{opt}.extraSources`",
                    m.declared,
                    m.path.display()
                )
            } else {
                format!(
                    "the build script declared `rerun-if-changed={}`, which is not in the sandbox; \
                     if it comes from a library or tool, add the package that provides it to \
                     `{opt}.inputs` (or `{opt}.nativeInputs` for tools)",
                    m.declared
                )
            }
        })
        .collect()
}

/// One hint line per unset variable.
pub fn env_hints(package: &str, unset: &[&str]) -> Vec<String> {
    let opt = option_prefix(package);
    unset
        .iter()
        .map(|v| {
            format!(
                "the build script reads `{v}` (`rerun-if-env-changed`), which is not set; \
                 set it with `{opt}.env.{v}` if the script needs it"
            )
        })
        .collect()
}

/// The parts of a finished run that decide its result.
pub struct Finished<'a> {
    pub run: &'a RenderedRun,
    pub argv: &'a [String],
    pub env: &'a BTreeMap<String, String>,
    pub out: &'a Path,
    pub status: std::process::ExitStatus,
    pub stdout: &'a [u8],
}

/// What a finished run produced, when it succeeded.
#[derive(Debug)]
pub struct Success {
    pub output: BuildOutput,
    /// Warnings to print, including the sandbox check's.
    pub warnings: Vec<String>,
}

fn failure(f: &Finished<'_>, reason: String, parsed: Option<&BuildOutput>) -> Error {
    let descr = package_descr(&f.run.package);
    let mut msg =
        format!("failed to run custom build command for `{descr}`\n\nCaused by:\n  {reason}");
    let stdout = String::from_utf8_lossy(f.stdout);
    if !stdout.trim().is_empty() {
        msg.push_str("\n  --- stdout\n");
        for l in stdout.lines() {
            msg.push_str("  ");
            msg.push_str(l);
            msg.push('\n');
        }
    }
    // Directives Cargo would still parse from a failed run's output, for
    // the hints. A parse error here is not worth reporting over the failure.
    let reparsed;
    let parsed = match parsed {
        Some(p) => Some(p),
        None => {
            reparsed = parse(f.stdout, &context(f.run, f.out)).ok();
            reparsed.as_ref()
        }
    };
    if let Some(p) = parsed {
        let cwd = Path::new(&f.run.cwd);
        let hints: Vec<String> = path_hints(&f.run.package, cwd, &missing_paths(p, cwd))
            .into_iter()
            .chain(env_hints(&f.run.package, &unset_vars(p, f.env)))
            .collect();
        for h in hints {
            msg.push_str("\nhint: ");
            msg.push_str(&h);
        }
    }
    Error(msg)
}

fn context<'a>(r: &'a RenderedRun, out: &'a Path) -> ParseContext<'a> {
    ParseContext {
        pkg_descr: &r.package,
        out_dir: out,
        nightly_features_allowed: r.nightly_features_allowed,
        targets: &r.targets,
        rust_version: r.rust_version.as_deref(),
    }
}

/// Decide the result of a finished run.
pub fn judge(f: &Finished<'_>) -> Result<Success, Error> {
    if !f.status.success() {
        let reason = format!(
            "process didn't exit successfully: `{}` ({})",
            shell_words(f.argv),
            describe_status(&f.status)
        );
        return Err(failure(f, reason, None));
    }
    let descr = package_descr(&f.run.package);
    let mut ctx = context(f.run, f.out);
    ctx.pkg_descr = &descr;
    let output = parse(f.stdout, &ctx).map_err(|e| failure(f, e.0, None))?;
    if streamed_log_messages(f.stdout)
        .iter()
        .any(|m| m.severity == Severity::Error)
    {
        return Err(failure(
            f,
            "build script logged errors".into(),
            Some(&output),
        ));
    }
    let cwd = Path::new(&f.run.cwd);
    let missing = missing_paths(&output, cwd);
    let hints = path_hints(&f.run.package, cwd, &missing);
    if f.run.strict_sources && !hints.is_empty() {
        let reason = format!(
            "`strictSources` is set and the build script declared paths that are not in the sandbox:\n  {}",
            hints.join("\n  ")
        );
        return Err(failure(f, reason, Some(&output)));
    }
    // Cargo's prefix for build-script messages is `name@version`.
    let spec = package_spec(&f.run.package);
    let mut warnings: Vec<String> = output
        .log_messages
        .iter()
        .map(|LogMessage { severity, message }| match severity {
            Severity::Warning => format!("warning: {spec}: {message}"),
            Severity::Error => format!("error: {spec}: {message}"),
        })
        .collect();
    warnings.extend(hints.into_iter().map(|h| format!("warning: {spec}: {h}")));
    Ok(Success { output, warnings })
}

/// The whole `run` mode.
pub fn run(r: &RenderedRun, outer: &Outer) -> Result<(), Error> {
    let out = outer.output("out")?;
    let flags = outer.output("flags")?;
    fresh_dir(&out)?;
    fresh_dir(&flags)?;

    let metadata = r
        .metadata_from
        .iter()
        .map(|f| read_metadata(Path::new(f)))
        .collect::<Result<Vec<_>, _>>()?;
    let capture = r
        .env_capture
        .as_deref()
        .map(|p| read_capture(Path::new(p)))
        .transpose()?;
    let dylib_dirs = r
        .dylib_path_from
        .iter()
        .map(|f| Ok((f.clone(), read_directives(Path::new(f))?)))
        .collect::<Result<BTreeMap<String, BuildOutput>, Error>>()?;
    let mut unit_env = run_env(r, &out, &metadata);
    expand_dylib_path(&mut unit_env, &r.dylib_path_from, |f| dylib_dirs.get(f))?;
    let env = layered(
        outer,
        capture.as_ref(),
        &unit_env,
        &run_cflags(r, outer, &out),
    );
    let argv = vec![script_path(Path::new(&r.script))?.display().to_string()];
    let cwd = PathBuf::from(&r.cwd);

    eprintln!("     Running `{}`", shell_words(&argv));
    let mut child = command(&argv, &env, &cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| Error(format!("could not start build script `{}`: {e}", argv[0])))?;
    let mut stdout = Vec::new();
    child
        .stdout
        .take()
        .expect("stdout is piped")
        .read_to_end(&mut stdout)
        .map_err(|e| Error(format!("reading the build script's stdout: {e}")))?;
    let status = child
        .wait()
        .map_err(|e| Error(format!("waiting for the build script: {e}")))?;

    let success = judge(&Finished {
        run: r,
        argv: &argv,
        env: &env,
        out: &out,
        status,
        stdout: &stdout,
    })?;
    for w in &success.warnings {
        eprintln!("{w}");
    }
    write_json(&flags.join(DIRECTIVES_FILE), &success.output)?;
    if let Some(links) = &r.links {
        write_json(
            &flags.join(METADATA_FILE),
            &MetadataFile {
                links: links.clone(),
                metadata: success.output.metadata.clone(),
            },
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
