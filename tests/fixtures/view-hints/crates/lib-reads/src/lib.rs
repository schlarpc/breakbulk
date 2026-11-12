//! Reads a file outside its package at compile time.

pub const DATA: &str = include_str!("../../../shared/data.txt");
