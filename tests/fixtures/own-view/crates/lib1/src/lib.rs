// Cargo compiles this crate in the workspace root (the root package's
// directory), as `crates/lib1/src/lib.rs`.

// The repository root, in lib1's own view, which holds lib1's directory.
pub const OWN: &str = include_str!(concat!(env!("BB_ROOT"), "crates/lib1/data/lib1.txt"));
// A root-level directory: lib1 lists it in extraSources.
pub const ASSETS: &str = include_str!(concat!(env!("BB_ASSETS"), "/data.txt"));

pub fn number(n: u32) -> String {
    itoa::Buffer::new().format(n).to_owned()
}
