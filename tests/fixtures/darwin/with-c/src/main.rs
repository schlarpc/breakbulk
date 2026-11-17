use std::ffi::{CStr, c_char, c_int, c_ulong};

unsafe extern "C" {
    fn greet(buf: *mut c_char, len: c_ulong, n: c_int) -> c_int;
}

fn main() {
    let mut buf = [0 as c_char; 64];
    unsafe { greet(buf.as_mut_ptr(), buf.len() as c_ulong, 21) };
    let s = unsafe { CStr::from_ptr(buf.as_ptr()) };
    println!("{}", s.to_str().unwrap());
}
