use std::{env, path::PathBuf, process::Command};

fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());

    // C: cc picks CC_<target>, AR_<target> and CFLAGS_<target> from the env.
    cc::Build::new().file("csrc/smoke.c").compile("smoke");

    // bindgen: libclang parses the header for the target, with the SDK
    // include paths from BINDGEN_EXTRA_CLANG_ARGS_<target>.
    bindgen::Builder::default()
        .header("csrc/smoke.h")
        .allowlist_function("smoke_.*")
        .allowlist_function("GetCurrentProcessId")
        .generate()
        .expect("bindgen")
        .write_to_file(out.join("bindings.rs"))
        .unwrap();

    // A resource: $RC (llvm-rc) compiles it to a .res, which lld-link embeds.
    let rc = env::var("RC").expect("RC must name a resource compiler");
    let rcflags = env::var("RCFLAGS").unwrap_or_default();
    let res = out.join("smoke.res");
    let status = Command::new(&rc)
        .args(rcflags.split_whitespace())
        .arg("/fo")
        .arg(&res)
        .arg("csrc/smoke.rc")
        .status()
        .expect("running RC");
    assert!(status.success(), "{rc} failed");
    println!("cargo:rustc-link-arg-bins={}", res.display());

    for f in ["csrc/smoke.c", "csrc/smoke.h", "csrc/smoke.rc"] {
        println!("cargo:rerun-if-changed={f}");
    }
    for v in ["RC", "RCFLAGS"] {
        println!("cargo:rerun-if-env-changed={v}");
    }
}
