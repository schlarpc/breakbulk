// An out-of-line module in a mod-rs file: src/plain.rs.
pub mod plain;
// A directory module: src/dir/mod.rs.
pub mod dir;
// A non-mod-rs file with children: src/nested.rs, src/nested/….
pub mod nested;
// `#[path]` in a mod-rs file: relative to its directory.
#[path = "elsewhere/renamed.rs"]
pub mod renamed;
// An out-of-line module inside an inline one: src/inline/child.rs.
pub mod inline {
    pub mod child;
}
// `#[path]` inside an inline module: src/inline_path/deep.rs.
pub mod inline_path {
    #[path = "deep.rs"]
    pub mod deep;
}
// A module behind a false cfg: rustc reads nothing for it.
#[cfg(any())]
mod gone;

// Includes: relative to this file, and under CARGO_MANIFEST_DIR.
pub const TEXT: &str = include_str!("data/text.txt");
pub const BYTES: &[u8] = include_bytes!("../assets/blob.bin");
pub const NUMBER: u32 = include!("data/number.in");
pub const NOTE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/note.txt"));
