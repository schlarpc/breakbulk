use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    std::fs::write(out.join("gen.rs"), "pub const GENERATED: u32 = 42;\n").unwrap();
    std::fs::create_dir_all(out.join("native")).unwrap();
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rustc-cfg=smoke_cfg");
    println!("cargo::rustc-check-cfg=cfg(smoke_cfg)");
    println!("cargo::rustc-env=SMOKE_ENV=hello-from-build");
    println!(
        "cargo::rustc-link-search=native={}",
        out.join("native").display()
    );
    println!("cargo::warning=smoke build script ran");
}
