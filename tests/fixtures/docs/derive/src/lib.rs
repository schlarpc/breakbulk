//! A derive macro for `util`'s types.

use proc_macro::TokenStream;

/// Derives nothing; it only has to be documented.
#[proc_macro_derive(Describe)]
pub fn describe(_input: TokenStream) -> TokenStream {
    TokenStream::new()
}
