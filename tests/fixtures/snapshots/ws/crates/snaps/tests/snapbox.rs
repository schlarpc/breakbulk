#[test]
fn render() {
    snapbox::assert_data_eq!(snaps::render(), snapbox::file!["snapbox/render.txt"]);
}
