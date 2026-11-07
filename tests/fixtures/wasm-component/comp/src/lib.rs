use std::ffi::{CStr, c_char};

unsafe extern "C" {
    fn c_checksum(s: *const c_char) -> u32;
}

/// FNV-1a of "breakbulk", computed by the C code.
#[unsafe(no_mangle)]
pub extern "C" fn checksum() -> u32 {
    let s: &CStr = c"breakbulk";
    unsafe { c_checksum(s.as_ptr()) }
}
