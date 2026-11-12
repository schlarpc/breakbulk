#[test]
fn reads_the_fixture() {
    let p = lib_to_tests::FIXTURE;
    let data = std::fs::read_to_string(p).unwrap_or_else(|e| panic!("reading {p}: {e}"));
    assert_eq!(data.trim(), "42");
}
