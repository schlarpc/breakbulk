pub fn quad(x: u32) -> u32 {
    util::double(util::double(x))
}

#[cfg(test)]
mod tests {
    #[test]
    fn quads() {
        assert_eq!(super::quad(3), 12);
    }
}
