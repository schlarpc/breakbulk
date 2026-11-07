/// The path of this file as `file!()` sees it.
pub fn where_am_i() -> &'static str {
    file!()
}

/// Formats a number with the registry crate `itoa`.
pub fn format(n: u32) -> String {
    let mut b = itoa::Buffer::new();
    format!("formatted {}", b.format(n))
}

/// Panics, so the panic location (this file) is compiled in.
#[inline(never)]
pub fn boom(n: u32) -> u32 {
    if n > 3 {
        panic!("boom {n}");
    }
    n
}

#[cfg(test)]
mod tests {
    #[test]
    fn location() {
        assert!(super::where_am_i().ends_with("lib.rs"));
    }

    #[test]
    #[should_panic(expected = "boom 9")]
    fn panics() {
        super::boom(9);
    }

    #[test]
    fn formats() {
        assert_eq!(super::format(5), "formatted 5");
    }
}
