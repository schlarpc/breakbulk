//! An integration test without the libtest harness: it reads a fixture in
//! `tests/` at compile time and one in `testdata/` at run time.

fn main() {
    assert_eq!(include_str!("fixtures/input.txt").trim(), "42");
    let more = std::fs::read_to_string("testdata/more.txt").unwrap();
    assert_eq!(more.trim(), proto::answer().to_string());
    println!("datadriven: ok");
}
