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
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=dylib=bbdll");
    println!("cargo::rerun-if-changed=csrc/bbdll.c");
}
