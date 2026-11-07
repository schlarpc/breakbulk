use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::write(out.join("libbeta_marker.so"), "beta\n").unwrap();
    std::fs::create_dir_all(out.join("sub")).unwrap();
    std::fs::write(out.join("sub/not-searched"), "x\n").unwrap();
    println!("cargo::rustc-link-search=native={}", out.display());
}
