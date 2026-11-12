//! Hints for a unit that fails naming a path its source view lacks.
//!
//! A unit of a repository package sees only its package's source view
//! ([`SourceView`]). Its output (rustc's diagnostics, a proc macro's error,
//! a build script's or a test's output) is searched for paths, absolute,
//! relative to the working directory, or as a remap names them
//! (`--remap-path-prefix`, so `crates/x/src/../../docs/a.md` in a
//! diagnostic). Each that resolves to a place that does not exist gets a
//! hint naming the option that adds it:
//!
//! - under one of the package's test-only paths, in a view that leaves it
//!   out (the view of the package's non-test units, wherever the path came
//!   from): `test.scopeTestsDir` or `extraSources`;
//! - otherwise inside the unit's own view root: the view's [`Widen`]
//!   option, the one for the unit's kind. Paths in the package directory
//!   count only when something other than the built-in steps chose its
//!   files (`test.runFiles`, a `sources` function); else the view holds
//!   the whole directory, and a file missing there is not in the
//!   repository either.
//!
//! Only the path decides, not who printed it, so one rule covers rustc,
//! proc macros and test output. A message without a path gets no hint.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::process::ExitCode;

use serde::Deserialize;

use crate::run::option_prefix;
use crate::spec::{SourceView, Widen};

/// `p` with `.` and `..` components resolved lexically.
pub(crate) fn normalize(p: &Path) -> PathBuf {
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
    /// Under the test-only path `entry`, in a view that leaves it out.
    TestOnly {
        path: PathBuf,
        rel: String,
        entry: String,
    },
    /// Inside the unit's view, outside the package directory (or anywhere,
    /// in a `test.runFiles` view), and not there.
    Missing { path: PathBuf, rel: String },
}

impl Found {
    pub fn path(&self) -> &Path {
        match self {
            Found::TestOnly { path, .. } | Found::Missing { path, .. } => path,
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

fn classify(p: &Path, view: &SourceView, exists: &dyn Fn(&Path) -> bool) -> Option<Found> {
    let root = normalize(Path::new(&view.root));
    // Any store path: the path may point into the view of the package's
    // non-test units from a unit with another view.
    if let Some(store) = root.parent()
        && let Ok(inside) = p.strip_prefix(store)
    {
        let mut comps = inside.components();
        if let Some(Component::Normal(name)) = comps.next() {
            let base = store.join(name);
            let rel = comps.as_path();
            for entry in &view.test_only {
                let e = normalize(Path::new(entry));
                if !e.as_os_str().is_empty()
                    && rel.starts_with(&e)
                    && !exists(&base.join(&e))
                    && !exists(p)
                {
                    return Some(Found::TestOnly {
                        path: p.to_owned(),
                        rel: rel.display().to_string(),
                        entry: e.display().to_string(),
                    });
                }
            }
        }
    }
    let rel = p.strip_prefix(&root).ok()?;
    if rel.as_os_str().is_empty() || rel.starts_with("..") {
        return None;
    }
    let whole_package = !view.custom && view.widen != Widen::TestRunFiles;
    if whole_package && rel.starts_with(&view.package_dir) || exists(p) {
        return None;
    }
    Some(Found::Missing {
        path: p.to_owned(),
        rel: rel.display().to_string(),
    })
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

/// How many paths get a hint; the rest are counted.
const MAX_HINTS: usize = 10;

/// `rel` (relative to the repository root) relative to the package
/// directory `dir`, as `test.runFiles` takes it.
fn package_relative(rel: &str, dir: &str) -> String {
    let rel: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
    let dir: Vec<&str> = dir.split('/').filter(|c| !c.is_empty()).collect();
    let common = rel.iter().zip(&dir).take_while(|(a, b)| a == b).count();
    let mut out: Vec<&str> = vec![".."; dir.len() - common];
    out.extend(&rel[common..]);
    out.join("/")
}

/// One hint line per path [`find`] finds, at most [`MAX_HINTS`].
pub fn hint_lines(package: &str, view: &SourceView, found: &[Found]) -> Vec<String> {
    let opt = option_prefix(package);
    let mut out: Vec<String> = found
        .iter()
        .take(MAX_HINTS)
        .map(|f| match f {
            Found::TestOnly { rel, entry, .. }
                if Path::new(entry) == Path::new(&view.package_dir).join("tests") =>
            {
                format!(
                    "`{rel}` is in the package's `tests/` directory, which only its test units \
                     see; if non-test code reads it, set `{opt}.test.scopeTestsDir = false`"
                )
            }
            Found::TestOnly { rel, .. } => format!(
                "`{rel}` is in `{opt}.test.sourceScope`, which only the package's test units \
                 see; if non-test code reads it, move it to `{opt}.extraSources`"
            ),
            Found::Missing { rel, .. } if view.widen == Widen::TestRunFiles => format!(
                "`{rel}` is not in this test run's `{opt}.test.runFiles`; if it is in the \
                 repository, add `{}` to it",
                package_relative(rel, &view.package_dir)
            ),
            Found::Missing { rel, .. } => format!(
                "`{rel}` is not in this unit's source view; if it is in the repository, add it \
                 to `{opt}.{}`",
                view.widen.option()
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

/// What `breakbulk-unit test-run-hints` gets from a test run: its package,
/// and its source view without the root, which is the run's
/// `CARGO_MANIFEST_DIR` without `package_dir`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TestRun {
    pub package: String,
    /// `None` when the binary's package has no source view.
    pub package_dir: Option<String>,
    #[serde(default)]
    pub test_only: Vec<String>,
    pub widen: Widen,
    #[serde(default)]
    pub custom: bool,
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
            widen: self.widen,
            test_only: self.test_only.clone(),
            custom: self.custom,
        })
    }
}

/// `breakbulk-unit test-run-hints SPEC LOG`: after a failed test run, print
/// the hints for its log (`SPEC` is a [`TestRun`] as JSON). Prints nothing
/// it cannot work out, and always succeeds: the run's own failure stands.
pub fn test_run_main(args: &[String]) -> ExitCode {
    let [spec, log] = args else {
        eprintln!("usage: breakbulk-unit test-run-hints SPEC LOG");
        return ExitCode::from(2);
    };
    let spec: TestRun = match serde_json::from_str(spec) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("breakbulk-unit test-run-hints: {e}");
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

    fn view(root: &str, dir: &str, widen: Widen) -> SourceView {
        SourceView {
            root: root.into(),
            package_dir: dir.into(),
            widen,
            test_only: vec![format!("{dir}/tests"), format!("{dir}/testdata")],
            custom: false,
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
        let v = view(VIEW, "crates/ruff_dev", Widen::ExtraSources);
        let text = "error: couldn't read `crates/ruff_dev/src/../../../docs/.overrides/partials/rule-filters.html`: No such file or directory (os error 2)\n  --> crates/ruff_dev/src/generate_rules_table.rs:12:5";
        let (_, h) = run(text, &v, &remap_to_dot(VIEW), VIEW, &[]);
        assert_eq!(
            h,
            [
                "`docs/.overrides/partials/rule-filters.html` is not in this unit's source view; \
              if it is in the repository, add it to `packages.x.extraSources`"
            ]
        );
    }

    // wasmtime: wit-bindgen's proc macro, with an absolute path.
    #[test]
    fn proc_macro_absolute_path() {
        let v = view(VIEW, "crates/test-programs", Widen::ExtraSources);
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

    // ruff: snapbox in a test run, which names `test.sourceScope`.
    #[test]
    fn test_run_output() {
        let v = view(TEST_VIEW, "crates/ruff", Widen::TestSourceScope);
        let text = format!(
            "thread 'format' panicked at crates/ruff/tests/format.rs:20:9:\n\
             Failed to read {TEST_VIEW}/crates/ruff/../ruff_python_formatter/resources/test/fixtures/a.py: No such file or directory (os error 2)"
        );
        let (_, h) = run(&text, &v, &[], &format!("{TEST_VIEW}/crates/ruff"), &[]);
        assert_eq!(
            h,
            [
                "`crates/ruff_python_formatter/resources/test/fixtures/a.py` is not in this unit's \
              source view; if it is in the repository, add it to `packages.x.test.sourceScope`"
            ]
        );
    }

    // A test reading a path relative to its working directory.
    #[test]
    fn test_run_relative_path() {
        assert_eq!(normalize(Path::new("../../a/./b")), Path::new("../../a/b"));
        assert_eq!(normalize(Path::new("/x/../../a")), Path::new("/a"));
        let v = view(TEST_VIEW, "crates/x", Widen::TestSourceScope);
        let text = "reading ../../shared/data.txt: No such file or directory (os error 2)";
        let (_, h) = run(text, &v, &[], &format!("{TEST_VIEW}/crates/x"), &[]);
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(h[0].starts_with("`shared/data.txt` is not in"), "{h:?}");
    }

    // wasmtime: a bare name is no path.
    #[test]
    fn no_path_no_hint() {
        let v = view(TEST_VIEW, "crates/x", Widen::TestSourceScope);
        let (f, _) = run(
            "filetests: No such file or directory (os error 2)",
            &v,
            &[],
            TEST_VIEW,
            &[],
        );
        assert!(f.is_empty(), "{f:?}");
    }

    // deno: a test's `include_bytes!` of a sibling package's test data,
    // relative to the source file.
    #[test]
    fn test_compile_include() {
        let v = view(TEST_VIEW, "ext/net", Widen::TestSourceScope);
        let text = "error: couldn't read `ext/net/../tls/testdata/example1_cert.der`: No such file or directory (os error 2)";
        let (_, h) = run(text, &v, &remap_to_dot(TEST_VIEW), TEST_VIEW, &[]);
        assert!(
            h[0].starts_with("`ext/tls/testdata/example1_cert.der`"),
            "{h:?}"
        );
        assert!(h[0].ends_with("`packages.x.test.sourceScope`"), "{h:?}");
    }

    #[test]
    fn present_paths_and_the_package_directory_give_nothing() {
        let v = view(VIEW, "crates/x", Widen::ExtraSources);
        let text = format!(
            "couldn't read `{VIEW}/crates/x/src/missing.txt` or `{VIEW}/assets/here.txt` \
             or `{VIEW}/../elsewhere/a` or `/tmp/x/y`"
        );
        let (f, _) = run(&text, &v, &[], VIEW, &[&format!("{VIEW}/assets/here.txt")]);
        assert!(f.is_empty(), "{f:?}");
        // A `test.runFiles` view counts the package directory too, relative
        // to it.
        let v = view(TEST_VIEW, "crates/x", Widen::TestRunFiles);
        let text = format!("reading {TEST_VIEW}/crates/x/fixtures/a and {TEST_VIEW}/shared/b");
        let (_, h) = run(&text, &v, &[], TEST_VIEW, &[]);
        assert!(h[0].contains("add `fixtures/a` to it"), "{h:?}");
        assert!(h[1].contains("add `../../shared/b` to it"), "{h:?}");
        // So does a view a `sources` function chose, with the kind's option.
        let v = SourceView {
            custom: true,
            ..view(VIEW, "crates/x", Widen::ExtraSources)
        };
        let text = format!("couldn't read `{VIEW}/crates/x/README.md`");
        let (_, h) = run(&text, &v, &[], VIEW, &[]);
        assert_eq!(
            h,
            [
                "`crates/x/README.md` is not in this unit's source view; if it is in the \
              repository, add it to `packages.x.extraSources`"
            ]
        );
    }

    #[test]
    fn test_only_paths_of_the_unit_view() {
        let v = view(VIEW, "crates/x", Widen::ExtraSources);
        let text = format!(
            "error: couldn't read `{VIEW}/crates/x/src/../tests/data.txt`: No such file or directory (os error 2)"
        );
        let (_, h) = run(&text, &v, &[], "/build", &[]);
        assert_eq!(
            h,
            [
                "`crates/x/tests/data.txt` is in the package's `tests/` directory, which only its \
              test units see; if non-test code reads it, set `packages.x.test.scopeTestsDir = false`"
            ]
        );
        // Remapped, and relative to the working directory, as a build
        // script's paths are.
        let text = "couldn't read `crates/x/src/../testdata/a.bin`";
        let (_, h) = run(text, &v, &remap_to_dot(VIEW), "/elsewhere", &[]);
        assert!(h[0].starts_with("`crates/x/testdata/a.bin` is in `packages.x.test.sourceScope`"));
        assert!(
            h[0].ends_with("move it to `packages.x.extraSources`"),
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
        let v = view(TEST_VIEW, "crates/x", Widen::TestSourceScope);
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
            h[0].contains("set `packages.x.test.scopeTestsDir = false`"),
            "{h:?}"
        );
        // In the test view itself, `tests/` is there: a missing fixture is
        // only missing.
        let text = format!("reading {TEST_VIEW}/crates/x/tests/fixtures/gone.txt");
        let (f, _) = run(&text, &v, &[], TEST_VIEW, &[&present]);
        assert!(f.is_empty(), "{f:?}");
    }

    #[test]
    fn many_paths_are_counted() {
        let v = view(VIEW, "crates/x", Widen::ExtraSources);
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
            r#"{"package": "x", "packageDir": "crates/x", "widen": "test.sourceScope"}"#,
        )
        .unwrap();
        let v = spec
            .view(Path::new(&format!("{TEST_VIEW}/crates/x")))
            .unwrap();
        assert_eq!(v.root, TEST_VIEW);
        assert!(spec.view(Path::new("/elsewhere/crates/y")).is_none());
        let root: TestRun =
            serde_json::from_str(r#"{"package": "x", "packageDir": "", "widen": "test.runFiles"}"#)
                .unwrap();
        assert_eq!(root.view(Path::new(TEST_VIEW)).unwrap().root, TEST_VIEW);
    }
}
