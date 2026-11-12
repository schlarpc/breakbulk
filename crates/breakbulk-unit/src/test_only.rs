//! The hint for a non-test unit that fails reading a test-only path: one
//! left out of its source view (`packages.<name>.test.sourceScope`, the
//! package's `tests/` directory) and kept for test units only.
//!
//! The unit's output (rustc's diagnostics, a build script's output) is
//! searched for paths under one of the unit's `test_only` directories,
//! absolute or as a remap names them (`--remap-path-prefix`, so
//! `crates/x/src/../tests/data.txt` in a diagnostic).

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::run::option_prefix;

/// `p` with `.` and `..` components resolved lexically.
pub(crate) fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            c => out.push(c),
        }
    }
    out
}

/// The forms each test-only directory can appear in: itself, and its name
/// under each remap pair whose `from` contains it.
fn prefixes(test_only: &[String], remap: &[(String, String)]) -> Vec<(PathBuf, PathBuf)> {
    let mut out = Vec::new();
    for t in test_only {
        let t = normalize(Path::new(t));
        out.push((t.clone(), t.clone()));
        for (from, to) in remap {
            if let Ok(rest) = t.strip_prefix(from) {
                out.push((normalize(&Path::new(to).join(rest)), t.clone()));
            }
        }
    }
    out
}

/// The test-only directories `text` names a path under, with the path, in
/// the order found. `cwd`: what relative paths are relative to.
pub fn find(
    text: &str,
    test_only: &[String],
    remap: &[(String, String)],
    cwd: &Path,
) -> Vec<(String, PathBuf)> {
    if test_only.is_empty() {
        return Vec::new();
    }
    let prefixes = prefixes(test_only, remap);
    let mut seen = BTreeSet::new();
    let mut found = Vec::new();
    // Only tokens with a `/`, and only paths strictly below a directory:
    // a lone word such as "tests" in a message is not a path.
    let tokens = text
        .split(|c: char| c.is_whitespace() || "`'\"(),;:".contains(c))
        .filter(|t| t.contains('/'));
    for token in tokens {
        let token = Path::new(token);
        let mut candidates = vec![normalize(token)];
        if token.is_relative() {
            candidates.push(normalize(&cwd.join(token)));
        }
        let hit = candidates.iter().find_map(|c| {
            prefixes
                .iter()
                .find(|(p, _)| !p.as_os_str().is_empty() && c != p && c.starts_with(p))
                .map(|(_, dir)| (c, dir))
        });
        if let Some((path, dir)) = hit
            && seen.insert(path.clone())
        {
            found.push((path.display().to_string(), dir.clone()));
        }
    }
    found
}

/// One hint line per test-only path `text` names.
pub fn hints(
    package: &str,
    text: &str,
    test_only: &[String],
    remap: &[(String, String)],
    cwd: &Path,
) -> Vec<String> {
    let opt = option_prefix(package);
    find(text, test_only, remap, cwd)
        .into_iter()
        .map(|(path, dir)| {
            if dir.file_name().is_some_and(|n| n == "tests") {
                format!(
                    "`{path}` is in the package's `tests/` directory, which only its test units \
                     see; if non-test code reads it, set `{opt}.test.scopeTestsDir = false`"
                )
            } else {
                format!(
                    "`{path}` is in `{opt}.test.sourceScope`, which only the package's test units \
                     see; if non-test code reads it, move it to `{opt}.extraSources`"
                )
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIEW: &str = "/nix/store/00000000000000000000000000000000-source";

    fn test_only() -> Vec<String> {
        vec![
            format!("{VIEW}/crates/x/tests"),
            format!("{VIEW}/crates/x/testdata"),
        ]
    }

    #[test]
    fn absolute_path_with_parent_components() {
        let text = format!(
            "error: couldn't read `{VIEW}/crates/x/src/../tests/data.txt`: No such file or directory (os error 2)"
        );
        let h = hints(
            "path+file:///p/crates/x#0.1.0",
            &text,
            &test_only(),
            &[],
            Path::new("/build"),
        );
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(h[0].contains(&format!("`{VIEW}/crates/x/tests/data.txt`")));
        assert!(h[0].contains("packages.x.test.scopeTestsDir = false"));
    }

    #[test]
    fn remapped_and_relative_paths() {
        let remap = vec![(VIEW.to_owned(), ".".to_owned())];
        let text = "--> crates/x/src/lib.rs:1:1\n couldn't read `crates/x/src/../testdata/a.bin`";
        let h = hints(
            "path+file:///p/crates/x#0.1.0",
            text,
            &test_only(),
            &remap,
            Path::new("/elsewhere"),
        );
        assert_eq!(h.len(), 1, "{h:?}");
        assert!(h[0].contains("`crates/x/testdata/a.bin`"));
        assert!(h[0].contains("packages.x.extraSources"));
        // Relative to the working directory, as a build script's paths are.
        let cwd = format!("{VIEW}/crates/x");
        let f = find(
            "reading tests/fixtures/one.json failed",
            &test_only(),
            &[],
            Path::new(&cwd),
        );
        assert_eq!(f.len(), 1, "{f:?}");
    }

    #[test]
    fn other_paths_give_nothing() {
        let text = format!("error: couldn't read `{VIEW}/crates/x/src/missing.txt`");
        assert!(find(&text, &test_only(), &[], Path::new("/build")).is_empty());
        assert!(find(&text, &[], &[], Path::new("/build")).is_empty());
    }
}
