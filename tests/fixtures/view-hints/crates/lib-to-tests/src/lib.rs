//! Hands its tests the path of a fixture in `tests/`, built from
//! `CARGO_MANIFEST_DIR` when the library is compiled.

pub const FIXTURE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/input.txt");
