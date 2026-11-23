use std::ffi::{c_char, c_int};

unsafe extern "C" {
    fn count_words(s: *const c_char) -> c_int;
}

/// What an app calls: counts the words of `s` in C++, -1 for a double
/// space, and logs the count.
#[unsafe(no_mangle)]
pub extern "C" fn cpp_count_words(s: *const c_char) -> c_int {
    let n = unsafe { count_words(s) };
    alog_sys::info(c"cpp", c"counted words");
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    unsafe extern "C" {
        fn cxx_source_file() -> *const c_char;
    }

    #[test]
    fn counts_through_cxx() {
        assert_eq!(cpp_count_words(c"one two three".as_ptr()), 3);
    }

    #[test]
    fn cxx_exceptions_unwind() {
        assert_eq!(cpp_count_words(c"one  two".as_ptr()), -1);
    }

    #[test]
    fn cxx_source_path_is_remapped() {
        let f = unsafe { CStr::from_ptr(cxx_source_file()) }.to_str().unwrap();
        assert!(!f.starts_with("/nix/store"), "{f}");
        assert!(f.ends_with("cxxsrc/words.cpp"), "{f}");
    }
}
