#[test]
fn reads_run_data() {
    let s = std::fs::read_to_string("data/input.txt").expect("reading data/input.txt");
    assert_eq!(s.trim(), lint::answer().to_string());
}
