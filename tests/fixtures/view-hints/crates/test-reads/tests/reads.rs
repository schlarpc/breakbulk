//! Reads a file outside its package at compile time.

#[test]
fn reads() {
    let data = include_str!("../../../shared/data.txt");
    assert_eq!(data.trim(), test_reads::answer().to_string());
}
