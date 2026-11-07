fn main() {
    // The cmake crate's Debug build compiles with -g, so the objects record
    // the compiler's switches (-frandom-seed among them) in debug info.
    let dst = cmake::Config::new("csrc").build();
    // CMake's build tree in OUT_DIR is not reproducible: try-compile
    // directories get random names, recorded in
    // CMakeFiles/CMakeConfigureLog.yaml. Only the installed library is
    // needed, so the tree goes (`nix build --rebuild` of the run is clean).
    std::fs::remove_dir_all(dst.join("build")).unwrap();
    println!("cargo::rustc-link-search=native={}/lib", dst.display());
    println!("cargo::rustc-link-lib=static=cm");
    println!("cargo::rerun-if-changed=csrc");
}
