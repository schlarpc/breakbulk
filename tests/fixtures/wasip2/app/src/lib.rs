use std::ffi::CString;

unsafe extern "C" {
    fn bb_fmt(buf: *mut u8, n: usize, v: i32, who: *const std::ffi::c_char) -> i32;
}

/// Formats through C's snprintf (wasi-libc).
pub fn greet(v: i32, who: &str) -> String {
    let who = CString::new(who).unwrap();
    let mut buf = [0u8; 128];
    let n = unsafe { bb_fmt(buf.as_mut_ptr(), buf.len(), v, who.as_ptr()) };
    String::from_utf8_lossy(&buf[..n as usize]).into_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn greets() {
        assert_eq!(super::greet(7, "wasi"), "c says 7 to wasi (4)");
    }

    #[test]
    fn target_is_wasip2() {
        assert!(cfg!(all(target_os = "wasi", target_env = "p2")));
    }
}
