unsafe extern "C" {
    fn bb_header_glibc_minor() -> i32;
    fn bb_runtime_glibc(buf: *mut u8, n: usize) -> i32;
}

fn header_minor() -> i32 {
    unsafe { bb_header_glibc_minor() }
}

fn runtime() -> String {
    let mut buf = [0u8; 32];
    let n = unsafe { bb_runtime_glibc(buf.as_mut_ptr(), buf.len()) };
    String::from_utf8_lossy(&buf[..n as usize]).into_owned()
}

fn main() {
    // Threads, time and env: std's usual glibc imports.
    let t = std::thread::spawn(|| std::env::args().count()).join().unwrap();
    let _ = std::time::SystemTime::now();
    println!("zig: headers=2.{} args={t} runtime={}", header_minor(), runtime());
}

#[cfg(test)]
mod tests {
    #[test]
    fn built_against_old_headers() {
        assert_eq!(super::header_minor(), 17);
    }

    #[test]
    fn runs_on_new_glibc() {
        let v = super::runtime();
        assert!(v.starts_with("2."), "{v}");
    }

    // Set by the container test run (tests/presets/extra-targets.nix, zig-centos7-*):
    // the glibc the test binary really runs on.
    #[test]
    fn runs_on_expected_glibc() {
        if let Ok(want) = std::env::var("BB_EXPECT_RUNTIME_GLIBC") {
            assert_eq!(super::runtime(), want);
        }
    }

    #[test]
    fn unwinds() {
        assert!(std::panic::catch_unwind(|| panic!("expected")).is_err());
    }
}
