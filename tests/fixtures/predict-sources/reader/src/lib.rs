//! `page!()`: the caller's `templates/page.txt` as a string literal, read
//! from its CARGO_MANIFEST_DIR as template engines do.
use proc_macro::TokenStream;

#[proc_macro]
pub fn page(_: TokenStream) -> TokenStream {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let path = format!("{dir}/templates/page.txt");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("couldn't read `{path}`: {e}"));
    format!("{text:?}").parse().unwrap()
}
