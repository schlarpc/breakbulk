fn main() {
    // The cmake crate's Debug build compiles with -g, so the objects record
    // the compiler's switches (-frandom-seed among them) in debug info.
    let dst = cmake::Config::new("csrc").build();
    println!("cargo::rustc-link-search=native={}/lib", dst.display());
    println!("cargo::rustc-link-lib=static=cm");
    println!("cargo::rerun-if-changed=csrc");
}
