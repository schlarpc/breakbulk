use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(
        out.join("gen.rs"),
        "pub const ANSWER: u64 = 6 * 7;\npub fn generated_file() -> &'static str { file!() }\n",
    )
    .unwrap();
    println!("cargo::rerun-if-changed=build.rs");
}
