extern "C" {
    fn cm_answer() -> i32;
}

pub fn answer() -> i32 {
    unsafe { cm_answer() }
}
