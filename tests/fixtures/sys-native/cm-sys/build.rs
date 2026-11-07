fn main() {
    // The cmake crate's Debug build compiles with -g, so the objects record
    // the compiler's switches (-frandom-seed among them) in debug info.
    let dst = cmake::Config::new("csrc").build();
    // CMake's build tree stays in OUT_DIR (dst/build); breakbulk-unit
    // removes CMake's internal state from it after the run (decision 65),
    // so `nix build --rebuild` of the run is clean.
    println!("cargo::rustc-link-search=native={}/lib", dst.display());
    println!("cargo::rustc-link-lib=static=cm");
    println!("cargo::rerun-if-changed=csrc");
}
