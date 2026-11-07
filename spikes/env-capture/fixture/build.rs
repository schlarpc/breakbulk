// Records the environment this build script was started with, so the
// base capture can be compared with what buildRustPackage gives build
// scripts. This package declares no inputs, so it gets the base capture.
use std::{env, fs, path::PathBuf};

fn main() {
    let mut vars: Vec<(String, String)> = env::vars().collect();
    vars.sort();
    let text: String = vars.iter().map(|(k, v)| format!("{k}={v}\n")).collect();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    fs::write(out.join("build-script-env.txt"), text).unwrap();
    println!("cargo::rerun-if-changed=build.rs");
}
