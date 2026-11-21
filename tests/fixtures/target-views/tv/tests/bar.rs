mod common;

#[test]
fn bar() {
    assert_eq!(tv::answer(), common::expected());
}
