fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::create_dir_all(format!("{out}/libs")).unwrap();
    // Inside OUT_DIR: on the test process's dynamic-library path.
    println!("cargo::rustc-link-search=native={out}/libs");
    // Outside: not on it.
    println!("cargo::rustc-link-search=native=/tmp/ctl-outside-out");
    // Set on compiles and, by Cargo, on the test process too.
    println!("cargo::rustc-env=CTL_BUILD_ENV=from-build-script");
}
