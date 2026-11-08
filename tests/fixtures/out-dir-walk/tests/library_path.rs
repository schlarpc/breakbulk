// Cargo puts `target/<profile>` and `<profile>/deps` on a test's
// dynamic-library path (`Compilation::fill_env`), so a library a build
// script copies there is found. breakbulk puts the copies of them in the
// run's `out` there instead (#23).
use std::path::Path;

#[test]
fn profile_and_deps_on_the_library_path() {
    let var = if cfg!(windows) { "PATH" } else { "LD_LIBRARY_PATH" };
    let path = std::env::var(var).unwrap_or_default();
    let dirs: Vec<_> = std::env::split_paths(&path)
        .filter(|d| Path::new(d).join("walked.txt").is_file())
        .collect();
    assert!(
        dirs.iter().any(|d| !d.ends_with("deps")),
        "no <profile> directory with walked.txt in {var}={path}"
    );
    assert!(
        dirs.iter().any(|d| d.ends_with("deps")),
        "no <profile>/deps directory with walked.txt in {var}={path}"
    );
}
