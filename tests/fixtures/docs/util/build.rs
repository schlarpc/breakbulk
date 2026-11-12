fn main() {
    println!("cargo::rustc-cfg=util_generated");
    println!("cargo::rustc-check-cfg=cfg(util_generated)");
    println!("cargo::rustc-env=UTIL_NOTE=Set by the build script.");
}
