#[test]
fn integration_greets() {
    assert_eq!(app::greet(-1, "it"), "c says -1 to it (2)");
}
