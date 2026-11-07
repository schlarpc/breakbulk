fn main() {
    println!(
        "cargo::rustc-env=FROM_BUILD={}",
        helper::helper() + shared::shared()
    );
    println!("cargo::rerun-if-changed=build.rs");
}
