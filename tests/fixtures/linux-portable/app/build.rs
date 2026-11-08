fn main() {
    // CC_<target> is zig cc for the old glibc.
    cc::Build::new().file("csrc/old.c").compile("old");
    println!("cargo::rerun-if-changed=csrc/old.c");
}
