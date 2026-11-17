fn main() {
    // cc picks CC_<target>, AR_<target> and CFLAGS_<target> (the SDK as
    // -isysroot) from the env.
    cc::Build::new().file("csrc/greet.c").compile("greet");
    println!("cargo:rerun-if-changed=csrc/greet.c");
}
