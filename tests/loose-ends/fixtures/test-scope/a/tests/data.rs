//! Reads a repository file outside the package directory at run time,
//! relative to the working directory (the package directory, as under
//! `cargo test`) and to `CARGO_MANIFEST_DIR`.

#[test]
fn reads_testdata() {
    let rel = std::fs::read_to_string("../testdata/expected.txt").unwrap();
    let dir = env!("CARGO_MANIFEST_DIR");
    let abs = std::fs::read_to_string(format!("{dir}/../testdata/expected.txt")).unwrap();
    assert_eq!(rel, abs);
    assert_eq!(a::shout(rel.trim()), "EXPECTED");
}
