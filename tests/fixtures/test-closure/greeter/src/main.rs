//! Loads `libgreet.so`, which the build script built, by name: only the
//! dynamic-library path finds it (no rpath names it).

use std::ffi::{c_char, c_int, c_void, CStr};

extern "C" {
    fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *mut c_char;
}

const RTLD_NOW: c_int = 2;

fn main() {
    unsafe {
        let lib = dlopen(c"libgreet.so".as_ptr(), RTLD_NOW);
        if lib.is_null() {
            eprintln!("dlopen: {}", CStr::from_ptr(dlerror()).to_string_lossy());
            std::process::exit(1);
        }
        let f = dlsym(lib, c"greet".as_ptr());
        assert!(!f.is_null(), "no symbol greet");
        let greet: extern "C" fn() -> c_int = std::mem::transmute(f);
        println!("greet={}", greet());
    }
}
