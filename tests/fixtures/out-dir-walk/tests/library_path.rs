// Cargo puts `target/<profile>` and `<profile>/deps` on a test's
// dynamic-library path (`Compilation::fill_env`), so a library a build
// script copies there is found. breakbulk puts the copies of them in the
// run's `out` there instead (#23), or, with content-addressed test runs,
// copies of their files.
use std::path::Path;

#[test]
fn profile_and_deps_on_the_library_path() {
    let var = if cfg!(windows) { "PATH" } else { "LD_LIBRARY_PATH" };
    let path = std::env::var(var).unwrap_or_default();
    let found: Vec<String> = std::env::split_paths(&path)
        .filter_map(|d| std::fs::read_to_string(Path::new(&d).join("walked.txt")).ok())
        .collect();
    // build.rs writes "profile" into `<profile>/walked.txt` and "deps" into
    // `<profile>/deps/walked.txt`.
    assert!(
        found.iter().any(|s| s == "profile\n"),
        "no <profile> directory with walked.txt in {var}={path}"
    );
    assert!(
        found.iter().any(|s| s == "deps\n"),
        "no <profile>/deps directory with walked.txt in {var}={path}"
    );
}
