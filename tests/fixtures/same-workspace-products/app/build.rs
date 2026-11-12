use std::process::Command;

/// Runs `tool`, which `packages.app.nativeInputs` puts on `PATH`, and keeps
/// its output for `main`; links `shared`, whose library directory
/// `packages.app.inputs` adds to the link's search path.
fn main() {
    let out = Command::new("tool").output().expect("running `tool` from PATH");
    assert!(out.status.success(), "`tool` failed");
    let dir = std::env::var("OUT_DIR").unwrap();
    std::fs::write(format!("{dir}/from-tool.txt"), &out.stdout).unwrap();
    println!("cargo:rustc-link-lib=dylib=shared");
}
