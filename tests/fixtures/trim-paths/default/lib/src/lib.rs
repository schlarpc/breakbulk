/// Where the shared crate's code says it is.
pub fn paths() -> [&'static str; 2] {
    [shared::where_am_i(), shared::generated_at()]
}

#[cfg(test)]
mod tests {
    #[test]
    fn remapped() {
        let [src, generated] = super::paths();
        assert_eq!(src, "/cargo/deps/shared-0.1.0/src/lib.rs");
        assert!(generated.starts_with("/cargo/build-dir/"), "{generated}");
        assert!(generated.ends_with("/out/gen.rs"), "{generated}");
        assert_eq!(file!(), "lib/src/lib.rs");
    }

    #[test]
    #[should_panic(expected = "boom 9")]
    fn panics() {
        shared::boom(9);
    }
}
