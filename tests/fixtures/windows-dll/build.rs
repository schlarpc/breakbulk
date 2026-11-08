use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let target = env::var("TARGET").unwrap();
    // The target's C compiler, as the preset gives it (CC_<target>).
    let var = format!("CC_{}", target.replace('-', "_"));
    let cc = env::var(&var).unwrap_or_else(|_| panic!("{var} is not set"));
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let status = Command::new(&cc)
        .arg("-shared")
        .arg("-o")
        .arg(out.join("bbdll.dll"))
        .arg("csrc/bbdll.c")
        .arg(format!(
            "-Wl,--out-implib,{}",
            out.join("libbbdll.dll.a").display()
        ))
        .arg("-static-libgcc")
        .status()
        .unwrap();
    assert!(status.success(), "{cc} failed");
    // As sdl2-sys (`bundled`) does: copy the DLL next to the binaries,
    // two directories above the one named after the package
    // (`target/<triple>/<profile>`), where Windows finds it beside the .exe
    // (#23).
    let pkg = env::var("CARGO_PKG_NAME").unwrap();
    let mut dir = out.clone();
    while !dir.file_name().unwrap().to_string_lossy().contains(&pkg) {
        assert!(dir.pop(), "no directory named after {pkg} above {}", out.display());
    }
    dir.pop();
    dir.pop();
    std::fs::copy(out.join("bbdll.dll"), dir.join("bbdll.dll")).unwrap();
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=dylib=bbdll");
    println!("cargo::rerun-if-changed=csrc/bbdll.c");
}
