//! Reads a fixture in `tests/` at compile time and one in `testdata/` at
//! run time, from the package directory (the working directory).

#[test]
fn reads_fixtures() {
    assert_eq!(include_str!("fixtures/input.txt").trim(), "42");
    let more = std::fs::read_to_string("testdata/more.txt").unwrap();
    assert_eq!(more.trim(), proto::answer().to_string());
}
