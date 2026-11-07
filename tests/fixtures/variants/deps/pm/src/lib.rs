use proc_macro::TokenStream;

/// Defines `fn answer() -> u32`.
#[proc_macro]
pub fn make_answer(_: TokenStream) -> TokenStream {
    "fn answer() -> u32 { 42 }".parse().unwrap()
}
