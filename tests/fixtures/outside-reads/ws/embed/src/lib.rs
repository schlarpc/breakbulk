//! `embed!("path")`: the file at `path`, relative to the calling crate's
//! CARGO_MANIFEST_DIR, as a string literal. Reads at compile time, outside
//! the proc macro's own directory.
use proc_macro::TokenStream;

#[proc_macro]
pub fn embed(input: TokenStream) -> TokenStream {
    let lit = input.to_string();
    let rel = lit.trim().trim_matches('"');
    let dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let path = std::path::Path::new(&dir).join(rel);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("embed!: cannot read {}: {e}", path.display()));
    format!("{text:?}").parse().unwrap()
}
