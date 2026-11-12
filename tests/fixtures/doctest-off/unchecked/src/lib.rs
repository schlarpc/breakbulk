/// Two.
///
/// ```
/// assert_eq!(unchecked::two(), 3, "this doctest fails by design");
/// ```
pub fn two() -> u32 {
    2
}

#[cfg(test)]
mod tests {
    #[test]
    fn two() {
        assert_eq!(super::two(), 2);
    }
}
