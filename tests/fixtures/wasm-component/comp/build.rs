// C for wasm32, with the target spec's clang and wasilibc headers; the C
// code calls libc (strlen, memcpy), so the package links wasilibc's libc.a
// (the preset puts its directory on the link path).
fn main() {
    cc::Build::new().file("csrc/checksum.c").compile("checksum");
    println!("cargo::rustc-link-lib=static=c");
    println!("cargo::rerun-if-changed=csrc/checksum.c");
}
