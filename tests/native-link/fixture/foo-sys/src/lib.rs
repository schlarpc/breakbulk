extern "C" {
    fn foo_answer() -> i32;
}

/// The answer from the C library.
pub fn answer() -> i32 {
    unsafe { foo_answer() }
}
