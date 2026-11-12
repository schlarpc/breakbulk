fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=../shared/version.txt");
    let version = std::fs::read_to_string("../shared/version.txt")
        .map(|v| v.trim().to_owned())
        .unwrap_or_else(|_| "unknown".to_owned());
    println!("cargo::rustc-env=SHARED_VERSION={version}");
}
