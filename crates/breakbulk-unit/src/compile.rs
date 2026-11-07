//! `compile` mode: one rustc invocation.
//!
//! 1. Set up the environment contract ([`crate::env`]).
//! 2. Symlink every dependency's crate file into `$TMPDIR/deps` (those the
//!    unit lists, and those its dependencies' manifests name; see
//!    [`crate::manifest`]) and pass it as the one `-L dependency=`.
//! 3. Expand splice points from the referenced runs' `flags` outputs.
//! 4. Add path remapping (`--remap-path-prefix`, `--remap-path-scope`).
//! 5. Point `--out-dir` at `$TMPDIR/out` and run the program.
//! 6. Print the `rendered` text of rustc's JSON diagnostics; drop artifact
//!    notifications.
//! 7. Move the listed outputs to their derivation outputs, and debuginfo
//!    side files to `debug` when the unit has it; discard the rest
//!    (dep-info).
//! 8. For a library, write its own manifest into its `rmeta` output.
//!
//! The plan carries no `--out-dir`, no `-L dependency=` and no
//! `-C incremental`: those name Cargo's shared target directory, which does
//! not exist here. Finding one is an error, not something to rewrite.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use crate::diag::{Line, classify};
use crate::directives::BuildOutput;
use crate::env::{CFlags, Outer, layered, read_capture};
use crate::process::{command, describe_status, shell_words};
use crate::spec::{DEBUG_OUTPUT, RenderedArg, RenderedCompile, SpliceKind, derivation_output};
use crate::splice::{expand_args, expand_dylib_path, expand_env};
use crate::{Error, io_err, manifest, read_directives};

/// The directories a compile works in, under `$TMPDIR`.
#[derive(Clone, Debug)]
pub struct WorkDirs {
    pub deps: PathBuf,
    pub out: PathBuf,
}

impl WorkDirs {
    pub fn under(tmp: &Path) -> WorkDirs {
        WorkDirs {
            deps: tmp.join("deps"),
            out: tmp.join("out"),
        }
    }
}

/// A fully expanded invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invocation {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
}

/// Reject literal arguments that name Cargo's target directory or conflict
/// with what `breakbulk-unit` adds.
pub fn check_args(c: &RenderedCompile) -> Result<(), Error> {
    let lits: Vec<&str> = c
        .args
        .iter()
        .map(|a| match a {
            RenderedArg::Literal(s) => s.as_str(),
            RenderedArg::Splice(_) => "",
        })
        .collect();
    let bad = |what: &str, arg: &str| {
        Err(Error(format!(
            "the unit's arguments already contain {what} (`{arg}`); the plan must leave it to breakbulk-unit"
        )))
    };
    for (i, a) in lits.iter().enumerate() {
        let next = lits.get(i + 1).copied().unwrap_or("");
        if *a == "--out-dir" || a.starts_with("--out-dir=") {
            return bad("an output directory", a);
        }
        let codegen = match *a {
            "-C" | "--codegen" => Some(next),
            _ => a
                .strip_prefix("-C")
                .or_else(|| a.strip_prefix("--codegen=")),
        };
        if let Some(cg) = codegen
            && cg.trim_start().starts_with("incremental")
        {
            return bad("incremental compilation", cg);
        }
        let search = match *a {
            "-L" => Some(next),
            _ => a.strip_prefix("-L"),
        };
        if let Some(s) = search
            && s.starts_with("dependency=")
        {
            return bad("a dependency search path", s);
        }
        if c.remap_scope.is_some()
            && (*a == "--remap-path-scope" || a.starts_with("--remap-path-scope="))
        {
            return bad("a remap scope", a);
        }
    }
    Ok(())
}

/// The arguments `breakbulk-unit` appends to every compile.
pub fn added_args(c: &RenderedCompile, dirs: &WorkDirs) -> Vec<String> {
    let mut args = vec![
        "--out-dir".to_owned(),
        dirs.out.display().to_string(),
        "-L".to_owned(),
        format!("dependency={}", dirs.deps.display()),
    ];
    for (from, to) in &c.remap {
        args.push(format!("--remap-path-prefix={from}={to}"));
    }
    // With Cargo's trim-paths, `remap` is empty and the pairs are in the
    // arguments; a scope still applies to them.
    if let Some(scope) = &c.remap_scope {
        args.push(format!("--remap-path-scope={scope}"));
    }
    args
}

/// Read the `directives.json` of every run the unit splices from.
pub fn load_directives(c: &RenderedCompile) -> Result<BTreeMap<String, BuildOutput>, Error> {
    let flags: BTreeSet<&str> = c
        .args
        .iter()
        .filter_map(|a| match a {
            RenderedArg::Splice(s) => Some(s.splice.as_str()),
            RenderedArg::Literal(_) => None,
        })
        .chain(c.env_splices.iter().map(|s| s.splice.as_str()))
        .chain(c.dylib_path_from.iter().map(String::as_str))
        .collect();
    flags
        .into_iter()
        .map(|f| Ok((f.to_owned(), read_directives(Path::new(f))?)))
        .collect()
}

/// Expand the unit into the command to run.
pub fn invocation(
    c: &RenderedCompile,
    outer: &Outer,
    directives: &BTreeMap<String, BuildOutput>,
    dirs: &WorkDirs,
) -> Result<Invocation, Error> {
    check_args(c)?;
    if c.program.is_empty() {
        return Err(Error::new("the unit has an empty program"));
    }
    let lookup = |f: &str| directives.get(f);
    let mut argv = c.program.clone();
    argv.extend(expand_args(&c.args, lookup)?);
    argv.extend(added_args(c, dirs));
    let mut unit_env = expand_env(&c.env, &c.env_splices, lookup)?;
    expand_dylib_path(&mut unit_env, &c.dylib_path_from, lookup)?;
    let capture = c
        .env_capture
        .as_deref()
        .map(|p| read_capture(Path::new(p)))
        .transpose()?;
    let cflags = CFlags {
        random_seed: c.seed.clone(),
        prefix_maps: c.remap.clone(),
    };
    Ok(Invocation {
        argv,
        env: layered(outer, capture.as_ref(), &unit_env, &cflags),
        cwd: PathBuf::from(&c.cwd),
    })
}

/// Create `dir` afresh, holding a symlink to each dependency file.
pub fn link_deps(deps: &[String], dir: &Path) -> Result<(), Error> {
    fresh_dir(dir)?;
    let mut seen: BTreeMap<&str, &str> = BTreeMap::new();
    for d in deps {
        let path = Path::new(d);
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| Error(format!("dependency path `{d}` has no file name")))?;
        if let Some(prev) = seen.insert(name, d) {
            if prev == d {
                continue;
            }
            return Err(Error(format!(
                "two dependencies have the file name `{name}`: {prev} and {d}"
            )));
        }
        if !path.exists() {
            return Err(Error(format!("dependency {d} does not exist")));
        }
        symlink(path, &dir.join(name))?;
    }
    Ok(())
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> Result<(), Error> {
    std::os::unix::fs::symlink(target, link).map_err(|e| io_err("creating symlink", link, e))
}

#[cfg(not(unix))]
fn symlink(target: &Path, link: &Path) -> Result<(), Error> {
    std::fs::copy(target, link)
        .map(drop)
        .map_err(|e| io_err("copying to", link, e))
}

pub(crate) fn fresh_dir(dir: &Path) -> Result<(), Error> {
    if dir.symlink_metadata().is_ok() {
        std::fs::remove_dir_all(dir).map_err(|e| io_err("removing", dir, e))?;
    }
    std::fs::create_dir_all(dir).map_err(|e| io_err("creating", dir, e))
}

/// Run rustc, rendering its stderr. Returns an error naming the crate when
/// it fails.
pub fn run_rustc(inv: &Invocation, crate_name: &str) -> Result<(), Error> {
    eprintln!("     Running `{}`", shell_words(&inv.argv));
    let mut child = command(&inv.argv, &inv.env, &inv.cwd)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error(format!("could not start `{}`: {e}", inv.argv[0])))?;
    let stderr = child.stderr.take().expect("stderr is piped");
    let mut future_incompat = 0;
    {
        let mut err = std::io::stderr().lock();
        for line in BufReader::new(stderr).split(b'\n') {
            let line = line.map_err(|e| Error(format!("reading rustc's stderr: {e}")))?;
            let line = String::from_utf8_lossy(&line);
            let line = line.strip_suffix('\r').unwrap_or(&line);
            match classify(line) {
                Line::Print(text) => {
                    let _ = err.write_all(text.as_bytes());
                }
                Line::Drop => {}
                Line::FutureIncompat(n) => future_incompat += n,
            }
        }
    }
    let status = child
        .wait()
        .map_err(|e| Error(format!("waiting for `{}`: {e}", inv.argv[0])))?;
    if future_incompat > 0 {
        eprintln!(
            "warning: `{crate_name}` has {future_incompat} future-incompatibility report(s); run `cargo report future-incompatibilities` locally for details"
        );
    }
    if !status.success() {
        return Err(Error(format!(
            "could not compile `{crate_name}` ({})",
            describe_status(&status)
        )));
    }
    Ok(())
}

/// Debuginfo side files rustc writes next to a linked output but
/// `--print=file-names` does not name: `.pdb` (msvc), `.dwp`
/// (`split-debuginfo=packed`), `.dwo` (`unpacked`).
pub const DEBUG_SIDE_FILES: &[&str] = &[".pdb", ".dwp", ".dwo"];

/// Move each listed output file into its derivation output. Every output
/// named in `outputs` is created, even if it lists no files. When the unit
/// has a `debug` output (it lists no files), unlisted debuginfo side files
/// ([`DEBUG_SIDE_FILES`]) go there, under rustc's names. Other unlisted
/// files, dep-info aside, are reported and left behind.
pub fn collect_outputs(
    outputs: &BTreeMap<String, Vec<String>>,
    from: &Path,
    dest: impl Fn(&str) -> Result<PathBuf, Error>,
) -> Result<(), Error> {
    let mut listed = BTreeSet::new();
    for (output, files) in outputs {
        let dir = dest(derivation_output(output))?;
        std::fs::create_dir_all(&dir).map_err(|e| io_err("creating", &dir, e))?;
        for f in files {
            let src = from.join(f);
            if src.symlink_metadata().is_err() {
                let mut found: Vec<String> = std::fs::read_dir(from)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                found.sort();
                return Err(Error(format!(
                    "rustc did not write `{f}` (output `{output}`); it wrote: {}",
                    found.join(", ")
                )));
            }
            move_file(&src, &dir.join(f))?;
            listed.insert(f.as_str());
        }
    }
    let debug = if outputs.contains_key(DEBUG_OUTPUT) {
        Some(dest(DEBUG_OUTPUT)?)
    } else {
        None
    };
    let mut names: Vec<String> = Vec::new();
    for e in std::fs::read_dir(from).map_err(|e| io_err("reading", from, e))? {
        let e = e.map_err(|e| io_err("reading", from, e))?;
        names.push(e.file_name().to_string_lossy().into_owned());
    }
    names.sort();
    for name in names {
        if listed.contains(name.as_str()) || name.ends_with(".d") {
            continue;
        }
        let side = DEBUG_SIDE_FILES.iter().any(|x| name.ends_with(x));
        match &debug {
            Some(dir) if side && from.join(&name).is_file() => {
                move_file(&from.join(&name), &dir.join(&name))?;
            }
            _ => eprintln!("warning: discarding unlisted rustc output `{name}`"),
        }
    }
    Ok(())
}

/// Rename, or copy and remove when the two paths are on different file
/// systems (the build directory and the store usually are).
pub(crate) fn move_file(src: &Path, dst: &Path) -> Result<(), Error> {
    if std::fs::rename(src, dst).is_ok() {
        return Ok(());
    }
    std::fs::copy(src, dst).map_err(|e| io_err("copying to", dst, e))?;
    std::fs::remove_file(src).map_err(|e| io_err("removing", src, e))
}

/// Every crate file for the dependency directory: `deps`, plus what the
/// manifests below name when the unit does not link.
pub fn all_deps(c: &RenderedCompile, below: &manifest::Below) -> Vec<String> {
    let mut deps = c.deps.clone();
    if c.link_manifest_crates {
        deps.extend(below.crates.iter().cloned());
    }
    deps
}

/// The unit's own manifest, for its `rmeta` output: its `.rmeta` file(s) in
/// `rmeta_dir`, the crates no manifest below names, the `flags` of its
/// `rustc-link-search` splices that no manifest below names, and its
/// dependencies' manifests. `None` for a unit without an `rmeta` output.
pub fn own_manifest(
    c: &RenderedCompile,
    rmeta_dir: &Path,
    below: &manifest::Below,
) -> Option<manifest::Manifest> {
    let files = c.outputs.get("rmeta")?;
    let mut m = manifest::Manifest {
        crates: files
            .iter()
            .map(|f| rmeta_dir.join(f).display().to_string())
            .collect(),
        flags: BTreeSet::new(),
        deps: c.dep_manifests.iter().cloned().collect(),
    };
    m.crates.extend(c.manifest_crates.iter().cloned());
    for a in &c.args {
        if let RenderedArg::Splice(s) = a
            && s.kind == SpliceKind::RustcLinkSearch
            && !below.flags.contains(&s.splice)
        {
            m.flags.insert(s.splice.clone());
        }
    }
    Some(m)
}

/// The whole `compile` mode.
pub fn compile(c: &RenderedCompile, outer: &Outer) -> Result<(), Error> {
    let dirs = WorkDirs::under(&outer.tmpdir());
    let below = manifest::walk(&c.dep_manifests)?;
    let directives = load_directives(c)?;
    let inv = invocation(c, outer, &directives, &dirs)?;
    link_deps(&all_deps(c, &below), &dirs.deps)?;
    fresh_dir(&dirs.out)?;
    run_rustc(&inv, &c.krate.name)?;
    collect_outputs(&c.outputs, &dirs.out, |o| outer.output(o))?;
    if c.outputs.contains_key("rmeta") {
        let dir = outer.output("rmeta")?;
        if let Some(m) = own_manifest(c, &dir, &below) {
            manifest::write(&dir, &m)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
