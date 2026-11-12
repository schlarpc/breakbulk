use std::path::PathBuf;

fn main() {
    let data = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("data");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(data.join("gen.txt"), "generated\n").unwrap();
    println!("cargo::rerun-if-changed=build.rs");
}
