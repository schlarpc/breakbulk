use std::path::Path;

fn main() {
    println!("cargo::rerun-if-env-changed=ENVDEP_DIR");
    let dir = std::env::var("ENVDEP_DIR").expect("ENVDEP_DIR is set");
    let answer = std::fs::read_to_string(Path::new(&dir).join("answer.txt"))
        .unwrap_or_else(|e| panic!("reading {dir}/answer.txt: {e}"));
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::write(
        Path::new(&out).join("answer.rs"),
        format!("{}", answer.trim()),
    )
    .unwrap();
}
