#[test]
fn reads_notes() {
    let notes = std::fs::read_to_string("notes.md").expect("reading notes.md");
    assert!(notes.contains("notes"));
}
