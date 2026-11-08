use std::ffi::{CStr, c_char};

unsafe extern "C" {
    fn where_c() -> *const c_char;
}

fn main() {
    // SAFETY: where_c returns a static NUL-terminated string.
    let c = unsafe { CStr::from_ptr(where_c()) };
    println!("c is {}", c.to_str().unwrap());
}
