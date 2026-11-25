mod a;

pub const DATA: &str = include_str!("data.txt");
pub const PAGE: &str = reader::page!();
pub const PROTO: &str = env!("PROTO");

pub fn answer() -> u32 {
    a::forty() + 2
}

// Read by the unit tests only: the library's other compiles do not see it.
#[cfg(test)]
mod tests {
    const EXPECTED: &str = include_str!("expected.txt");

    #[test]
    fn data_beside_the_manifest() {
        let p = concat!(env!("CARGO_MANIFEST_DIR"), "/src/data.txt");
        assert_eq!(std::fs::read_to_string(p).unwrap(), EXPECTED);
    }
}
