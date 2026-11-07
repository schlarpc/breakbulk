use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    cc::Build::new().file("csrc/bg.c").compile("bg");
    bindgen::Builder::default()
        .header("csrc/bg.h")
        .allowlist_function("bg_.*")
        .generate()
        .expect("bindgen failed")
        .write_to_file(out.join("bindings.rs"))
        .unwrap();
    println!("cargo::rerun-if-changed=csrc");
}
