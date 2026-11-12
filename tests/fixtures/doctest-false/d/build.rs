fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    println!("cargo::rustc-link-search=native={out}");
    println!("cargo::rustc-env=D_FROM_BUILD=from-build-script");
}
