fn main() {
    println!("cargo::rustc-check-cfg=cfg(gitbase_cfg)");
    println!("cargo::rustc-cfg=gitbase_cfg");
}
