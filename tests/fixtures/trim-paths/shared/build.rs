use std::{env, fs, path::Path};

fn main() {
    let out = env::var("OUT_DIR").unwrap();
    fs::write(
        Path::new(&out).join("gen.rs"),
        "/// The path of the generated file as `file!()` sees it.\n\
         pub fn generated_at() -> &'static str { file!() }\n",
    )
    .unwrap();
    println!("cargo::rerun-if-changed=build.rs");
}
