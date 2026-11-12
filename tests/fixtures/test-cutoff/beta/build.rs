use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::write(out.join("libbeta_marker.so"), "beta\n").unwrap();
    // A subdirectory, which the dynamic loader never searches. The cutoff
    // tests change what goes in it through BETA_SUB, so that the run and
    // everything below it are rebuilt while no source changes.
    let sub = std::env::var("BETA_SUB").unwrap_or_else(|_| "1".to_owned());
    std::fs::create_dir_all(out.join("sub")).unwrap();
    std::fs::write(out.join("sub/not-searched"), format!("edit {sub}\n")).unwrap();
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rerun-if-env-changed=BETA_SUB");
}
