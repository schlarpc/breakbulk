//! Reads a file outside its package in a doctest.

/// The answer, as `shared/data.txt` has it:
///
/// ```
/// let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../shared/data.txt");
/// let data = std::fs::read_to_string(p).unwrap_or_else(|e| panic!("reading {p}: {e}"));
/// assert_eq!(data.trim(), doc_reads::answer().to_string());
/// ```
pub fn answer() -> u32 {
    42
}
