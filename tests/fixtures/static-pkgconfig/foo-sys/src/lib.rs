unsafe extern "C" {
    fn bbfoo_answer() -> i32;
}

/// The answer, from libbbfoo.
pub fn answer() -> i32 {
    unsafe { bbfoo_answer() }
}
