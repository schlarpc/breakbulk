use std::path::PathBuf;

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let profile = std::env::var("PROFILE").unwrap();
    std::fs::write(
        out.join("generated.rs"),
        format!("pub const PROFILE: &str = {profile:?};\npub const ANSWER: u64 = 6 * 7;\n"),
    )
    .unwrap();
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rustc-cfg=walking_skeleton");
    println!("cargo::rustc-check-cfg=cfg(walking_skeleton)");
    println!("cargo::rustc-env=WS_FROM_BUILD=hello-from-build-script");
}
