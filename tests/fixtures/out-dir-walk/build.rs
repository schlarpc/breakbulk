use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    std::fs::write(out_dir.join("generated.rs"), "pub const WALKED: bool = true;\n").unwrap();
    // sdl2-sys's walk: up to the deepest directory whose name contains the
    // package name, then two more (`<target>/<profile>`).
    let pkg = std::env::var("CARGO_PKG_NAME").unwrap();
    let mut dir = out_dir.clone();
    while !dir.file_name().unwrap().to_string_lossy().contains(&pkg) {
        assert!(dir.pop(), "no directory named after {pkg} above {}", out_dir.display());
    }
    dir.pop();
    dir.pop();
    std::fs::write(dir.join("walked.txt"), "profile\n").unwrap();
    // Cargo's classic layout has `<profile>/deps`; the new one does not.
    if dir.join("deps").is_dir() {
        std::fs::write(dir.join("deps").join("walked.txt"), "deps\n").unwrap();
    }
    println!("cargo::rerun-if-changed=build.rs");
}
