//! A library whose tests depend on no build script.
//!
//! ```
//! assert_eq!(quiet::add(2, 2), 4);
//! ```

pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 2), 4);
    }
}
