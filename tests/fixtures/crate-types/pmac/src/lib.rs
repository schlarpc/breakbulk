use proc_macro::TokenStream;

/// Expands to a string literal naming the macro's crate.
#[proc_macro]
pub fn from_macro(_: TokenStream) -> TokenStream {
    "\"from-proc-macro\"".parse().unwrap()
}
