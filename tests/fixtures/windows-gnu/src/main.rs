unsafe extern "C" {
    fn smoke_add(a: u32, b: u32) -> u32;
    fn smoke_pid() -> std::ffi::c_ulong;
}

/// C code compiled by the mingw gcc.
fn c_add(a: u32, b: u32) -> u32 {
    unsafe { smoke_add(a, b) }
}

fn pid_matches() -> bool {
    (unsafe { smoke_pid() }) as u32 == std::process::id()
}

/// Unwinding through a panic (libgcc_eh on windows-gnu).
fn caught() -> bool {
    std::panic::catch_unwind(|| panic!("expected")).is_err()
}

fn main() {
    println!(
        "gnu-smoke: c_add={} pid_match={} unwind={}",
        c_add(2, 40),
        pid_matches(),
        caught()
    );
}

#[cfg(test)]
mod tests {
    #[test]
    fn c_code() {
        assert_eq!(super::c_add(2, 40), 42);
    }

    #[test]
    fn pid() {
        assert!(super::pid_matches());
    }

    #[test]
    fn unwinds() {
        assert!(super::caught());
    }

    #[test]
    fn is_windows_gnu() {
        assert!(cfg!(all(windows, target_env = "gnu")));
    }
}
