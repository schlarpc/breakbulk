use std::{env, fs, path::Path};

fn main() {
    println!("cargo::rerun-if-env-changed=MYLIB_DIR");
    println!("cargo::rerun-if-changed=../vendor/mylib.txt");
    let vendored = fs::read_to_string("../vendor/mylib.txt").expect("read ../vendor/mylib.txt");
    let dir = env::var("MYLIB_DIR").expect("MYLIB_DIR is not set");
    let header = fs::read_to_string(Path::new(&dir).join("include/mylib.h")).expect("read mylib.h");
    println!("cargo::rustc-env=MYLIB_VERSION={}", header.trim());
    println!("cargo::rustc-env=MYLIB_VENDORED={}", vendored.trim());
}
