fn main() {
    println!("cargo::rustc-check-cfg=cfg(shared_cfg)");
    println!("cargo::rustc-cfg=shared_cfg");
}
