fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::create_dir_all(format!("{out}/lib")).unwrap();
    println!("cargo::rustc-cfg=tiny_cfg");
    println!("cargo::rustc-check-cfg=cfg(tiny_cfg)");
    println!("cargo::rustc-link-search=native={out}/lib");
    println!("cargo::metadata=root={out}");
    println!("cargo::rerun-if-changed=build.rs");
}
