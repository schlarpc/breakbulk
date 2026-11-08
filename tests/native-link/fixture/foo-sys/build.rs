fn main() {
    // The library only: where it lives comes from the environment, as with
    // a system library found by the linker's default search path.
    println!("cargo:rustc-link-lib=foo");
}
