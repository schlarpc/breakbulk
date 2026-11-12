fn greeting() -> &'static str {
    "hello"
}

#[no_mangle]
pub extern "C" fn greeting_len() -> u32 {
    greeting().len() as u32
}

#[cfg(test)]
mod tests {
    #[test]
    fn greets() {
        assert_eq!(super::greeting_len(), 5);
    }
}
