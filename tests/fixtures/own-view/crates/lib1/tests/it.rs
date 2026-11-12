// A test unit of a member: compiled in the workspace root, in lib1's test
// view.
#[test]
fn own_view() {
    assert_eq!(lib1::OWN.trim(), "lib1 data");
    assert_eq!(lib1::ASSETS.trim(), "asset v1");
    assert_eq!(lib1::number(42), "42");
}
