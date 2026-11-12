//! Reads a file outside its package at run time, from the package
//! directory (the working directory).

#[test]
fn reads_at_run_time() {
    let p = "../../shared/data.txt";
    let data = std::fs::read_to_string(p).unwrap_or_else(|e| panic!("reading {p}: {e}"));
    assert_eq!(data.trim(), run_reads::answer().to_string());
}
