fn main() {
    // Reaches rustdoc's process, so doctests can read it with env!.
    println!("cargo::rustc-env=DD_FROM_BUILD=from-build-script");
    println!("cargo::rustc-cfg=dd_cfg");
    println!("cargo::rustc-check-cfg=cfg(dd_cfg)");
    let out = std::env::var("OUT_DIR").unwrap();
    println!("cargo::rustc-link-search=native={out}");
}
