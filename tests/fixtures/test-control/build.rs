fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::create_dir_all(format!("{out}/libs")).unwrap();
    // A file the test recognises the directory by: with content-addressed
    // test runs, the dynamic-library path holds a copy of this directory's
    // files instead of the directory itself (lib/test-runs.nix stableSpec).
    std::fs::write(format!("{out}/libs/ctl-libs-marker"), "ctl-libs\n").unwrap();
    // Inside OUT_DIR: on the test process's dynamic-library path.
    println!("cargo::rustc-link-search=native={out}/libs");
    // Outside: not on it.
    println!("cargo::rustc-link-search=native=/tmp/ctl-outside-out");
    // Set on compiles and, by Cargo, on the test process too.
    println!("cargo::rustc-env=CTL_BUILD_ENV=from-build-script");
}
