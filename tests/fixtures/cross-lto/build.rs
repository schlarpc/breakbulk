fn main() {
    // cc picks CC_<target>, AR_<target> and CFLAGS_<target> from the env.
    cc::Build::new().file("csrc/mix.c").compile("mix");
    println!("cargo:rerun-if-changed=csrc/mix.c");
}
