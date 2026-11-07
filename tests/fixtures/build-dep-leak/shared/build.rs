// Runs twice in one build: once for the host copy of `shared` (a
// build-dependency of app) and once for the target copy.
fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::write(format!("{out}/libshared_marker.a"), b"!<arch>\n").unwrap();
    println!("cargo::rustc-link-search=native={out}");
    println!("cargo::rustc-link-lib=static=shared_marker");
    println!("cargo::rustc-env=SHARED_OUT_DIR={out}");
    println!("cargo::rerun-if-changed=build.rs");
}
