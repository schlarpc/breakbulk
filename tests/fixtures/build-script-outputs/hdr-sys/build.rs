use std::path::PathBuf;

fn main() {
    let include = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("include");
    std::fs::create_dir_all(&include).unwrap();
    std::fs::write(include.join("hdr.h"), "#define HDR_ANSWER 42\n").unwrap();
    println!("cargo::metadata=include={}", include.display());
    println!("cargo::metadata=answer=42");
    println!("cargo::rerun-if-changed=build.rs");
}
