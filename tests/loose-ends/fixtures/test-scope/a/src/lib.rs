/// Shouts.
///
/// ```
/// assert_eq!(a::shout("hi"), "HI");
/// ```
pub fn shout(s: &str) -> String {
    s.to_uppercase()
}

#[cfg(test)]
mod tests {
    #[test]
    fn shouts() {
        assert_eq!(super::shout("a"), "A");
    }
}
