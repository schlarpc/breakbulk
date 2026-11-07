// C for wasm32-wasip2: snprintf and strlen come from wasi-libc, so the
// headers the C compiler sees and the libc.a the link uses must be the
// same wasi-libc build.
fn main() {
    cc::Build::new().file("csrc/fmt.c").compile("fmt");
    println!("cargo::rerun-if-changed=csrc/fmt.c");
}
