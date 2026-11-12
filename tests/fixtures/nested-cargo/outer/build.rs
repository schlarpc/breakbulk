use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Builds `inner` with the Cargo that runs this script, into OUT_DIR.
fn main() {
    let target_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("nested");
    let status = Command::new(env::var_os("CARGO").unwrap())
        .args(["build", "--locked", "-p", "inner", "--target-dir"])
        .arg(&target_dir)
        .status()
        .expect("running cargo");
    assert!(status.success(), "the nested cargo build failed");
    let bin = target_dir.join("debug").join("inner");
    println!("cargo:rustc-env=INNER_BIN={}", bin.display());
    println!("cargo:rerun-if-changed=../inner");
}
