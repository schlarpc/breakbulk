//! Reads a file in its own package directory, which a `sources` function
//! can leave out of its view.

pub const DATA: &str = include_str!("../data.txt");
