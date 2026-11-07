// Records which of the other packages' variables this build script sees.
// With per-package captures it sees none of them.
fn main() {
    let seen: Vec<&str> = ["PKG_CONFIG_PATH", "LIBCLANG_PATH", "BB_MARKER"]
        .into_iter()
        .filter(|v| std::env::var_os(v).is_some())
        .collect();
    let saw = if seen.is_empty() {
        "none".to_owned()
    } else {
        seen.join(",")
    };
    println!("cargo::rustc-env=PLAIN_SAW={saw}");
    for v in ["PKG_CONFIG_PATH", "LIBCLANG_PATH", "BB_MARKER"] {
        println!("cargo::rerun-if-env-changed={v}");
    }
}
