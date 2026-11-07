pub fn twice(x: u32) -> u32 {
    other::add(x, x)
}

#[cfg(test)]
mod tests {
    #[test]
    fn unit_ok() {
        assert_eq!(super::twice(2), 4);
    }
}
