/// Shouts twice.
pub fn shout_twice(s: &str) -> String {
    a::shout(s).repeat(2)
}

#[cfg(test)]
mod tests {
    #[test]
    fn twice() {
        assert_eq!(super::shout_twice("b"), "BB");
    }
}
