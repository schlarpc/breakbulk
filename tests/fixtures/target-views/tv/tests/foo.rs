mod common;

#[test]
fn foo() {
    assert_eq!(tv::answer(), common::expected());
}
