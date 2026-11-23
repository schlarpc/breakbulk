use std::path::PathBuf;

fn main() {
    // No settings of its own: libclang and the clang arguments (the
    // target with its API level, the NDK's sysroot) come from
    // presets.android's LIBCLANG_PATH and BINDGEN_EXTRA_CLANG_ARGS_<target>.
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    bindgen::Builder::default()
        .header("csrc/wrapper.h")
        .allowlist_function("__android_log_write")
        .allowlist_type("android_LogPriority")
        .allowlist_item("BB_ANDROID_API")
        .generate()
        .expect("bindgen failed")
        .write_to_file(out.join("bindings.rs"))
        .unwrap();
    println!("cargo::rustc-link-lib=log");
    println!("cargo::rerun-if-changed=csrc");
}
