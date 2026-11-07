/// Callable from Rust (rlib) and from C (cdylib).
#[unsafe(no_mangle)]
pub extern "C" fn both_answer() -> u32 {
    42
}
