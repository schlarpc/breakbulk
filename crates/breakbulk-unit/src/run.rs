//! `run` mode: one build-script run.
//!
//! 1. Set up the environment contract, with `OUT_DIR=$out` (writable, empty).
//! 2. Add `DEP_<LINKS>_<KEY>` from each `metadataFrom` run's `metadata.json`.
//! 3. Run the script with the package source as the working directory.
//! 4. Parse stdout into `$flags/directives.json`, and write
//!    `$flags/metadata.json` (package, `links` metadata, `OUT_DIR`).
//! 5. Fail on a non-zero exit, on death by signal (naming the signal), on a
//!    directive Cargo rejects, and on an `error` directive by Cargo's rule
//!    (only lines starting exactly with `cargo::error=`; decision log #8),
//!    with Cargo's messages ([`judge`]). Print warnings. A failure ends with
//!    the last lines of the script's
//!    stderr, which is streamed as the script runs, so a panic is not buried
//!    under stdout and hints.
//! 6. Check `rerun-if-changed` paths against the sandbox: on failure, hint at
//!    each missing path, at failures of common crates ([`recognize`]) and
//!    at the unset `rerun-if-env-changed` variables; on success, warn about
//!    missing paths and list them in `$flags/missing-paths.json`, which the
//!    products' `buildScriptPaths` check reads. The run itself does not
//!    fail on them: a check fails without blocking what is built above it,
//!    and names every missing path below a product at once.
//! 7. After a successful run, remove CMake's internal state from `OUT_DIR`
//!    ([`remove_cmake_state`]).

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::{Deserialize, Serialize};

use crate::compile::fresh_dir;
use crate::directives::{
    BuildOutput, LogMessage, MetadataFile, ParseContext, Severity, parse, streamed_log_messages,
};
use crate::env::{CFlags, Outer, layered, read_capture};
use crate::process::{command, describe_status, shell_words};
use crate::spec::{RenderedRun, package_descr, package_name_version, package_spec};
use crate::splice::expand_dylib_path;
use crate::test_only;
use crate::{
    DIRECTIVES_FILE, Error, METADATA_FILE, MISSING_PATHS_FILE, TARGET_FILES_FILE, io_err,
    read_directives, read_metadata, write_json,
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

/// The env a run adds to its rendered env: `DEP_*` from upstream runs,
/// `OUT_DIR` (`out_dir`, inside the run's `out`), and under Cargo's
/// trim-paths the build-directory pairs of `CARGO_TRIM_PATHS_REMAP`.
pub fn run_env(
    r: &RenderedRun,
    out_dir: &Path,
    metadata: &[MetadataFile],
) -> BTreeMap<String, String> {
    let mut env = r.env.clone();
    for m in metadata {
        env.extend(m.env());
    }
    env.insert("OUT_DIR".into(), out_dir.display().to_string());
    if let Some(v) = env.get_mut(TRIM_PATHS_REMAP) {
        *v = with_build_dir_pairs(v, r, &out_of(out_dir, &r.out_dir));
    }
    env
}

const TRIM_PATHS_REMAP: &str = "CARGO_TRIM_PATHS_REMAP";

/// The run's `out`: `out_dir` without the `rel` components it was created
/// at ([`prepare_out_dir`]).
fn out_of(out_dir: &Path, rel: &str) -> PathBuf {
    let mut p = out_dir;
    if !rel.is_empty() {
        for _ in rel.split('/') {
            p = p.parent().unwrap_or(p);
        }
    }
    p.to_owned()
}

/// Cargo's `CARGO_TRIM_PATHS_REMAP` is the package pair, the build
/// directory's pair and the sysroot's, in that order (cargo
/// `trim_paths.rs`, `trim_paths_remap`). The plan leaves out the build
/// directory's, because the run cannot name its own `out` in its
/// attributes; each run's `out` copies Cargo's build directory, so it comes
/// back here as `<out>=<name>`, with the same pair for every other run's
/// `out` the script names (`remap` entries with that name), before the
/// sysroot's. cc-rs turns the pairs into prefix maps for C code.
fn with_build_dir_pairs(value: &str, r: &RenderedRun, out: &Path) -> String {
    let Some(name) = r.out_dir_remap.as_deref() else {
        return value.to_owned();
    };
    if value.is_empty() {
        return String::new();
    }
    let mut pairs: Vec<String> = value.split(':').map(str::to_owned).collect();
    let mut add: Vec<String> = r
        .remap
        .iter()
        .filter(|(_, to)| to == name)
        .map(|(from, to)| format!("{from}={to}"))
        .collect();
    add.push(format!("{}={name}", out.display()));
    let at = pairs.len().saturating_sub(1);
    for p in add.into_iter().rev() {
        if !pairs.contains(&p) {
            pairs.insert(at, p);
        }
    }
    pairs.join(":")
}

/// What the run adds to C flags: its own random seed, and a prefix map for
/// each remapped path, including its own `OUT_DIR`.
pub fn run_cflags(r: &RenderedRun, out: &Path) -> CFlags {
    let mut prefix_maps = r.remap.clone();
    if let Some(name) = &r.out_dir_remap {
        prefix_maps.push((out.display().to_string(), name.clone()));
    }
    CFlags {
        random_seed: r.seed.clone(),
        prefix_maps,
    }
}

/// The `packages.<name>` option prefix for hints.
pub(crate) fn option_prefix(package: &str) -> String {
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
    /// Resolved against the package directory, `.` and `..` resolved
    /// lexically, so that a path in the source view reads as its place in
    /// the repository.
    pub path: PathBuf,
}

/// The `rerun-if-changed` paths missing from the sandbox. Relative paths are
/// relative to the package directory, as in Cargo.
pub fn missing_paths(out: &BuildOutput, cwd: &Path) -> Vec<MissingPath> {
    let mut seen = std::collections::BTreeSet::new();
    out.rerun_if_changed
        .iter()
        .filter(|p| seen.insert(p.as_str()))
        .map(|p| MissingPath {
            declared: p.clone(),
            path: cwd.join(p),
        })
        .filter(|m| m.path.symlink_metadata().is_err())
        .map(|m| MissingPath {
            path: test_only::normalize(&m.path),
            ..m
        })
        .collect()
}

/// The `rerun-if-env-changed` variables not set in the run's env.
/// Each once, in the order printed: a script may print the same one many
/// times.
pub fn unset_vars<'a>(out: &'a BuildOutput, env: &BTreeMap<String, String>) -> Vec<&'a str> {
    let mut seen = std::collections::BTreeSet::new();
    out.rerun_if_env_changed
        .iter()
        .map(String::as_str)
        .filter(|v| !env.contains_key(*v) && seen.insert(*v))
        .collect()
}

/// A missing `rerun-if-changed` path as `$flags/missing-paths.json` lists
/// it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MissingPathEntry {
    /// As the script printed it.
    pub declared: String,
    /// As [`MissingPath::path`].
    pub path: String,
    /// The option to add it to ([`path_hints`]).
    pub hint: String,
}

/// The entries of `$flags/missing-paths.json`.
pub fn missing_path_entries(
    package: &str,
    cwd: &Path,
    missing: &[MissingPath],
) -> Vec<MissingPathEntry> {
    missing
        .iter()
        .zip(path_hints(package, cwd, missing))
        .map(|(m, hint)| MissingPathEntry {
            declared: m.declared.clone(),
            path: m.path.display().to_string(),
            hint,
        })
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

/// The parts of a finished run that decide its result.
pub struct Finished<'a> {
    pub run: &'a RenderedRun,
    pub argv: &'a [String],
    pub env: &'a BTreeMap<String, String>,
    pub out: &'a Path,
    /// The `OUT_DIR`s of the runs in `metadata_from`.
    pub upstream_out_dirs: &'a [PathBuf],
    pub status: std::process::ExitStatus,
    pub stdout: &'a [u8],
    /// The end of the script's stderr, which was also streamed to ours.
    pub stderr_tail: &'a [u8],
}

/// How many lines of the script's stderr a failure repeats at its end.
const STDERR_TAIL_LINES: usize = 20;

/// The last `STDERR_TAIL_LINES` lines of `bytes`.
fn tail_lines(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(STDERR_TAIL_LINES);
    lines[start..].iter().map(|l| (*l).to_owned()).collect()
}

/// What a finished run produced, when it succeeded.
#[derive(Debug)]
pub struct Success {
    pub output: BuildOutput,
    /// Warnings to print, including the sandbox check's.
    pub warnings: Vec<String>,
    /// The declared `rerun-if-changed` paths missing from the sandbox.
    pub missing: Vec<MissingPathEntry>,
}

/// A failed run, as Cargo reports it: the build script's messages, then
/// the error.
#[derive(Debug)]
pub struct Failure {
    /// The `warning` and `error` directives Cargo collected while the script
    /// ran ([`streamed_log_messages`]), as Cargo prints them before the
    /// error of a run that exited unsuccessfully or logged errors.
    pub messages: Vec<String>,
    pub error: Error,
}

impl Failure {
    fn bare(error: Error) -> Failure {
        Failure {
            messages: Vec::new(),
            error,
        }
    }
}

/// A build script's message as Cargo prints it, prefixed `name@version`.
fn message_line(spec: &str, LogMessage { severity, message }: &LogMessage) -> String {
    match severity {
        Severity::Warning => format!("warning: {spec}: {message}"),
        Severity::Error => format!("error: {spec}: {message}"),
    }
}

/// Cargo's error for a run that failed as a process, with the script's
/// stdout as Cargo shows it, then breakbulk's [`diagnostics`].
fn failure(f: &Finished<'_>, reason: String) -> Error {
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
    msg.push_str(&diagnostics(f, None));
    Error(msg)
}

/// What breakbulk adds to a failure: hints at missing paths and unset
/// variables, and the end of the script's stderr.
fn diagnostics(f: &Finished<'_>, parsed: Option<&BuildOutput>) -> String {
    let mut msg = String::new();
    // Directives Cargo would still parse from a failed run's output, for
    // the hints. A parse error here is not worth reporting over the failure.
    let reparsed;
    let parsed = match parsed {
        Some(p) => Some(p),
        None => {
            reparsed = parse(f.stdout, &context(f)).ok();
            reparsed.as_ref()
        }
    };
    let cwd = Path::new(&f.run.cwd);
    let stdout = String::from_utf8_lossy(f.stdout);
    let stderr = String::from_utf8_lossy(f.stderr_tail);
    let mut hints = Vec::new();
    if let Some(p) = parsed {
        let lines = stdout.lines().chain(stderr.lines());
        hints.extend(path_hints(&f.run.package, cwd, &missing_paths(p, cwd)));
        hints.extend(recognize::hints(
            &option_prefix(&f.run.package),
            &p.rerun_if_env_changed,
            &unset_vars(p, f.env),
            lines,
        ));
    }
    // The script's output, or the paths it declared, naming a test-only path.
    let mut text = format!("{stdout}\n{stderr}");
    for m in parsed.map(|p| missing_paths(p, cwd)).unwrap_or_default() {
        text.push('\n');
        text.push_str(&m.path.display().to_string());
    }
    hints.extend(test_only::hints(
        &f.run.package,
        &text,
        &f.run.test_only,
        &f.run.remap,
        cwd,
    ));
    for h in hints {
        msg.push_str("\nhint: ");
        msg.push_str(&h);
    }
    // Cargo prints the script's stderr after its stdout. breakbulk streamed
    // it as the script ran, so stdout and the hints would bury a panic;
    // repeat its end last, where the build log's tail shows it.
    let tail = tail_lines(f.stderr_tail);
    if !tail.is_empty() {
        msg.push_str(&format!(
            "\n  --- stderr (last {} lines; all of it is above)\n",
            tail.len()
        ));
        for l in tail {
            msg.push_str("  ");
            msg.push_str(&l);
            msg.push('\n');
        }
    }
    msg
}

fn context<'a>(f: &'a Finished<'a>) -> ParseContext<'a> {
    ParseContext {
        pkg_descr: &f.run.package,
        out_dir: f.out,
        nightly_features_allowed: f.run.nightly_features_allowed,
        targets: &f.run.targets,
        rust_version: f.run.rust_version.as_deref(),
        upstream_out_dirs: f.upstream_out_dirs,
    }
}

/// Decide the result of a finished run.
///
/// As Cargo: a run that exited unsuccessfully fails with "failed to run
/// custom build command"; a directive Cargo rejects fails with Cargo's
/// message alone; an `error` directive fails with "build script logged
/// errors". The first and last print the streamed messages first.
pub fn judge(f: &Finished<'_>) -> Result<Success, Failure> {
    // Cargo's prefix for build-script messages is `name@version`.
    let spec = package_spec(&f.run.package);
    let streamed = streamed_log_messages(f.stdout);
    let streamed_lines = || streamed.iter().map(|m| message_line(&spec, m)).collect();
    if !f.status.success() {
        let reason = format!(
            "process didn't exit successfully: `{}` ({})",
            shell_words(f.argv),
            describe_status(&f.status)
        );
        return Err(Failure {
            messages: streamed_lines(),
            error: failure(f, reason),
        });
    }
    let descr = package_descr(&f.run.package);
    let mut ctx = context(f);
    ctx.pkg_descr = &descr;
    let output = parse(f.stdout, &ctx).map_err(|e| Failure::bare(Error(e.0)))?;
    if streamed.iter().any(|m| m.severity == Severity::Error) {
        return Err(Failure {
            messages: streamed_lines(),
            error: Error(format!(
                "build script logged errors{}",
                diagnostics(f, Some(&output))
            )),
        });
    }
    let cwd = Path::new(&f.run.cwd);
    let missing = missing_path_entries(&f.run.package, cwd, &missing_paths(&output, cwd));
    let mut warnings: Vec<String> = output
        .log_messages
        .iter()
        .map(|m| message_line(&spec, m))
        .collect();
    warnings.extend(
        missing
            .iter()
            .map(|m| format!("warning: {spec}: {}", m.hint)),
    );
    Ok(Success {
        output,
        warnings,
        missing,
    })
}

/// Remove the `CMakeFiles` directory of every CMake build tree under `out`
/// (a directory holding both `CMakeCache.txt` and `CMakeFiles/`), and
/// return what was removed.
///
/// CMake writes its configure log there (`CMakeConfigureLog.yaml`, or
/// `CMakeOutput.log` and `CMakeError.log` before CMake 3.26). It names the
/// randomly named try-compile directories under `CMakeFiles/CMakeScratch`,
/// so a run that builds with CMake (the `cmake` crate builds in
/// `$OUT_DIR/build`) is not reproducible: for cm-sys in the sys-native
/// fixture, `CMakeConfigureLog.yaml` is the only file `nix build --rebuild`
/// finds different. Nothing reads `CMakeFiles` after the build script: the
/// `cmake` crate reads `CMakeCache.txt` and `Makefile` back only within the
/// same run (cmake-rs 0.1.58, `Config::build` and `maybe_clear` in
/// `src/lib.rs`), and consumers link the installed or built libraries,
/// which lie outside it (inside are object files and generator
/// bookkeeping). The rest of the tree (`CMakeCache.txt`, `Makefile`, built
/// libraries) stays, because crates do link from `$OUT_DIR/build`. Nested
/// project directories' own `CMakeFiles` (no `CMakeCache.txt` next to
/// them) hold no configure log and stay too.
pub fn remove_cmake_state(out: &Path) -> Result<Vec<PathBuf>, Error> {
    let mut removed = Vec::new();
    let mut stack = vec![out.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let state = dir.join("CMakeFiles");
        let is_tree = dir.join("CMakeCache.txt").is_file()
            && state.symlink_metadata().is_ok_and(|m| m.is_dir());
        if is_tree {
            std::fs::remove_dir_all(&state).map_err(|e| io_err("removing", &state, e))?;
            removed.push(state);
        }
        let entries = std::fs::read_dir(&dir).map_err(|e| io_err("reading", &dir, e))?;
        for entry in entries {
            let entry = entry.map_err(|e| io_err("reading", &dir, e))?;
            let file_type = entry
                .file_type()
                .map_err(|e| io_err("reading", &entry.path(), e))?;
            if file_type.is_dir() {
                stack.push(entry.path());
            }
        }
    }
    removed.sort();
    Ok(removed)
}

/// The whole `run` mode.
pub fn run(r: &RenderedRun, outer: &Outer) -> Result<(), Error> {
    let out = outer.output("out")?;
    let flags = outer.output("flags")?;
    fresh_dir(&out)?;
    fresh_dir(&flags)?;
    let out_dir = prepare_out_dir(&out, &r.out_dir)?;
    let (package, version) = package_name_version(&r.package).ok_or_else(|| {
        Error(format!(
            "cannot read a name and version from package id `{}`",
            r.package
        ))
    })?;

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
    let mut unit_env = run_env(r, &out_dir, &metadata);
    expand_dylib_path(&mut unit_env, &r.dylib_path_from, |f| dylib_dirs.get(f))?;
    let env = layered(outer, capture.as_ref(), &unit_env, &run_cflags(r, &out));
    let argv = vec![script_path(Path::new(&r.script))?.display().to_string()];
    let cwd = PathBuf::from(&r.cwd);

    eprintln!("     Running `{}`", shell_words(&argv));
    let mut child = command(&argv, &env, &cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error(format!("could not start build script `{}`: {e}", argv[0])))?;
    let stderr_tail = tee_stderr(child.stderr.take().expect("stderr is piped"));
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
    let stderr_tail = stderr_tail
        .join()
        .map_err(|_| Error("copying the build script's stderr failed".into()))?;

    let upstream_out_dirs: Vec<PathBuf> = metadata.iter().map(|m| PathBuf::from(&m.out)).collect();
    let judged = judge(&Finished {
        run: r,
        argv: &argv,
        env: &env,
        out: &out_dir,
        upstream_out_dirs: &upstream_out_dirs,
        status,
        stdout: &stdout,
        stderr_tail: &stderr_tail,
    });
    let success = match judged {
        Ok(s) => s,
        Err(Failure { messages, error }) => {
            for m in &messages {
                eprintln!("{m}");
            }
            return Err(error);
        }
    };
    for w in &success.warnings {
        eprintln!("{w}");
    }
    for removed in remove_cmake_state(&out)? {
        eprintln!(
            "     Removed CMake's internal state `{}`",
            removed.display()
        );
    }
    let outside = files_outside(&out, &out_dir)?;
    let mut output = success.output;
    output.target_dirs = target_dirs(&out, &r.out_dir, &outside);
    write_json(&flags.join(DIRECTIVES_FILE), &output)?;
    if !outside.is_empty() {
        write_json(&flags.join(TARGET_FILES_FILE), &outside)?;
    }
    if !success.missing.is_empty() {
        write_json(&flags.join(MISSING_PATHS_FILE), &success.missing)?;
    }
    write_json(
        &flags.join(METADATA_FILE),
        &MetadataFile {
            package: package.to_owned(),
            version: version.to_owned(),
            links: r.links.clone(),
            metadata: output.metadata.clone(),
            out: out_dir.display().to_string(),
        },
    )?;
    Ok(())
}

/// Create the run's `OUT_DIR` at `rel` inside `out` (#23), with what Cargo
/// creates around it before running build scripts, so a script that walks
/// up from `OUT_DIR` to the target directory finds what it finds under
/// Cargo: in the classic layout (`<profile>/build/<pkg>-<hash>/out`),
/// `<profile>/deps` and `<profile>/examples` (cargo `layout.rs`,
/// `BuildDirLayout::prepare`); the new layout
/// (`<profile>/build/<pkg>/<hash>/out`, Cargo 1.100) creates neither.
/// Returns the `OUT_DIR`.
pub fn prepare_out_dir(out: &Path, rel: &str) -> Result<PathBuf, Error> {
    if rel.is_empty() {
        return Ok(out.to_owned());
    }
    let out_dir = out.join(rel);
    let mut dirs = vec![out_dir.clone()];
    // Classic: `…/<profile>/build/<pkg>-<hash>/out`; new: the unit
    // directory is the bare hash, `…/build/<pkg>/<hash>/out`.
    let parts: Vec<&str> = rel.split('/').collect();
    if let [profile @ .., "build", unit, "out"] = parts.as_slice()
        && unit.contains('-')
    {
        let profile = out.join(profile.join("/"));
        dirs.push(profile.join("deps"));
        dirs.push(profile.join("examples"));
    }
    for d in dirs {
        std::fs::create_dir_all(&d).map_err(|e| io_err("creating", &d, e))?;
    }
    Ok(out_dir)
}

/// Of `<profile>` and `<profile>/deps` in the run's `out` (`rel` is
/// `[<triple>/]<profile>/build/…/out`), the ones holding a file of `files`
/// (paths relative to `out`), as absolute paths: what goes on a test's
/// dynamic-library path ([`BuildOutput::target_dirs`]).
pub fn target_dirs(out: &Path, rel: &str, files: &[String]) -> Vec<String> {
    let Some((profile, _)) = rel.split_once("/build/") else {
        return Vec::new();
    };
    [profile.to_owned(), format!("{profile}/deps")]
        .into_iter()
        .filter(|d| {
            files
                .iter()
                .any(|f| Path::new(f).parent() == Some(Path::new(d)))
        })
        .map(|d| out.join(d).display().to_string())
        .collect()
}

/// Files (and symlinks) under `out` but not under `out_dir`, relative to
/// `out`, sorted: what the script wrote outside its `OUT_DIR`.
pub fn files_outside(out: &Path, out_dir: &Path) -> Result<Vec<String>, Error> {
    fn walk(dir: &Path, skip: &Path, root: &Path, found: &mut Vec<String>) -> Result<(), Error> {
        if dir == skip {
            return Ok(());
        }
        let entries = std::fs::read_dir(dir).map_err(|e| io_err("reading", dir, e))?;
        for e in entries {
            let e = e.map_err(|e| io_err("reading", dir, e))?;
            let p = e.path();
            let t = e.file_type().map_err(|e| io_err("reading", &p, e))?;
            if t.is_dir() {
                walk(&p, skip, root, found)?;
            } else if let Ok(rel) = p.strip_prefix(root) {
                found.push(rel.display().to_string());
            }
        }
        Ok(())
    }
    let mut found = Vec::new();
    if out_dir != out {
        walk(out, out_dir, out, &mut found)?;
    }
    found.sort();
    Ok(found)
}

/// Copy the script's stderr to ours as it comes, and keep its last 64 KiB
/// for the failure message.
fn tee_stderr(mut from: std::process::ChildStderr) -> std::thread::JoinHandle<Vec<u8>> {
    use std::io::Write;
    const KEEP: usize = 64 * 1024;
    std::thread::spawn(move || {
        let mut kept = Vec::new();
        let mut buf = [0u8; 8192];
        let mut err = std::io::stderr();
        loop {
            match from.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let _ = err.write_all(&buf[..n]);
                    kept.extend_from_slice(&buf[..n]);
                    if kept.len() > 2 * KEEP {
                        kept.drain(..kept.len() - KEEP);
                    }
                }
            }
        }
        if kept.len() > KEEP {
            kept.drain(..kept.len() - KEEP);
        }
        kept
    })
}

mod recognize;

#[cfg(test)]
mod tests;
