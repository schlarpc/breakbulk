use std::path::Path;

#[test]
fn runtime_env() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let cwd = std::env::current_dir().unwrap();
    println!("CARGO_MANIFEST_DIR={dir}");
    println!("cwd={}", cwd.display());
    assert_eq!(Path::new(&dir), cwd);
    assert_eq!(
        std::env::var("CARGO_MANIFEST_PATH").unwrap(),
        format!("{dir}/Cargo.toml")
    );
    // The working directory is the package directory, as with cargo test.
    assert_eq!(
        std::fs::read_to_string("data/input.txt").unwrap().trim(),
        "fixture data"
    );
    assert_eq!(std::env::var("CARGO_PKG_NAME").unwrap(), "ctl");
    assert_eq!(std::env::var("CARGO_PKG_VERSION").unwrap(), "0.1.0");
    assert_eq!(std::env::var("CTL_BUILD_ENV").unwrap(), "from-build-script");
}

#[test]
fn dylib_path_has_only_out_dir_search_paths() {
    let ld = std::env::var("LD_LIBRARY_PATH").unwrap();
    let parts: Vec<&str> = ld.split(':').collect();
    let want = concat!(env!("OUT_DIR"), "/libs");
    // The build script's directory itself, or (content-addressed test runs
    // in breakbulk, lib/test-runs.nix stableSpec) a stable copy of its
    // files, recognised by the marker file the build script wrote.
    let is_copy = |p: &str| {
        std::fs::read_to_string(Path::new(p).join("ctl-libs-marker"))
            .is_ok_and(|s| s == "ctl-libs\n")
    };
    assert!(parts.iter().any(|p| *p == want || is_copy(p)), "{ld}");
    assert!(!parts.contains(&"/tmp/ctl-outside-out"), "{ld}");
}

#[test]
fn target_tmpdir_is_writable() {
    let d = env!("CARGO_TARGET_TMPDIR");
    std::fs::write(format!("{d}/probe"), "x").unwrap();
}

/// What the test-control check configures: `test.env`, `test.path` and
/// `RUST_TEST_THREADS`. Skipped under plain cargo.
#[test]
fn test_config() {
    if std::env::var_os("CTL_EXPECT_NIX").is_none() {
        return;
    }
    assert_eq!(
        std::env::var("RUST_TEST_THREADS").unwrap(),
        std::env::var("NIX_BUILD_CORES").unwrap()
    );
    let out = std::process::Command::new("hello").output().unwrap();
    assert_eq!(String::from_utf8(out.stdout).unwrap().trim(), "Hello, world!");
}
