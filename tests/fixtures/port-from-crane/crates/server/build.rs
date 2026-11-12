use std::{env, fs, path::Path, process::Command};

// Runs the generator that the nightly workspace builds.
fn main() {
    println!("cargo::rerun-if-env-changed=SQUARES_GEN");
    let generator = env::var("SQUARES_GEN").expect("SQUARES_GEN names the generator");
    let out = Command::new(generator)
        .output()
        .expect("the generator runs");
    assert!(out.status.success(), "the generator failed");
    let dir = env::var("OUT_DIR").unwrap();
    fs::write(Path::new(&dir).join("squares.rs"), out.stdout).unwrap();
}
