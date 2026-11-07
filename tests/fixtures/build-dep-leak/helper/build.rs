// Links an (empty) static library that exists only for host builds.
fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::write(format!("{out}/libhelper_host_marker.a"), b"!<arch>\n").unwrap();
    println!("cargo::rustc-link-search=native={out}");
    println!("cargo::rustc-link-lib=static=helper_host_marker");
    println!("cargo::rustc-link-arg=-Wl,--defsym=helper_host_marker_arg=0");
    println!("cargo::rustc-cfg=helper_cfg");
    println!("cargo::rustc-check-cfg=cfg(helper_cfg)");
    println!("cargo::rerun-if-changed=build.rs");
}
