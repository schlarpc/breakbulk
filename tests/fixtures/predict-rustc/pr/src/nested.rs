// From a non-mod-rs file: src/nested/inner.rs.
pub mod inner;
// `#[path]` inside an inline module of a non-mod-rs file:
// src/nested/tricky/t.rs.
pub mod tricky {
    #[path = "t.rs"]
    pub mod t;
}
