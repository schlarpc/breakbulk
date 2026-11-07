fn main() {
    // cc picks CC_<target>, AR_<target> and CFLAGS_<target> from the env.
    cc::Build::new().file("csrc/smoke.c").compile("smoke");
    println!("cargo:rerun-if-changed=csrc/smoke.c");
}
