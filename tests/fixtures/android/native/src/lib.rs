use std::ffi::{CStr, c_char, c_int, c_ulong};

unsafe extern "C" {
    fn scale(x: c_int) -> c_int;
    fn api_level() -> c_int;
    fn source_file() -> *const c_char;
    fn describe(buf: *mut c_char, len: c_ulong, x: c_int) -> c_int;
}

/// What an app calls, through JNI or another FFI.
#[unsafe(no_mangle)]
pub extern "C" fn native_scale(x: c_int) -> c_int {
    unsafe { scale(x) }
}

pub fn description(x: i32) -> String {
    let mut buf = [0 as c_char; 64];
    unsafe { describe(buf.as_mut_ptr(), buf.len() as c_ulong, x) };
    unsafe { CStr::from_ptr(buf.as_ptr()) }
        .to_str()
        .unwrap()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_through_c() {
        assert_eq!(native_scale(14), 42);
        assert_eq!(description(7), "c scales 7 to 21");
    }

    #[test]
    fn compiled_for_the_api_level() {
        assert_eq!(unsafe { api_level() }, 26);
    }

    #[test]
    fn c_source_path_is_remapped() {
        let f = unsafe { CStr::from_ptr(source_file()) }.to_str().unwrap();
        assert!(!f.starts_with("/nix/store"), "{f}");
        assert!(f.ends_with("csrc/scale.c"), "{f}");
    }

    #[test]
    fn runs_on_android() {
        assert!(cfg!(target_os = "android"));
        assert!(std::path::Path::new("/system/build.prop").exists());
    }
}
