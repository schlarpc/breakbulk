unsafe extern "C" {
    fn bbdll_answer() -> i32;
}

/// The answer, from bbdll.dll.
pub fn answer() -> i32 {
    unsafe { bbdll_answer() }
}

#[cfg(test)]
mod tests {
    #[test]
    fn calls_the_dll() {
        assert_eq!(super::answer(), 42);
    }
}
