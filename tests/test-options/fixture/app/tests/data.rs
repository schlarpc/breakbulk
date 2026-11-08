use std::path::Path;

#[test]
fn reads_listed_data() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    assert_eq!(Path::new(&dir), std::env::current_dir().unwrap());
    let input = std::fs::read_to_string("data/input.txt").unwrap();
    assert_eq!(app::quad(input.trim().parse().unwrap()), 20);
}
