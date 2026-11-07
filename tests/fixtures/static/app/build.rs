// C code for the target, compiled with the target spec's CC_<triple>. The
// build script itself is a host binary and stays dynamically linked.
fn main() {
    cc::Build::new().file("csrc/mix.c").compile("mix");
    println!("cargo::rerun-if-changed=csrc/mix.c");
}
