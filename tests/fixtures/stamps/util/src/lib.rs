pub fn describe(n: u64) -> String {
    let mut b = itoa::Buffer::new();
    format!("util:{}:{}", b.format(n), env!("UTIL_BUILT"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn describes() {
        assert_eq!(super::describe(3), "util:3:yes");
    }
}
