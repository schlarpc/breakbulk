//! Hints for a unit that fails naming a path its source view lacks.
//!
//! A unit of a repository package sees only its package's source view
//! ([`SourceView`]). Its output (rustc's diagnostics, a proc macro's error,
//! a build script's or a test's output) is searched for paths, absolute,
//! relative to the working directory, or as a remap names them
//! (`--remap-path-prefix`, so `crates/x/src/../../docs/a.md` in a
//! diagnostic). Each that resolves to a place that does not exist gets a
//! hint:
//!
//! - inside the package directory, repeating its end (`crates/x/crates/x/…`):
//!   a library that takes the topmost directory with a `Cargo.toml` as the
//!   workspace root found the package's own, so the hint names a
//!   `sources` entry that adds the workspace's root `Cargo.toml`;
//! - under a path a step left out ([`Removed`]): that step, `sources.<name>`
//!   (or source prediction, whose fix is `predictSources.keep`). The view
//!   carries what each step of its pipeline left out, and the path the
//!   most specific report names wins;
//! - otherwise outside the package directory: `extraSources`, or
//!   `test.sourceScope` for the package's test units. Inside it, a path no
//!   step left out is not in the repository either.
//!
//! Only the path decides, not who printed it, so one rule covers rustc,
//! proc macros and test output. A message without a path gets no hint.
//!
//! A crate of its own, with a binary for test runs (`breakbulk-hints SPEC
//! LOG`, [`main`]), rather than a mode of `breakbulk-unit`: a test run that
//! calls it then has no `breakbulk-unit` among its inputs, so with content
//! addressing a `breakbulk-unit` change leaves test runs cut off.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::process::ExitCode;

use serde::{Deserialize, Serialize};

/// The source view a unit of a repository package sees, for the hints
/// when it fails naming a path the view lacks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SourceView {
    /// The view's root, which stands for the repository root.
    pub root: String,
    /// The package directory, relative to the repository root (empty for
    /// the root).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub package_dir: String,
    /// What the steps of the view's pipeline left out, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<Removed>,
}

/// What one step left out of a view (`lib/source-views.nix` `pipeline`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Removed {
    /// The `sources` entry, or [`PREDICT`].
    pub step: String,
    /// Paths relative to the repository root, everything under each
    /// included; `""` for every path.
    pub paths: Vec<String>,
    /// A step of the package's non-test units' view, not of this unit's:
    /// it counts for a path into that view (a library's
    /// `CARGO_MANIFEST_DIR`, a build script's `rustc-env`), which a unit
    /// with another view can name too.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub elsewhere: bool,
}

/// The step name of source prediction in [`Removed::step`].
pub const PREDICT: &str = "predictSources";

/// The name and version in a Cargo package id spec, as `cargo metadata`
/// writes them: `registry+https://…#ring@0.17.14`, or `path+file:///…/app#0.1.0`
/// where the name is the URL's last path segment. Returns `None` for other
/// shapes.
pub fn package_name_version(id: &str) -> Option<(&str, &str)> {
    let (url, frag) = id.rsplit_once('#')?;
    if let Some((name, version)) = frag.split_once('@') {
        return Some((name, version));
    }
    let path = url.split(['?', '#']).next()?;
    let name = path.trim_end_matches('/').rsplit('/').next()?;
    (!name.is_empty() && !frag.is_empty()).then_some((name, frag))
}

/// A package's options, `packages.<name>`, quoted when the name needs it.
/// `package` is a Cargo package id spec or a bare name.
pub fn option_prefix(package: &str) -> String {
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

/// `p` with `.` and `..` components resolved lexically.
pub fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => match out.components().next_back() {
                // `/..` is `/`.
                Some(Component::RootDir) => {}
                Some(Component::Normal(_)) => {
                    out.pop();
                }
                _ => out.push(".."),
            },
            c => out.push(c),
        }
    }
    out
}

/// The words of `text` that may be paths: those with a `/`, split at
/// whitespace and the punctuation messages put around paths, without a
/// sentence's final `.`. Source locations (`src/lib.rs:3:5`, a span or a
/// panic location) are left out: they name files rustc read, and the
/// remapped names of other packages' files would resolve into this view.
fn words(text: &str) -> Vec<&str> {
    const DELIMS: &str = "`'\"(),;:[]{}<>=";
    let mut out = Vec::new();
    let mut start = None;
    let ends = text
        .char_indices()
        .map(|(i, c)| (i, c.is_whitespace() || DELIMS.contains(c)))
        .chain(std::iter::once((text.len(), true)));
    for (i, delim) in ends {
        match (delim, start) {
            (true, Some(s)) => {
                start = None;
                let mut rest = text[i..].chars();
                if rest.next() == Some(':') && rest.next().is_some_and(|c| c.is_ascii_digit()) {
                    continue;
                }
                let mut w = &text[s..i];
                if let Some(t) = w.strip_suffix('.')
                    && !t.ends_with(['.', '/'])
                {
                    w = t;
                }
                if w.contains('/') {
                    out.push(w);
                }
            }
            (false, None) => start = Some(i),
            _ => {}
        }
    }
    out
}

/// A path a unit's output names that its view lacks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Found {
    /// Under `entry`, which the step `step` left out.
    Removed {
        path: PathBuf,
        rel: String,
        step: String,
        entry: String,
    },
    /// In the package directory, repeating its end: resolved against the
    /// package directory where the workspace root was meant.
    WorkspaceRoot { path: PathBuf, rel: String },
    /// Inside the unit's view, outside the package directory, and no step
    /// left it out.
    Missing { path: PathBuf, rel: String },
}

impl Found {
    pub fn path(&self) -> &Path {
        match self {
            Found::Removed { path, .. }
            | Found::WorkspaceRoot { path, .. }
            | Found::Missing { path, .. } => path,
        }
    }
}

/// Where a word of the output can point: itself (relative to `cwd`), and
/// its name under each remap pair.
fn candidates(word: &str, remap: &[(String, String)], cwd: &Path) -> Vec<PathBuf> {
    let w = normalize(Path::new(word));
    let mut out = Vec::new();
    for (from, to) in remap {
        let to = normalize(Path::new(to));
        if to.is_absolute() == w.is_absolute()
            && let Ok(rest) = w.strip_prefix(&to)
        {
            out.push(normalize(&Path::new(from).join(rest)));
        }
    }
    out.push(if w.is_absolute() {
        w
    } else {
        normalize(&cwd.join(&w))
    });
    out
}

/// The step that left `rel` out, with the path of its report: the most
/// specific path that holds `rel`, of the later step on a tie. `keep`
/// decides which reports count, and whether one of them does here.
fn left_out_by<'v>(
    rel: &Path,
    view: &'v SourceView,
    keep: &dyn Fn(&Removed, &Path) -> bool,
) -> Option<(&'v Removed, PathBuf)> {
    let mut best: Option<(&Removed, PathBuf)> = None;
    for r in &view.removed {
        for p in &r.paths {
            let e = normalize(Path::new(p));
            if rel.starts_with(&e)
                && keep(r, &e)
                && best
                    .as_ref()
                    .is_none_or(|(_, b)| e.components().count() >= b.components().count())
            {
                best = Some((r, e));
            }
        }
    }
    best
}

fn classify(p: &Path, view: &SourceView, exists: &dyn Fn(&Path) -> bool) -> Option<Found> {
    if exists(p) {
        return None;
    }
    let root = normalize(Path::new(&view.root));
    let removed = |rel: &Path, r: &Removed, e: &PathBuf| Found::Removed {
        path: p.to_owned(),
        rel: rel.display().to_string(),
        step: r.step.clone(),
        entry: e.display().to_string(),
    };
    if let Ok(rel) = p.strip_prefix(&root) {
        if rel.as_os_str().is_empty() || rel.starts_with("..") {
            return None;
        }
        if repeats_package_dir(rel, &view.package_dir) {
            return Some(Found::WorkspaceRoot {
                path: p.to_owned(),
                rel: rel.display().to_string(),
            });
        }
        if let Some((r, e)) = left_out_by(rel, view, &|r, _| !r.elsewhere) {
            return Some(removed(rel, r, &e));
        }
        if rel.starts_with(&view.package_dir) {
            return None;
        }
        return Some(Found::Missing {
            path: p.to_owned(),
            rel: rel.display().to_string(),
        });
    }
    // Another store path: the path may point into the view of the
    // package's non-test units from a unit with another view.
    let store = root.parent()?;
    let inside = p.strip_prefix(store).ok()?;
    let mut comps = inside.components();
    let Some(Component::Normal(name)) = comps.next() else {
        return None;
    };
    let base = store.join(name);
    let rel = comps.as_path();
    let (r, e) = left_out_by(rel, view, &|r, e| {
        r.elsewhere && !e.as_os_str().is_empty() && !exists(&base.join(e))
    })?;
    Some(removed(rel, r, &e))
}

/// Whether `rel` (relative to the repository root) is in the package
/// directory `dir` and goes on with the end of `dir` again: the whole of
/// it, or its last two components or more. A file's path relative to the
/// workspace root (`file!()`) joined to the package directory gives that.
fn repeats_package_dir(rel: &Path, dir: &str) -> bool {
    let d: Vec<&str> = dir.split('/').filter(|c| !c.is_empty()).collect();
    let r: Vec<String> = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    if d.is_empty() || r.len() <= d.len() || r[..d.len()] != d[..] {
        return false;
    }
    let rest = &r[d.len()..];
    (1..=d.len())
        .any(|k| (k >= 2 || k == d.len()) && rest.len() > k && rest[..k] == d[d.len() - k..])
}

/// The paths `text` names that the unit's `view` lacks, in the order
/// found, each once. `cwd`: what relative paths are relative to;
/// `exists`: whether a path exists in the sandbox.
pub fn find(
    text: &str,
    view: &SourceView,
    remap: &[(String, String)],
    cwd: &Path,
    exists: &dyn Fn(&Path) -> bool,
) -> Vec<Found> {
    let mut seen = BTreeSet::new();
    let mut found = Vec::new();
    for w in words(text) {
        let hit = candidates(w, remap, cwd)
            .iter()
            .find_map(|c| classify(c, view, exists));
        if let Some(f) = hit
            && seen.insert(f.path().to_owned())
        {
            found.push(f);
        }
    }
    found
}

/// The step that left `rel` (relative to the repository root) out of
/// `view`, when one did.
pub fn step_of<'v>(view: &'v SourceView, rel: &str) -> Option<&'v str> {
    left_out_by(Path::new(rel), view, &|r, _| !r.elsewhere).map(|(r, _)| r.step.as_str())
}

/// How many paths get a hint; the rest are counted.
const MAX_HINTS: usize = 10;

/// What adds the missing path `rel` (relative to the repository root) to
/// `view`, as a clause after "if it is in the repository, ". `opt`: the
/// package's options ([`option_prefix`]).
pub fn adds(opt: &str, view: &SourceView, rel: &str) -> String {
    match step_of(view, rel) {
        Some(PREDICT) => format!("add it to `{opt}.predictSources.keep`"),
        Some(step) => {
            format!("add it in a `{opt}.sources` entry after `{step}`, or change that entry")
        }
        None => format!(
            "add it to `{opt}.extraSources`, or to `{opt}.test.sourceScope` for the package's \
             test units only"
        ),
    }
}

/// One hint line per path [`find`] finds, at most [`MAX_HINTS`].
pub fn hint_lines(package: &str, view: &SourceView, found: &[Found]) -> Vec<String> {
    let opt = option_prefix(package);
    let at = |rel: &str, entry: &str| {
        if rel == entry || entry.is_empty() {
            format!("`{rel}` is")
        } else {
            format!("`{rel}` is under `{entry}`, which is")
        }
    };
    let mut out: Vec<String> = found
        .iter()
        .take(MAX_HINTS)
        .map(|f| match f {
            Found::Removed { rel, step, .. } if step == PREDICT => format!(
                "`{rel}` is not in this unit's predicted view: source prediction finds the files \
                 of `mod` items, `#[path]` and `include*!` with literal paths, not files a proc \
                 macro or build script reads; if it is in the repository, add it to \
                 `{opt}.predictSources.keep`"
            ),
            Found::Removed {
                rel, step, entry, ..
            } => format!(
                "{} left out by `{opt}.sources.{step}`; if the unit reads it, add it in an entry \
                 after that one, or change that entry",
                at(rel, entry)
            ),
            Found::WorkspaceRoot { rel, .. } => format!(
                "`{rel}` repeats the package directory: a library that takes the topmost \
                 directory with a `Cargo.toml` as the workspace root found the package's own; if \
                 so, add the workspace's root `Cargo.toml` to the package's test views with an \
                 entry of `{opt}.sources`, as `sysDefaults.dependents.snapbox` does"
            ),
            Found::Missing { rel, .. } => format!(
                "`{rel}` is not in this unit's source view; if it is in the repository, {}",
                adds(&opt, view, rel)
            ),
        })
        .collect();
    if found.len() > MAX_HINTS {
        out.push(format!(
            "({} more paths missing from the source view)",
            found.len() - MAX_HINTS
        ));
    }
    out
}

/// The hints for a failed unit's output `text`: none without a view.
pub fn hints(
    package: &str,
    text: &str,
    view: Option<&SourceView>,
    remap: &[(String, String)],
    cwd: &Path,
) -> Vec<String> {
    let Some(view) = view else {
        return Vec::new();
    };
    let found = find(text, view, remap, cwd, &|p| p.symlink_metadata().is_ok());
    hint_lines(package, view, &found)
}

/// What `breakbulk-hints` gets from a test run: its package,
/// and its source view without the root, which is the run's
/// `CARGO_MANIFEST_DIR` without `package_dir`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TestRun {
    pub package: String,
    /// `None` when the binary's package has no source view.
    pub package_dir: Option<String>,
    #[serde(default)]
    pub removed: Vec<Removed>,
}

impl TestRun {
    /// The run's view, given its `CARGO_MANIFEST_DIR`.
    pub fn view(&self, manifest_dir: &Path) -> Option<SourceView> {
        let dir = self.package_dir.as_deref()?;
        let manifest_dir = normalize(manifest_dir);
        let mut root = manifest_dir.as_path();
        for _ in Path::new(dir).components() {
            root = root.parent()?;
        }
        (root.join(dir) == manifest_dir).then(|| SourceView {
            root: root.display().to_string(),
            package_dir: dir.to_owned(),
            removed: self.removed.clone(),
        })
    }
}

pub fn main(args: &[String]) -> ExitCode {
    let [spec, log] = args else {
        eprintln!("usage: breakbulk-hints SPEC LOG");
        return ExitCode::from(2);
    };
    let spec: TestRun = match serde_json::from_str(spec) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("breakbulk-hints: {e}");
            return ExitCode::SUCCESS;
        }
    };
    let Some(manifest_dir) = std::env::var_os("CARGO_MANIFEST_DIR").map(PathBuf::from) else {
        return ExitCode::SUCCESS;
    };
    let Ok(bytes) = std::fs::read(log) else {
        return ExitCode::SUCCESS;
    };
    let view = spec.view(&manifest_dir);
    let text = String::from_utf8_lossy(&bytes);
    for h in hints(&spec.package, &text, view.as_ref(), &[], &manifest_dir) {
        eprintln!("hint: {h}");
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEW: &str = "/nix/store/00000000000000000000000000000000-source";
    const TEST_VIEW: &str = "/nix/store/11111111111111111111111111111111-source";

    fn step(step: &str, paths: &[&str]) -> Removed {
        Removed {
            step: step.into(),
            paths: paths.iter().map(|p| (*p).to_owned()).collect(),
            elsewhere: false,
        }
    }

    /// A view of `dir`'s non-test units, as the built-in steps leave it:
    /// `tests/` and an in-package `test.sourceScope` path out.
    fn view(root: &str, dir: &str) -> SourceView {
        SourceView {
            root: root.into(),
            package_dir: dir.into(),
            removed: vec![
                step("sourceScope", &[&format!("{dir}/testdata")]),
                step("testsDir", &[&format!("{dir}/tests")]),
            ],
        }
    }

    /// A view of its test units: nothing left out.
    fn test_view(root: &str, dir: &str) -> SourceView {
        SourceView {
            root: root.into(),
            package_dir: dir.into(),
            removed: Vec::new(),
        }
    }

    /// `find` and the hints, where only `existing` paths (and their
    /// ancestors) exist.
    fn run(
        text: &str,
        view: &SourceView,
        remap: &[(String, String)],
        cwd: &str,
        existing: &[&str],
    ) -> (Vec<Found>, Vec<String>) {
        let exists = |p: &Path| existing.iter().any(|e| Path::new(e).starts_with(p));
        let f = find(text, view, remap, Path::new(cwd), &exists);
        let h = hint_lines("path+file:///p/crates/x#0.1.0", view, &f);
        (f, h)
    }

    fn remap_to_dot(root: &str) -> Vec<(String, String)> {
        vec![(root.to_owned(), ".".to_owned())]
    }

    const ADD: &str = "add it to `packages.x.extraSources`, or to `packages.x.test.sourceScope` \
                       for the package's test units only";

    #[test]
    fn words_skip_locations_and_sentence_ends() {
        assert_eq!(
            words("--> crates/a/src/lib.rs:3:5 and [/x/y/z] failed: read a/b. ok ../.."),
            ["/x/y/z", "a/b", "../.."]
        );
    }

    // ruff: `include_str!` of a file outside the package, as rustc prints
    // it with the view remapped to `.`.
    #[test]
    fn rustc_include_outside_the_package() {
        let v = view(VIEW, "crates/ruff_dev");
        let text = "error: couldn't read `crates/ruff_dev/src/../../../docs/.overrides/partials/rule-filters.html`: No such file or directory (os error 2)\n  --> crates/ruff_dev/src/generate_rules_table.rs:12:5";
        let (_, h) = run(text, &v, &remap_to_dot(VIEW), VIEW, &[]);
        assert_eq!(
            h,
            [format!(
                "`docs/.overrides/partials/rule-filters.html` is not in this unit's source view; \
                 if it is in the repository, {ADD}"
            )]
        );
    }

    // wasmtime: wit-bindgen's proc macro, with an absolute path.
    #[test]
    fn proc_macro_absolute_path() {
        let v = view(VIEW, "crates/test-programs");
        let text = format!(
            "error: failed to read path for WIT [{VIEW}/crates/test-programs/../wasi-http/src/p3/wit]\n\nCaused by:\n    No such file or directory (os error 2)"
        );
        let (f, h) = run(&text, &v, &remap_to_dot(VIEW), VIEW, &[]);
        assert_eq!(f.len(), 1, "{f:?}");
        assert!(
            h[0].starts_with("`crates/wasi-http/src/p3/wit` is not in this unit's source view"),
            "{h:?}"
        );
    }

    // ruff: snapbox in a test run, reading a sibling's fixture.
    #[test]
    fn test_run_output() {
        let v = test_view(TEST_VIEW, "crates/ruff");
        let text = format!(
            "thread 'format' panicked at crates/ruff/tests/format.rs:20:9:\n\
             Failed to read {TEST_VIEW}/crates/ruff/../ruff_python_formatter/resources/test/fixtures/a.py: No such file or directory (os error 2)"
        );
        let (_, h) = run(&text, &v, &[], &format!("{TEST_VIEW}/crates/ruff"), &[]);
        assert_eq!(
            h,
            [format!(
                "`crates/ruff_python_formatter/resources/test/fixtures/a.py` is not in this \
                 unit's source view; if it is in the repository, {ADD}"
            )]
        );
    }

    // A test reading a path relative to its working directory.
    #[test]
    fn test_run_relative_path() {
        assert_eq!(normalize(Path::new("../../a/./b")), Path::new("../../a/b"));
        assert_eq!(normalize(Path::new("/x/../../a")), Path::new("/a"));
        let v = test_view(TEST_VIEW, "crates/x");
        let text = "reading ../../shared/data.txt: No such file or directory (os error 2)";
        let (_, h) = run(text, &v, &[], &format!("{TEST_VIEW}/crates/x"), &[]);
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(h[0].starts_with("`shared/data.txt` is not in"), "{h:?}");
    }

    // wasmtime: a bare name is no path.
    #[test]
    fn no_path_no_hint() {
        let v = test_view(TEST_VIEW, "crates/x");
        let (f, _) = run(
            "filetests: No such file or directory (os error 2)",
            &v,
            &[],
            TEST_VIEW,
            &[],
        );
        assert!(f.is_empty(), "{f:?}");
    }

    #[test]
    fn present_paths_and_the_package_directory_give_nothing() {
        let v = view(VIEW, "crates/x");
        let text = format!(
            "couldn't read `{VIEW}/crates/x/src/missing.txt` or `{VIEW}/assets/here.txt` \
             or `{VIEW}/../elsewhere/a` or `/tmp/x/y`"
        );
        let (f, _) = run(&text, &v, &[], VIEW, &[&format!("{VIEW}/assets/here.txt")]);
        assert!(f.is_empty(), "{f:?}");
    }

    // Each step's report names the step; the most specific path wins.
    #[test]
    fn a_step_that_left_it_out() {
        let v = SourceView {
            removed: vec![
                step("package", &["crates/x/target", "crates/x/result"]),
                step("runFiles", &[""]),
            ],
            ..test_view(TEST_VIEW, "crates/x")
        };
        let text = format!(
            "reading {TEST_VIEW}/crates/x/fixtures/a, {TEST_VIEW}/shared/b and \
             {TEST_VIEW}/crates/x/result/c"
        );
        let (_, h) = run(&text, &v, &[], TEST_VIEW, &[]);
        assert_eq!(
            h,
            [
                "`crates/x/fixtures/a` is left out by `packages.x.sources.runFiles`; if the unit \
                 reads it, add it in an entry after that one, or change that entry",
                "`shared/b` is left out by `packages.x.sources.runFiles`; if the unit reads it, \
                 add it in an entry after that one, or change that entry",
                "`crates/x/result/c` is under `crates/x/result`, which is left out by \
                 `packages.x.sources.package`; if the unit reads it, add it in an entry after \
                 that one, or change that entry",
            ]
        );
        // A step of the user's, and another target's root.
        let v = SourceView {
            removed: vec![
                step("targetRoots", &["crates/x/src/bin/tool"]),
                step("noDocs", &["crates/x/docs"]),
            ],
            ..test_view(TEST_VIEW, "crates/x")
        };
        let text = format!(
            "couldn't read `{TEST_VIEW}/crates/x/src/bin/tool/cli.rs` or `{TEST_VIEW}/crates/x/docs`"
        );
        let (_, h) = run(&text, &v, &[], TEST_VIEW, &[]);
        assert!(
            h[0].starts_with(
                "`crates/x/src/bin/tool/cli.rs` is under `crates/x/src/bin/tool`, which is left \
                 out by `packages.x.sources.targetRoots`"
            ),
            "{h:?}"
        );
        assert!(
            h[1].starts_with("`crates/x/docs` is left out by `packages.x.sources.noDocs`"),
            "{h:?}"
        );
    }

    #[test]
    fn predicted_view_names_keep() {
        // A file a proc macro reads, missing from a predicted view: in the
        // package directory, so it counts.
        let v = SourceView {
            removed: vec![step(PREDICT, &[""])],
            ..view(VIEW, "crates/x")
        };
        let text = format!(
            "error: couldn't read `{VIEW}/crates/x/templates/page.html`: No such file or directory"
        );
        let (_, h) = run(&text, &v, &[], VIEW, &[]);
        assert_eq!(
            h,
            [
                "`crates/x/templates/page.html` is not in this unit's predicted view: source \
                 prediction finds the files of `mod` items, `#[path]` and `include*!` with literal \
                 paths, not files a proc macro or build script reads; if it is in the repository, \
                 add it to `packages.x.predictSources.keep`"
            ]
        );
        assert_eq!(
            adds("packages.x", &v, "crates/x/a"),
            "add it to `packages.x.predictSources.keep`"
        );
    }

    #[test]
    fn test_only_paths_of_the_unit_view() {
        let v = view(VIEW, "crates/x");
        let text = format!(
            "error: couldn't read `{VIEW}/crates/x/src/../tests/data.txt`: No such file or directory (os error 2)"
        );
        let (_, h) = run(&text, &v, &[], "/build", &[]);
        assert_eq!(
            h,
            [
                "`crates/x/tests/data.txt` is under `crates/x/tests`, which is left out by \
                 `packages.x.sources.testsDir`; if the unit reads it, add it in an entry after \
                 that one, or change that entry"
            ]
        );
        // Remapped, and relative to the working directory, as a build
        // script's paths are.
        let text = "couldn't read `crates/x/src/../testdata/a.bin`";
        let (_, h) = run(text, &v, &remap_to_dot(VIEW), "/elsewhere", &[]);
        assert!(
            h[0].ends_with("left out by `packages.x.sources.sourceScope`; if the unit reads it, add it in an entry after that one, or change that entry"),
            "{h:?}"
        );
        let (f, _) = run(
            "reading tests/fixtures/one.json failed",
            &v,
            &[],
            &format!("{VIEW}/crates/x"),
            &[],
        );
        assert_eq!(f.len(), 1, "{f:?}");
    }

    // A test run reads a path into `tests/` that library code built from
    // `CARGO_MANIFEST_DIR` in the view of the package's non-test units.
    #[test]
    fn test_run_reads_the_library_view() {
        let v = SourceView {
            removed: view(VIEW, "crates/x")
                .removed
                .into_iter()
                .map(|r| Removed {
                    elsewhere: true,
                    ..r
                })
                .collect(),
            ..test_view(TEST_VIEW, "crates/x")
        };
        let text = format!("reading {VIEW}/crates/x/tests/fixtures/input.txt: No such file");
        let present = format!("{TEST_VIEW}/crates/x/tests/fixtures/input.txt");
        let (_, h) = run(
            &text,
            &v,
            &[],
            &format!("{TEST_VIEW}/crates/x"),
            &[&present],
        );
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(
            h[0].contains("left out by `packages.x.sources.testsDir`"),
            "{h:?}"
        );
        // In the test view itself, `tests/` is there: a missing fixture is
        // only missing.
        let text = format!("reading {TEST_VIEW}/crates/x/tests/fixtures/gone.txt");
        let (f, _) = run(&text, &v, &[], TEST_VIEW, &[&present]);
        assert!(f.is_empty(), "{f:?}");
    }

    // A snapshot library that found the package's `Cargo.toml` as the
    // workspace root joins `file!()` to the package directory.
    #[test]
    fn workspace_root_missing() {
        let v = test_view(TEST_VIEW, "ws/crates/x");
        let text = format!(
            "Failed to read {TEST_VIEW}/ws/crates/x/crates/x/tests/snapshots/a.txt: No such file"
        );
        let (_, h) = run(&text, &v, &[], TEST_VIEW, &[]);
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(
            h[0].starts_with("`ws/crates/x/crates/x/tests/snapshots/a.txt` repeats the package"),
            "{h:?}"
        );
        assert!(h[0].contains("`packages.x.sources`"), "{h:?}");
        // One component again is not enough: `crates/x/x/` is a layout.
        assert!(!repeats_package_dir(
            Path::new("ws/crates/x/x/a.rs"),
            "ws/crates/x"
        ));
        assert!(repeats_package_dir(Path::new("x/x/a.rs"), "x"));
    }

    #[test]
    fn many_paths_are_counted() {
        let v = view(VIEW, "crates/x");
        let text: String = (0..12)
            .map(|i| format!("{VIEW}/assets/{i}.txt\n"))
            .collect();
        let (_, h) = run(&text, &v, &[], VIEW, &[]);
        assert_eq!(h.len(), MAX_HINTS + 1);
        assert_eq!(h[MAX_HINTS], "(2 more paths missing from the source view)");
    }

    #[test]
    fn test_run_view_from_the_manifest_dir() {
        let spec: TestRun = serde_json::from_str(
            r#"{"package": "x", "packageDir": "crates/x", "removed": [{"step": "runFiles", "paths": [""]}]}"#,
        )
        .unwrap();
        let v = spec
            .view(Path::new(&format!("{TEST_VIEW}/crates/x")))
            .unwrap();
        assert_eq!(v.root, TEST_VIEW);
        assert_eq!(v.removed, [step("runFiles", &[""])]);
        assert!(spec.view(Path::new("/elsewhere/crates/y")).is_none());
        let root: TestRun = serde_json::from_str(r#"{"package": "x", "packageDir": ""}"#).unwrap();
        assert_eq!(root.view(Path::new(TEST_VIEW)).unwrap().root, TEST_VIEW);
    }
}
