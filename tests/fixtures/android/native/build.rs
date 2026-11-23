fn main() {
    // cc picks CC_<target> and AR_<target>: presets.android's NDK clang,
    // named as the NDK's drivers, so cc adds no --target of its own.
    cc::Build::new().file("csrc/scale.c").compile("scale");
    println!("cargo:rerun-if-changed=csrc/scale.c");
}
