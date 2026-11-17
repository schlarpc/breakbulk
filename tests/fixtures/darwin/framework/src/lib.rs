use std::ffi::{c_char, c_void};

// CoreFoundation, a framework from the SDK (System/Library/Frameworks).
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        s: *const c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFStringGetLength(s: *const c_void) -> isize;
    fn CFRelease(cf: *const c_void);
}

const UTF8: u32 = 0x0800_0100;

/// The length of `s` as CoreFoundation counts it.
#[unsafe(no_mangle)]
pub extern "C" fn cf_length(s: *const c_char) -> isize {
    unsafe {
        let cf = CFStringCreateWithCString(std::ptr::null(), s, UTF8);
        let n = CFStringGetLength(cf);
        CFRelease(cf);
        n
    }
}
