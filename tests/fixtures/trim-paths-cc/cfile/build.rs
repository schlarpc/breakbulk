use std::path::Path;

fn main() {
    // An absolute source path, so `__FILE__` names it in full unless a
    // prefix map rewrites it.
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    cc::Build::new()
        .file(Path::new(&dir).join("c/where.c"))
        .compile("where");
    println!("cargo::rerun-if-changed=c/where.c");
}
