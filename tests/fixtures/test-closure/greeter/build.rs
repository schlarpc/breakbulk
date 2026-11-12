use std::process::Command;

fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let status = Command::new(&cc)
        .args(["-shared", "-fPIC", "-o"])
        .arg(format!("{out}/libgreet.so"))
        .arg("csrc/greet.c")
        .status()
        .unwrap();
    assert!(status.success(), "{cc} failed");
    // Inside OUT_DIR: on the dynamic-library path of the tests below this
    // run.
    println!("cargo::rustc-link-search=native={out}");
    println!("cargo::rerun-if-changed=csrc/greet.c");
}
