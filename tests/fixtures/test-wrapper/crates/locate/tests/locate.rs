use std::path::Path;

#[test]
fn finds_the_repository_from_current_exe() {
    let exe = std::env::current_exe().unwrap();
    println!("current_exe={}", exe.display());
    assert!(
        exe.parent().unwrap().ends_with("target/debug/deps"),
        "{}",
        exe.display()
    );
    let root = locate::root_path();
    assert_eq!(
        std::fs::read_to_string(root.join("repo-marker.txt")).unwrap(),
        "the repository root\n"
    );
    assert_eq!(
        root.join("crates/locate/Cargo.toml").canonicalize().unwrap(),
        Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join("Cargo.toml")
            .canonicalize()
            .unwrap()
    );
}

/// The working directory is still the package directory.
#[test]
fn runs_in_the_package_directory() {
    let cwd = std::env::current_dir().unwrap();
    println!("cwd={}", cwd.display());
    assert_eq!(
        cwd.join("Cargo.toml").canonicalize().unwrap(),
        Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join("Cargo.toml")
            .canonicalize()
            .unwrap()
    );
}

#[test]
fn target_tmpdir_is_writable() {
    let d = env!("CARGO_TARGET_TMPDIR");
    std::fs::write(format!("{d}/probe"), "x").unwrap();
}
