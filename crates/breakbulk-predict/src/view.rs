//! Predicted views: a unit's source view narrowed to the files source
//! prediction finds (plus the declared `keep` paths), as a directory tree.
//!
//! Both delivery modes build the tree with [`materialize`]: IFD mode in a
//! derivation whose output Nix copies to the store with `builtins.path`,
//! dynamic-derivation mode in the outer derivation, which adds it with
//! [`nar`]. The same tree gives the same NAR and so the same store path
//! (`source`, recursive SHA-256), and the units come out the same in both.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{Fallback, predict_build_script_run, predict_crate};

/// What a view predicts for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    /// A compile (or doctest) of the crate root `root`.
    Crate,
    /// A run of the build script `root`.
    Run,
}

/// One predicted view to make.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ViewSpec {
    /// The instantiation key it stands for (`src:<dir>#<kind>/<name>`).
    pub key: String,
    /// The view prediction reads and takes the files from: its store
    /// path, rooted at the repository root. The package's widest view, so
    /// that a predicted read wins over a step that left the file out of
    /// the unit's own view.
    pub view: String,
    /// The unit's own view, which it sees when prediction falls back.
    /// Absent where the caller makes that view itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
    /// The package directory, relative to the repository root.
    pub package_dir: String,
    pub kind: Kind,
    /// Whether the compile sets `cfg(test)` (a test compile): items under
    /// a `#[cfg]` false for it are not read. False for a run.
    pub test: bool,
    /// The crate root or build script, relative to the repository root.
    pub root: String,
    /// Paths kept whatever the prediction says (`predictSources.keep` and
    /// the curated keeps), relative to the repository root.
    #[serde(default)]
    pub keep: Vec<String>,
}

/// What a predicted view holds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    /// The files (or directories) of the view to keep.
    Files(BTreeSet<String>),
    /// The prediction cannot be trusted: the unit sees `fallback`.
    Fallback(Vec<String>),
}

/// The paths of `spec`'s view that its predicted view keeps.
pub fn outcome(spec: &ViewSpec) -> Outcome {
    let view = Path::new(&spec.view);
    let (mut files, fallback): (BTreeSet<String>, Vec<Fallback>) = match spec.kind {
        Kind::Crate => {
            let p = predict_crate(view, &spec.root, &spec.package_dir, spec.test);
            (p.files, p.fallback)
        }
        Kind::Run => {
            let p = predict_build_script_run(view, &spec.root, &spec.package_dir);
            (p.declared, p.fallback)
        }
    };
    if !fallback.is_empty() {
        return Outcome::Fallback(fallback.iter().map(ToString::to_string).collect());
    }
    files.extend(spec.keep.iter().cloned());
    Outcome::Files(files)
}

/// A readable report of each spec's outcome, sorted by key: the paths its
/// predicted view holds (those `view` has; a `keep` path marked so), or
/// why it falls back.
pub fn explain(specs: &[ViewSpec]) -> String {
    let mut sorted: Vec<&ViewSpec> = specs.iter().collect();
    sorted.sort_by(|a, b| a.key.cmp(&b.key));
    let mut out = String::new();
    for s in sorted {
        match outcome(s) {
            Outcome::Files(files) => {
                let view = Path::new(&s.view);
                let held: Vec<&String> = files
                    .iter()
                    .filter(|p| view.join(p).symlink_metadata().is_ok() && !under_symlink(view, p))
                    .collect();
                out.push_str(&format!("{}: predicted, {} paths\n", s.key, held.len()));
                for p in held {
                    let kept = if s.keep.contains(p) { " (kept)" } else { "" };
                    out.push_str(&format!("  {p}{kept}\n"));
                }
            }
            Outcome::Fallback(reasons) => {
                out.push_str(&format!("{}: whole view\n", s.key));
                for r in reasons {
                    out.push_str(&format!("  {r}\n"));
                }
            }
        }
    }
    out
}

/// Write the predicted view: every path of `paths` that `view` has (a
/// directory with everything under it), at its place, and the package
/// directory even when empty (it is the unit's working directory), as
/// `lib/source-views.nix` `realize` keeps it.
pub fn materialize(
    view: &Path,
    package_dir: &str,
    paths: &BTreeSet<String>,
    dest: &Path,
) -> io::Result<()> {
    std::fs::create_dir_all(dest.join(package_dir))?;
    for p in paths {
        let src = view.join(p);
        if src.symlink_metadata().is_err() || under_symlink(view, p) {
            continue;
        }
        let to = dest.join(p);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        copy(&src, &to)?;
    }
    Ok(())
}

/// Whether a directory on the way to `rel` is a symbolic link: the file
/// set the view came from never holds such a path itself.
fn under_symlink(view: &Path, rel: &str) -> bool {
    let mut at = view.to_path_buf();
    let comps: Vec<&str> = rel.split('/').collect();
    for c in &comps[..comps.len().saturating_sub(1)] {
        at.push(c);
        if at
            .symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink())
        {
            return true;
        }
    }
    false
}

/// Write a whole view at `dest`, as [`materialize`] writes a predicted
/// one: for a unit whose prediction falls back where its view is made
/// from the spec alone.
pub fn copy_view(view: &Path, dest: &Path) -> io::Result<()> {
    copy(view, dest)
}

fn copy(src: &Path, to: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = src.symlink_metadata()?;
    let ft = meta.file_type();
    if to.symlink_metadata().is_ok() {
        // Already there: a directory kept whole and a file under it.
        if ft.is_dir() && to.is_dir() {
            for e in std::fs::read_dir(src)? {
                let e = e?;
                copy(&e.path(), &to.join(e.file_name()))?;
            }
        }
        return Ok(());
    }
    if ft.is_symlink() {
        std::os::unix::fs::symlink(std::fs::read_link(src)?, to)
    } else if ft.is_dir() {
        std::fs::create_dir(to)?;
        for e in std::fs::read_dir(src)? {
            let e = e?;
            copy(&e.path(), &to.join(e.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(src, to)?;
        let exec = meta.permissions().mode() & 0o111 != 0;
        std::fs::set_permissions(
            to,
            std::fs::Permissions::from_mode(if exec { 0o755 } else { 0o644 }),
        )
    }
}

/// The NAR serialization of `path`, as `nix-store --dump` writes it.
pub fn nar(path: &Path) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    str(&mut out, b"nix-archive-1");
    entry(&mut out, path)?;
    Ok(out)
}

fn str(out: &mut Vec<u8>, s: &[u8]) {
    out.extend_from_slice(&(s.len() as u64).to_le_bytes());
    out.extend_from_slice(s);
    out.extend(std::iter::repeat_n(0u8, (8 - s.len() % 8) % 8));
}

fn entry(out: &mut Vec<u8>, path: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;
    let meta = path.symlink_metadata()?;
    let ft = meta.file_type();
    str(out, b"(");
    str(out, b"type");
    if ft.is_symlink() {
        str(out, b"symlink");
        str(out, b"target");
        str(out, std::fs::read_link(path)?.as_os_str().as_bytes());
    } else if ft.is_dir() {
        str(out, b"directory");
        let mut names: BTreeMap<Vec<u8>, std::path::PathBuf> = BTreeMap::new();
        for e in std::fs::read_dir(path)? {
            let e = e?;
            names.insert(e.file_name().as_bytes().to_vec(), e.path());
        }
        for (name, p) in names {
            str(out, b"entry");
            str(out, b"(");
            str(out, b"name");
            str(out, &name);
            str(out, b"node");
            entry(out, &p)?;
            str(out, b")");
        }
    } else {
        str(out, b"regular");
        if meta.permissions().mode() & 0o111 != 0 {
            str(out, b"executable");
            str(out, b"");
        }
        str(out, b"contents");
        str(out, &std::fs::read(path)?);
    }
    str(out, b")");
    Ok(())
}
