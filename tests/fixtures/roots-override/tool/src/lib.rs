/// ```
/// assert_eq!(tool::greeting(), "hello");
/// ```
pub fn greeting() -> &'static str {
    "hello"
}

#[cfg(test)]
mod tests {
    #[test]
    fn greets() {
        assert_eq!(super::greeting(), "hello");
    }
}
